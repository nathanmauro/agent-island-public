import Darwin
import Foundation
import IslandCore

/// Append-only JSONL transition log (spec §9). One line per record. Before an append
/// would push the current file past `rotateBytes`, the files shift:
/// `transitions.1.jsonl` → `transitions.2.jsonl`, `transitions.jsonl` → `transitions.1.jsonl`,
/// keeping `keepFiles` files in total. The file is opened per append and closed again,
/// so the log holds no descriptor between writes. Thread-safe; callers append from a
/// background queue.
public final class TransitionLog: @unchecked Sendable {
    public let fileURL: URL
    private let rotateBytes: Int
    private let keepFiles: Int
    private let lock = NSLock()
    private let encoder = TransitionRecord.makeEncoder()
    private var reportedFailure = false

    public init(fileURL: URL, rotateBytes: Int = IslandTiming.logRotateBytes, keepFiles: Int = IslandTiming.logKeepFiles) {
        self.fileURL = fileURL
        self.rotateBytes = rotateBytes
        self.keepFiles = max(1, keepFiles)
    }

    /// `index` 0 is `fileURL`; 1… are the rotated files (`transitions.1.jsonl`, …).
    public func rotatedFileURL(index: Int) -> URL {
        guard index > 0 else { return fileURL }
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let pathExtension = fileURL.pathExtension
        let name = pathExtension.isEmpty ? "\(base).\(index)" : "\(base).\(index).\(pathExtension)"
        return directory.appendingPathComponent(name)
    }

    public func append(_ records: [TransitionRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            var payload = Data()
            for record in records {
                payload.append(try encoder.encode(record))
                payload.append(0x0A)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let currentSize = Self.fileSize(fileURL)
            if currentSize > 0, currentSize + payload.count > rotateBytes {
                try rotate()
            }
            try Self.appendData(payload, to: fileURL)
        } catch {
            guard !reportedFailure else { return }
            reportedFailure = true
            NSLog("Agent Island could not append to the transition log: %@", String(describing: error))
        }
    }

    private func rotate() throws {
        guard keepFiles > 1 else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        for index in stride(from: keepFiles - 1, through: 1, by: -1) {
            let source = rotatedFileURL(index: index - 1)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            // rename(2) atomically replaces the destination, which drops the oldest file.
            guard Darwin.rename(source.path, rotatedFileURL(index: index).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return 0 }
        return Int(metadata.st_size)
    }

    private static func appendData(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}

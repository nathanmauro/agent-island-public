import Darwin
import Foundation
import IslandCore

public enum RolloutReadResult: Equatable, Sendable {
    case lines([Data])
    /// The file shrank below the read offset or was replaced (new inode): cold-start it again.
    case reset
}

/// Reads complete lines appended to a rollout since `offset`. A trailing partial line is buffered
/// until its newline arrives. A line longer than `maxLineBytes` is dropped without buffering more
/// than `maxLineBytes` bytes of it.
public struct RolloutTailReader: Sendable {
    static let readChunk = 262_144

    private let url: URL
    public private(set) var offset: UInt64
    private var identity: RolloutFileIdentity?
    private var splitter = RolloutLineSplitter()

    public init(url: URL, startOffset: UInt64) {
        self.url = url
        offset = startOffset
        identity = RolloutFileIdentity(path: url.path)
    }

    /// Bytes of the unfinished last line currently held in memory (test seam).
    package var bufferedByteCount: Int { splitter.bufferedByteCount }

    public mutating func readNewLines(maxLineBytes: Int = IslandTiming.codexMaxLineBytes) throws -> RolloutReadResult {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RolloutFileIO.posixError() }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw RolloutFileIO.posixError() }
        let current = RolloutFileIdentity(metadata)
        if let identity, identity != current {
            return .reset
        }
        identity = current
        let size = UInt64(max(0, metadata.st_size))
        if size < offset {
            return .reset
        }
        var lines: [Data] = []
        var position = offset
        while position < size {
            let count = Int(min(UInt64(Self.readChunk), size - position))
            let chunk = try RolloutFileIO.read(descriptor, offset: position, count: count)
            if chunk.isEmpty { break }
            splitter.feed(chunk, maxLineBytes: maxLineBytes, into: &lines)
            position += UInt64(chunk.count)
        }
        offset = position
        return .lines(lines)
    }
}

struct RolloutFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(UInt32(bitPattern: metadata.st_dev))
        inode = metadata.st_ino
    }

    init?(path: String) {
        var metadata = stat()
        guard fstatat(AT_FDCWD, path, &metadata, 0) == 0 else { return nil }
        self.init(metadata)
    }
}

/// Splits a byte stream into "\n"-terminated lines. Empty lines are dropped.
struct RolloutLineSplitter: Sendable {
    private var partial = Data()
    private var skippingLongLine = false

    var bufferedByteCount: Int { partial.count }

    mutating func feed(_ chunk: Data, maxLineBytes: Int, into lines: inout [Data]) {
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = 0
            while cursor < raw.count {
                let remaining = raw.count - cursor
                let start = base.advanced(by: cursor)
                if let hit = memchr(start, 0x0A, remaining) {
                    let length = start.distance(to: UnsafeRawPointer(hit))
                    if skippingLongLine {
                        skippingLongLine = false
                    } else if partial.count + length <= maxLineBytes {
                        partial.append(start.assumingMemoryBound(to: UInt8.self), count: length)
                        if !partial.isEmpty { lines.append(partial) }
                    }
                    partial = Data()
                    cursor += length + 1
                } else {
                    if !skippingLongLine {
                        if partial.count + remaining <= maxLineBytes {
                            partial.append(start.assumingMemoryBound(to: UInt8.self), count: remaining)
                        } else {
                            partial = Data()
                            skippingLongLine = true
                        }
                    }
                    cursor = raw.count
                }
            }
        }
    }
}

enum RolloutFileIO {
    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// One pread of up to `count` bytes; fewer bytes at EOF.
    static func read(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { raw in
            pread(descriptor, raw.baseAddress, count, off_t(offset))
        }
        guard received >= 0 else { throw posixError() }
        data.count = received
        return data
    }

    /// Exactly [offset, offset + count), looping over short reads; shorter only at EOF.
    static func readExactly(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try read(descriptor, offset: offset + UInt64(data.count), count: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    static func firstIndex(of byte: UInt8, in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress, let hit = memchr(base, Int32(byte), raw.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    static func lastIndex(of byte: UInt8, in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = bytes.count - 1
            while index >= 0 {
                if bytes[index] == byte { return index }
                index -= 1
            }
            return nil
        }
    }

    static func occurrences(of token: [UInt8], in data: Data) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            guard let base = raw.baseAddress, raw.count >= token.count else { return [] }
            var result: [Int] = []
            var cursor = 0
            token.withUnsafeBytes { needle in
                while cursor <= raw.count - token.count,
                      let hit = memmem(base.advanced(by: cursor), raw.count - cursor, needle.baseAddress, needle.count) {
                    let index = base.distance(to: UnsafeRawPointer(hit))
                    result.append(index)
                    cursor = index + 1
                }
            }
            return result
        }
    }
}

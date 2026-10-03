import Foundation
import IslandCore

/// Wraps a FileReading and records every listing and every read attempt (recorded before the inner call, so an
/// attempt that fails still shows up). `failNextReads` holds file names whose next read throws once.
public final class FileAccessSpy: FileReading, @unchecked Sendable {
    private struct InjectedReadFailure: Error, CustomStringConvertible {
        let fileName: String
        var description: String { "injected read failure for \(fileName)" }
    }

    private let inner: any FileReading
    private let lock = NSLock()
    private var recordedReadPaths: [String] = []
    private var recordedDirectories: [String] = []
    private var pendingFailures: Set<String> = []

    public init(wrapping inner: any FileReading = LiveFileReader()) {
        self.inner = inner
    }

    public var readPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReadPaths
    }

    public var listedDirectories: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDirectories
    }

    public var failNextReads: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pendingFailures
        }
        set {
            lock.lock()
            pendingFailures = newValue
            lock.unlock()
        }
    }

    public func fileNames(in directory: URL) throws -> [String] {
        lock.lock()
        recordedDirectories.append(directory.path)
        lock.unlock()
        return try inner.fileNames(in: directory)
    }

    public func read(_ url: URL, maximumSize: Int) throws -> Data {
        lock.lock()
        recordedReadPaths.append(url.path)
        let shouldFail = pendingFailures.remove(url.lastPathComponent) != nil
        lock.unlock()
        if shouldFail { throw InjectedReadFailure(fileName: url.lastPathComponent) }
        return try inner.read(url, maximumSize: maximumSize)
    }
}

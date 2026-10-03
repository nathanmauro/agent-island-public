import Foundation

/// The registry feed's only file-system access, so tests can wrap it with `FileAccessSpy`.
public protocol FileReading: Sendable {
    /// Directory entry names (no paths). Listing never opens the entries.
    func fileNames(in directory: URL) throws -> [String]
    func read(_ url: URL, maximumSize: Int) throws -> Data
}

/// Lists with FileManager and reads with SecureFileReader: regular files owned by the user, not group- or
/// world-writable, no symlink at the final path component, at most `maximumSize` bytes. A read throws when the
/// file is rewritten while it is being read, which is why the registry feed tolerates failed reads.
public struct LiveFileReader: FileReading {
    public init() {}

    public func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    public func read(_ url: URL, maximumSize: Int) throws -> Data {
        try SecureFileReader.read(at: url, maximumSize: maximumSize, followSymlinks: false)
    }
}

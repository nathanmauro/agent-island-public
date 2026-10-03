import Darwin
import Foundation

/// Committed, masked or synthetic fixtures under <repo>/Tests/Fixtures. Paths resolve
/// from this file's location, so they work under `swift run` from any directory.
public enum Fixtures {
    /// <repo> (this file is <repo>/Tests/IslandTestSupport/Fixtures.swift).
    public static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// <repo>/Tests/Fixtures
    public static var root: URL {
        repositoryRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    public static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public static func string(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    public static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }
}

/// A fresh directory under the real (realpath-resolved) temporary directory. The
/// whole directory is removed when the object is released.
public final class TemporaryDirectory {
    public let url: URL

    public init(prefix: String = "island-tests") throws {
        let base = try TemporaryDirectory.realTemporaryDirectory()
        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A path inside the directory. Nothing is created.
    public func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// `FileManager.default.temporaryDirectory` resolved through `realpath(3)`, so
    /// `/var` becomes `/private/var` (URL.resolvingSymlinksInPath() does not reliably
    /// strip that prefix here). FSEvents reports the real, `/private`-prefixed path for
    /// anything written under this directory, so this keeps exact-path comparisons true.
    private static func realTemporaryDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(raw, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

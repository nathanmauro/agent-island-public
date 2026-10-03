import Foundation
import Darwin

public enum ResourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case bundleMissing(searched: [String])
    case resourceMissing(name: String, bundlePath: String)

    public var description: String {
        switch self {
        case let .bundleMissing(searched):
            """
            Agent Island resource bundle \(BundledResources.bundleName) not found. \
            Searched: \(searched.joined(separator: ", ")). Rebuild with scripts/build-app.sh.
            """
        case let .resourceMissing(name, bundlePath):
            "Agent Island resource \(name) is missing from \(bundlePath). Rebuild with scripts/build-app.sh."
        }
    }
}

public enum BundledResources {
    /// The name SwiftPM gives IslandCore's resource bundle: `<package>_<target>.bundle`.
    public static let bundleName = "AgentIsland_IslandCore.bundle"

    /// Official brand marks (Anthropic's Claude spark, sst/opencode's glyph,
    /// OpenAI's knot for Codex) — see NOTICE for trademark attribution.
    /// Herdr panes have no bundled mark (the row draws a system symbol), and
    /// an unreadable bundle degrades to nil rather than failing the row.
    public static func iconURL(for source: SessionSource) -> URL? {
        let name: String
        switch source {
        case .claudeRegistry: name = "claude"
        case .codexDesktop: name = "codex"
        case .herdr: return nil
        }
        return try? resourceURL(named: name, extension: "svg", subdirectory: "Resources/icons")
    }

    /// The resolved bundle itself, so `Installer` can ship a copy of it beside
    /// the binary it installs.
    public static var bundleURL: URL {
        get throws { try locatedBundle.get().bundleURL }
    }

    /// Locations that may hold the resource bundle, in priority order.
    ///
    /// SwiftPM's generated `Bundle.module` resolves only the directory holding
    /// the running executable and the absolute build directory of the machine
    /// that compiled it, so an installed app would read its icons out of the
    /// developer's `.build` tree. These are the two layouts Agent Island runs
    /// from, and none is a baked-in build path.
    public static func bundleSearchPaths(
        named bundleName: String = bundleName,
        executableURL: URL?,
        mainResourceURL: URL?
    ) -> [String] {
        var directories: [URL] = []
        if let executableDirectory = executableURL?.deletingLastPathComponent() {
            // .build/<config>/AgentIsland during development (`swift run`):
            // SwiftPM writes the bundle beside the binary.
            directories.append(executableDirectory)
        }
        if let mainResourceURL {
            // AgentIsland.app/Contents/MacOS/AgentIsland: the app binary reaches
            // Contents/Resources only through its own bundle.
            directories.append(mainResourceURL)
        }
        var paths: [String] = []
        for directory in directories {
            let path = directory.standardizedFileURL.appendingPathComponent(bundleName).path
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    private static let locatedBundle: Result<Bundle, ResourceError> = {
        let searched = bundleSearchPaths(
            executableURL: Bundle.main.executableURL,
            mainResourceURL: Bundle.main.resourceURL
        )
        for path in searched {
            if let bundle = Bundle(path: path) { return .success(bundle) }
        }
        return .failure(.bundleMissing(searched: searched))
    }()

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) throws -> URL {
        let bundle = try locatedBundle.get()
        guard let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            throw ResourceError.resourceMissing(
                name: "\(name).\(fileExtension)",
                bundlePath: bundle.bundleURL.path
            )
        }
        return url
    }
}

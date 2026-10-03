import Foundation
import IslandTestSupport

// Spec §12.1 static guards, plus the §2 and §11 principles they protect. They scan every file
// under Sources/, comments included. The forbidden literals may appear here (Tests/ is never
// scanned) but never in Sources/.

private let guardNotificationLiterals = [
    "UNUserNotificationCenter",
    "NSUserNotification",
    "display notification",
    "terminal-notifier",
]

private let guardAgentConfigurationLiterals = [
    ".claude/settings",
    ".codex/hooks",
    ".codex/config",
    "herdr/config",
]

private let guardHerdrMethodLiterals = [
    "send_keys",
    "agent.prompt",
    "plugin.link",
    "agent.explain",
    "recent_unwrapped",
    "client.window_title",
]

/// Spec §5.1: agent.read uses source "detection" only; "recent" scrolls idle agents and is
/// refused on busy ones ("recent_unwrapped" is in the list above). One expression, so a line
/// reports at most one hit.
private let guardRecentSourcePatterns = [
    #""recent"|\.string\("recent"#,
]

/// Spec §11: no network calls or telemetry. The Herdr client talks to a local AF_UNIX socket
/// through POSIX calls, which none of these names.
private let guardNetworkLiterals = [
    "URLSession",
    "NWConnection",
    "import Network",
    "CFSocketCreate",
]

/// Spec §2 and success criterion 5: every sound has a visible card, so sound APIs appear only in
/// ChimePlayer, which PeekController drives. Task 14 creates that file; until then no file may
/// use them.
private let guardSoundLiterals = [
    "NSSound",
    "NSBeep",
    "AudioServicesPlay",
    "AVAudioPlayer",
    "afplay",
]

/// Global Constraints: never open an ingest or control socket. The Herdr client only
/// ever dials out with `socket(2)`/`connect(2)`; nothing under Sources/ may `bind(2)`,
/// `listen(2)` or `accept(2)` to listen for incoming connections. Word-boundary-anchored
/// so "rebind(" or "listener(" (identifiers, not the POSIX calls) do not match.
private let guardListeningSocketPatterns = [
    #"\bbind\("#,
    #"\blisten\("#,
    #"\baccept\("#,
]

private let guardSoundAllowedPath = "Sources/AgentIsland/Peek/ChimePlayer.swift"

/// Pure IslandCore directories: no wall-clock reads (inject a WallClock instead).
private let guardPureDirectories = ["Model", "Herdr", "ClaudeRegistry", "Codex", "Policy", "Jump"]

private let guardWallClockPatterns = [
    #"(?<![A-Za-z0-9_])Date\(\)"#,
    #"(?<![A-Za-z0-9_])Date\.now(?![A-Za-z0-9_])"#,
]

private struct GuardHit: CustomStringConvertible {
    let path: String
    let line: Int
    let match: String

    var description: String {
        "\(path):\(line): \(match)"
    }
}

/// Every regular file under `directory`, sorted; [] when the directory does not exist.
private func guardFiles(under directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

private func guardRelativePath(_ url: URL, root: URL) -> String {
    let full = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path + "/"
    return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
}

private func guardLiteralHits(_ literals: [String], in files: [URL], root: URL) throws -> [GuardHit] {
    var hits: [GuardHit] = []
    for file in files {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            for literal in literals where line.contains(literal) {
                hits.append(GuardHit(path: guardRelativePath(file, root: root), line: index + 1, match: literal))
            }
        }
    }
    return hits
}

private func guardPatternHits(_ patterns: [String], in files: [URL], root: URL) throws -> [GuardHit] {
    let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
    var hits: [GuardHit] = []
    for file in files {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for expression in expressions where expression.firstMatch(in: line, range: range) != nil {
                hits.append(GuardHit(path: guardRelativePath(file, root: root), line: index + 1, match: expression.pattern))
            }
        }
    }
    return hits
}

/// Sound-API hits outside ChimePlayer.swift. The suffix check keeps the allowance exact even if
/// a path could not be made relative to `root`.
private func guardSoundHits(in files: [URL], root: URL) throws -> [GuardHit] {
    try guardLiteralHits(guardSoundLiterals, in: files, root: root).filter { hit in
        hit.path != guardSoundAllowedPath && !hit.path.hasSuffix("/" + guardSoundAllowedPath)
    }
}

private var guardSourcesDirectory: URL {
    Fixtures.repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
}

private func guardSourceFiles() throws -> [URL] {
    let files = try guardFiles(under: guardSourcesDirectory)
    try expectTrue(files.count > 20, "the guard sees the Sources tree (found \(files.count) files)")
    return files
}

private func guardScanSources(for literals: [String]) throws {
    let hits = try guardLiteralHits(literals, in: try guardSourceFiles(), root: Fixtures.repositoryRoot)
    try expectTrue(hits.isEmpty, "forbidden literals in Sources:\n" + hits.map(\.description).joined(separator: "\n"))
}

func testGuardSourcesHaveNoNotificationAPIs() throws {
    try guardScanSources(for: guardNotificationLiterals)
}

func testGuardSourcesNeverNameAgentConfigurationPaths() throws {
    try guardScanSources(for: guardAgentConfigurationLiterals)
}

func testGuardSourcesNeverNameForbiddenHerdrMethods() throws {
    try guardScanSources(for: guardHerdrMethodLiterals)
}

func testGuardSourcesNeverRequestTheRecentReadSource() throws {
    let hits = try guardPatternHits(guardRecentSourcePatterns, in: try guardSourceFiles(), root: Fixtures.repositoryRoot)
    try expectTrue(hits.isEmpty, "agent.read \"recent\" source in Sources:\n" + hits.map(\.description).joined(separator: "\n"))
}

func testGuardSourcesMakeNoNetworkCalls() throws {
    try guardScanSources(for: guardNetworkLiterals)
}

func testGuardSourcesNeverOpenAListeningOrControlSocket() throws {
    let hits = try guardPatternHits(guardListeningSocketPatterns, in: try guardSourceFiles(), root: Fixtures.repositoryRoot)
    try expectTrue(hits.isEmpty, "listening/control socket calls in Sources:\n" + hits.map(\.description).joined(separator: "\n"))
}

func testGuardOnlyChimePlayerUsesSoundAPIs() throws {
    let hits = try guardSoundHits(in: try guardSourceFiles(), root: Fixtures.repositoryRoot)
    try expectTrue(
        hits.isEmpty,
        "sound APIs outside \(guardSoundAllowedPath):\n" + hits.map(\.description).joined(separator: "\n")
    )
}

func testGuardPureCoreDirectoriesNeverReadTheWallClock() throws {
    let root = Fixtures.repositoryRoot
    let core = guardSourcesDirectory.appendingPathComponent("IslandCore", isDirectory: true)
    var files: [URL] = []
    for name in guardPureDirectories {
        files += try guardFiles(under: core.appendingPathComponent(name, isDirectory: true))
    }
    try expectTrue(
        files.contains { $0.lastPathComponent == "Model.swift" },
        "the purity guard sees Sources/IslandCore/Model/Model.swift"
    )
    let hits = try guardPatternHits(guardWallClockPatterns, in: files, root: root)
    try expectTrue(hits.isEmpty, "wall-clock reads in pure directories:\n" + hits.map(\.description).joined(separator: "\n"))
}

func testGuardScannersCatchPlantedViolations() throws {
    let directory = try TemporaryDirectory(prefix: "island-guard")
    let fileManager = FileManager.default

    let model = directory.url.appendingPathComponent("Model", isDirectory: true)
    try fileManager.createDirectory(at: model, withIntermediateDirectories: true)
    let text = [
        "// posts through UNUserNotificationCenter",
        "let stamp = Date()",
        "let later = Foundation.Date.now",
        "let fine = Date(timeIntervalSince1970: 0)",
        "let alsoFine = makeDate()",
        "let reads = \"~/.codex/config.toml\"",
        "let session = URLSession.shared",
        "import Network",
        "NSSound(named: \"Glass\")?.play()",
        "let scroll = [\"source\": .string(\"recent\")]",
        "let json = #\"{\"source\":\"recent\"}\"#",
        "let passive = [\"source\": .string(\"detection\")]",
        "let window = IslandTiming.codexRecentWindow",
        "let handle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)",
        "guard bind(handle, &address, socklen) == 0 else { return }",
        "listen(handle, 5)",
        "let client = accept(handle, nil, nil)",
        "let rebound = rebind(handle)",
    ].joined(separator: "\n")
    try Data(text.utf8).write(to: model.appendingPathComponent("Planted.swift"))

    // The one allowed sound file, and a file elsewhere that must still be flagged.
    let peek = directory.url.appendingPathComponent("Sources/AgentIsland/Peek", isDirectory: true)
    try fileManager.createDirectory(at: peek, withIntermediateDirectories: true)
    try Data("let sound = NSSound(named: \"Glass\")\n".utf8).write(to: peek.appendingPathComponent("ChimePlayer.swift"))
    let composition = directory.url.appendingPathComponent("Sources/AgentIsland/Composition", isDirectory: true)
    try fileManager.createDirectory(at: composition, withIntermediateDirectories: true)
    try Data("// builds the ChimePlayer, never NSSound itself\n".utf8)
        .write(to: composition.appendingPathComponent("PeekWiring.swift"))

    let files = try guardFiles(under: directory.url)
    try expect(files.count, equals: 3, "three planted files")

    let literalHits = try guardLiteralHits(
        guardNotificationLiterals + guardAgentConfigurationLiterals + guardHerdrMethodLiterals,
        in: files,
        root: directory.url
    )
    try expect(literalHits.map(\.line), equals: [1, 6], "literal hits by line")
    try expect(literalHits.first?.path ?? "", equals: "Model/Planted.swift", "hit path is relative")

    let patternHits = try guardPatternHits(guardWallClockPatterns, in: files, root: directory.url)
    try expect(patternHits.map(\.line), equals: [2, 3], "Date() and Date.now are caught; other Date uses are not")

    let networkHits = try guardLiteralHits(guardNetworkLiterals, in: files, root: directory.url)
    try expect(networkHits.map(\.line), equals: [7, 8], "URLSession and import Network are caught")

    let recentHits = try guardPatternHits(guardRecentSourcePatterns, in: files, root: directory.url)
    try expect(
        recentHits.map(\.line),
        equals: [10, 11],
        "a \"recent\" read source is caught; detection and identifiers containing Recent are not"
    )

    let rawSoundHits = try guardLiteralHits(guardSoundLiterals, in: files, root: directory.url)
    try expect(rawSoundHits.count, equals: 3, "the sound scan sees all three files")
    let soundHits = try guardSoundHits(in: files, root: directory.url)
    try expect(
        soundHits.map { "\($0.path):\($0.line)" },
        equals: ["Model/Planted.swift:9", "Sources/AgentIsland/Composition/PeekWiring.swift:1"],
        "sound APIs are allowed only in Sources/AgentIsland/Peek/ChimePlayer.swift"
    )

    let socketHits = try guardPatternHits(guardListeningSocketPatterns, in: files, root: directory.url)
    try expect(
        socketHits.map(\.line),
        equals: [15, 16, 17],
        "bind, listen and accept are caught; a plain socket() call and rebind( are not"
    )

    try expect(try guardFiles(under: directory.url.appendingPathComponent("Missing")), equals: [], "a missing directory is skipped")
}

let staticGuardTests: [TestCase] = [
    ("guard: Sources have no notification APIs", testGuardSourcesHaveNoNotificationAPIs),
    ("guard: Sources never name agent configuration paths", testGuardSourcesNeverNameAgentConfigurationPaths),
    ("guard: Sources never name forbidden Herdr methods", testGuardSourcesNeverNameForbiddenHerdrMethods),
    ("guard: Sources never request the recent agent.read source", testGuardSourcesNeverRequestTheRecentReadSource),
    ("guard: Sources make no network calls", testGuardSourcesMakeNoNetworkCalls),
    ("guard: Sources never open a listening or control socket", testGuardSourcesNeverOpenAListeningOrControlSocket),
    ("guard: only ChimePlayer uses sound APIs", testGuardOnlyChimePlayerUsesSoundAPIs),
    ("guard: pure core directories never read the wall clock", testGuardPureCoreDirectoriesNeverReadTheWallClock),
    ("guard: scanners catch planted violations", testGuardScannersCatchPlantedViolations),
]

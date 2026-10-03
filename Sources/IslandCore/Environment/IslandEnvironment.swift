import Foundation

/// Environment variables the app and the test/E2E harness read. Values are the
/// variable names; `resolve(environment:…)` below turns them into paths and flags.
public enum EnvironmentKeys {
    public static let herdrSocketPath = "HERDR_SOCKET_PATH"
    public static let codexSessionsDir = "CODEX_SESSIONS_DIR"
    public static let claudeSessionsDir = "CLAUDE_SESSIONS_DIR"
    public static let stateDump = "AGENT_ISLAND_STATE_DUMP"
    public static let jumpDryRun = "AGENT_ISLAND_JUMP_DRY_RUN"
    public static let jumpTestControl = "AGENT_ISLAND_JUMP_TEST_CONTROL"
    public static let herdrContract = "HERDR_CONTRACT"
    /// Test seam: moves the support and log directories under one root.
    public static let stateDir = "AGENT_ISLAND_STATE_DIR"
    /// Test seam: pins the bundle id the app treats as frontmost.
    public static let frontmostOverride = "AGENT_ISLAND_FRONTMOST_BUNDLE_ID"
}

/// A variable counts as set only when it holds at least one character.
private func nonEmptyValue(_ key: String, in environment: [String: String]) -> String? {
    guard let value = environment[key], !value.isEmpty else { return nil }
    return value
}

/// Where Agent Island keeps its own files. It writes nothing anywhere else.
public struct AppPaths: Equatable, Sendable {
    /// `~/Library/Application Support/AgentIsland`, or `$AGENT_ISLAND_STATE_DIR/support`.
    public let supportDirectory: URL
    /// `~/.local/state/agent-island`, or `$AGENT_ISLAND_STATE_DIR/log`.
    public let logDirectory: URL

    public var lockFile: URL { supportDirectory.appendingPathComponent("app.lock", isDirectory: false) }
    public var sessionNamesFile: URL {
        supportDirectory.appendingPathComponent("session-names.json", isDirectory: false)
    }
    public var codexSeenFile: URL {
        supportDirectory.appendingPathComponent("codex-seen.json", isDirectory: false)
    }
    public var transitionLogFile: URL {
        logDirectory.appendingPathComponent("transitions.jsonl", isDirectory: false)
    }

    public init(supportDirectory: URL, logDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.logDirectory = logDirectory
    }

    public static func resolve(environment: [String: String], home: URL) -> AppPaths {
        if let root = nonEmptyValue(EnvironmentKeys.stateDir, in: environment) {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            return AppPaths(
                supportDirectory: rootURL.appendingPathComponent("support", isDirectory: true),
                logDirectory: rootURL.appendingPathComponent("log", isDirectory: true)
            )
        }
        return AppPaths(
            supportDirectory: home.appendingPathComponent(
                "Library/Application Support/AgentIsland",
                isDirectory: true
            ),
            logDirectory: home.appendingPathComponent(".local/state/agent-island", isDirectory: true)
        )
    }
}

/// Where the three read-only feeds look for agent state.
public struct FeedPaths: Equatable, Sendable {
    /// `$HERDR_SOCKET_PATH`, or `~/.config/herdr/herdr.sock`.
    public let herdrSocket: URL
    /// `$CLAUDE_SESSIONS_DIR`, or `~/.claude/sessions`.
    public let claudeSessionsDirectory: URL
    /// `$CODEX_SESSIONS_DIR`, or `~/.codex/sessions`.
    public let codexSessionsDirectory: URL

    /// Codex keeps its thread-title index beside the sessions directory.
    public var codexSessionIndex: URL {
        codexSessionsDirectory.deletingLastPathComponent()
            .appendingPathComponent("session_index.jsonl", isDirectory: false)
    }

    public init(herdrSocket: URL, claudeSessionsDirectory: URL, codexSessionsDirectory: URL) {
        self.herdrSocket = herdrSocket
        self.claudeSessionsDirectory = claudeSessionsDirectory
        self.codexSessionsDirectory = codexSessionsDirectory
    }

    public static func resolve(environment: [String: String], home: URL) -> FeedPaths {
        func directory(_ key: String, default relativePath: String) -> URL {
            if let value = nonEmptyValue(key, in: environment) {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appendingPathComponent(relativePath, isDirectory: true)
        }
        let socket = nonEmptyValue(EnvironmentKeys.herdrSocketPath, in: environment)
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? home.appendingPathComponent(".config/herdr/herdr.sock", isDirectory: false)
        return FeedPaths(
            herdrSocket: socket,
            claudeSessionsDirectory: directory(EnvironmentKeys.claudeSessionsDir, default: ".claude/sessions"),
            codexSessionsDirectory: directory(EnvironmentKeys.codexSessionsDir, default: ".codex/sessions")
        )
    }
}

/// Debug and test switches. Boolean switches turn on only for the exact value "1".
public struct DebugFlags: Equatable, Sendable {
    /// `AGENT_ISLAND_STATE_DUMP`: write the state-dump JSON here on every change.
    public let stateDumpURL: URL?
    /// `AGENT_ISLAND_JUMP_DRY_RUN == "1"`: record jump actions without running them.
    public let jumpDryRun: Bool
    /// Fixture-only jump outcomes. Requires dry-run and an explicit isolated state directory.
    public let jumpTestControl: Bool
    /// `AGENT_ISLAND_FRONTMOST_BUNDLE_ID`: treat this bundle id as frontmost.
    public let frontmostBundleIDOverride: String?
    /// `HERDR_CONTRACT == "1"`: run the live Herdr contract tests (tests only).
    public let herdrContract: Bool

    public init(stateDumpURL: URL?, jumpDryRun: Bool, frontmostBundleIDOverride: String?, herdrContract: Bool,
                jumpTestControl: Bool = false) {
        self.stateDumpURL = stateDumpURL
        self.jumpDryRun = jumpDryRun
        self.frontmostBundleIDOverride = frontmostBundleIDOverride
        self.herdrContract = herdrContract
        self.jumpTestControl = jumpTestControl
    }

    public static func resolve(environment: [String: String]) -> DebugFlags {
        DebugFlags(
            stateDumpURL: nonEmptyValue(EnvironmentKeys.stateDump, in: environment)
                .map { URL(fileURLWithPath: $0, isDirectory: false) },
            jumpDryRun: environment[EnvironmentKeys.jumpDryRun] == "1",
            frontmostBundleIDOverride: nonEmptyValue(EnvironmentKeys.frontmostOverride, in: environment),
            herdrContract: environment[EnvironmentKeys.herdrContract] == "1",
            jumpTestControl: environment[EnvironmentKeys.jumpTestControl] == "1"
                && environment[EnvironmentKeys.jumpDryRun] == "1"
                && nonEmptyValue(EnvironmentKeys.stateDir, in: environment) != nil
        )
    }
}

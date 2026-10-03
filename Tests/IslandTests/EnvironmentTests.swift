import Foundation

import IslandCore

private let environmentTestHome = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

func testEnvironmentKeysNameTheDocumentedVariables() throws {
    try expect(EnvironmentKeys.herdrSocketPath, equals: "HERDR_SOCKET_PATH", "Herdr socket variable")
    try expect(EnvironmentKeys.codexSessionsDir, equals: "CODEX_SESSIONS_DIR", "Codex sessions variable")
    try expect(EnvironmentKeys.claudeSessionsDir, equals: "CLAUDE_SESSIONS_DIR", "Claude registry variable")
    try expect(EnvironmentKeys.stateDump, equals: "AGENT_ISLAND_STATE_DUMP", "state dump variable")
    try expect(EnvironmentKeys.jumpDryRun, equals: "AGENT_ISLAND_JUMP_DRY_RUN", "jump dry-run variable")
    try expect(EnvironmentKeys.herdrContract, equals: "HERDR_CONTRACT", "live contract variable")
    try expect(EnvironmentKeys.stateDir, equals: "AGENT_ISLAND_STATE_DIR", "state root variable")
    try expect(
        EnvironmentKeys.frontmostOverride,
        equals: "AGENT_ISLAND_FRONTMOST_BUNDLE_ID",
        "frontmost override variable"
    )
}

func testEnvironmentAppPathsDefaultToApplicationSupportAndLocalState() throws {
    let paths = AppPaths.resolve(environment: [:], home: environmentTestHome)
    try expect(
        paths.supportDirectory.path,
        equals: "/Users/tester/Library/Application Support/AgentIsland",
        "support directory"
    )
    try expect(paths.logDirectory.path, equals: "/Users/tester/.local/state/agent-island", "log directory")
    try expect(
        paths.lockFile.path,
        equals: "/Users/tester/Library/Application Support/AgentIsland/app.lock",
        "lock file"
    )
    try expect(
        paths.sessionNamesFile.path,
        equals: "/Users/tester/Library/Application Support/AgentIsland/session-names.json",
        "session names file"
    )
    try expect(
        paths.codexSeenFile.path,
        equals: "/Users/tester/Library/Application Support/AgentIsland/codex-seen.json",
        "Codex seen store"
    )
    try expect(
        paths.transitionLogFile.path,
        equals: "/Users/tester/.local/state/agent-island/transitions.jsonl",
        "transition log"
    )
}

func testEnvironmentStateDirMovesSupportAndLogUnderOneRoot() throws {
    let paths = AppPaths.resolve(
        environment: ["AGENT_ISLAND_STATE_DIR": "/tmp/island-e2e"],
        home: environmentTestHome
    )
    try expect(paths.supportDirectory.path, equals: "/tmp/island-e2e/support", "support directory")
    try expect(paths.logDirectory.path, equals: "/tmp/island-e2e/log", "log directory")
    try expect(paths.lockFile.path, equals: "/tmp/island-e2e/support/app.lock", "lock file")
    try expect(
        paths.sessionNamesFile.path,
        equals: "/tmp/island-e2e/support/session-names.json",
        "session names file"
    )
    try expect(paths.codexSeenFile.path, equals: "/tmp/island-e2e/support/codex-seen.json", "Codex seen store")
    try expect(
        paths.transitionLogFile.path,
        equals: "/tmp/island-e2e/log/transitions.jsonl",
        "transition log"
    )
    try expectTrue(
        !paths.supportDirectory.path.hasPrefix("/Users/tester"),
        "the override keeps tests out of the real home directory"
    )
}

func testEnvironmentEmptyStateDirFallsBackToTheDefaults() throws {
    try expect(
        AppPaths.resolve(environment: ["AGENT_ISLAND_STATE_DIR": ""], home: environmentTestHome),
        equals: AppPaths.resolve(environment: [:], home: environmentTestHome),
        "an empty AGENT_ISLAND_STATE_DIR is the same as an unset one"
    )
}

func testEnvironmentFeedPathsDefaultToTheAgentLocations() throws {
    let paths = FeedPaths.resolve(environment: [:], home: environmentTestHome)
    try expect(paths.herdrSocket.path, equals: "/Users/tester/.config/herdr/herdr.sock", "Herdr socket")
    try expect(paths.claudeSessionsDirectory.path, equals: "/Users/tester/.claude/sessions", "Claude registry")
    try expect(paths.codexSessionsDirectory.path, equals: "/Users/tester/.codex/sessions", "Codex sessions")
}

func testEnvironmentFeedPathOverridesReplaceEachDefault() throws {
    let paths = FeedPaths.resolve(
        environment: [
            "HERDR_SOCKET_PATH": "/tmp/hf-1-1.sock",
            "CLAUDE_SESSIONS_DIR": "/tmp/fixture/claude-sessions",
            "CODEX_SESSIONS_DIR": "/tmp/fixture/codex/sessions",
        ],
        home: environmentTestHome
    )
    try expect(paths.herdrSocket.path, equals: "/tmp/hf-1-1.sock", "Herdr socket override")
    try expect(
        paths.claudeSessionsDirectory.path,
        equals: "/tmp/fixture/claude-sessions",
        "Claude registry override"
    )
    try expect(paths.codexSessionsDirectory.path, equals: "/tmp/fixture/codex/sessions", "Codex sessions override")

    let onlySocket = FeedPaths.resolve(
        environment: ["HERDR_SOCKET_PATH": "/tmp/hf-1-2.sock"],
        home: environmentTestHome
    )
    try expect(onlySocket.herdrSocket.path, equals: "/tmp/hf-1-2.sock", "the socket override applies alone")
    try expect(
        onlySocket.claudeSessionsDirectory.path,
        equals: "/Users/tester/.claude/sessions",
        "an unrelated override leaves the Claude default"
    )
    try expect(
        onlySocket.codexSessionsDirectory.path,
        equals: "/Users/tester/.codex/sessions",
        "an unrelated override leaves the Codex default"
    )
}

func testEnvironmentEmptyFeedOverridesFallBackToTheDefaults() throws {
    try expect(
        FeedPaths.resolve(
            environment: ["HERDR_SOCKET_PATH": "", "CLAUDE_SESSIONS_DIR": "", "CODEX_SESSIONS_DIR": ""],
            home: environmentTestHome
        ),
        equals: FeedPaths.resolve(environment: [:], home: environmentTestHome),
        "empty feed overrides are the same as unset ones"
    )
}

func testEnvironmentCodexSessionIndexSitsBesideTheSessionsDirectory() throws {
    try expect(
        FeedPaths.resolve(environment: [:], home: environmentTestHome).codexSessionIndex.path,
        equals: "/Users/tester/.codex/session_index.jsonl",
        "default index"
    )
    try expect(
        FeedPaths.resolve(
            environment: ["CODEX_SESSIONS_DIR": "/tmp/fixture/codex/sessions"],
            home: environmentTestHome
        ).codexSessionIndex.path,
        equals: "/tmp/fixture/codex/session_index.jsonl",
        "override index"
    )
    try expect(
        FeedPaths.resolve(
            environment: ["CODEX_SESSIONS_DIR": "/tmp/fixture/codex/sessions/"],
            home: environmentTestHome
        ).codexSessionIndex.path,
        equals: "/tmp/fixture/codex/session_index.jsonl",
        "a trailing slash on the override does not change the index"
    )
}

func testEnvironmentDebugFlagsTurnOnOnlyForExactlyOne() throws {
    let on = DebugFlags.resolve(environment: ["AGENT_ISLAND_JUMP_DRY_RUN": "1", "HERDR_CONTRACT": "1"])
    try expect(on.jumpDryRun, equals: true, "dry-run on for 1")
    try expect(on.herdrContract, equals: true, "contract on for 1")
    for value in ["", "0", "true", "yes", "TRUE", " 1", "1 ", "01"] {
        let flags = DebugFlags.resolve(environment: ["AGENT_ISLAND_JUMP_DRY_RUN": value, "HERDR_CONTRACT": value])
        try expect(flags.jumpDryRun, equals: false, "dry-run stays off for \"\(value)\"")
        try expect(flags.herdrContract, equals: false, "contract stays off for \"\(value)\"")
    }
}

func testEnvironmentDebugFlagsReadTheDumpPathAndFrontmostOverride() throws {
    let flags = DebugFlags.resolve(environment: [
        "AGENT_ISLAND_STATE_DUMP": "/tmp/island-e2e/state.json",
        "AGENT_ISLAND_FRONTMOST_BUNDLE_ID": "com.apple.finder",
    ])
    try expect(flags.stateDumpURL?.path, equals: "/tmp/island-e2e/state.json", "state dump path")
    try expect(flags.frontmostBundleIDOverride, equals: "com.apple.finder", "frontmost override")

    let empty = DebugFlags.resolve(environment: [
        "AGENT_ISLAND_STATE_DUMP": "",
        "AGENT_ISLAND_FRONTMOST_BUNDLE_ID": "",
    ])
    try expect(empty.stateDumpURL, equals: nil, "an empty dump path means no dump")
    try expect(empty.frontmostBundleIDOverride, equals: nil, "an empty override means no override")
}

func testEnvironmentDefaultDebugFlagsAreAllOff() throws {
    try expect(
        DebugFlags.resolve(environment: [:]),
        equals: DebugFlags(stateDumpURL: nil, jumpDryRun: false, frontmostBundleIDOverride: nil, herdrContract: false),
        "no variables, no debug behavior"
    )
}

func testEnvironmentRunnerParsesRepeatableFilters() throws {
    try expect(parseTestFilters([]), equals: [], "no arguments selects everything")
    try expect(parseTestFilters(["--filter", "kept:"]), equals: ["kept:"], "one filter")
    try expect(
        parseTestFilters(["--filter", "herdrCodec:", "--filter", "herdrClient:"]),
        equals: ["herdrCodec:", "herdrClient:"],
        "filters repeat"
    )
    try expect(parseTestFilters(["--filter"]), equals: nil, "a filter needs a prefix")
    try expect(parseTestFilters(["--filter", ""]), equals: nil, "an empty prefix is a usage error")
    try expect(parseTestFilters(["kept:"]), equals: nil, "a bare prefix is a usage error")
    try expect(parseTestFilters(["--verbose"]), equals: nil, "unknown flags are usage errors")
}

func testEnvironmentRunnerSelectsByCaseInsensitivePrefix() throws {
    let noop: @MainActor () throws -> Void = {}
    let tests: [TestCase] = [
        ("kept: one", noop),
        ("environment: two", noop),
        ("herdrCodec: three", noop),
        ("herdrClient: four", noop),
    ]
    try expect(selectTests(tests, filters: []).map { $0.0 }, equals: tests.map { $0.0 }, "no filter runs everything")
    try expect(selectTests(tests, filters: ["KEPT:"]).map { $0.0 }, equals: ["kept: one"], "case-insensitive")
    try expect(
        selectTests(tests, filters: ["herdrclient:", "herdrCodec:"]).map { $0.0 },
        equals: ["herdrCodec: three", "herdrClient: four"],
        "several filters keep registration order"
    )
    try expect(selectTests(tests, filters: ["one"]).map { $0.0 }, equals: [], "a filter matches prefixes, not substrings")
    try expect(selectTests(tests, filters: ["nosuchprefix:"]).isEmpty, equals: true, "an unknown prefix selects nothing")
}

func testEnvironmentJumpControlRequiresIsolatedDryRun() throws {
    var env = [EnvironmentKeys.jumpTestControl: "1"]
    try expect(DebugFlags.resolve(environment: env).jumpTestControl, equals: false, "live jumps never use fixture control")
    env[EnvironmentKeys.jumpDryRun] = "1"
    try expect(DebugFlags.resolve(environment: env).jumpTestControl, equals: false, "default user state is excluded")
    env[EnvironmentKeys.stateDir] = "/tmp/island-fixture"
    try expect(DebugFlags.resolve(environment: env).jumpTestControl, equals: true, "explicit isolated dry run")
    env[EnvironmentKeys.jumpTestControl] = "true"
    try expect(DebugFlags.resolve(environment: env).jumpTestControl, equals: false, "only exactly 1 enables control")
}

let environmentTests: [TestCase] = [
    ("environment: jump control requires isolated dry run", testEnvironmentJumpControlRequiresIsolatedDryRun),
    ("environment: keys name the documented variables", testEnvironmentKeysNameTheDocumentedVariables),
    ("environment: app paths default to Application Support and ~/.local/state", testEnvironmentAppPathsDefaultToApplicationSupportAndLocalState),
    ("environment: AGENT_ISLAND_STATE_DIR moves support and log under one root", testEnvironmentStateDirMovesSupportAndLogUnderOneRoot),
    ("environment: an empty AGENT_ISLAND_STATE_DIR falls back to the defaults", testEnvironmentEmptyStateDirFallsBackToTheDefaults),
    ("environment: feed paths default to the Herdr socket, Claude registry and Codex sessions", testEnvironmentFeedPathsDefaultToTheAgentLocations),
    ("environment: feed path overrides replace each default independently", testEnvironmentFeedPathOverridesReplaceEachDefault),
    ("environment: empty feed path overrides fall back to the defaults", testEnvironmentEmptyFeedOverridesFallBackToTheDefaults),
    ("environment: the Codex session index sits beside the sessions directory", testEnvironmentCodexSessionIndexSitsBesideTheSessionsDirectory),
    ("environment: debug flags turn on only for exactly 1", testEnvironmentDebugFlagsTurnOnOnlyForExactlyOne),
    ("environment: debug flags read the state dump path and frontmost override", testEnvironmentDebugFlagsReadTheDumpPathAndFrontmostOverride),
    ("environment: default debug flags are all off", testEnvironmentDefaultDebugFlagsAreAllOff),
    ("environment: runner parses repeatable --filter arguments", testEnvironmentRunnerParsesRepeatableFilters),
    ("environment: runner selects tests by case-insensitive display-name prefix", testEnvironmentRunnerSelectsByCaseInsensitivePrefix),
]

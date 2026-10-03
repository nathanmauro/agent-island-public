import Foundation
import IslandCore

private let jumpCodexPath = "/Applications/Codex.app"
private let jumpClaudePath = "/Applications/Claude.app"

func testJumpPlannerHerdrPaneFocusesRaisesThenFallsBack() throws {
    let plan = JumpPlanner.plan(
        .herdrPane(paneID: "w1:p2", windowTitlePrefix: "host: api"),
        context: JumpContext(codexAppPath: jumpCodexPath, claudeAppPath: jumpClaudePath)
    )
    try expect(plan, equals: [
        .herdrFocus(paneID: "w1:p2"),
        .raiseGhostty(windowTitlePrefix: "host: api"),
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: true),
    ], "Herdr plan is exactly focus, raise, fallback activate")

    let noPrefix = JumpPlanner.plan(.herdrPane(paneID: "w1:p2", windowTitlePrefix: nil), context: JumpContext())
    try expect(noPrefix[1], equals: .raiseGhostty(windowTitlePrefix: nil), "a nil prefix is passed through")
}

func testJumpPlannerCodexThreadOpensThreadURLWithAppPath() throws {
    let plan = JumpPlanner.plan(.codexThread(id: "0199aa00-1111-7222-8333-944445555666"), context: JumpContext(codexAppPath: jumpCodexPath))
    try expect(plan, equals: [
        .openURL("codex://threads/0199aa00-1111-7222-8333-944445555666", appPath: jumpCodexPath, onlyIfPreviousFailed: false),
    ], "Codex opens the thread URL with the resolved app")
}

func testJumpPlannerCodexThreadWithoutAppPathPlansNothing() throws {
    let plan = JumpPlanner.plan(.codexThread(id: "t1"), context: JumpContext(claudeAppPath: jumpClaudePath))
    try expect(plan, equals: [], "no Codex app path gives an empty plan")
}

func testJumpPlannerClaudeDesktopOpensContinueThenNeedsInputFallback() throws {
    let plan = JumpPlanner.plan(
        .claudeDesktop(sessionID: "abc def&x=1", tmuxTarget: "main:@1.%2"),
        context: JumpContext(claudeAppPath: jumpClaudePath)
    )
    try expect(plan, equals: [
        .openURL("claude://code/continue?session=abc%20def%26x%3D1", appPath: jumpClaudePath, onlyIfPreviousFailed: false),
        .openURL("claude://code/needs-input", appPath: jumpClaudePath, onlyIfPreviousFailed: true),
    ], "Claude plan: continue URL with a percent-encoded id, then the fallback-only needs-input URL")

    let uuid = JumpPlanner.plan(
        .claudeDesktop(sessionID: "4f1c2b3a-0000-4000-8000-00000000abcd", tmuxTarget: nil),
        context: JumpContext(claudeAppPath: jumpClaudePath)
    )
    try expect(
        uuid.first,
        equals: .openURL(
            "claude://code/continue?session=4f1c2b3a-0000-4000-8000-00000000abcd",
            appPath: jumpClaudePath,
            onlyIfPreviousFailed: false
        ),
        "a UUID session id needs no encoding"
    )
}

func testJumpPlannerClaudeDesktopWithoutAppFallsBackToTerminalPlan() throws {
    let withTmux = JumpPlanner.plan(.claudeDesktop(sessionID: "s1", tmuxTarget: "main:@1.%2"), context: JumpContext())
    try expect(withTmux, equals: JumpPlanner.plan(.terminal(tmuxTarget: "main:@1.%2"), context: JumpContext()), "same as the terminal plan")
    try expect(withTmux, equals: [
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false),
        .tmuxSwitchClient(target: "main:@1.%2"),
    ], "activate Ghostty, then switch the tmux client")

    let withoutTmux = JumpPlanner.plan(.claudeDesktop(sessionID: "s1", tmuxTarget: nil), context: JumpContext(codexAppPath: jumpCodexPath))
    try expect(withoutTmux, equals: [
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false),
    ], "no tmux target: activate only")
}

func testJumpPlannerClaudeRemoteControlOpensTheEpitaxyConversation() throws {
    let target = JumpTarget.claudeRemoteControl(bridgeSessionID: "session_01FixtureBridge000000001")
    let expected: [JumpAction] = [
        .openURL("claude://claude.ai/epitaxy/session_01FixtureBridge000000001", appPath: jumpClaudePath, onlyIfPreviousFailed: false),
    ]
    try expect(JumpPlanner.plan(target, context: JumpContext(claudeAppPath: jumpClaudePath)), equals: expected,
               "exactly one action: the bridge id's conversation in the running Claude app, with no fallback")
    try expect(JumpPlanner.plan(target, context: JumpContext(codexAppPath: jumpCodexPath, claudeAppPath: jumpClaudePath)),
               equals: expected, "a running Codex app changes nothing")
    let longest = "session_" + String(repeating: "A1", count: 32)
    try expect(JumpPlanner.plan(.claudeRemoteControl(bridgeSessionID: longest), context: JumpContext(claudeAppPath: jumpClaudePath)),
               equals: [.openURL("claude://claude.ai/epitaxy/\(longest)", appPath: jumpClaudePath, onlyIfPreviousFailed: false)],
               "a 64-character suffix is still a valid id")
}

func testJumpPlannerClaudeRemoteControlWithoutTheAppPlansNothing() throws {
    let target = JumpTarget.claudeRemoteControl(bridgeSessionID: "session_01FixtureBridge000000001")
    try expect(JumpPlanner.plan(target, context: JumpContext()), equals: [],
               "no running Claude app: an empty plan, never a terminal or generic Claude fallback")
    try expect(JumpPlanner.plan(target, context: JumpContext(codexAppPath: jumpCodexPath)), equals: [],
               "only the Claude app can open the conversation")
}

func testJumpPlannerClaudeRemoteControlRejectsMalformedBridgeIDs() throws {
    let malformed = [
        "",
        "session_",
        "cse_01FixtureBridge000000001",
        "Session_01FixtureBridge000000001",
        "01FixtureBridge000000001",
        "session_01FixtureBridge000000001 ",
        "session_01FixtureBridge000000001\n",
        "session_01Fixture_Bridge00000001",
        "session_../../01FixtureBridge01",
        "session_01FixtureBridge/0000001",
        "session_01FixtureBridge?x=1#frag",
        "session_01FixtureBridge00%2F0001",
        "session_01FixtureBr\u{EF}dge000000001",
        "session_" + String(repeating: "A", count: 65),
    ]
    for id in malformed {
        try expect(JumpPlanner.plan(.claudeRemoteControl(bridgeSessionID: id), context: JumpContext(claudeAppPath: jumpClaudePath)),
                   equals: [], "\(String(reflecting: id)) never reaches a URL")
    }
}

func testJumpPlannerTerminalWithValidTmuxTargetSwitchesClient() throws {
    let plan = JumpPlanner.plan(.terminal(tmuxTarget: "work:@3.%12"), context: JumpContext())
    try expect(plan, equals: [
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false),
        .tmuxSwitchClient(target: "work:@3.%12"),
    ], "terminal plan with a valid target")
}

func testJumpPlannerInvalidTmuxTargetsPlanActivateOnly() throws {
    let activateOnly: [JumpAction] = [.activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false)]
    let invalid: [String?] = [
        nil,
        "",
        "-t",
        "--kill-server",
        "main :@1",
        "main\t@1",
        "main\n@1",
        "main\u{7}@1",
        "main\u{0}@1",
        String(repeating: "a", count: 257),
    ]
    for target in invalid {
        try expect(JumpPlanner.isValidTmuxTarget(target), equals: false, "invalid target \(String(reflecting: target))")
        try expect(JumpPlanner.plan(.terminal(tmuxTarget: target), context: JumpContext()), equals: activateOnly, "activate-only plan")
    }
}

func testJumpPlannerTmuxTargetLengthBoundary() throws {
    try expect(JumpPlanner.isValidTmuxTarget(String(repeating: "a", count: 256)), equals: true, "256 bytes is allowed")
    try expect(JumpPlanner.isValidTmuxTarget(String(repeating: "a", count: 257)), equals: false, "257 bytes is not")
    try expect(JumpPlanner.isValidTmuxTarget(String(repeating: "\u{E9}", count: 129)), equals: false, "the limit counts UTF-8 bytes")
    try expect(JumpPlanner.isValidTmuxTarget("main:@1.%2"), equals: true, "registry tmux shape")
}

func testJumpPlannerActionsRoundTripThroughCodable() throws {
    let actions: [JumpAction] = [
        .herdrFocus(paneID: "w1:p1"),
        .raiseGhostty(windowTitlePrefix: nil),
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: true),
        .openURL("codex://threads/t1", appPath: jumpCodexPath, onlyIfPreviousFailed: false),
        .tmuxSwitchClient(target: "main:@1.%2"),
    ]
    let decoded = try JSONDecoder().decode([JumpAction].self, from: JSONEncoder().encode(actions))
    try expect(decoded, equals: actions, "jump actions survive the state dump encoding")
}

@MainActor
func testJumpPlannerStaticContextProviderReturnsItsContext() throws {
    let context = JumpContext(codexAppPath: jumpCodexPath, claudeAppPath: nil)
    let provider = StaticJumpContextProvider(context)
    try expect(provider.currentJumpContext(), equals: context, "static provider")
    try expect(JumpError.actionFailed("x"), equals: .actionFailed("x"), "JumpError is Equatable")
}

let jumpPlannerTests: [TestCase] = [
    ("jumpPlanner: herdr pane focuses, raises, then falls back", testJumpPlannerHerdrPaneFocusesRaisesThenFallsBack),
    ("jumpPlanner: codex thread opens the thread URL with the app path", testJumpPlannerCodexThreadOpensThreadURLWithAppPath),
    ("jumpPlanner: codex thread without an app path plans nothing", testJumpPlannerCodexThreadWithoutAppPathPlansNothing),
    ("jumpPlanner: claude desktop opens continue, then needs-input fallback", testJumpPlannerClaudeDesktopOpensContinueThenNeedsInputFallback),
    ("jumpPlanner: claude desktop without the app falls back to the terminal plan", testJumpPlannerClaudeDesktopWithoutAppFallsBackToTerminalPlan),
    ("jumpPlanner: claude remote control opens the epitaxy conversation", testJumpPlannerClaudeRemoteControlOpensTheEpitaxyConversation),
    ("jumpPlanner: claude remote control without the app plans nothing", testJumpPlannerClaudeRemoteControlWithoutTheAppPlansNothing),
    ("jumpPlanner: claude remote control rejects malformed bridge ids", testJumpPlannerClaudeRemoteControlRejectsMalformedBridgeIDs),
    ("jumpPlanner: terminal with a valid tmux target switches client", testJumpPlannerTerminalWithValidTmuxTargetSwitchesClient),
    ("jumpPlanner: invalid tmux targets plan activate only", testJumpPlannerInvalidTmuxTargetsPlanActivateOnly),
    ("jumpPlanner: tmux target length boundary", testJumpPlannerTmuxTargetLengthBoundary),
    ("jumpPlanner: actions round-trip through Codable", testJumpPlannerActionsRoundTripThroughCodable),
    ("jumpPlanner: static context provider returns its context", testJumpPlannerStaticContextProviderReturnsItsContext),
]

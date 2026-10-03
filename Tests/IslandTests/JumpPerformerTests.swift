import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - GhosttyScript

func testJumpPerformerGhosttyScriptFocusesFirstMatchingTerminalThenActivates() throws {
    let script = GhosttyScript.focusTerminal(titlePrefix: "fixture-host: api")
    try expectTrue(script.contains(#"every terminal whose name starts with "fixture-host: api""#),
                   "matches terminals by window-title prefix:\n\(script)")
    try expectTrue(script.contains(#"tell application id "com.mitchellh.ghostty""#), "addresses Ghostty by bundle id")
    try expectTrue(script.contains(#"application id "com.mitchellh.ghostty" is not running"#),
                   "never launches Ghostty just to raise it")
    guard let focus = script.range(of: "focus item 1 of matches"),
          let activate = script.range(of: "activate") else {
        throw TestFailure.expectation("script must focus item 1 and activate:\n\(script)")
    }
    try expectTrue(focus.upperBound <= activate.lowerBound, "focus comes before activate")
}

func testJumpPerformerGhosttyScriptEscapesQuotesAndBackslashes() throws {
    let script = GhosttyScript.focusTerminal(titlePrefix: #"host: a"b\c"#)
    try expectTrue(script.contains(#"starts with "host: a\"b\\c""#), "quotes and backslashes are escaped:\n\(script)")
}

func testJumpPerformerGhosttyScriptFlattensNewlines() throws {
    let script = GhosttyScript.focusTerminal(titlePrefix: "host: a\nb\rc")
    try expectTrue(script.contains(#"starts with "host: a b c""#), "newlines and returns become spaces:\n\(script)")
}

func testJumpPerformerHostOnlyPrefix() throws {
    try expect(GhosttyScript.hostOnlyPrefix(from: "fixture-host: api"), equals: "fixture-host: ", "keeps host and separator")
    try expect(GhosttyScript.hostOnlyPrefix(from: "fixture-host: a: b"), equals: "fixture-host: ", "splits at the first separator")
    try expect(GhosttyScript.hostOnlyPrefix(from: "fixture-host"), equals: nil, "no separator")
    try expect(GhosttyScript.hostOnlyPrefix(from: ": api"), equals: nil, "empty host")
    try expect(GhosttyScript.hostOnlyPrefix(from: "fixture-host: "), equals: nil, "already host-only")
}

func testJumpPerformerRaiseAttemptOrder() throws {
    try expect(GhosttyScript.exactAttempts, equals: 3, "three exact attempts")
    try expect(GhosttyScript.retryDelayNanoseconds, equals: 150_000_000, "150 ms between exact attempts")
    try expect(GhosttyScript.attemptPrefixes(for: "fixture-host: api"),
               equals: ["fixture-host: api", "fixture-host: api", "fixture-host: api", "fixture-host: "],
               "exact prefix three times, then host-only")
    try expect(GhosttyScript.attemptPrefixes(for: "fixture-host"),
               equals: ["fixture-host", "fixture-host", "fixture-host"], "no host-only attempt without a separator")
    try expect(GhosttyScript.attemptPrefixes(for: nil), equals: [], "nil prefix: nothing to try")
    try expect(GhosttyScript.attemptPrefixes(for: ""), equals: [], "empty prefix: nothing to try")
}

func testJumpPerformerGhosttyScriptCompilesAgainstInstalledGhostty() throws {
    let dictionary = "/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef"
    guard FileManager.default.fileExists(atPath: dictionary) else {
        throw TestSkipped(reason: "Ghostty.app is not installed in /Applications")
    }
    let directory = try TemporaryDirectory()
    let source = directory.file("raise.applescript")
    try GhosttyScript.focusTerminal(titlePrefix: #"fixture-host: a"b\c"#).write(to: source, atomically: true, encoding: .utf8)
    // Compiles only (resolves Ghostty's terminology); it never runs the script or sends an Apple Event.
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/osacompile"),
        arguments: ["-o", directory.file("raise.scpt").path, source.path],
        timeout: 10
    )
    try expect(result.status, equals: 0, "osacompile accepts the script against Ghostty's dictionary")
}

// MARK: - JumpSequencer

private struct ScriptedJumpFailure: Error, CustomStringConvertible {
    let name: String
    var description: String { "scripted failure \(name)" }
}

/// Drives a JumpSequencer the way LiveJumpPerformer does; `failing` lists the plan indices that throw.
private func runSequence(_ actions: [JumpAction], failing: Set<Int> = []) -> (executed: [JumpAction], failure: JumpError?) {
    var sequencer = JumpSequencer(actions)
    while let action = sequencer.next() {
        if let index = actions.firstIndex(of: action), failing.contains(index) {
            sequencer.failed(ScriptedJumpFailure(name: JumpSequencer.label(for: action)))
        } else {
            sequencer.succeeded()
        }
    }
    return (sequencer.executed, sequencer.failure)
}

private let herdrPlan = JumpPlanner.plan(.herdrPane(paneID: "w1:p1", windowTitlePrefix: "fixture-host: api"),
                                         context: JumpContext())

func testJumpPerformerSequencerSkipsFallbackAfterSuccess() throws {
    try expect(herdrPlan, equals: [
        .herdrFocus(paneID: "w1:p1"),
        .raiseGhostty(windowTitlePrefix: "fixture-host: api"),
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: true),
    ], "Task 2 herdr plan shape")
    let result = runSequence(herdrPlan)
    try expect(result.executed, equals: Array(herdrPlan.prefix(2)), "the activate fallback is skipped")
    try expect(result.failure, equals: nil, "no failure")
}

func testJumpPerformerSequencerRunsFallbackAndTreatsItAsRecovered() throws {
    let result = runSequence(herdrPlan, failing: [1])
    try expect(result.executed, equals: herdrPlan, "raise failed, so Ghostty is activated")
    try expect(result.failure, equals: nil, "a fallback that succeeds recovers the failure")
}

func testJumpPerformerSequencerReportsOriginalFailureWhenFallbackFails() throws {
    let result = runSequence(herdrPlan, failing: [1, 2])
    try expect(result.executed, equals: herdrPlan, "all three actions ran")
    guard case let .actionFailed(message)? = result.failure else {
        throw TestFailure.expectation("expected actionFailed, got \(String(describing: result.failure))")
    }
    try expectTrue(message.hasPrefix("raiseGhostty:"), "the first unrecovered failure is the raise: \(message)")
}

func testJumpPerformerSequencerRunsEveryPrimaryActionAndThrowsFirstFailure() throws {
    let result = runSequence(herdrPlan, failing: [0])
    try expect(result.executed, equals: Array(herdrPlan.prefix(2)),
               "a failed agent.focus still raises Ghostty; the raise succeeded so the fallback is skipped")
    guard case let .actionFailed(message)? = result.failure else {
        throw TestFailure.expectation("expected actionFailed, got \(String(describing: result.failure))")
    }
    try expectTrue(message.hasPrefix("herdrFocus:"), "focus failure is reported: \(message)")

    let terminal: [JumpAction] = [
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false),
        .tmuxSwitchClient(target: "main:1"),
    ]
    let terminalResult = runSequence(terminal, failing: [0])
    try expect(terminalResult.executed, equals: terminal, "tmux still runs after a failed activate")
    try expectTrue(terminalResult.failure != nil, "the activate failure is reported")
}

func testJumpPerformerSequencerClaudeFallbackURL() throws {
    let plan: [JumpAction] = [
        .openURL("claude://code/continue?session=s1", appPath: "/Applications/Claude.app", onlyIfPreviousFailed: false),
        .openURL("claude://code/needs-input", appPath: "/Applications/Claude.app", onlyIfPreviousFailed: true),
    ]
    try expect(runSequence(plan).executed, equals: [plan[0]], "needs-input only when continue fails")
    let recovered = runSequence(plan, failing: [0])
    try expect(recovered.executed, equals: plan, "continue failed, so needs-input opens")
    try expect(recovered.failure, equals: nil, "needs-input recovered the failure")
}

func testJumpPerformerSequencerKeepsJumpErrorsAndHandlesEmptyPlans() throws {
    var sequencer = JumpSequencer([.herdrFocus(paneID: "w1:p1")])
    _ = sequencer.next()
    sequencer.failed(JumpError.rowNotFound)
    try expect(sequencer.next(), equals: nil, "plan exhausted")
    try expect(sequencer.failure, equals: .rowNotFound, "a JumpError passes through unwrapped")

    var empty = JumpSequencer([])
    try expect(empty.next(), equals: nil, "nothing to run")
    try expect(empty.failure, equals: nil, "no failure")
}

// MARK: - App resolution

func testJumpPerformerCodexAppPathPrefersCodexApp() throws {
    let codex = "/Applications/Codex.app"
    let chatGPT = "/Applications/ChatGPT.app"
    try expect(JumpAppResolver.codexAppPath(runningPath: codex, installedPaths: []), equals: codex,
               "running Codex.app wins")
    try expect(JumpAppResolver.codexAppPath(runningPath: chatGPT, installedPaths: [chatGPT, codex]), equals: codex,
               "an installed Codex.app beats a running ChatGPT.app that shares the bundle id")
    try expect(JumpAppResolver.codexAppPath(runningPath: nil, installedPaths: [chatGPT, codex]), equals: codex,
               "installed Codex.app when nothing runs")
    try expect(JumpAppResolver.codexAppPath(runningPath: chatGPT, installedPaths: [chatGPT]), equals: chatGPT,
               "the running bundle when no Codex.app exists")
    try expect(JumpAppResolver.codexAppPath(runningPath: nil, installedPaths: [chatGPT]), equals: nil,
               "never an installed ChatGPT.app")
}

func testJumpPerformerClaudeAppPathRequiresRunningApp() throws {
    try expect(JumpAppResolver.claudeAppPath(runningPath: "/Applications/Claude.app"),
               equals: "/Applications/Claude.app", "running Claude.app")
    try expect(JumpAppResolver.claudeAppPath(runningPath: nil), equals: nil, "not running: no path")
    try expect(JumpAppResolver.claudeAppPath(runningPath: ""), equals: nil, "empty path: no path")
}

// MARK: - OffMainActionRunner

private final class OffMainProbe: @unchecked Sendable {
    var mainBlockRan = false
    var taskFinishedWhenMainBlockRan: Bool?
    var taskFinished = false
    var taskError: Error?
    var finishedUptime: TimeInterval = 0
}

@MainActor
func testJumpPerformerOffMainRunnerKeepsMainThreadFree() throws {
    let probe = OffMainProbe()
    let startedUptime = ProcessInfo.processInfo.systemUptime
    Task {
        do {
            try await OffMainActionRunner.run([.run(executable: "/bin/sleep", arguments: ["0.5"])])
        } catch {
            probe.taskError = error
        }
        probe.finishedUptime = ProcessInfo.processInfo.systemUptime
        probe.taskFinished = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        probe.taskFinishedWhenMainBlockRan = probe.taskFinished
        probe.mainBlockRan = true
    }
    try spinMainRunLoop(timeout: 2) { probe.mainBlockRan }
    try expect(probe.taskFinishedWhenMainBlockRan, equals: false,
               "a main-queue block ran while the 0.5 s subprocess was still in flight")
    try spinMainRunLoop(timeout: 2) { probe.taskFinished }
    try expectTrue(probe.taskError == nil, "sleep succeeds: \(String(describing: probe.taskError))")
    try expectTrue(probe.finishedUptime - startedUptime >= 0.45, "the subprocess really ran for about 0.5 s")
}

func testJumpPerformerOffMainRunnerThrowsFirstFailureAndRunsTheRest() throws {
    let directory = try TemporaryDirectory()
    let marker = directory.file("second-action-ran")
    do {
        _ = try waitForAsync(timeout: 5) {
            try await OffMainActionRunner.run([
                .run(executable: "/usr/bin/false", arguments: []),
                .run(executable: "/usr/bin/touch", arguments: [marker.path]),
            ])
            return true
        }
        throw TestFailure.expectation("a failing action must throw")
    } catch let error as FocusError {
        try expect(error, equals: .commandFailed("/usr/bin/false", 1), "the first failure is reported")
    }
    try expectTrue(FileManager.default.fileExists(atPath: marker.path),
                   "later actions still run, as FocusActionRunner does")
}

// MARK: - Herdr focus request

func testJumpPerformerHerdrFocusSendsTargetParameter() throws {
    let server = try FakeHerdrServer()
    defer { server.stop() }
    server.setState(FakeHerdrState(panes: [FakeHerdrPane(paneID: "w1:p1", workspaceID: "w1")],
                                   workspaceLabels: ["w1": "api"]))
    guard case let .herdrFocus(paneID)? = herdrPlan.first else {
        throw TestFailure.expectation("the herdr plan starts with herdrFocus")
    }
    // The exact call LiveJumpPerformer makes for .herdrFocus.
    let client = HerdrClient(socketPath: server.socketPath)
    _ = try waitForAsync(timeout: 5) { try await client.request(.focus(paneID: paneID)) }
    try expect(server.focusRequests, equals: ["w1:p1"], "one agent.focus for the pane")
    guard let record = server.requestLog.last(where: { $0.method == "agent.focus" }),
          let params = try JSONSerialization.jsonObject(with: Data(record.paramsJSON.utf8)) as? NSDictionary else {
        throw TestFailure.expectation("agent.focus was logged with object params")
    }
    try expect(params, equals: ["target": "w1:p1"] as NSDictionary, "agent.focus takes target, never pane_id")
}

// MARK: - Source guard

func testJumpPerformerAppTargetNeverRunsActionsSynchronously() throws {
    let appSources = Fixtures.repositoryRoot.appendingPathComponent("Sources/AgentIsland")
    guard let enumerator = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) else {
        throw TestFailure.expectation("Sources/AgentIsland must exist")
    }
    var offenders: [String] = []
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        if text.contains("FocusActionRunner.run") {
            offenders.append(file.lastPathComponent)
        }
        if file.path.contains("/Jump/"), text.contains("BoundedProcessRunner") || text.contains("waitUntilExit") {
            offenders.append(file.lastPathComponent)
        }
    }
    try expect(offenders, equals: [], "the app target reaches subprocesses only through OffMainActionRunner")
}

let jumpPerformerTests: [TestCase] = [
    ("jumpPerformer: ghostty script focuses the first matching terminal, then activates",
     testJumpPerformerGhosttyScriptFocusesFirstMatchingTerminalThenActivates),
    ("jumpPerformer: ghostty script escapes quotes and backslashes", testJumpPerformerGhosttyScriptEscapesQuotesAndBackslashes),
    ("jumpPerformer: ghostty script flattens newlines", testJumpPerformerGhosttyScriptFlattensNewlines),
    ("jumpPerformer: host-only prefix keeps the host and separator", testJumpPerformerHostOnlyPrefix),
    ("jumpPerformer: raise tries the exact prefix three times, then host-only", testJumpPerformerRaiseAttemptOrder),
    ("jumpPerformer: ghostty script compiles against the installed Ghostty",
     testJumpPerformerGhosttyScriptCompilesAgainstInstalledGhostty),
    ("jumpPerformer: sequencer skips the fallback after a success", testJumpPerformerSequencerSkipsFallbackAfterSuccess),
    ("jumpPerformer: sequencer runs the fallback and treats it as recovered",
     testJumpPerformerSequencerRunsFallbackAndTreatsItAsRecovered),
    ("jumpPerformer: sequencer reports the original failure when the fallback fails",
     testJumpPerformerSequencerReportsOriginalFailureWhenFallbackFails),
    ("jumpPerformer: sequencer runs every primary action and reports the first failure",
     testJumpPerformerSequencerRunsEveryPrimaryActionAndThrowsFirstFailure),
    ("jumpPerformer: sequencer opens needs-input only when continue fails", testJumpPerformerSequencerClaudeFallbackURL),
    ("jumpPerformer: sequencer keeps JumpErrors and handles empty plans",
     testJumpPerformerSequencerKeepsJumpErrorsAndHandlesEmptyPlans),
    ("jumpPerformer: codex app path prefers Codex.app over ChatGPT.app", testJumpPerformerCodexAppPathPrefersCodexApp),
    ("jumpPerformer: claude app path requires the running app", testJumpPerformerClaudeAppPathRequiresRunningApp),
    ("jumpPerformer: off-main runner keeps the main thread free", testJumpPerformerOffMainRunnerKeepsMainThreadFree),
    ("jumpPerformer: off-main runner throws the first failure and runs the rest",
     testJumpPerformerOffMainRunnerThrowsFirstFailureAndRunsTheRest),
    ("jumpPerformer: herdr focus sends agent.focus with target", testJumpPerformerHerdrFocusSendsTargetParameter),
    ("jumpPerformer: app target never runs actions synchronously", testJumpPerformerAppTargetNeverRunsActionsSynchronously),
]

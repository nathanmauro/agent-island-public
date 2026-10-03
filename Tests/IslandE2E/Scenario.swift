// Scenario.swift: the fake world island-e2e drives (FakeHerdrServer, temp registry/rollout/state dirs),
// the app launch, and the steps that assert on the app's state dump (spec §12.3).
import AppKit
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

/// pid of the launched app. The signal handler reads it and cannot hop to the main actor.
nonisolated(unsafe) var e2eChildPID: pid_t = 0

enum E2EInterrupt {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// Ctrl-C or SIGTERM stops the launched app before the driver exits, so no second island is left running.
    static func install() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                if e2eChildPID > 0 { kill(e2eChildPID, SIGTERM) }
                FileHandle.standardError.write(Data("island-e2e: interrupted; sent SIGTERM to the app\n".utf8))
                exit(130)
            }
            source.resume()
            sources.append(source)
        }
    }
}

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Waits in 50 ms slices while draining the main run loop. It never busy-spins, because step 5 measures CPU.
@MainActor
func e2eWait(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        _ = RunLoop.main.run(mode: .default, before: Date())
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return }
        Thread.sleep(forTimeInterval: min(0.05, remaining))
    }
}

struct DumpReader {
    let url: URL

    /// Task 16 writes the dump atomically, so a read never sees a partial file.
    func load() -> (snapshot: StateDumpSnapshot?, problem: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, "no state dump at \(url.path)") }
        do {
            return (try Self.makeDecoder().decode(StateDumpSnapshot.self, from: data), nil)
        } catch {
            return (nil, "the state dump does not decode as StateDumpSnapshot: \(error)")
        }
    }

    /// Accepts either date encoding Task 16 may use: JSONEncoder's default (seconds since 2001) or ISO 8601.
    /// No step compares dates, so either reading is fine.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized date \(text)")
        }
        return decoder
    }
}

enum NCAudit {
    static let islandBundleID = "com.nathan.agent-island"

    /// nc-agent-audit.py's --since format, in local time.
    static func sinceArgument(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Exit 0 or 1: count hit lines ("<ISO date>  <app id>  <title>") by app; only agent-island records fail
    /// this run (other agent apps fail only the trial loop). Exit 2 (no database) and 3 (unreadable) skip.
    ///
    /// Controller ruling (fix round 1, Finding 1b): a crash whose exit code happens to coincide with
    /// "records found" (status 1) — the reviewer's exact repro, an uncaught OSError from an out-of-range
    /// delivered_date — used to read as "0 records, PASS" here, because no hit line matched the parser and
    /// nothing checked the script's own summary line. Now the summary line is required, and its count must
    /// agree with what was actually parsed; anything else (a crash, a truncated run, a partial write) fails.
    static func outcome(status: Int32, output: String) -> StepOutcome {
        switch status {
        case 2:
            return .skipped("no usernoted database")
        case 3:
            return .skipped("usernoted database unreadable; grant Full Disk Access to the terminal")
        case 0, 1:
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            let apps: [String] = lines.compactMap { line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2, let first = fields[0].first, first.isNumber, fields[0].contains("T") else {
                    return nil
                }
                return fields[1].lowercased()
            }
            guard let summaryLine = lines.last(where: { $0.hasPrefix("agent records since ") }) else {
                return .failed("nc-agent-audit.py exited \(status) with no \"agent records since …: N\" summary line (a crash or partial run): \(output.suffix(400))")
            }
            guard let colon = summaryLine.lastIndex(of: ":"),
                  let reportedCount = Int(String(summaryLine[summaryLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)) else {
                return .failed("nc-agent-audit.py's summary line does not end in a number: \(summaryLine)")
            }
            guard reportedCount == apps.count else {
                return .failed("nc-agent-audit.py reported \(reportedCount) record(s) but printed \(apps.count) hit line(s) (a crash or partial run): \(output.suffix(400))")
            }
            guard status == 0 || reportedCount > 0 else {
                return .failed("nc-agent-audit.py exited 1 (records found) but reported 0 records: \(output.suffix(400))")
            }
            let islandCount = apps.filter { $0 == islandBundleID }.count
            if islandCount > 0 {
                return .failed("\(islandCount) Notification Center record(s) from \(islandBundleID)")
            }
            let note = apps.isEmpty ? "" : "; \(apps.count) record(s) from other agent apps (reported only; they fail the trial loop, not this run)"
            return .passed("0 records from \(islandBundleID)" + note)
        default:
            return .failed("nc-agent-audit.py exited \(status): \(output.suffix(400))")
        }
    }
}

@MainActor
enum CodexAppProbe {
    /// Mirrors LiveJumpContextProvider (Task 15): a running com.openai.codex app, or an installed Codex.app.
    static func isPresent() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: KnownBundleIDs.codex).isEmpty {
            return true
        }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: KnownBundleIDs.codex)
            .contains { $0.lastPathComponent == "Codex.app" }
    }
}

/// Spec §1.4 criteria 2 and 5, checked on the first state dump that shows a new chime. The dump must come within
/// 2 s of the agent becoming blocked (the 1 s blocked hold included). The same dump must show the card, on the
/// display under the pointer, because every sound needs a visible card.
enum PeekTiming {
    /// §1.4 criterion 2.
    static let budget: TimeInterval = 2.0
    /// Extra time on a CI runner: the 50 ms dump debounce, the dump's 0.25 s chime poll and FSEvents latency on a
    /// loaded VM.
    static let ciAllowance: TimeInterval = 0.5

    static func limit(isCI: Bool) -> TimeInterval {
        isCI ? budget + ciAllowance : budget
    }

    /// nil when the chime's dump meets criteria 2 and 5; otherwise what is wrong.
    static func problem(latency: TimeInterval, limit: TimeInterval, cardVisible: Bool, cardDisplayID: UInt32?,
                        pointerDisplayIDs: Set<UInt32>) -> String? {
        if latency > limit {
            return "the chime came " + String(format: "%.2f", latency) + " s after the agent blocked; the limit is "
                + String(format: "%.1f", limit) + " s (spec §1.4 criterion 2)"
        }
        guard cardVisible else {
            return "a chime played with no visible card: ui.cardVisible is false (spec §1.4 criterion 5)"
        }
        guard let cardDisplayID else {
            return "ui.cardVisible is true but ui.cardDisplayID is missing"
        }
        guard pointerDisplayIDs.contains(cardDisplayID) else {
            return "the card is on display \(cardDisplayID) but the pointer was on display \(pointerDisplayIDs.sorted()) (spec §1.4 criterion 2)"
        }
        return nil
    }
}

/// The display under the pointer, chosen the way the app places a new card (ScreenSelection.pointerDisplay): the
/// display that contains the pointer, or the main display when the pointer is on none. Reading the pointer's
/// location needs no Accessibility permission, so this works on CI too.
enum PointerDisplay {
    static func current() -> UInt32 {
        let location = CGEvent(source: nil)?.location ?? .zero
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
            return display
        }
        return CGMainDisplayID()
    }
}

@MainActor
final class E2EScenario {
    static let workspaceID = "w1"
    static let workspaceLabel = "e2e-ws"
    static let tabID = "w1:t1"
    static let paneBlocked = "w1:p1"          // step 1: working → blocked
    static let paneDone = "w1:p2"             // step 2: working → done
    static let paneExit = "w1:p3"             // step 2: pane_exited, never closed → error
    static let paneUserClose = "w1:p4"        // step 2: exited + closed at once → no error
    static let paneWaitingAtLaunch = "w1:p5"  // step 0: already blocked when the app starts
    static let allPanes = [paneBlocked, paneDone, paneExit, paneUserClose, paneWaitingAtLaunch]
    static let quietMargin: TimeInterval = 1.5
    static let soakSettle: TimeInterval = 15
    static let detectionText = """
        ────────────────────────────────────────
         Do you want to apply the fixture edit?

         ❯ 1. Yes
           2. No
        """

    let appURL: URL
    let muteChime: Bool
    let temp: TemporaryDirectory
    let server: FakeHerdrServer
    let claudeSessionsDir: URL
    let codexSessionsDir: URL
    let stateDir: URL
    let dumpURL: URL
    let appLogURL: URL
    let codexThreadID: String
    let codexRolloutURL: URL
    let dumpReader: DumpReader
    private var app: Process?
    private var launchedAt = Date.distantPast

    var codexRowID: RowID { RowID(source: .codexDesktop, key: codexThreadID) }
    var transitionLogURL: URL { stateDir.appendingPathComponent("log/transitions.jsonl") }

    init(appPath: String, muteChime: Bool) throws {
        let fileManager = FileManager.default
        let tempDirectory = try TemporaryDirectory(prefix: "island-e2e")
        let root = tempDirectory.url
        let claudeDir = root.appendingPathComponent("claude-sessions", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        let codexDir = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        for directory in [claudeDir, codexDir, state.appendingPathComponent("support", isDirectory: true),
                          state.appendingPathComponent("log", isDirectory: true)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // One visible Codex Desktop thread with a turn in progress: working, or stale while Codex is not running.
        let now = Date()
        let threadID = UUID().uuidString.lowercased()
        let dayDir = codexDir.appendingPathComponent(E2EScenario.dayPath(now), isDirectory: true)
        try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let rollout = dayDir.appendingPathComponent(RolloutLine.fileName(threadID: threadID, at: now))
        try E2EScenario.writeFile(rollout, E2EScenario.jsonl([
            RolloutLine.sessionMeta(id: threadID, at: now),
            RolloutLine.taskStarted(turnID: "e2e-turn-1", at: now),
        ]))
        let indexLine = try JSONSerialization.data(
            withJSONObject: ["id": threadID, "thread_name": "E2E fixture thread",
                             "updated_at": ISO8601DateFormatter().string(from: now)],
            options: [.sortedKeys])
        try E2EScenario.writeFile(codexRoot.appendingPathComponent("session_index.jsonl"), indexLine + Data("\n".utf8))

        let fakeHerdr = try FakeHerdrServer()

        appURL = URL(fileURLWithPath: appPath)
        self.muteChime = muteChime
        temp = tempDirectory
        server = fakeHerdr
        claudeSessionsDir = claudeDir
        codexSessionsDir = codexDir
        stateDir = state
        dumpURL = root.appendingPathComponent("state-dump.json")
        appLogURL = root.appendingPathComponent("app.log")
        codexThreadID = threadID
        codexRolloutURL = rollout
        dumpReader = DumpReader(url: root.appendingPathComponent("state-dump.json"))

        server.setState(E2EScenario.initialHerdrState())
        for paneID in E2EScenario.allPanes {
            server.setProcessInfo(paneID: paneID, foregroundPIDs: [])
        }
        server.setDetectionText(paneID: E2EScenario.paneWaitingAtLaunch, E2EScenario.detectionText)
    }

    // MARK: - Launch

    /// NSArgumentDomain overrides, so Nathan's real com.nathan.agent-island preferences cannot change the assertions.
    var launchArguments: [String] {
        ["-\(PreferenceKeys.chimeMuted)", muteChime ? "YES" : "NO",
         "-\(PreferenceKeys.showExecThreads)", "NO",
         "-\(PreferenceKeys.screenSelectionMode)", "primary",
         "-\(PreferenceKeys.hideWhenEmpty)", "NO"]
    }

    var launchEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[EnvironmentKeys.herdrSocketPath] = server.socketPath
        environment[EnvironmentKeys.codexSessionsDir] = codexSessionsDir.path
        environment[EnvironmentKeys.claudeSessionsDir] = claudeSessionsDir.path
        environment[EnvironmentKeys.stateDir] = stateDir.path
        environment[EnvironmentKeys.stateDump] = dumpURL.path
        environment[EnvironmentKeys.jumpDryRun] = "1"
        environment[EnvironmentKeys.frontmostOverride] = "com.apple.finder"
        environment[EnvironmentKeys.herdrContract] = nil
        return environment
    }

    func launch() throws {
        let executable = appURL.appendingPathComponent("Contents/MacOS/AgentIsland")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw E2EError("no executable at \(executable.path); run scripts/build-app.sh first")
        }
        try E2EScenario.writeFile(appLogURL, Data())
        let log = try FileHandle(forWritingTo: appLogURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = launchArguments
        process.environment = launchEnvironment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        app = process
        launchedAt = Date()
        e2eChildPID = process.processIdentifier

        let ready = waitForDump(timeout: 30) { dump in
            E2EScenario.health(dump, .herdr)?.isOnline == true
                && dump.rows.filter { $0.source == .herdr }.count == E2EScenario.allPanes.count
                && dump.rows.contains { $0.id == self.codexRowID }
        }
        guard ready != nil else {
            throw E2EError("within 30 s the app did not report Herdr online with \(E2EScenario.allPanes.count) Herdr rows and the Codex row: \(latestDumpDescription()); app log \(appLogURL.path)")
        }
    }

    // MARK: - Step 0: launch quiet guard

    /// Spec §7.4 and §10: nothing peeks or chimes during the 10 s quiet period after launch, and a pane that is
    /// already waiting at launch shows in the count only (Task 13: its episode is marked announced). The wake
    /// handler reuses this guard (Task 14).
    func stepLaunchGuard() -> StepOutcome {
        let rowID = RowID(source: .herdr, key: E2EScenario.paneWaitingAtLaunch)
        let observeUntil = launchedAt.addingTimeInterval(IslandTiming.quietPeriod + E2EScenario.quietMargin + 2)
        var violation: String?
        repeat {
            if violation == nil, let dump = dumpReader.load().snapshot,
               dump.chimePlayedCount > 0 || dump.peekQueue.current != nil || !dump.peekQueue.pending.isEmpty {
                violation = E2EScenario.describe(dump)
            }
            e2eWait(0.1)
        } while Date() < observeUntil
        if let violation {
            return .failed("a peek or chime happened with only a launch-time waiting row: \(violation)")
        }
        guard let dump = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        guard dump.rows.first(where: { $0.id == rowID })?.state == .waiting, dump.summaryText.contains("1 waiting") else {
            return .failed("the pane blocked at launch should count as \"1 waiting\": \(E2EScenario.describe(dump))")
        }
        let logged = waitFor(timeout: 3) {
            self.transitionRecords().contains { record in
                (record["rule"] as? String) == PolicyRule.quietPeriod.rawValue
                    && ((record["rowID"] as? String) ?? "").contains(E2EScenario.paneWaitingAtLaunch)
            }
        }
        guard logged else {
            return .failed("\(transitionLogURL.path) has no \(PolicyRule.quietPeriod.rawValue) record for \(rowID)")
        }
        // Remove the launch-time row so step 1 starts from its own "1 waiting".
        server.emitPaneClosed(paneID: E2EScenario.paneWaitingAtLaunch)
        server.updateState { state in
            state.panes.removeAll { pane in pane.paneID == E2EScenario.paneWaitingAtLaunch }
        }
        guard waitForDump(timeout: 5, { dump in !dump.rows.contains { $0.id == rowID } }) != nil else {
            return .failed("the closed launch-time pane is still listed: \(latestDumpDescription())")
        }
        return .passed("the pane blocked at launch counted as waiting with no peek or chime; \(PolicyRule.quietPeriod.rawValue) logged")
    }

    // MARK: - Step 1: Herdr blocked

    func stepHerdrBlocked(isCI: Bool) -> StepOutcome {
        guard waitForPeekIdle() else { return .failed("an earlier peek never finished: \(latestDumpDescription())") }
        let rowID = RowID(source: .herdr, key: E2EScenario.paneBlocked)
        let chimesBefore = dumpReader.load().snapshot?.chimePlayedCount ?? 0
        server.setDetectionText(paneID: E2EScenario.paneBlocked, E2EScenario.detectionText)
        let pointerAtBlock = PointerDisplay.current()
        let blockedAt = Date()
        server.emitStatus(paneID: E2EScenario.paneBlocked, status: "blocked")
        guard let arrival = waitForChime(after: chimesBefore, timeout: 8) else {
            return .failed("blocked > 1 s: expected summaryText containing \"1 waiting\", peekQueue.current \(rowID) and a chime; got \(latestDumpDescription())")
        }
        let chimed = arrival.dump
        guard chimed.summaryText.contains("1 waiting"), chimed.peekQueue.current == rowID else {
            return .failed("blocked > 1 s: the dump with the chime should show \"1 waiting\" and peekQueue.current \(rowID); got \(E2EScenario.describe(chimed))")
        }
        let latency = arrival.seenAt.timeIntervalSince(blockedAt)
        if let problem = PeekTiming.problem(latency: latency, limit: PeekTiming.limit(isCI: isCI),
                                            cardVisible: chimed.ui.cardVisible, cardDisplayID: chimed.ui.cardDisplayID,
                                            pointerDisplayIDs: Set([pointerAtBlock, PointerDisplay.current()])) {
            return .failed("Herdr blocked: \(problem); \(E2EScenario.describe(chimed))")
        }
        e2eWait(1.5)
        guard let settled = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        guard settled.chimePlayedCount == chimesBefore + 1 else {
            return .failed("chimePlayedCount went from \(chimesBefore) to \(settled.chimePlayedCount); expected exactly one chime")
        }
        let expected: [JumpAction] = [
            .herdrFocus(paneID: E2EScenario.paneBlocked),
            .raiseGhostty(windowTitlePrefix: "\(HostName.short()): \(E2EScenario.workspaceLabel)"),
            .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: true),
        ]
        let plan = settled.plannedJumps[rowID.description]
        guard plan == expected else {
            return .failed("plannedJumps[\(rowID)] is \(plan.map { "\($0)" } ?? "missing"); expected \(expected)")
        }
        let cardDisplay = chimed.ui.cardDisplayID.map { "\($0)" } ?? "?"
        return .passed("\"\(settled.summaryText)\", peek \(rowID) with its card on display \(cardDisplay) "
            + String(format: "%.2f", latency) + " s after blocked, exactly one chime, plan herdrFocus → raiseGhostty → activateApp")
    }

    // MARK: - Step 2: other Herdr transitions

    func stepHerdrTransitions() -> StepOutcome {
        guard waitForPeekIdle() else { return .failed("an earlier peek never finished: \(latestDumpDescription())") }
        let doneRow = RowID(source: .herdr, key: E2EScenario.paneDone)
        let errorRow = RowID(source: .herdr, key: E2EScenario.paneExit)
        let closedRow = RowID(source: .herdr, key: E2EScenario.paneUserClose)

        // done → "1 done", silently.
        let chimesBefore = dumpReader.load().snapshot?.chimePlayedCount ?? 0
        server.emitStatus(paneID: E2EScenario.paneDone, status: "done")
        guard waitForDump(timeout: 6, { $0.summaryText.contains("1 done") }) != nil else {
            return .failed("done: expected summaryText containing \"1 done\"; got \(latestDumpDescription())")
        }
        e2eWait(2)
        guard let afterDone = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        if afterDone.chimePlayedCount != chimesBefore {
            return .failed("done chimed: chimePlayedCount \(chimesBefore) → \(afterDone.chimePlayedCount)")
        }
        if afterDone.peekQueue.current == doneRow || afterDone.peekQueue.pending.contains(doneRow) {
            return .failed("done peeked: \(E2EScenario.describe(afterDone))")
        }

        // pane_exited while working and no pane_closed → error row and error peek after the 1 s grace.
        // Controller ruling (Task 6 review): FakeHerdrServer.emitPaneExited alone leaves the pane's agent
        // field set, so session.snapshot still lists it in `agents`. A Herdr reconcile (every 12 s) landing
        // in the up-to-8-s window before this step used to remove the pane could see that stale "working"
        // pane and erase the error before the tombstone took effect. Clearing the pane's agent at exit
        // time (and never removing the pane outright) closes that flake window: the fake cannot be edited
        // here, so the driver does it instead of the fake.
        server.updateState { state in
            if let index = state.panes.firstIndex(where: { $0.paneID == E2EScenario.paneExit }) {
                state.panes[index].agent = nil
            }
        }
        server.emitPaneExited(paneID: E2EScenario.paneExit)
        guard waitForDump(timeout: 8, { dump in
            dump.rows.first(where: { $0.id == errorRow })?.state == .error
                && (dump.peekQueue.current == errorRow || dump.peekQueue.pending.contains(errorRow))
        }) != nil else {
            return .failed("exit without close: expected \(errorRow) in state error with a peek; got \(latestDumpDescription())")
        }

        // User close: exit, then close within 1 s → no error.
        server.emitPaneExited(paneID: E2EScenario.paneUserClose)
        server.emitPaneClosed(paneID: E2EScenario.paneUserClose)
        e2eWait(IslandTiming.herdrExitGrace + 2)
        guard let afterClose = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        if afterClose.rows.contains(where: { $0.id == closedRow && $0.state == .error }) {
            return .failed("user close produced an error row: \(E2EScenario.describe(afterClose))")
        }
        if afterClose.peekQueue.current == closedRow || afterClose.peekQueue.pending.contains(closedRow) {
            return .failed("user close produced a peek: \(E2EScenario.describe(afterClose))")
        }
        return .passed("done → \"1 done\" with no chime; exit without close → error row and error peek; exit + close within 1 s → no error")
    }

    // MARK: - Step 3: Codex and the Claude registry

    func stepCodexAndRegistry(isCI: Bool) -> StepOutcome {
        guard waitForPeekIdle() else { return .failed("an earlier peek never finished: \(latestDumpDescription())") }
        let codexRow = codexRowID
        let limit = PeekTiming.limit(isCI: isCI)
        let chimesBefore = dumpReader.load().snapshot?.chimePlayedCount ?? 0
        let pointerAtAppend = PointerDisplay.current()
        let appendedAt = Date()
        do {
            try E2EScenario.append([RolloutLine.functionCall(name: "request_user_input", callID: "e2e-call-1",
                                                             question: "E2E fixture question?",
                                                             options: ["Option A", "Option B"], at: Date())],
                                   to: codexRolloutURL)
        } catch {
            return .failed("could not append to \(codexRolloutURL.path): \(error)")
        }
        guard let codexArrival = waitForChime(after: chimesBefore, timeout: 10) else {
            return .failed("Codex request_user_input: expected a waiting row, peekQueue.current \(codexRow) and a chime; got \(latestDumpDescription())")
        }
        let codexChimed = codexArrival.dump
        guard codexChimed.rows.first(where: { $0.id == codexRow })?.state == .waiting,
              codexChimed.peekQueue.current == codexRow else {
            return .failed("Codex request_user_input: the dump with the chime should show \(codexRow) waiting as peekQueue.current; got \(E2EScenario.describe(codexChimed))")
        }
        let codexLatency = codexArrival.seenAt.timeIntervalSince(appendedAt)
        if let problem = PeekTiming.problem(latency: codexLatency, limit: limit,
                                            cardVisible: codexChimed.ui.cardVisible, cardDisplayID: codexChimed.ui.cardDisplayID,
                                            pointerDisplayIDs: Set([pointerAtAppend, PointerDisplay.current()])) {
            return .failed("Codex request_user_input: \(problem); \(E2EScenario.describe(codexChimed))")
        }
        e2eWait(1.5)
        guard let codexDump = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        guard codexDump.chimePlayedCount == chimesBefore + 1 else {
            return .failed("Codex: chimePlayedCount went from \(chimesBefore) to \(codexDump.chimePlayedCount); expected exactly one chime")
        }
        let plan = codexDump.plannedJumps[codexRow.description] ?? []
        if let problem = E2EScenario.codexPlanProblem(plan, threadID: codexThreadID, codexPresent: CodexAppProbe.isPresent()) {
            return .failed(problem)
        }

        // The Codex card has retired (8 s), so the 3 s chime gap is over and the registry peek must chime too.
        guard waitForPeekIdle() else { return .failed("the Codex peek never finished: \(latestDumpDescription())") }
        let registryChimesBefore = dumpReader.load().snapshot?.chimePlayedCount ?? 0
        let pid = getpid()
        guard let processStart = E2EScenario.processStartText(pid) else {
            return .failed("ps -o lstart= failed for the driver's pid \(pid)")
        }
        let pointerAtWrite = PointerDisplay.current()
        let writtenAt = Date()
        do {
            try writeRegistryEntry(pid: pid, processStart: processStart)
        } catch {
            return .failed("could not write the registry entry: \(error)")
        }
        guard let registryArrival = waitForChime(after: registryChimesBefore, timeout: 10) else {
            return .failed("registry: expected a waiting row for pid \(pid) with a peek and a chime; got \(latestDumpDescription())")
        }
        let registryChimed = registryArrival.dump
        guard let registryRow = registryChimed.rows.first(where: { $0.source == .claudeRegistry && $0.processIDs.contains(pid) }),
              registryRow.state == .waiting, registryChimed.peekQueue.current == registryRow.id else {
            return .failed("registry: the dump with the chime should show a waiting row for pid \(pid) as peekQueue.current; got \(E2EScenario.describe(registryChimed))")
        }
        let registryLatency = registryArrival.seenAt.timeIntervalSince(writtenAt)
        if let problem = PeekTiming.problem(latency: registryLatency, limit: limit,
                                            cardVisible: registryChimed.ui.cardVisible, cardDisplayID: registryChimed.ui.cardDisplayID,
                                            pointerDisplayIDs: Set([pointerAtWrite, PointerDisplay.current()])) {
            return .failed("registry: \(problem); \(E2EScenario.describe(registryChimed))")
        }
        e2eWait(1.5)
        guard let registrySettled = dumpReader.load().snapshot else { return .failed(latestDumpDescription()) }
        guard registrySettled.chimePlayedCount == registryChimesBefore + 1 else {
            return .failed("registry: chimePlayedCount went from \(registryChimesBefore) to \(registrySettled.chimePlayedCount); expected exactly one chime")
        }
        let planText = plan.isEmpty ? "[] (no Codex app on this Mac)" : "openURL codex://threads/<id>"
        return .passed("Codex waiting with its card and one chime " + String(format: "%.2f", codexLatency)
            + " s after the append, plan \(planText); registry \(registryRow.id.description) waiting with its card and one chime "
            + String(format: "%.2f", registryLatency) + " s after the write")
    }

    /// Task 15: [] without a Codex app, else exactly one openURL("codex://threads/<id>", appPath: <bundle>, false).
    static func codexPlanProblem(_ plan: [JumpAction], threadID: String, codexPresent: Bool) -> String? {
        if plan.isEmpty {
            return codexPresent ? "a Codex app is installed or running but the Codex row's plannedJumps is []" : nil
        }
        guard plan.count == 1, case let .openURL(url, appPath, onlyIfPreviousFailed) = plan[0] else {
            return "the Codex row's plannedJumps is \(plan); expected [] or exactly one openURL"
        }
        if url != "codex://threads/\(threadID)" { return "Codex openURL is \(url); expected codex://threads/\(threadID)" }
        if appPath == nil { return "Codex openURL has no appPath (ChatGPT.app also claims codex:)" }
        if onlyIfPreviousFailed { return "Codex openURL must not be fallback-only" }
        return nil
    }

    /// A live, interactive, waiting registry entry for the driver's own pid with its real lstart. The file is
    /// staged as 0600 and renamed in, so the feed never sees a partial or group-writable file.
    func writeRegistryEntry(pid: pid_t, processStart: String, status: String = "waiting",
                            updatedAt: Date = Date()) throws {
        let entry: [String: Any] = [
            "pid": Int(pid),
            "sessionId": UUID().uuidString.lowercased(),
            "cwd": "/tmp/fixture-project",
            "procStart": processStart,
            "kind": "interactive",
            "entrypoint": "cli",
            "name": "e2e-registry",
            "status": status,
            "waitingFor": "permission prompt",
            "statusUpdatedAt": Int64(updatedAt.timeIntervalSince1970 * 1000),
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        let staging = temp.url.appendingPathComponent("registry-staging.json")
        try? FileManager.default.removeItem(at: staging)
        try E2EScenario.writeFile(staging, data, permissions: 0o600)
        let destination = claudeSessionsDir.appendingPathComponent("\(pid).json")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    // MARK: - Step 7: stale activity and recovery through the real registry feed

    func stepStaleRecovery() -> StepOutcome {
        guard waitForPeekIdle() else { return .failed("an earlier peek never finished") }
        let pid = getpid()
        guard let processStart = E2EScenario.processStartText(pid) else {
            return .failed("could not identify the fixture process")
        }
        let chimesBefore = dumpReader.load().snapshot?.chimePlayedCount
        do {
            try writeRegistryEntry(pid: pid, processStart: processStart, status: "busy",
                                   updatedAt: Date().addingTimeInterval(-3600))
            guard let staleDump = waitForDump(timeout: 10, { dump in
                dump.rows.contains { $0.source == .claudeRegistry && $0.processIDs.contains(pid) && $0.state == .stale }
            }) else { return .failed("old registry activity did not become stale: \(latestDumpDescription())") }
            let staleCount = staleDump.rows.filter { $0.state == .stale }.count
            let workingCount = staleDump.rows.filter { $0.state == .working }.count
            guard staleDump.segments.first(where: { $0.kind == .stale })?.count == staleCount,
                  (staleDump.segments.first(where: { $0.kind == .working })?.count ?? 0) == workingCount else {
                return .failed("stale activity was counted as working: \(staleDump.summaryText)")
            }
            try writeRegistryEntry(pid: pid, processStart: processStart, status: "busy")
            guard let freshDump = waitForDump(timeout: 10, { dump in
                dump.rows.contains { $0.source == .claudeRegistry && $0.processIDs.contains(pid) && $0.state == .working }
            }) else { return .failed("fresh registry activity did not return to working: \(latestDumpDescription())") }
            guard (freshDump.segments.first(where: { $0.kind == .stale })?.count ?? 0) == staleCount - 1,
                  freshDump.segments.first(where: { $0.kind == .working })?.count == workingCount + 1,
                  freshDump.chimePlayedCount == chimesBefore else {
                return .failed("recovery did not move exactly one count silently: \(freshDump.summaryText)")
            }
            e2eWait(1.5) // Cover the policy's blocked hold and the UI's chime-count poll.
            guard let settled = dumpReader.load().snapshot,
                  let fixtureRow = settled.rows.first(where: { $0.source == .claudeRegistry && $0.processIDs.contains(pid) }),
                  settled.chimePlayedCount == chimesBefore,
                  settled.peekQueue.current != fixtureRow.id,
                  !settled.peekQueue.pending.contains(fixtureRow.id) else {
                return .failed("stale recovery unexpectedly queued a card or played a delayed chime")
            }
            return .passed("old registry activity counts as stale; fresh activity moves one count to working without a chime")
        } catch { return .failed("registry recovery fixture: \(error)") }
    }

    // MARK: - Step 4: synthetic mouse

    func stepPointer(isCI: Bool) -> StepOutcome {
        if isCI { return .skipped("CI runner") }
        guard SyntheticMouse.isTrusted else { return .skipped("grant Accessibility to the terminal") }
        guard waitForPeekIdle(), let before = dumpReader.load().snapshot else {
            return .failed("the peek queue never went idle: \(latestDumpDescription())")
        }
        let displayID: CGDirectDisplayID = before.ui.primaryDisplayID ?? CGMainDisplayID()
        guard before.ui.pillDisplayIDs.contains(displayID) else {
            return .failed("ui.pillDisplayIDs \(before.ui.pillDisplayIDs) does not contain the primary display \(displayID)")
        }
        let points = PillProbePoints(displayBounds: CGDisplayBounds(displayID))
        let original = SyntheticMouse.currentLocation()
        defer { SyntheticMouse.move(to: original) }

        SyntheticMouse.move(to: points.pillCenter)
        guard waitForDump(timeout: 2, { $0.ui.boardExpanded && !$0.ui.pillIgnoresMouseEvents }) != nil else {
            return .failed("pointer on the pill center \(points.pillCenter): expected ui.boardExpanded true and ui.pillIgnoresMouseEvents false; got \(latestDumpDescription())")
        }
        // Leave the expanded board sideways: it spans the full 800 pt panel width, so a straight move down
        // would stay inside it.
        SyntheticMouse.move(to: points.outsidePanel)
        guard waitForDump(timeout: 1.25, { !$0.ui.boardExpanded && $0.ui.pillIgnoresMouseEvents }) != nil else {
            return .failed("pointer outside the panel at \(points.outsidePanel): expected the board to collapse within 1 s; got \(latestDumpDescription())")
        }
        // 100 pt below the pill, inside the panel frame: must stay click-through and collapsed.
        SyntheticMouse.move(to: points.belowPill)
        e2eWait(1.0)
        guard let below = dumpReader.load().snapshot, !below.ui.boardExpanded, below.ui.pillIgnoresMouseEvents else {
            return .failed("pointer 100 pt below the pill at \(points.belowPill): expected ui.pillIgnoresMouseEvents true and ui.boardExpanded false; got \(latestDumpDescription())")
        }
        return .passed("hover on the pill expands the board and takes mouse events; leaving collapses within 1 s; 100 pt below the pill stays click-through")
    }

    // MARK: - Step 5: soak

    func stepSoak(seconds: Int) -> StepOutcome {
        guard seconds > 0 else { return .skipped("--soak-seconds 0") }
        guard let process = app, process.isRunning else { return .failed(appExitDescription() ?? "the app is not running") }
        _ = waitForPeekIdle()
        e2eWait(E2EScenario.soakSettle)
        let pid = process.processIdentifier
        let interval = max(1, min(5, seconds / 6))
        let sampleCount = seconds / interval + 1
        let cpuTimeStart = ProcessSampler.cpuTimeSeconds(pid: pid)
        let wallStart = Date()
        var samples: [SoakSample] = []
        for index in 0..<sampleCount {
            if index > 0 { e2eWait(TimeInterval(interval)) }
            guard let cpu = ProcessSampler.cpuPercent(pid: pid), let files = ProcessSampler.openFileCount(pid: pid) else {
                return .failed("ps/lsof stopped answering for pid \(pid) at sample \(index + 1): \(appExitDescription() ?? "the app is still running")")
            }
            samples.append(SoakSample(cpuPercent: cpu, openFiles: files))
        }
        let verdict = ProcessSampler.evaluate(samples)
        var detail = "\(seconds) s soak: \(verdict.summary)"
        if let start = cpuTimeStart, let end = ProcessSampler.cpuTimeSeconds(pid: pid) {
            let elapsed = max(1, Date().timeIntervalSince(wallStart))
            detail += "; cumulative CPU time gives " + String(format: "%.2f", (end - start) / elapsed * 100) + " %"
        }
        return verdict.passed ? .passed(detail) : .failed(detail)
    }

    // MARK: - Step 6: Notification Center audit

    func stepNotificationAudit(since: Date, isCI: Bool) -> StepOutcome {
        if isCI { return .skipped("CI runner") }
        let script = Fixtures.repositoryRoot.appendingPathComponent("scripts/nc-agent-audit.py").path
        let result = ProcessSampler.run("/usr/bin/env", ["python3", script, "--since", NCAudit.sinceArgument(since)],
                                        includeStandardError: true)
        return NCAudit.outcome(status: result.status, output: result.output)
    }

    // MARK: - Teardown and diagnostics

    func appExitDescription() -> String? {
        guard let process = app else { return "the app was never launched" }
        if process.isRunning { return nil }
        return "the app exited with status \(process.terminationStatus); log \(appLogURL.path)"
    }

    func shutDown() {
        if let process = app, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { e2eWait(0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        e2eChildPID = 0
        server.stop()
    }

    /// Copies the dump, the transition log and the app log into .build/e2e-artifacts/<timestamp>/ (gitignored),
    /// because the temp directory is removed when the driver exits.
    func saveArtifacts() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = Fixtures.repositoryRoot
            .appendingPathComponent(".build/e2e-artifacts/\(formatter.string(from: Date()))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in [dumpURL, appLogURL, transitionLogURL] where FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
            }
            print("island-e2e: artifacts saved to \(destination.path)")
        } catch {
            print("island-e2e: could not save artifacts: \(error)")
        }
    }

    // MARK: - Polling helpers

    func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            e2eWait(0.1)
        }
    }

    func waitForDump(timeout: TimeInterval, _ predicate: (StateDumpSnapshot) -> Bool) -> StateDumpSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let dump = dumpReader.load().snapshot, predicate(dump) { return dump }
            if Date() >= deadline { return nil }
            e2eWait(0.1)
        }
    }

    /// The first dump whose chime count is above `before`, and when the driver saw it. The driver polls every
    /// 0.1 s, so the measured latency overstates the app's by at most one poll plus a file read.
    func waitForChime(after before: Int, timeout: TimeInterval) -> (dump: StateDumpSnapshot, seenAt: Date)? {
        guard let dump = waitForDump(timeout: timeout, { $0.chimePlayedCount > before }) else { return nil }
        return (dump: dump, seenAt: Date())
    }

    /// Idle peek queue: no card showing and nothing pending (a card stays up 8 s, so allow two).
    func waitForPeekIdle(timeout: TimeInterval = 30) -> Bool {
        let idle = waitForDump(timeout: timeout) { dump in
            dump.peekQueue.current == nil && dump.peekQueue.pending.isEmpty && !dump.ui.cardVisible
        }
        return idle != nil
    }

    func transitionRecords() -> [[String: Any]] {
        guard let text = try? String(contentsOf: transitionLogURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    func latestDumpDescription() -> String {
        let result = dumpReader.load()
        if let snapshot = result.snapshot { return E2EScenario.describe(snapshot) }
        return result.problem ?? "no state dump"
    }

    // MARK: - Static helpers

    static func initialHerdrState() -> FakeHerdrState {
        let panes = allPanes.enumerated().map { index, paneID in
            FakeHerdrPane(paneID: paneID, workspaceID: workspaceID, tabID: tabID, agent: "claude",
                          status: paneID == paneWaitingAtLaunch ? "blocked" : "working",
                          title: "E2E pane \(index + 1)", cwd: "/tmp/fixture-project", focused: false, stateChangeSeq: 1)
        }
        return FakeHerdrState(panes: panes, workspaceLabels: [workspaceID: workspaceLabel],
                              tabLabels: [tabID: "main"], focusedPaneID: nil)
    }

    /// feedHealth is keyed by SessionSource.rawValue (Task 16); displayName and case-insensitive keys are tolerated.
    static func health(_ dump: StateDumpSnapshot, _ source: SessionSource) -> FeedHealth? {
        if let health = dump.feedHealth[source.rawValue] { return health }
        if let health = dump.feedHealth[source.displayName] { return health }
        return dump.feedHealth.first { $0.key.caseInsensitiveCompare(source.rawValue) == .orderedSame }?.value
    }

    static func describe(_ dump: StateDumpSnapshot) -> String {
        let rows = dump.rows.map { "\($0.id.description)=\($0.state.rawValue)" }.joined(separator: " ")
        let pending = dump.peekQueue.pending.map(\.description).joined(separator: ",")
        return "summary=\"\(dump.summaryText)\" rows=[\(rows)] peek.current=\(dump.peekQueue.current?.description ?? "nil") "
            + "peek.pending=[\(pending)] chimes=\(dump.chimePlayedCount) ui.boardExpanded=\(dump.ui.boardExpanded) "
            + "ui.pillIgnoresMouseEvents=\(dump.ui.pillIgnoresMouseEvents) ui.cardVisible=\(dump.ui.cardVisible) "
            + "ui.cardDisplayID=\(dump.ui.cardDisplayID.map { "\($0)" } ?? "nil")"
    }

    static func processStartText(_ pid: pid_t) -> String? {
        let result = ProcessSampler.run("/bin/ps", ["-o", "lstart=", "-p", String(pid)], environment: ["LC_ALL": "C"])
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !text.isEmpty ? text : nil
    }

    static func dayPath(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    static func jsonl(_ lines: [String]) -> Data {
        Data(lines.map { $0.trimmingCharacters(in: .newlines) + "\n" }.joined().utf8)
    }

    static func writeFile(_ url: URL, _ data: Data, permissions: Int = 0o644) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw E2EError("could not create \(url.path)")
        }
    }

    static func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonl(lines))
    }
}

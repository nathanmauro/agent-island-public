// DemoScenario.swift: `island-e2e --demo SECONDS` runs the built app against a curated, fully synthetic world
// (fake Herdr panes, one Codex Desktop thread, one Claude registry session) and holds it on screen so README
// screenshots can be captured. scripts/demo.sh builds the bundle and runs it. Every name, path and question
// here is invented: the app only ever sees the temp directories and the fake Herdr socket, never real feeds.
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

struct DemoOptions: Equatable {
    static let displayModes = ["primary", "allDisplays"]
    static let usage = "usage: island-e2e --app PATH --demo SECONDS [--display-mode primary|allDisplays]"

    enum Outcome: Equatable {
        case options(DemoOptions)
        case usageError(String)

        var isUsageError: Bool { if case .usageError = self { return true } else { return false } }
    }

    var appPath: String
    var seconds: Int
    var displayMode: String

    static func parse(_ arguments: [String]) -> Outcome {
        var appPath: String?
        var seconds: Int?
        var displayMode = "primary"
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { return .usageError("missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--app":
                appPath = value
            case "--demo":
                guard let parsed = Int(value), parsed > 0 else {
                    return .usageError("--demo takes a positive whole number of seconds, got \(value)")
                }
                seconds = parsed
            case "--display-mode":
                guard displayModes.contains(value) else {
                    return .usageError("--display-mode takes primary or allDisplays, got \(value)")
                }
                displayMode = value
            default:
                return .usageError("unknown demo argument \(flag)")
            }
            index += 2
        }
        guard let appPath else { return .usageError("--app is required") }
        guard let seconds else { return .usageError("--demo is required") }
        return .options(DemoOptions(appPath: appPath, seconds: seconds, displayMode: displayMode))
    }
}

/// One synthetic Herdr pane: `workspace › tab`, the terminal title the row shows, and the project whose fake
/// git HEAD gives the row its branch.
struct DemoPane {
    let paneID: String
    let workspaceID: String
    let tabID: String
    let tabLabel: String
    let title: String
    let status: String
    let project: String
    let recap: String?
}

@MainActor
final class DemoScenario {
    /// Blocks after the 10 s launch quiet period, so its card pops exactly as a real question would.
    static let blockAfter: TimeInterval = IslandTiming.quietPeriod + 2
    static let blockedPaneID = "w3:p1"
    static let workspaces: [String: String] = [
        "w1": "api-gateway", "w2": "web-app", "w3": "infra", "w4": "docs-site", "w5": "mobile",
    ]
    static let panes: [DemoPane] = [
        DemoPane(paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", tabLabel: "auth-refactor",
                 title: "Refactor token refresh", status: "working", project: "api-gateway", recap: nil),
        DemoPane(paneID: "w1:p2", workspaceID: "w1", tabID: "w1:t2", tabLabel: "load-tests",
                 title: "Tune rate limiter", status: "idle", project: "api-gateway", recap: nil),
        DemoPane(paneID: "w2:p1", workspaceID: "w2", tabID: "w2:t1", tabLabel: "checkout-flow",
                 title: "Fix checkout validation", status: "working", project: "web-app", recap: nil),
        DemoPane(paneID: "w2:p2", workspaceID: "w2", tabID: "w2:t2", tabLabel: "storybook",
                 title: "Update button stories", status: "idle", project: "web-app", recap: nil),
        DemoPane(paneID: blockedPaneID, workspaceID: "w3", tabID: "w3:t1", tabLabel: "terraform-plan",
                 title: "Plan staging rollout", status: "working", project: "infra", recap: nil),
        DemoPane(paneID: "w4:p1", workspaceID: "w4", tabID: "w4:t1", tabLabel: "release-notes",
                 title: "Draft v2.4 release notes", status: "done", project: "docs-site",
                 recap: "Drafted the v2.4 notes: 12 changes grouped by area, ready for review."),
        DemoPane(paneID: "w5:p1", workspaceID: "w5", tabID: "w5:t1", tabLabel: "crash-triage",
                 title: "Triage iOS crash reports", status: "done", project: "mobile",
                 recap: "Top crash is a nil session token on resume; the fix is on fix/resume-token."),
        DemoPane(paneID: "w5:p2", workspaceID: "w5", tabID: "w5:t2", tabLabel: "profiling",
                 title: "Profile cold start", status: "idle", project: "mobile", recap: nil),
    ]
    static let branches: [String: String] = [
        "api-gateway": "feat/token-refresh", "web-app": "fix/checkout-validation", "infra": "ops/staging-plan",
        "docs-site": "docs/v2.4-notes", "mobile": "fix/resume-token", "billing-service": "feat/billing-v2",
        "data-pipeline": "main",
    ]
    static let blockedDetectionText = """
        ⏺ terraform plan: 3 to add, 1 to change, 0 to destroy.

        ────────────────────────────────────────
         Apply this plan to staging?

         ❯ 1. Apply
           2. Show the diff first
           3. Cancel
        ────────────────────────────────────────
        """
    static let codexThreadTitle = "Migrate billing to v2"
    static let registryName = "Backfill event partitions"

    let appURL: URL
    let displayMode: String
    let temp: TemporaryDirectory
    let server: FakeHerdrServer
    let claudeSessionsDir: URL
    let codexSessionsDir: URL
    let stateDir: URL
    let dumpURL: URL
    let appLogURL: URL
    let codexThreadID: String
    let dumpReader: DumpReader
    private var app: Process?
    private(set) var launchedAt = Date.distantPast

    init(appPath: String, displayMode: String) throws {
        let fileManager = FileManager.default
        let tempDirectory = try TemporaryDirectory(prefix: "island-demo")
        let root = tempDirectory.url
        let claudeDir = root.appendingPathComponent("claude-sessions", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        let codexDir = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        for directory in [claudeDir, codexDir, state.appendingPathComponent("support", isDirectory: true),
                          state.appendingPathComponent("log", isDirectory: true)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Each project is an empty folder with a one-line .git/HEAD, so rows show a synthetic branch.
        for (project, branch) in DemoScenario.branches {
            let gitDir = projects.appendingPathComponent("\(project)/.git", isDirectory: true)
            try fileManager.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try E2EScenario.writeFile(gitDir.appendingPathComponent("HEAD"), Data("ref: refs/heads/\(branch)\n".utf8))
        }
        func projectPath(_ name: String) -> String { projects.appendingPathComponent(name).path }

        // One Codex Desktop thread with a turn in progress for the last 9 minutes.
        let now = Date()
        let threadID = UUID().uuidString.lowercased()
        let startedAt = now.addingTimeInterval(-9 * 60)
        let dayDir = codexDir.appendingPathComponent(E2EScenario.dayPath(startedAt), isDirectory: true)
        try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let rollout = dayDir.appendingPathComponent(RolloutLine.fileName(threadID: threadID, at: startedAt))
        try E2EScenario.writeFile(rollout, E2EScenario.jsonl([
            RolloutLine.sessionMeta(id: threadID, cwd: projectPath("billing-service"), at: startedAt),
            RolloutLine.taskStarted(turnID: "demo-turn-1", at: startedAt),
        ]))
        let indexLine = try JSONSerialization.data(
            withJSONObject: ["id": threadID, "thread_name": DemoScenario.codexThreadTitle,
                             "updated_at": ISO8601DateFormatter().string(from: startedAt)],
            options: [.sortedKeys])
        try E2EScenario.writeFile(codexRoot.appendingPathComponent("session_index.jsonl"), indexLine + Data("\n".utf8))

        let fakeHerdr = try FakeHerdrServer()
        appURL = URL(fileURLWithPath: appPath)
        self.displayMode = displayMode
        temp = tempDirectory
        server = fakeHerdr
        claudeSessionsDir = claudeDir
        codexSessionsDir = codexDir
        stateDir = state
        dumpURL = root.appendingPathComponent("state-dump.json")
        appLogURL = root.appendingPathComponent("app.log")
        codexThreadID = threadID
        dumpReader = DumpReader(url: root.appendingPathComponent("state-dump.json"))

        let herdrPanes = DemoScenario.panes.map { pane in
            FakeHerdrPane(paneID: pane.paneID, workspaceID: pane.workspaceID, tabID: pane.tabID, agent: "claude",
                          status: pane.status, title: pane.title, cwd: projectPath(pane.project), focused: false,
                          stateChangeSeq: 1)
        }
        server.setState(FakeHerdrState(
            panes: herdrPanes, workspaceLabels: DemoScenario.workspaces,
            tabLabels: Dictionary(uniqueKeysWithValues: DemoScenario.panes.map { ($0.tabID, $0.tabLabel) }),
            focusedPaneID: nil))
        for pane in DemoScenario.panes {
            server.setProcessInfo(paneID: pane.paneID, foregroundPIDs: [])
            if let recap = pane.recap {
                server.setDetectionText(paneID: pane.paneID, "⏺ Done.\n\n※ recap: \(recap)\n")
            }
        }

        // A Claude Code session outside Herdr: this driver's own pid, busy for the last 6 minutes.
        let pid = getpid()
        guard let processStart = E2EScenario.processStartText(pid) else {
            throw E2EError("ps -o lstart= failed for the driver's pid \(pid)")
        }
        let entry: [String: Any] = [
            "pid": Int(pid),
            "sessionId": UUID().uuidString.lowercased(),
            "cwd": projectPath("data-pipeline"),
            "procStart": processStart,
            "kind": "interactive",
            "entrypoint": "cli",
            "name": DemoScenario.registryName,
            "status": "busy",
            "statusUpdatedAt": Int64(now.addingTimeInterval(-6 * 60).timeIntervalSince1970 * 1000),
        ]
        try E2EScenario.writeFile(claudeDir.appendingPathComponent("\(pid).json"),
                                  try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                                  permissions: 0o600)
    }

    var codexRowID: RowID { RowID(source: .codexDesktop, key: codexThreadID) }

    /// NSArgumentDomain overrides: muted chime, no exec threads, the requested display mode, never hidden.
    var launchArguments: [String] {
        ["-\(PreferenceKeys.chimeMuted)", "YES",
         "-\(PreferenceKeys.showExecThreads)", "NO",
         "-\(PreferenceKeys.screenSelectionMode)", displayMode,
         "-\(PreferenceKeys.hideWhenEmpty)", "NO"]
    }

    /// Every feed points into the temp directory or the fake Herdr socket; jumps are dry runs.
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

        let herdrRows = DemoScenario.panes.count
        let ready = waitForDump(timeout: 30) { dump in
            E2EScenario.health(dump, .herdr)?.isOnline == true
                && dump.rows.filter { $0.source == .herdr }.count == herdrRows
                && dump.rows.contains { $0.id == self.codexRowID }
                && dump.rows.contains { $0.source == .claudeRegistry }
        }
        guard ready != nil else {
            throw E2EError("within 30 s the app did not show \(herdrRows) Herdr rows, the Codex row and the registry row: \(latestDumpDescription()); app log \(appLogURL.path)")
        }
    }

    /// The infra pane asks its question, the way a real blocked Claude pane does: detection text first, then
    /// the status event. The card appears after the 1 s blocked hold.
    func blockInfraPane() {
        server.setDetectionText(paneID: DemoScenario.blockedPaneID, DemoScenario.blockedDetectionText)
        server.emitStatus(paneID: DemoScenario.blockedPaneID, status: "blocked")
    }

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

    func waitForDump(timeout: TimeInterval, _ predicate: (StateDumpSnapshot) -> Bool) -> StateDumpSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let dump = dumpReader.load().snapshot, predicate(dump) { return dump }
            if Date() >= deadline { return nil }
            e2eWait(0.1)
        }
    }

    func latestDumpDescription() -> String {
        let result = dumpReader.load()
        if let snapshot = result.snapshot { return E2EScenario.describe(snapshot) }
        return result.problem ?? "no state dump"
    }
}

/// Launches the demo, blocks the infra pane once the quiet period is over, holds until SECONDS after launch,
/// then stops the app. It moves no pointer and plays no sound; capture frames from another shell meanwhile.
@MainActor
final class DemoRunner {
    private let options: DemoOptions

    init(options: DemoOptions) {
        self.options = options
    }

    func run() -> Int32 {
        let scenario: DemoScenario
        do {
            scenario = try DemoScenario(appPath: options.appPath, displayMode: options.displayMode)
        } catch {
            print("island-e2e demo: setup failed: \(error)")
            return 1
        }
        print("island-e2e demo: temp \(scenario.temp.url.path); state dump \(scenario.dumpURL.path)")
        do {
            try scenario.launch()
        } catch {
            print("island-e2e demo: launch failed: \(error)")
            scenario.shutDown()
            return 1
        }
        print("island-e2e demo: ready (\(options.displayMode)): \(scenario.latestDumpDescription())")
        let holdUntil = scenario.launchedAt.addingTimeInterval(TimeInterval(options.seconds))
        let blockAt = scenario.launchedAt.addingTimeInterval(DemoScenario.blockAfter)
        var status: Int32 = 0
        if blockAt < holdUntil {
            e2eWait(max(0, blockAt.timeIntervalSinceNow))
            scenario.blockInfraPane()
            print("island-e2e demo: " + elapsed(since: scenario.launchedAt) + " infra › terraform-plan is blocked")
            if scenario.waitForDump(timeout: 5, { $0.ui.cardVisible }) != nil {
                print("island-e2e demo: " + elapsed(since: scenario.launchedAt) + " card visible for "
                      + String(format: "%.0f", IslandTiming.peekDuration) + " s")
            } else {
                print("island-e2e demo: no card within 5 s: \(scenario.latestDumpDescription())")
                status = 1
            }
        }
        print("island-e2e demo: holding until t=\(options.seconds) s")
        while Date() < holdUntil {
            if let exitNote = scenario.appExitDescription() {
                print("island-e2e demo: \(exitNote)")
                status = 1
                break
            }
            e2eWait(min(1, max(0, holdUntil.timeIntervalSinceNow)))
        }
        print("island-e2e demo: final \(scenario.latestDumpDescription())")
        scenario.shutDown()
        print("island-e2e demo: app stopped")
        return status
    }

    private func elapsed(since start: Date) -> String {
        "t=" + String(format: "%.1f", Date().timeIntervalSince(start)) + " s"
    }
}

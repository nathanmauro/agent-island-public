// island-e2e: scripted end-to-end run against the built AgentIsland.app (agent-island spec §12.3).
//
//   island-e2e --app PATH [--soak-seconds N] [--steps 1,2,...]   drive the app; PASS/SKIP/FAIL per step
//   island-e2e --self-check                                       check this driver's pure helpers
//   island-e2e --app PATH --demo SECONDS [--display-mode primary|allDisplays]
//                                                                  hold a synthetic demo on screen (scripts/demo.sh)
//
// scripts/e2e.sh builds the bundle and runs this with --soak-seconds 600 (CI passes --soak-seconds 30).
// Step 0 (the launch quiet guard) always runs; --steps selects among steps 1-7.
// Steps 1 and 3 time every peek: the first dump with the new chime must come within 2 s of the agent blocking
// (2.5 s on CI) and show the card, on the display under the pointer (spec §1.4 criteria 2 and 5; PeekTiming).
// CI=true skips steps 4 and 6. ISLAND_E2E_NEGATIVE_CONTROL=mute launches the app with -chimeMuted YES,
// so steps 1 and 3 must FAIL on their chime check (this proves the chime assertions are live).
import CoreGraphics
import Foundation
import IslandCore

setvbuf(stdout, nil, _IOLBF, 0)

let commandArguments = Array(CommandLine.arguments.dropFirst())
if commandArguments == ["--self-check"] {
    let status: Int32 = MainActor.assumeIsolated { runSelfCheck() }
    exit(status)
}
if commandArguments.contains("--demo") {
    switch DemoOptions.parse(commandArguments) {
    case .usageError(let message):
        FileHandle.standardError.write(Data("island-e2e: \(message)\n\(DemoOptions.usage)\n".utf8))
        exit(64)
    case .options(let options):
        E2EInterrupt.install()
        let status: Int32 = MainActor.assumeIsolated { DemoRunner(options: options).run() }
        exit(status)
    }
}
switch E2EOptions.parse(commandArguments) {
case .usageError(let message):
    FileHandle.standardError.write(Data("island-e2e: \(message)\n\(E2EOptions.usage)\n".utf8))
    exit(64)
case .options(let options):
    E2EInterrupt.install()
    let status: Int32 = MainActor.assumeIsolated { E2ERunner(options: options).run() }
    exit(status)
}

struct E2EOptions: Equatable {
    static let allSteps: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    static let usage = "usage: island-e2e --app PATH [--soak-seconds N] [--steps 1,2,...] | island-e2e --self-check"

    enum Outcome: Equatable {
        case options(E2EOptions)
        case usageError(String)
    }

    var appPath: String
    var soakSeconds: Int
    var steps: Set<Int>

    /// Flags may repeat and the last value wins: scripts/e2e.sh passes --soak-seconds 600 before the caller's arguments.
    static func parse(_ arguments: [String]) -> Outcome {
        var appPath: String?
        var soakSeconds = 600
        var steps = allSteps
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { return .usageError("missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--app":
                appPath = value
            case "--soak-seconds":
                guard let seconds = Int(value), seconds >= 0 else {
                    return .usageError("--soak-seconds takes a whole number of seconds, got \(value)")
                }
                soakSeconds = seconds
            case "--steps":
                let parsed = value.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !parsed.isEmpty, parsed.allSatisfy({ step in step.map { allSteps.contains($0) } ?? false }) else {
                    return .usageError("--steps takes numbers 1-7, got \(value)")
                }
                steps = Set(parsed.compactMap { $0 })
            default:
                return .usageError("unknown argument \(flag)")
            }
            index += 2
        }
        guard let appPath else { return .usageError("--app is required") }
        return .options(E2EOptions(appPath: appPath, soakSeconds: soakSeconds, steps: steps))
    }
}

enum StepOutcome: Equatable {
    case passed(String)
    case skipped(String)
    case failed(String)

    var isPass: Bool { if case .passed = self { return true } else { return false } }
    var isSkip: Bool { if case .skipped = self { return true } else { return false } }
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

@MainActor
final class E2ERunner {
    private let options: E2EOptions
    private var passed = 0
    private var failed = 0
    private var skipped = 0

    init(options: E2EOptions) {
        self.options = options
    }

    func run() -> Int32 {
        let startedAt = Date()
        let environment = ProcessInfo.processInfo.environment
        let isCI = environment["CI"] == "true"
        let muteChime = environment["ISLAND_E2E_NEGATIVE_CONTROL"] == "mute"
        if muteChime {
            print("island-e2e: NEGATIVE CONTROL: the app runs with -chimeMuted YES; steps 1 and 3 must FAIL")
        }
        let scenario: E2EScenario
        do {
            scenario = try E2EScenario(appPath: options.appPath, muteChime: muteChime)
        } catch {
            report("setup", .failed("\(error)"))
            return summary()
        }
        print("island-e2e: temp \(scenario.temp.url.path); fake Herdr socket \(scenario.server.socketPath)")
        do {
            try scenario.launch()
        } catch {
            report("setup", .failed("\(error)"))
            scenario.saveArtifacts()
            scenario.shutDown()
            return summary()
        }
        report("step 0", scenario.stepLaunchGuard())
        for step in 1...7 {
            let outcome: StepOutcome
            if !options.steps.contains(step) {
                outcome = .skipped("not selected with --steps")
            } else if let exitNote = scenario.appExitDescription() {
                outcome = .failed(exitNote)
            } else {
                switch step {
                case 1: outcome = scenario.stepHerdrBlocked(isCI: isCI)
                case 2: outcome = scenario.stepHerdrTransitions()
                case 3: outcome = scenario.stepCodexAndRegistry(isCI: isCI)
                case 4: outcome = scenario.stepPointer(isCI: isCI)
                case 5: outcome = scenario.stepSoak(seconds: options.soakSeconds)
                case 6: outcome = scenario.stepNotificationAudit(since: startedAt, isCI: isCI)
                default: outcome = scenario.stepStaleRecovery()
                }
            }
            report("step \(step)", outcome)
        }
        if failed > 0 { scenario.saveArtifacts() }
        scenario.shutDown()
        return summary()
    }

    private func report(_ label: String, _ outcome: StepOutcome) {
        switch outcome {
        case .passed(let detail):
            passed += 1
            print("PASS \(label) (\(detail))")
        case .skipped(let reason):
            skipped += 1
            print("SKIP \(label) (\(reason))")
        case .failed(let reason):
            failed += 1
            print("FAIL \(label): \(reason)")
        }
    }

    private func summary() -> Int32 {
        print("island-e2e: \(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed > 0 ? 1 : 0
    }
}

@MainActor
func runSelfCheck() -> Int32 {
    var passed = 0
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 } else { failures.append(message) }
    }

    // Options (7)
    check(E2EOptions.parse(["--app", "/x.app"]) == .options(E2EOptions(appPath: "/x.app", soakSeconds: 600, steps: E2EOptions.allSteps)),
          "defaults: soak 600 s and steps 1-7")
    check(E2EOptions.parse(["--app", "/x.app", "--soak-seconds", "600", "--soak-seconds", "30"])
              == .options(E2EOptions(appPath: "/x.app", soakSeconds: 30, steps: E2EOptions.allSteps)),
          "the last --soak-seconds wins (scripts/e2e.sh relies on it)")
    check(E2EOptions.parse(["--app", "/x.app", "--steps", "1,3"]) == .options(E2EOptions(appPath: "/x.app", soakSeconds: 600, steps: [1, 3])),
          "--steps selects a subset")
    check(E2EOptions.parse(["--soak-seconds", "30"]) == .usageError("--app is required"), "--app is required")
    check(E2EOptions.parse(["--app", "/x.app", "--steps", "8"]) == .usageError("--steps takes numbers 1-7, got 8"), "--steps rejects 8")
    check(E2EOptions.parse(["--app", "/x.app", "--bogus", "1"]) == .usageError("unknown argument --bogus"), "unknown arguments are rejected")
    check(E2EOptions.parse(["--app"]) == .usageError("missing value for --app"), "a flag without a value is rejected")

    // Demo options (5)
    check(DemoOptions.parse(["--app", "/x.app", "--demo", "60"])
              == .options(DemoOptions(appPath: "/x.app", seconds: 60, displayMode: "primary")),
          "--demo defaults to the primary display")
    check(DemoOptions.parse(["--app", "/x.app", "--demo", "90", "--display-mode", "allDisplays"])
              == .options(DemoOptions(appPath: "/x.app", seconds: 90, displayMode: "allDisplays")),
          "--display-mode allDisplays is accepted")
    check(DemoOptions.parse(["--app", "/x.app", "--demo", "0"]).isUsageError, "--demo 0 is rejected")
    check(DemoOptions.parse(["--app", "/x.app", "--demo", "60", "--display-mode", "notch"]).isUsageError,
          "an unknown display mode is rejected")
    check(DemoOptions.parse(["--app", "/x.app", "--demo", "60", "--soak-seconds", "30"]).isUsageError,
          "E2E flags are not demo flags")

    // Notification Center audit output (13)
    let islandHit = "2026-09-25T16:24:01  com.nathan.agent-island            Fixture title\nagent records since 2026-09-25 16:00: 1\n"
    let otherHit = "2026-09-25T16:24:01  com.openai.codex                   Fixture title\nagent records since 2026-09-25 16:00: 1\n"
    check(NCAudit.outcome(status: 1, output: islandHit).isFailure, "an agent-island record fails step 6")
    check(NCAudit.outcome(status: 1, output: otherHit).isPass, "another agent app's record is reported but passes")
    check(NCAudit.outcome(status: 0, output: "agent records since 2026-09-25 16:00: 0\n").isPass, "a clean audit passes")
    check(NCAudit.outcome(status: 2, output: "nc-agent-audit: no usernoted database\n") == .skipped("no usernoted database"),
          "exit 2 prints SKIP step 6 (no usernoted database)")
    check(NCAudit.outcome(status: 3, output: "nc-agent-audit: cannot read usernoted database (PermissionError)\n").isSkip,
          "exit 3 (unreadable) skips")
    check(NCAudit.outcome(status: 64, output: "usage").isFailure, "any other exit fails")
    check(NCAudit.sinceArgument(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!) == "1970-01-01 00:00",
          "--since is formatted yyyy-MM-dd HH:mm")
    // Fix round 1, Finding 1b: a crash whose exit code coincides with "records found" must not read as
    // "0 records, PASS". This is the reviewer's exact repro (an uncaught OSError from fromtimestamp): a
    // traceback with no "agent records since …: N" summary line at all.
    let traceback = "Traceback (most recent call last):\n  File \"scripts/nc-agent-audit.py\", line 101\nOSError: [Errno 22] Invalid argument\n"
    check(NCAudit.outcome(status: 1, output: traceback).isFailure, "status 1 with no summary line fails, not passes (the crash regression)")
    check(NCAudit.outcome(status: 0, output: traceback).isFailure, "status 0 with no summary line also fails")
    check(NCAudit.outcome(status: 1, output: "agent records since 2026-09-25 16:00: 1\n").isFailure,
          "status 1 with a summary line but zero parsed hit lines fails (count mismatch)")
    let twoHitsOneSummary = "2026-09-25T16:24:01  com.nathan.agent-island            Fixture title\n"
        + "2026-09-25T16:25:02  com.openai.codex                   Fixture title\n"
        + "agent records since 2026-09-25 16:00: 1\n"
    check(NCAudit.outcome(status: 1, output: twoHitsOneSummary).isFailure, "two hit lines but a summary of 1 fails (count mismatch)")
    check(NCAudit.outcome(status: 1, output: "agent records since 2026-09-25 16:00: 0\n").isFailure,
          "status 1 reporting zero records is inconsistent and fails")
    check(NCAudit.outcome(status: 1, output: "agent records since 2026-09-25 16:00: notanumber\n").isFailure,
          "a summary line that does not end in a number fails")

    // Soak evaluation (8)
    check(ProcessSampler.evaluate([SoakSample(cpuPercent: 0.2, openFiles: 40), SoakSample(cpuPercent: 0.4, openFiles: 42)]).passed,
          "0.3 % average and an fd spread of 2 pass")
    check(!ProcessSampler.evaluate([SoakSample(cpuPercent: 1.5, openFiles: 40), SoakSample(cpuPercent: 0.7, openFiles: 40)]).passed,
          "a 1.1 % average fails")
    check(!ProcessSampler.evaluate([SoakSample(cpuPercent: 0.1, openFiles: 40), SoakSample(cpuPercent: 0.1, openFiles: 43)]).passed,
          "an fd spread of 3 fails")
    check(!ProcessSampler.evaluate([SoakSample(cpuPercent: 0.1, openFiles: 40)]).passed, "one sample is not a soak")
    check(ProcessSampler.parseCPUTime("0:01.50") == 1.5, "ps time m:ss.ss")
    check(ProcessSampler.parseCPUTime("323:27.51").map { abs($0 - 19_407.51) < 0.001 } == true, "ps time mmm:ss.ss")
    check(ProcessSampler.parseCPUTime("1:02:03.00") == 3_723, "ps time h:mm:ss.ss")
    check(ProcessSampler.parseCPUTime("junk") == nil, "junk is not a CPU time")

    // Pointer probe points on a 2560 × 1440 primary display (3)
    let points = PillProbePoints(displayBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    check(points.pillCenter == CGPoint(x: 1280, y: 12), "the pill probe is the top center, inside the menu bar")
    check(points.belowPill == CGPoint(x: 1280, y: 140), "the below-pill probe is at least 100 pt under the pill's bottom edge")
    check(points.outsidePanel == CGPoint(x: 1800, y: 140), "the side probe is beyond half the 800 pt panel width")

    // Codex jump plan rule (5)
    let codexPath = "/Applications/Codex.app"
    check(E2EScenario.codexPlanProblem([], threadID: "t1", codexPresent: false) == nil, "[] is right when Codex is absent")
    check(E2EScenario.codexPlanProblem([], threadID: "t1", codexPresent: true) != nil, "[] is wrong when Codex is present")
    check(E2EScenario.codexPlanProblem([.openURL("codex://threads/t1", appPath: codexPath, onlyIfPreviousFailed: false)],
                                       threadID: "t1", codexPresent: true) == nil, "one openURL with the app path is right")
    check(E2EScenario.codexPlanProblem([.openURL("codex://threads/t1", appPath: nil, onlyIfPreviousFailed: false)],
                                       threadID: "t1", codexPresent: true) != nil, "an openURL without an app path is wrong")
    check(E2EScenario.codexPlanProblem([.openURL("codex://threads/other", appPath: codexPath, onlyIfPreviousFailed: false)],
                                       threadID: "t1", codexPresent: true) != nil, "an openURL for another thread is wrong")

    // Peek arrival, spec §1.4 criteria 2 and 5 (8)
    check(PeekTiming.limit(isCI: false) == 2.0, "the peek budget is 2 s")
    check(PeekTiming.limit(isCI: true) == 2.5, "CI gets 0.5 s more for the dump debounce and FSEvents latency")
    check(PeekTiming.problem(latency: 1.3, limit: 2.0, cardVisible: true, cardDisplayID: 5, pointerDisplayIDs: [5]) == nil,
          "a card on the pointer's display 1.3 s after blocking passes")
    check(PeekTiming.problem(latency: 2.3, limit: 2.0, cardVisible: true, cardDisplayID: 5, pointerDisplayIDs: [5]) != nil,
          "2.3 s is over the 2 s budget")
    check(PeekTiming.problem(latency: 2.3, limit: 2.5, cardVisible: true, cardDisplayID: 5, pointerDisplayIDs: [5]) == nil,
          "2.3 s is inside the CI allowance")
    check(PeekTiming.problem(latency: 1.0, limit: 2.0, cardVisible: false, cardDisplayID: nil, pointerDisplayIDs: [5]) != nil,
          "a chime with no visible card fails (criterion 5)")
    check(PeekTiming.problem(latency: 1.0, limit: 2.0, cardVisible: true, cardDisplayID: 7, pointerDisplayIDs: [5]) != nil,
          "a card on a display the pointer was not on fails")
    check(PeekTiming.problem(latency: 1.0, limit: 2.0, cardVisible: true, cardDisplayID: 7, pointerDisplayIDs: [5, 7]) == nil,
          "the pointer's display when the agent blocked or when the chime was seen both count")

    for failure in failures { print("self-check FAIL: \(failure)") }
    print("island-e2e self-check: \(passed) passed, \(failures.count) failed")
    return failures.isEmpty ? 0 : 1
}

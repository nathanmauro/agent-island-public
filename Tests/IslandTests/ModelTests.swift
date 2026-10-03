import Foundation
import IslandCore
import IslandTestSupport

private let modelEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private func modelRow(
    _ key: String,
    _ state: DisplayState,
    source: SessionSource = .herdr,
    since: Date = modelEpoch,
    processIDs: [Int32] = [],
    sourceStatus: String? = nil,
    jump: JumpTarget? = nil
) -> AgentRow {
    AgentRow(
        id: RowID(source: source, key: key),
        title: "title \(key)",
        subtitle: "subtitle",
        state: state,
        since: since,
        jump: jump ?? .herdrPane(paneID: key, windowTitlePrefix: nil),
        processIDs: processIDs,
        sourceStatus: sourceStatus
    )
}

func testModelSummaryOrdersSegmentsBySeverityAndOmitsZeroCounts() throws {
    let rows = [
        modelRow("p1", .doneUnseen),
        modelRow("p2", .working),
        modelRow("p3", .waiting),
        modelRow("p4", .error),
        modelRow("p5", .waiting),
    ]
    let summary = Summary(rows: rows)
    try expect(summary.segments, equals: [
        Summary.Segment(kind: .error, count: 1),
        Summary.Segment(kind: .waiting, count: 2),
        Summary.Segment(kind: .working, count: 1),
        Summary.Segment(kind: .done, count: 1),
    ], "segments in error, waiting, working, done order")

    let noErrors = Summary(rows: [modelRow("p1", .working), modelRow("p2", .doneUnseen)])
    try expect(noErrors.segments.map(\.kind), equals: [.working, .done], "zero-count kinds are omitted")
}

func testModelSummarySeparatesStaleAndNeverCountsIdleOrStarting() throws {
    let summary = Summary(rows: [
        modelRow("p1", .working),
        modelRow("p2", .stale),
        modelRow("p3", .idle),
        modelRow("p4", .starting),
    ])
    try expect(summary.segments.map(\.label), equals: ["1 working", "1 stale"], "uncertain activity is separate from working")
    try expect(summary.staleCount, equals: 1, "stale count")
    try expect(summary.idleCount, equals: 2, "idle and starting are tallied outside the segments")
}

func testModelSummaryTextJoinsLabelsWithMiddleDot() throws {
    let summary = Summary(rows: [
        modelRow("p1", .error),
        modelRow("p2", .waiting),
        modelRow("p3", .working),
        modelRow("p4", .stale),
        modelRow("p5", .doneUnseen),
    ])
    try expect(summary.text, equals: "1 error · 1 waiting · 1 working · 1 stale · 1 done", "pill text")
    try expect(summary.segments.first?.label ?? "", equals: "1 error", "segment label")
    try expect(summary.segments.first?.id, equals: .error, "segment id is its kind")
    try expect(summary.isEmpty, equals: false, "non-empty summary")
}

func testModelEmptySummaryHasEmptyText() throws {
    let empty = Summary(rows: [])
    try expect(empty.text, equals: "", "no rows gives empty text")
    try expect(empty.isEmpty, equals: true, "no rows is empty")

    let idleOnly = Summary(rows: [modelRow("p1", .idle), modelRow("p2", .starting)])
    try expect(idleOnly.text, equals: "", "idle-only rows give empty text")
    try expect(idleOnly.isEmpty, equals: true, "idle-only rows count as empty")
    try expect(idleOnly.idleCount, equals: 2, "idle rows are still tallied")
}

func testModelDisplayStateMappingTables() throws {
    let expected: [DisplayState: (rank: Int, kind: Summary.Segment.Kind?, interrupting: Bool)] = [
        .error: (0, .error, true),
        .waiting: (1, .waiting, true),
        .working: (2, .working, false),
        .stale: (3, .stale, false),
        .doneUnseen: (4, .done, false),
        .starting: (5, nil, false),
        .idle: (6, nil, false),
    ]
    for state in DisplayState.allCases {
        let entry = try expectedEntry(expected, state)
        try expect(state.severityRank, equals: entry.rank, "severityRank of \(state)")
        try expect(state.segmentKind, equals: entry.kind, "segmentKind of \(state)")
        try expect(state.isInterrupting, equals: entry.interrupting, "isInterrupting of \(state)")
        try expectTrue(!state.accessibilityName.isEmpty, "accessibilityName of \(state) is not empty")
    }
    try expect(SessionSource.allCases.map(\.displayName), equals: ["Herdr", "Claude", "Codex"], "source display names")
}

private func expectedEntry<Value>(_ table: [DisplayState: Value], _ state: DisplayState) throws -> Value {
    guard let value = table[state] else {
        throw TestFailure.expectation("no expectation for \(state)")
    }
    return value
}

func testModelRowIDDescriptionAndStorageKey() throws {
    let id = RowID(source: .herdr, key: "w14:p9")
    try expect(id.description, equals: "herdr:w14:p9", "description")
    try expect(id.storageKey, equals: "herdr|w14:p9", "storage key")
    try expect(RowID(source: .codexDesktop, key: "t-1").storageKey, equals: "codexDesktop|t-1", "codex storage key")
    try expect(RowID(source: .claudeRegistry, key: "42@x").description, equals: "claudeRegistry:42@x", "registry description")
}

func testModelDetailKeepsAtMostFourOptions() throws {
    let detail = Detail(question: "pick", options: ["a", "b", "c", "d", "e"], kind: .question)
    try expect(detail.options, equals: ["a", "b", "c", "d"], "options are capped at four")
    try expect(Detail(question: "boom", kind: .error).options, equals: [], "options default to empty")
}

func testModelAgentRowRoundTripsThroughCodable() throws {
    let rows = [
        AgentRow(
            id: RowID(source: .herdr, key: "w1:p1"),
            title: "title",
            subtitle: "api › tab",
            state: .waiting,
            since: modelEpoch,
            detail: Detail(question: "continue?", options: ["Yes", "No"], kind: .permission),
            jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "host: api"),
            cwd: "/tmp/fixture-project",
            processIDs: [101, 102],
            sourceStatus: "blocked"
        ),
        modelRow("thread-1", .doneUnseen, source: .codexDesktop, jump: .codexThread(id: "thread-1")),
        modelRow("7@x", .idle, source: .claudeRegistry, jump: .claudeDesktop(sessionID: "s-1", tmuxTarget: "main:@1.%2")),
        modelRow("8@y", .working, source: .claudeRegistry, jump: .terminal(tmuxTarget: nil)),
        modelRow("9@z", .waiting, source: .claudeRegistry, jump: .claudeRemoteControl(bridgeSessionID: "session_01FixtureBridge000000001")),
    ]
    let decoded = try JSONDecoder().decode([AgentRow].self, from: JSONEncoder().encode(rows))
    try expect(decoded, equals: rows, "rows survive an encode/decode round trip")
    try expect(decoded[0].source, equals: .herdr, "source equals id.source")
}

func testModelFeedHealthRoundTripsAndOnlyOfflineOrDisabledWarn() throws {
    let all: [FeedHealth] = [
        .online,
        .inactive(reason: "registry directory missing"),
        .offline(reason: "socket missing"),
        .disabled(reason: "protocol 23"),
    ]
    let decoded = try JSONDecoder().decode([FeedHealth].self, from: JSONEncoder().encode(all))
    try expect(decoded, equals: all, "FeedHealth round trip")
    try expect(all.map(\.showsWarning), equals: [false, false, true, true], "showsWarning")
    try expect(all.map(\.dimsRows), equals: [false, false, true, true], "dimsRows")
    try expect(all.map(\.isOnline), equals: [true, false, false, false], "isOnline")
    try expect(all.map(\.summary), equals: [
        "online",
        "inactive: registry directory missing",
        "offline: socket missing",
        "disabled: protocol 23",
    ], "summary text")
}

func testModelDegradedHealthWarnsWithoutDimmingAndCountsAsOnline() throws {
    let degraded = FeedHealth.degraded(reason: "server 0.9.0 cannot move the Herdr view")
    let decoded = try JSONDecoder().decode(FeedHealth.self, from: JSONEncoder().encode(degraded))
    try expect(decoded, equals: degraded, "degraded round trip")
    try expectTrue(degraded.showsWarning, "a degraded feed shows the warning glyph")
    try expectTrue(!degraded.dimsRows, "a degraded feed keeps its rows bright: they are live")
    try expectTrue(degraded.isOnline, "a degraded feed is online for pruning and quiet periods")
    try expect(degraded.summary, equals: "degraded: server 0.9.0 cannot move the Herdr view", "summary text")
}

func testModelFocusContextIsLookingForEveryJumpTarget() throws {
    let herdr = modelRow("w1:p1", .waiting, source: .herdr, jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: nil))
    let codex = modelRow("t1", .waiting, source: .codexDesktop, jump: .codexThread(id: "t1"))
    let claude = modelRow("1@x", .waiting, source: .claudeRegistry, jump: .claudeDesktop(sessionID: "s", tmuxTarget: nil))
    let terminal = modelRow("2@x", .waiting, source: .claudeRegistry, jump: .terminal(tmuxTarget: "main:@1.%1"))
    let remote = modelRow("3@x", .waiting, source: .claudeRegistry,
                          jump: .claudeRemoteControl(bridgeSessionID: "session_01FixtureBridge000000001"))

    let ghosttyOnPane = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty, herdrFocusedPaneID: "w1:p1")
    try expect(ghosttyOnPane.isLooking(at: herdr), equals: true, "Ghostty frontmost on the focused pane")
    let ghosttyElsewhere = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty, herdrFocusedPaneID: "w1:p2")
    try expect(ghosttyElsewhere.isLooking(at: herdr), equals: false, "Ghostty frontmost on another pane")
    let paneButNotGhostty = FocusContext(frontmostBundleID: KnownBundleIDs.codex, herdrFocusedPaneID: "w1:p1")
    try expect(paneButNotGhostty.isLooking(at: herdr), equals: false, "focused pane but Ghostty not frontmost")

    try expect(FocusContext(frontmostBundleID: KnownBundleIDs.codex).isLooking(at: codex), equals: true, "Codex frontmost")
    try expect(FocusContext(frontmostBundleID: KnownBundleIDs.ghostty).isLooking(at: codex), equals: false, "Codex not frontmost")
    try expect(
        FocusContext(frontmostBundleID: KnownBundleIDs.claudeDesktop).isLooking(at: claude),
        equals: true,
        "Claude frontmost"
    )
    try expect(FocusContext(frontmostBundleID: KnownBundleIDs.codex).isLooking(at: claude), equals: false, "Claude not frontmost")
    try expect(
        FocusContext(frontmostBundleID: KnownBundleIDs.claudeDesktop).isLooking(at: remote),
        equals: true,
        "Claude frontmost shows the Remote Control conversation too"
    )
    try expect(ghosttyOnPane.isLooking(at: remote), equals: false, "a Remote Control session has no terminal to look at")
    try expect(FocusContext().isLooking(at: remote), equals: false, "Remote Control with nothing frontmost")
    try expect(ghosttyOnPane.isLooking(at: terminal), equals: false, "terminal rows are never looked at")
    try expect(FocusContext().isLooking(at: herdr), equals: false, "empty context looks at nothing")
}

func testModelRowMergerDropsRegistryRowSharingAHerdrProcess() throws {
    let herdr = modelRow("w1:p1", .working, source: .herdr, processIDs: [500, 501])
    var registry = modelRow("501@x", .working, source: .claudeRegistry, processIDs: [501])
    registry.sourceStatus = "busy"
    let result = RowMerger.merge([.herdr: [herdr], .claudeRegistry: [registry]])
    try expect(result.rows.map(\.id), equals: [herdr.id], "the registry duplicate is dropped")
    try expect(result.registryShadow, equals: [herdr.id: "busy"], "shadow keeps the registry status under the herdr row")
}

func testModelRowMergerKeepsRegistryRowWithDisjointProcesses() throws {
    let herdr = modelRow("w1:p1", .working, source: .herdr, processIDs: [500])
    let registry = modelRow("900@x", .waiting, source: .claudeRegistry, processIDs: [900], sourceStatus: "waiting")
    let codex = modelRow("t1", .doneUnseen, source: .codexDesktop, jump: .codexThread(id: "t1"))
    let noPIDs = modelRow("901@x", .idle, source: .claudeRegistry)
    let result = RowMerger.merge([.herdr: [herdr], .claudeRegistry: [registry, noPIDs], .codexDesktop: [codex]])
    try expect(Set(result.rows.map(\.id)), equals: Set([herdr.id, registry.id, codex.id, noPIDs.id]), "every row is kept")
    try expect(result.registryShadow, equals: [:], "nothing shadowed")
    try expect(result.rows.map(\.id), equals: [registry.id, herdr.id, codex.id, noPIDs.id], "merged rows are sorted with precedes")
}

func testModelPrecedesOrdersBySeverityThenNewestThenID() throws {
    let older = modelEpoch
    let newer = modelEpoch.addingTimeInterval(60)
    let error = modelRow("z", .error, since: older)
    let waitingNew = modelRow("y", .waiting, since: newer)
    let waitingOldA = modelRow("a", .waiting, since: older)
    let waitingOldB = modelRow("b", .waiting, since: older)
    let idle = modelRow("c", .idle, since: newer)
    let sorted = [idle, waitingOldB, waitingOldA, error, waitingNew].sorted(by: RowMerger.precedes)
    try expect(sorted.map(\.id.key), equals: ["z", "y", "a", "b", "c"], "severity, then newest since, then id")
    try expect(RowMerger.precedes(waitingOldA, waitingOldA), equals: false, "a row never precedes itself")
}

func testModelNoInterruptsDecidesNothing() throws {
    var policy = NoInterrupts()
    let decision = policy.decide(
        prev: [],
        next: [modelRow("p1", .waiting)],
        focus: FocusContext(),
        now: modelEpoch
    )
    try expect(decision, equals: .none, "NoInterrupts never peeks or chimes")
    try expect(PolicyDecision.none, equals: PolicyDecision(peeks: [], chime: false, notes: [], nextDeadline: nil), "PolicyDecision.none is empty")
    policy.beginQuietPeriod(for: Set(SessionSource.allCases), at: modelEpoch)
    try expect(PolicyRule.chimeGap.rawValue, equals: "suppressed.chime-gap", "policy rule raw values are log words")
}

func testModelStoreChangeCarriesMergeOutputs() throws {
    let rowID = RowID(source: .herdr, key: "w1:p1")
    let change = StoreChange(
        at: modelEpoch,
        previousRows: [],
        rows: [modelRow("w1:p1", .waiting)],
        decision: PolicyDecision(peeks: [PeekEvent(rowID: rowID, kind: .waiting, question: nil, at: modelEpoch)], chime: true),
        registryShadow: [rowID: "busy"],
        healthChanges: [HealthChange(source: .herdr, from: nil, to: .online)]
    )
    try expect(change.decision.peeks.first?.rowID, equals: rowID, "peek row")
    try expect(change.healthChanges.first?.to, equals: .online, "health change")
    let snapshot = PeekQueueSnapshot(current: rowID)
    try expect(snapshot.pending, equals: [], "snapshot defaults")
    try expect(snapshot.moreCount, equals: 0, "snapshot more count default")
}

@MainActor
private final class ModelSchedulerProbe {
    var fired = 0
}

@MainActor
func testModelManualDeadlineSchedulerNeverFires() throws {
    let probe = ModelSchedulerProbe()
    DeadlineScheduler.manual.schedule(after: 0) { probe.fired += 1 }
    DeadlineScheduler.manual.schedule(after: 0.01) { probe.fired += 1 }
    let firedWithinWindow = (try? spinMainRunLoop(timeout: 0.1) { probe.fired > 0 }) != nil
    try expect(firedWithinWindow, equals: false, ".manual never runs its work")
    try expect(probe.fired, equals: 0, "no work ran")
}

@MainActor
func testModelMainQueueDeadlineSchedulerFiresAfterTheDelay() throws {
    let probe = ModelSchedulerProbe()
    let started = ProcessInfo.processInfo.systemUptime
    DeadlineScheduler.mainQueue.schedule(after: 0.05) { probe.fired += 1 }
    try expect(probe.fired, equals: 0, "work never runs synchronously")
    try spinMainRunLoop(timeout: 2) { probe.fired == 1 }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    try expectTrue(elapsed >= 0.04, "work ran only after the delay (elapsed \(elapsed) s)")
}

func testModelManualWallClockAdvancesAndSets() throws {
    let clock = ManualWallClock()
    try expect(clock.now(), equals: Date(timeIntervalSince1970: 1_800_000_000), "default start")
    clock.advance(by: 1.5)
    try expect(clock.now(), equals: Date(timeIntervalSince1970: 1_800_000_001.5), "advance")
    clock.set(Date(timeIntervalSince1970: 10))
    try expect(clock.now(), equals: Date(timeIntervalSince1970: 10), "set")
}

func testModelAgentRowFixtureDefaults() throws {
    let herdr = AgentRow.fixture(key: "w1:p1")
    try expect(herdr.id, equals: RowID(source: .herdr, key: "w1:p1"), "fixture id")
    try expect(herdr.state, equals: .working, "default state")
    try expect(herdr.since, equals: Date(timeIntervalSince1970: 1_800_000_000), "default since")
    try expect(herdr.title, equals: "row w1:p1", "default title")
    try expect(herdr.jump, equals: .herdrPane(paneID: "w1:p1", windowTitlePrefix: nil), "herdr default jump")
    try expect(AgentRow.fixture(source: .codexDesktop, key: "t1").jump, equals: .codexThread(id: "t1"), "codex default jump")
    try expect(
        AgentRow.fixture(source: .claudeRegistry, key: "1@x").jump,
        equals: .terminal(tmuxTarget: nil),
        "registry default jump"
    )
    let custom = AgentRow.fixture(
        source: .claudeRegistry,
        key: "2@x",
        state: .waiting,
        title: "custom",
        detail: Detail(question: "q", kind: .question),
        processIDs: [7],
        jump: .claudeDesktop(sessionID: "s", tmuxTarget: nil),
        cwd: "/tmp/fixture-project"
    )
    try expect(custom.title, equals: "custom", "title override")
    try expect(custom.processIDs, equals: [7], "process ids")
    try expect(custom.cwd, equals: "/tmp/fixture-project", "cwd")
    try expect(custom.source, equals: .claudeRegistry, "source follows the id")
}

@MainActor
private final class ModelFeedSink {
    var published: [[AgentRow]] = []
    var health: [FeedHealth] = []
}

@MainActor
func testModelFakeSessionFeedDeliversRowsAndHealth() throws {
    let feed = FakeSessionFeed(source: .codexDesktop)
    let sink = ModelFeedSink()
    try expect(feed.isStarted, equals: false, "not started yet")
    feed.observeHealth { sink.health.append($0) }
    feed.start { sink.published.append($0) }
    try expect(feed.isStarted, equals: true, "started")

    let rows = [AgentRow.fixture(source: .codexDesktop, key: "t1", state: .doneUnseen)]
    feed.publish(rows)
    feed.report(.offline(reason: "socket missing"))
    try expect(sink.published, equals: [rows], "publish reaches the start callback")
    try expect(sink.health, equals: [.offline(reason: "socket missing")], "report reaches observeHealth")

    feed.loadDetail(for: rows[0])
    try expect(feed.detailRequests, equals: [rows[0].id], "detail requests are recorded")
    feed.stop()
    feed.stop()
    try expect(feed.isStarted, equals: false, "stopped")
    try expect(feed.stopCount, equals: 2, "every stop is counted")
}

@MainActor
private final class ModelJumpOutcome {
    var finished = false
    var failure: Error?
}

@MainActor
func testModelFakeSessionFeedRecordsJumps() throws {
    let feed = FakeSessionFeed(source: .herdr)
    let row = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    let outcome = ModelJumpOutcome()
    Task { @MainActor in
        do {
            try await feed.jump(row)
        } catch {
            outcome.failure = error
        }
        outcome.finished = true
    }
    try spinMainRunLoop(timeout: 2) { outcome.finished }
    try expectTrue(outcome.failure == nil, "jump does not throw")
    try expect(feed.jumpedRows, equals: [row.id], "jump is recorded")
}

@MainActor
func testModelFakeFocusAndActivityDoubles() throws {
    let focus = FakeFocusContextProvider()
    try expect(focus.currentFocus(), equals: FocusContext(), "default focus is empty")
    focus.focus = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty, herdrFocusedPaneID: "w1:p1")
    try expect(focus.currentFocus().herdrFocusedPaneID, equals: "w1:p1", "focus is settable")

    let activity = FakeAppActivity()
    var activations: [String] = []
    activity.addActivationObserver { activations.append($0) }
    activity.appPaths[KnownBundleIDs.codex] = "/Applications/Codex.app"
    try expect(activity.runningAppPath(bundleID: KnownBundleIDs.codex), equals: nil, "no path while not running")
    activity.running.insert(KnownBundleIDs.codex)
    try expect(activity.isRunning(bundleID: KnownBundleIDs.codex), equals: true, "running")
    try expect(
        activity.runningAppPath(bundleID: KnownBundleIDs.codex),
        equals: "/Applications/Codex.app",
        "path while running"
    )
    activity.activate(KnownBundleIDs.codex)
    try expect(activity.frontmostBundleID(), equals: KnownBundleIDs.codex, "activate sets frontmost")
    try expect(activations, equals: [KnownBundleIDs.codex], "activate fires observers")
}

func testModelSpyInterruptDeciderReturnsScriptedDecisionsThenNone() throws {
    let rowID = RowID(source: .herdr, key: "w1:p1")
    let scripted = PolicyDecision(
        peeks: [PeekEvent(rowID: rowID, kind: .waiting, question: "q", at: Date(timeIntervalSince1970: 1_800_000_000))],
        chime: true
    )
    let log = SpyInterruptDecider.Log()
    var spy = SpyInterruptDecider(log: log, scripted: [scripted])
    let focus = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try expect(spy.decide(prev: [], next: [], focus: focus, now: now), equals: scripted, "first call returns the script")
    try expect(spy.decide(prev: [], next: [], focus: focus, now: now), equals: .none, "then none")
    spy.beginQuietPeriod(for: [.herdr], at: now)
    try expect(log.decideCalls, equals: 2, "decide calls counted")
    try expect(log.lastFocus, equals: focus, "last focus recorded")
    try expect(log.quietPeriods.map(\.sources), equals: [[.herdr]], "quiet period sources recorded")
    try expect(log.quietPeriods.map(\.at), equals: [now], "quiet period time recorded")
}

func testModelOlderRowJSONHasNoAcknowledgment() throws {
    var row = modelRow("p1", .doneUnseen)
    row.acknowledgmentID = "fixture:1"
    let encoder = JSONEncoder()
    guard var object = try JSONSerialization.jsonObject(with: encoder.encode(row)) as? [String: Any] else {
        throw TestFailure.expectation("AgentRow encodes as an object")
    }
    object.removeValue(forKey: "acknowledgmentID")
    let decoded = try JSONDecoder().decode(AgentRow.self, from: JSONSerialization.data(withJSONObject: object))
    try expect(decoded.acknowledgmentID, equals: nil, "older dumps decode without granting acknowledgment")
}

let modelTests: [TestCase] = [
    ("model: older row JSON has no acknowledgment", testModelOlderRowJSONHasNoAcknowledgment),
    ("model: summary orders segments by severity and omits zero counts", testModelSummaryOrdersSegmentsBySeverityAndOmitsZeroCounts),
    ("model: summary separates stale and never counts idle or starting", testModelSummarySeparatesStaleAndNeverCountsIdleOrStarting),
    ("model: summary text joins labels with a middle dot", testModelSummaryTextJoinsLabelsWithMiddleDot),
    ("model: empty summary has empty text", testModelEmptySummaryHasEmptyText),
    ("model: display state mapping tables", testModelDisplayStateMappingTables),
    ("model: row id description and storage key", testModelRowIDDescriptionAndStorageKey),
    ("model: detail keeps at most four options", testModelDetailKeepsAtMostFourOptions),
    ("model: agent row round-trips through Codable", testModelAgentRowRoundTripsThroughCodable),
    ("model: feed health round-trips and only offline or disabled warn", testModelFeedHealthRoundTripsAndOnlyOfflineOrDisabledWarn),
    ("model: degraded health warns without dimming and counts as online", testModelDegradedHealthWarnsWithoutDimmingAndCountsAsOnline),
    ("model: focus context isLooking for every jump target", testModelFocusContextIsLookingForEveryJumpTarget),
    ("model: row merger drops a registry row sharing a Herdr process", testModelRowMergerDropsRegistryRowSharingAHerdrProcess),
    ("model: row merger keeps registry rows with disjoint processes", testModelRowMergerKeepsRegistryRowWithDisjointProcesses),
    ("model: precedes orders by severity, then newest, then id", testModelPrecedesOrdersBySeverityThenNewestThenID),
    ("model: NoInterrupts decides nothing", testModelNoInterruptsDecidesNothing),
    ("model: store change carries merge outputs", testModelStoreChangeCarriesMergeOutputs),
    ("model: manual deadline scheduler never fires", testModelManualDeadlineSchedulerNeverFires),
    ("model: main-queue deadline scheduler fires after the delay", testModelMainQueueDeadlineSchedulerFiresAfterTheDelay),
    ("model: manual wall clock advances and sets", testModelManualWallClockAdvancesAndSets),
    ("model: agent row fixture defaults", testModelAgentRowFixtureDefaults),
    ("model: fake session feed delivers rows and health", testModelFakeSessionFeedDeliversRowsAndHealth),
    ("model: fake session feed records jumps", testModelFakeSessionFeedRecordsJumps),
    ("model: fake focus and activity doubles", testModelFakeFocusAndActivityDoubles),
    ("model: spy interrupt decider returns scripted decisions, then none", testModelSpyInterruptDeciderReturnsScriptedDecisionsThenNone),
]

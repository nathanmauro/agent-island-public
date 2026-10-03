import Foundation
import Observation

import IslandCore
import IslandIO
import IslandTestSupport

// MARK: Helpers (file-private)

/// Observation calls `onChange` from a `@Sendable` closure, so the flag it
/// raises cannot be a captured `var`.
private final class StoreObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func recordChange() {
        lock.lock()
        defer { lock.unlock() }
        observed = true
    }

    var sawChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }
}

/// Every `StoreChange` the store emits, in order. Tests spin on `count` so
/// they work whether a fake feed delivers synchronously or on the main queue.
@MainActor
private final class StoreChangeLog {
    private(set) var changes: [StoreChange] = []

    init(_ store: StateStore) {
        store.addChangeObserver { [weak self] change in
            self?.changes.append(change)
        }
    }

    var count: Int { changes.count }
}

/// Records every delay the store asks for and keeps the work so a test can
/// fire it by hand.
private final class StoreDeadlineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [TimeInterval] = []
    private var recordedWork: [@MainActor @Sendable () -> Void] = []

    var scheduler: DeadlineScheduler {
        DeadlineScheduler { [self] delay, work in
            lock.lock()
            recordedDelays.append(delay)
            recordedWork.append(work)
            lock.unlock()
        }
    }

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDelays
    }

    var lastWork: (@MainActor @Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return recordedWork.last
    }
}

/// A performer that notes which rows the feed had marked seen at the moment
/// the jump ran, which proves navigation precedes acknowledgment.
@MainActor
private final class StoreOrderProbePerformer: JumpPerforming {
    let feed: FakeSessionFeed
    private(set) var performedLog: [[JumpAction]] = []
    private(set) var jumpedRowsAtPerform: [[RowID]] = []

    init(feed: FakeSessionFeed) {
        self.feed = feed
    }

    func perform(_ actions: [JumpAction]) async throws {
        jumpedRowsAtPerform.append(feed.jumpedRows)
        performedLog.append(actions)
    }
}

@MainActor
private final class StoreFocusOutcome {
    var finished = false
    var error: Error?
}

/// Runs `store.focus(id)` as the UI does (a main-actor Task) and spins the
/// main run loop until it settles. Returns the thrown error, if any.
@MainActor
private func runStoreFocus(_ store: StateStore, _ id: RowID) throws -> Error? {
    let outcome = StoreFocusOutcome()
    Task { @MainActor in
        do {
            try await store.focus(id)
        } catch {
            outcome.error = error
        }
        outcome.finished = true
    }
    try spinMainRunLoop(timeout: 2) { outcome.finished }
    return outcome.error
}

/// Default arguments are evaluated outside the main actor, so the main-actor
/// performer is created inside the body.
@MainActor
private func makeStore(
    feeds: [any SessionFeed],
    clock: ManualWallClock = ManualWallClock(),
    policy: any InterruptDeciding = NoInterrupts(),
    performer: (any JumpPerforming)? = nil,
    context: JumpContext = JumpContext(),
    focus: FocusContext = FocusContext(),
    namesFile: URL? = nil,
    scheduler: DeadlineScheduler = .manual
) -> StateStore {
    StateStore(
        feeds: feeds,
        clock: clock,
        focusProvider: FakeFocusContextProvider(focus),
        jumpPerformer: performer ?? RecordingJumpPerformer(),
        jumpContextProvider: StaticJumpContextProvider(context),
        policy: policy,
        nameOverridesFileURL: namesFile,
        deadlineScheduler: scheduler
    )
}

private extension Optional {
    func unwrapStore(_ message: String) throws -> Wrapped {
        guard let self else { throw TestFailure.expectation(message) }
        return self
    }
}

// MARK: Publishing and merging

@MainActor
func testStoreUnchangedPublishDoesNotInvalidateObservation() throws {
    let feed = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [feed])
    let log = StoreChangeLog(store)
    store.start()
    let steady = [AgentRow.fixture(key: "w1:p1", state: .working)]
    feed.publish(steady)
    try spinMainRunLoop(timeout: 1) { log.count == 1 }

    // Feeds republish their full row set on every event; reassigning equal
    // values would invalidate the whole widget tree for nothing.
    let unchanged = StoreObservationProbe()
    withObservationTracking {
        _ = store.rows
        _ = store.summary
        _ = store.feedHealth
        _ = store.nameOverrides
    } onChange: {
        unchanged.recordChange()
    }
    feed.publish(steady)
    try spinMainRunLoop(timeout: 1) { log.count == 2 }
    try expect(unchanged.sawChange, equals: false, "an identical publish must not invalidate observers")

    // The guard must not make the store go blind: real change still publishes.
    let changed = StoreObservationProbe()
    withObservationTracking {
        _ = store.rows
    } onChange: {
        changed.recordChange()
    }
    feed.publish([AgentRow.fixture(key: "w1:p1", state: .waiting)])
    try spinMainRunLoop(timeout: 1) { log.count == 3 }
    try expect(changed.sawChange, equals: true, "a state change still reaches observers")
    try expect(store.summary.text, equals: "1 waiting", "summary follows the published rows")
}

@MainActor
func testStoreMergesFeedsAndDropsDuplicateRegistryRows() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let registry = FakeSessionFeed(source: .claudeRegistry)
    let store = makeStore(feeds: [herdr, registry])
    let log = StoreChangeLog(store)
    store.start()

    let herdrRow = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .working, processIDs: [100])
    var duplicate = AgentRow.fixture(source: .claudeRegistry, key: "100@Mon Sep 21 10:00:00 2026",
                                     state: .working, processIDs: [100])
    duplicate.sourceStatus = "busy"
    let outside = AgentRow.fixture(source: .claudeRegistry, key: "200@Mon Sep 21 10:00:00 2026",
                                   state: .waiting, processIDs: [200])
    herdr.publish([herdrRow])
    registry.publish([duplicate, outside])
    try spinMainRunLoop(timeout: 1) { log.count == 2 }

    try expect(store.rows.map(\.id), equals: [outside.id, herdrRow.id],
               "Herdr owns pid 100, so its registry row is dropped; waiting sorts before working")
    try expect(log.changes.last?.registryShadow, equals: [herdrRow.id: "busy"],
               "the dropped registry status is kept as the soak shadow for the Herdr row")
    try expect(store.summary.text, equals: "1 waiting · 1 working", "summary counts the merged rows only")
}

@MainActor
func testStoreKeepsOfflineFeedRowsAndPublishesHealth() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let codex = FakeSessionFeed(source: .codexDesktop)
    let store = makeStore(feeds: [herdr, codex])
    let log = StoreChangeLog(store)
    store.start()
    let pane = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .waiting)
    herdr.report(.online)
    herdr.publish([pane])
    try spinMainRunLoop(timeout: 1) { log.count == 2 }

    herdr.report(.offline(reason: "connection refused"))
    try spinMainRunLoop(timeout: 1) { log.count == 3 }
    try expect(store.feedHealth[.herdr], equals: .offline(reason: "connection refused"), "health is published")
    try expect(store.rows, equals: [pane], "an offline feed's rows stay on screen (dimmed by the UI)")

    // An offline feed cannot see agents end: its empty publish is ignored.
    // The Codex publish after it is a sync point that does produce a change.
    herdr.publish([])
    codex.publish([])
    try spinMainRunLoop(timeout: 1) { log.count == 4 }
    try expect(store.rows, equals: [pane], "an empty publish while offline does not clear the rows")
    try expect(store.warningSources, equals: [.herdr], "offline shows the warning glyph")

    codex.report(.disabled(reason: "unsupported method x"))
    try spinMainRunLoop(timeout: 1) { log.count == 5 }
    try expect(store.warningSources, equals: [.herdr, .codexDesktop], "disabled shows the warning glyph too")
    codex.report(.inactive(reason: "sessions directory missing"))
    try spinMainRunLoop(timeout: 1) { log.count == 6 }
    try expect(store.warningSources, equals: [.herdr], "inactive shows no warning glyph")

    herdr.report(.online)
    herdr.publish([])
    try spinMainRunLoop(timeout: 1) { log.count == 8 }
    try expect(store.rows, equals: [], "once online again, the feed's empty set is authoritative")
    try expect(store.warningSources, equals: [], "back online clears the warning")
}

@MainActor
func testStoreHandlesFortyEightPaneChurn() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [herdr])
    let log = StoreChangeLog(store)
    store.start()
    let panes = (0..<48).map { AgentRow.fixture(key: "w\($0 / 8):p\($0)", state: .working) }
    herdr.publish(panes)
    var churned = panes
    churned[17].state = .waiting
    churned[40].state = .error
    herdr.publish(churned)
    herdr.publish(churned)
    try spinMainRunLoop(timeout: 1) { log.count == 3 }

    try expect(store.rows.count, equals: 48, "every pane is kept")
    try expect(Array(store.rows.prefix(2).map(\.id.key)), equals: ["w5:p40", "w2:p17"],
               "error sorts first, then waiting")
    try expect(store.summary.text, equals: "1 error · 1 waiting · 46 working", "summary follows the churn")
    try expect(log.changes[2].previousRows, equals: log.changes[2].rows,
               "an identical republish still reports one change, with nothing moved")
}

// MARK: Quiet periods

@MainActor
func testStoreStartBeginsQuietPeriodForEverySource() throws {
    let clock = ManualWallClock()
    let spy = SpyInterruptDecider()
    let store = makeStore(feeds: [FakeSessionFeed(source: .herdr)], clock: clock, policy: spy)
    store.start()
    try expect(spy.log.quietPeriods.map(\.sources), equals: [Set(SessionSource.allCases)],
               "launch starts one quiet period covering every source")
    try expect(spy.log.quietPeriods.map(\.at), equals: [clock.now()], "at the injected clock's time")
}

@MainActor
func testStoreReconnectBeginsQuietPeriodForThatSourceOnly() throws {
    let clock = ManualWallClock()
    let herdr = FakeSessionFeed(source: .herdr)
    let codex = FakeSessionFeed(source: .codexDesktop)
    let spy = SpyInterruptDecider()
    let store = makeStore(feeds: [herdr, codex], clock: clock, policy: spy)
    let log = StoreChangeLog(store)
    store.start()
    herdr.report(.online)
    codex.report(.online)
    try spinMainRunLoop(timeout: 1) { log.count == 2 }
    try expect(spy.log.quietPeriods.count, equals: 1, "a first online report is not a reconnect")

    // Herdr restarts: refused, then a backoff step, then back.
    herdr.report(.offline(reason: "connection refused"))
    clock.advance(by: 1)
    herdr.report(.offline(reason: "reconnecting in 1 s"))
    try spinMainRunLoop(timeout: 1) { log.count == 4 }
    try expect(spy.log.quietPeriods.count, equals: 1, "an offline reason change is not a reconnect")
    clock.advance(by: 1)
    herdr.report(.online)
    try spinMainRunLoop(timeout: 1) { log.count == 5 }
    try expect(spy.log.quietPeriods.count, equals: 2, "offline to online is a reconnect")
    try expect(spy.log.quietPeriods.last?.sources, equals: [.herdr], "only the reconnected source goes quiet")
    try expect(spy.log.quietPeriods.last?.at, equals: clock.now(), "the quiet period starts at the reconnect")

    // A protocol change disables the feed; a later probe recovers it.
    herdr.report(.disabled(reason: "protocol 23"))
    herdr.report(.online)
    try spinMainRunLoop(timeout: 1) { log.count == 7 }
    try expect(spy.log.quietPeriods.count, equals: 3, "disabled to online is also a reconnect")
    try expect(spy.log.quietPeriods.last?.sources, equals: [.herdr], "still only the recovered source")

    codex.report(.inactive(reason: "sessions directory missing"))
    codex.report(.online)
    try spinMainRunLoop(timeout: 1) { log.count == 9 }
    try expect(spy.log.quietPeriods.count, equals: 3, "inactive to online is not a reconnect")
}

// MARK: Policy and deadlines

@MainActor
func testStoreDeadlineAndTickRerunPolicy() throws {
    let clock = ManualWallClock()
    let feed = FakeSessionFeed(source: .herdr)
    let recorder = StoreDeadlineRecorder()
    let spy = SpyInterruptDecider(scripted: [PolicyDecision(nextDeadline: clock.now().addingTimeInterval(1))])
    let focus = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty, herdrFocusedPaneID: "w1:p1")
    let store = makeStore(feeds: [feed], clock: clock, policy: spy, focus: focus, scheduler: recorder.scheduler)
    store.start()
    feed.publish([AgentRow.fixture(key: "w1:p1", state: .waiting)])
    try spinMainRunLoop(timeout: 1) { spy.log.decideCalls == 1 }
    try expect(spy.log.lastFocus, equals: focus, "the policy sees the injected focus context")
    try expect(recorder.delays, equals: [1], "the store asks the scheduler to wake it at the deadline")

    clock.advance(by: 1)
    let wake = try recorder.lastWork.unwrapStore("a deadline was scheduled")
    wake()
    try expect(spy.log.decideCalls, equals: 2, "the scheduled wake-up re-runs the policy")

    clock.advance(by: 5)
    store.tick()
    try expect(spy.log.decideCalls, equals: 3, "tick re-runs the policy on demand")
}

@MainActor
func testStoreChangeObserversReceiveEverything() throws {
    let clock = ManualWallClock()
    let herdr = FakeSessionFeed(source: .herdr)
    let row = AgentRow.fixture(key: "w1:p1", state: .waiting)
    let peek = PeekEvent(rowID: row.id, kind: .waiting, question: nil, at: clock.now())
    let scripted = PolicyDecision(peeks: [peek], chime: true)
    let spy = SpyInterruptDecider(scripted: [scripted])
    let store = makeStore(feeds: [herdr], clock: clock, policy: spy)
    let first = StoreChangeLog(store)
    let second = StoreChangeLog(store)
    store.start()
    herdr.publish([row])
    try spinMainRunLoop(timeout: 1) { first.count == 1 }
    let published = first.changes[0]
    try expect(published.previousRows, equals: [], "previous rows are the rows before the merge")
    try expect(published.rows, equals: [row], "rows are the merged rows")
    try expect(published.decision, equals: scripted, "the policy decision rides along")
    try expect(published.at, equals: clock.now(), "stamped with the injected clock")
    try expect(published.healthChanges, equals: [], "a publish carries no health change")

    herdr.report(.offline(reason: "socket missing"))
    try spinMainRunLoop(timeout: 1) { first.count == 2 }
    try expect(first.changes[1].healthChanges,
               equals: [HealthChange(source: .herdr, from: nil, to: .offline(reason: "socket missing"))],
               "a health change is reported with its previous value")
    try expect(first.changes[1].previousRows, equals: first.changes[1].rows, "health alone moves no rows")
    try expect(second.changes, equals: first.changes, "every observer receives every change")
}

// MARK: Jumps and detail

@MainActor
func testStoreFocusPreservesClickedSnapshotBeforeTaskStarts() throws {
    let feed = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [feed])
    store.start()
    defer { store.stop() }
    var clicked = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    clicked.acknowledgmentID = "A"
    feed.publish([clicked])
    var newer = clicked
    newer.acknowledgmentID = "B"
    let outcome = StoreFocusOutcome()
    Task { @MainActor in
        do { try await store.focus(clicked) }
        catch { outcome.error = error }
        outcome.finished = true
    }
    // The UI handler captured A, but B is published before its Task can execute.
    feed.publish([newer])
    try spinMainRunLoop(timeout: 1) { outcome.finished }
    try expectTrue(outcome.error == nil, "navigation succeeds")
    try expect(feed.jumpedSnapshots.map(\.acknowledgmentID), equals: ["A"],
               "only the clicked snapshot reaches acknowledgment")
}

@MainActor
func testStoreFocusPerformsPlanBeforeMarkingSeen() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let performer = StoreOrderProbePerformer(feed: herdr)
    let store = makeStore(feeds: [herdr], performer: performer)
    store.start()
    let row = AgentRow.fixture(key: "w1:p1", state: .waiting,
                               jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "host: api"))
    herdr.publish([row])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }

    let error = try runStoreFocus(store, row.id)
    try expect(error == nil, equals: true, "focus succeeds")
    try expect(herdr.jumpedRows, equals: [row.id], "the owning feed marks the row seen")
    try expect(performer.jumpedRowsAtPerform, equals: [[]], "seen is marked only after the jump succeeds")
    try expect(performer.performedLog, equals: [JumpPlanner.plan(row.jump, context: JumpContext())],
               "the performer runs exactly the planned actions")
    try expect(store.plannedJumps(), equals: [row.id: JumpPlanner.plan(row.jump, context: JumpContext())],
               "planned jumps cover every row")
}

@MainActor
func testStoreFocusRejectsUnknownRowAndEmptyPlan() throws {
    let codex = FakeSessionFeed(source: .codexDesktop)
    let performer = RecordingJumpPerformer()
    let store = makeStore(feeds: [codex], performer: performer, context: JumpContext(codexAppPath: nil))
    store.start()
    let thread = AgentRow.fixture(source: .codexDesktop, key: "thread-1", state: .doneUnseen,
                                  jump: .codexThread(id: "thread-1"))
    codex.publish([thread])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }

    let unknown = try runStoreFocus(store, RowID(source: .herdr, key: "w9:p9"))
    try expect(unknown as? JumpError, equals: .rowNotFound, "an unknown row is rejected")
    let empty = try runStoreFocus(store, thread.id)
    try expect(empty as? JumpError, equals: .noActions, "no Codex app means no actions")
    try expect(codex.jumpedRows, equals: [], "a click that cannot jump leaves the row unseen")
    try expect(performer.performedLog, equals: [], "nothing is performed")
}

@MainActor
func testStoreRequestDetailNeverMarksSeen() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [herdr])
    store.start()
    let done = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    herdr.publish([done])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }
    store.requestDetail(done.id)
    store.requestDetail(RowID(source: .herdr, key: "missing"))
    try expect(herdr.detailRequests, equals: [done.id], "detail requests reach the owning feed for known rows")
    try expect(herdr.jumpedRows, equals: [], "hover detail never marks a row seen")
}

// MARK: Lifecycle

@MainActor
func testStoreStopStopsFeedsAndIgnoresLatePublishes() throws {
    let herdr = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [herdr])
    store.start()
    try expect(herdr.isStarted, equals: true, "start starts every feed")
    store.stop()
    try expect(herdr.stopCount, equals: 1, "stop stops every feed")
    herdr.publish([AgentRow.fixture(key: "w1:p1")])
    // Let a main-queue delivery (if the fake uses one) run before asserting.
    _ = try? spinMainRunLoop(timeout: 0.1) { false }
    try expect(store.rows, equals: [], "a publish after stop is ignored")
    store.stop()
    try expect(herdr.stopCount, equals: 1, "stop is idempotent")
}

// MARK: Names

@MainActor
func testStoreRenamePersistsAndPruneSparesSilentSources() throws {
    let directory = try TemporaryDirectory()
    let namesFile = directory.url
        .appendingPathComponent("support", isDirectory: true)
        .appendingPathComponent("session-names.json")
    let pane = AgentRow.fixture(source: .herdr, key: "w1:p1")
    let registryID = RowID(source: .claudeRegistry, key: "4242@Mon Sep 21 10:00:00 2026")

    let herdr = FakeSessionFeed(source: .herdr)
    let store = makeStore(feeds: [herdr, FakeSessionFeed(source: .claudeRegistry)], namesFile: namesFile)
    store.start()
    herdr.publish([pane])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }
    store.rename(pane.id, to: "API refactor")
    store.rename(registryID, to: "Registry agent")
    try expect(store.nameOverrides.displayName(for: pane.id), equals: "API refactor", "renamed in the store")
    let mode = try FileManager.default.attributesOfItem(atPath: namesFile.path)[.posixPermissions] as? Int
    try expect(mode, equals: 0o600, "the names file is private")
    let directoryMode = try FileManager.default
        .attributesOfItem(atPath: namesFile.deletingLastPathComponent().path)[.posixPermissions] as? Int
    try expect(directoryMode, equals: 0o700, "its directory is private")

    // The app restarts: a fresh store reads both names back.
    let restartedHerdr = FakeSessionFeed(source: .herdr)
    let restartedRegistry = FakeSessionFeed(source: .claudeRegistry)
    let restarted = makeStore(feeds: [restartedHerdr, restartedRegistry], namesFile: namesFile)
    let log = StoreChangeLog(restarted)
    try expect(restarted.nameOverrides.displayName(for: pane.id), equals: "API refactor", "survives a restart")
    restarted.start()

    // Herdr publishes without the pane: its name goes. The registry has not
    // published yet, so its name stays.
    restartedHerdr.publish([])
    try spinMainRunLoop(timeout: 1) { log.count == 1 }
    try expect(restarted.nameOverrides.displayName(for: pane.id), equals: nil,
               "a published, online source prunes names for rows that ended")
    try expect(restarted.nameOverrides.displayName(for: registryID), equals: "Registry agent",
               "a source that has not published keeps its names")

    // Offline: a publish prunes nothing for that source.
    restartedRegistry.report(.offline(reason: "directory unreadable"))
    restartedRegistry.publish([])
    try spinMainRunLoop(timeout: 1) { log.count == 3 }
    try expect(restarted.nameOverrides.displayName(for: registryID), equals: "Registry agent",
               "an offline source keeps its names")

    // Back online with the row gone: now it is pruned, and the prune persists.
    restartedRegistry.report(.online)
    restartedRegistry.publish([])
    try spinMainRunLoop(timeout: 1) { log.count == 5 }
    try expect(restarted.nameOverrides.displayName(for: registryID), equals: nil,
               "an online source that published prunes ended rows")
    let reread = makeStore(feeds: [], namesFile: namesFile)
    try expect(reread.nameOverrides, equals: SessionNameOverrides(), "the prune reached disk")
}

@MainActor
func testStoreDisplayNamePrefersOverride() throws {
    let store = makeStore(feeds: [])
    let long = String(repeating: "x", count: 200)
    let pane = AgentRow.fixture(key: "w1:p1", title: long)
    try expect(store.displayName(for: pane).count, equals: SessionTitleFormatter.maximumTitleLength,
               "a runaway title is capped")
    store.rename(pane.id, to: "  Short name  ")
    try expect(store.displayName(for: pane), equals: "Short name", "a trimmed override wins")
    store.rename(pane.id, to: "   ")
    try expect(store.displayName(for: pane),
               equals: SessionTitleFormatter.truncate(long, to: SessionTitleFormatter.maximumTitleLength),
               "a blank rename restores the row title")
}

@MainActor
func testStoreClearAllSessionNamesPersists() throws {
    let directory = try TemporaryDirectory()
    let namesFile = directory.file("session-names.json")
    let store = makeStore(feeds: [], namesFile: namesFile)
    let id = RowID(source: .codexDesktop, key: "thread-1")
    store.rename(id, to: "Custom name")
    store.clearAllSessionNames()
    try expect(store.nameOverrides.displayName(for: id), equals: nil, "cleared in memory")
    let restarted = makeStore(feeds: [], namesFile: namesFile)
    try expect(restarted.nameOverrides.displayName(for: id), equals: nil, "cleared on disk")
}

// MARK: Presentation mappings the store's rows drive

func testStoreIndicatorStylesCoverEveryStateAndSegment() throws {
    try expect(DisplayState.allCases.map(\.indicatorStyle),
               equals: [.orangeDot, .redDot, .spinner, .uncertain, .greenDot, .mutedDot, .mutedDot],
               "waiting, error, working, stale, doneUnseen, idle, starting")
    try expect(Summary.Segment.Kind.allCases.map(\.indicatorStyle),
               equals: [.redDot, .orangeDot, .spinner, .uncertain, .greenDot],
               "error, waiting, working, done")
}

func testStoreRowIconsResolvePerSource() throws {
    try expect(BundledResources.iconURL(for: .claudeRegistry)?.lastPathComponent, equals: "claude.svg",
               "Claude rows use the bundled Claude mark")
    try expect(BundledResources.iconURL(for: .codexDesktop)?.lastPathComponent, equals: "codex.svg",
               "Codex rows use the bundled Codex mark")
    try expect(BundledResources.iconURL(for: .herdr), equals: nil, "Herdr rows use a system symbol")
}

// MARK: Codex app identity (the rule LiveAppActivity applies; risk 40)

func testStoreCodexAppIdentitySeparatesChatGPTFromCodexApp() throws {
    let codexApp = "/Applications/Codex.app"
    let chatGPTApp = "/Applications/ChatGPT.app"
    var lookups = 0
    let installed: () -> Bool = { true }
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: codexApp) {
            lookups += 1
            return true
        },
        equals: KnownBundleIDs.codex, "Codex.app is Codex")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: "/Users/me/Applications/Codex.app/") {
            lookups += 1
            return true
        },
        equals: KnownBundleIDs.codex, "a Codex.app anywhere, trailing slash or not, is Codex")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.ghostty, bundlePath: "/Applications/Ghostty.app") {
            lookups += 1
            return true
        },
        equals: KnownBundleIDs.ghostty, "other ids pass through")
    try expect(lookups, equals: 0, "LaunchServices is not asked for Codex.app or other apps")

    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: chatGPTApp) {
            lookups += 1
            return true
        },
        equals: CodexAppIdentity.chatGPTAppBundleID,
        "ChatGPT.app shares com.openai.codex but is not Codex while a Codex.app is installed")
    try expect(lookups, equals: 1, "the installed lookup runs only for a com.openai.codex bundle outside Codex.app")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: chatGPTApp, codexAppInstalled: { false }),
        equals: KnownBundleIDs.codex, "with no Codex.app installed the running bundle stands in for Codex")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: nil, codexAppInstalled: installed),
        equals: KnownBundleIDs.codex, "an unknown bundle path keeps the shared id")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: KnownBundleIDs.codex, bundlePath: "", codexAppInstalled: installed),
        equals: KnownBundleIDs.codex, "an empty bundle path keeps the shared id")
    try expect(
        CodexAppIdentity.effectiveBundleID(bundleID: nil, bundlePath: chatGPTApp, codexAppInstalled: installed),
        equals: nil, "no bundle id stays nil")
}

func testStoreCodexAppIdentityLooksUpTheSharedIDForTheChatGPTAlias() throws {
    try expect(CodexAppIdentity.systemBundleID(for: CodexAppIdentity.chatGPTAppBundleID), equals: KnownBundleIDs.codex,
               "ChatGPT.app is found among com.openai.codex applications")
    try expect(CodexAppIdentity.systemBundleID(for: KnownBundleIDs.codex), equals: KnownBundleIDs.codex,
               "Codex is looked up as itself")
    try expect(CodexAppIdentity.systemBundleID(for: KnownBundleIDs.claudeDesktop), equals: KnownBundleIDs.claudeDesktop,
               "other ids are looked up as themselves")
    try expectTrue(CodexAppIdentity.chatGPTAppBundleID != KnownBundleIDs.codex
                       && CodexAppIdentity.chatGPTAppBundleID != KnownBundleIDs.ghostty
                       && CodexAppIdentity.chatGPTAppBundleID != KnownBundleIDs.claudeDesktop,
                   "the alias matches no known bundle id, so no Codex rule fires for it")
}

let stateStoreTests: [TestCase] = [
    ("store: focus preserves clicked snapshot before task starts", testStoreFocusPreservesClickedSnapshotBeforeTaskStarts),
    ("store: an unchanged publish does not invalidate observation", testStoreUnchangedPublishDoesNotInvalidateObservation),
    ("store: two feeds merge, sort and drop registry rows Herdr owns", testStoreMergesFeedsAndDropsDuplicateRegistryRows),
    ("store: an offline feed keeps its rows and its health is published", testStoreKeepsOfflineFeedRowsAndPublishesHealth),
    ("store: 48 panes churn with one change per publish", testStoreHandlesFortyEightPaneChurn),
    ("store: start begins a quiet period for every source", testStoreStartBeginsQuietPeriodForEverySource),
    ("store: a reconnect begins a quiet period for that source only", testStoreReconnectBeginsQuietPeriodForThatSourceOnly),
    ("store: a policy deadline is scheduled and tick re-runs the policy", testStoreDeadlineAndTickRerunPolicy),
    ("store: change observers receive rows, decision, shadow and health", testStoreChangeObserversReceiveEverything),
    ("store: focus performs the planned jump before marking the row seen", testStoreFocusPerformsPlanBeforeMarkingSeen),
    ("store: focus rejects an unknown row and an empty plan", testStoreFocusRejectsUnknownRowAndEmptyPlan),
    ("store: detail requests reach the feed and never mark seen", testStoreRequestDetailNeverMarksSeen),
    ("store: stop stops every feed and ignores later publishes", testStoreStopStopsFeedsAndIgnoresLatePublishes),
    ("store: rename persists and prune spares silent or offline sources", testStoreRenamePersistsAndPruneSparesSilentSources),
    ("store: display name prefers the override, then the capped title", testStoreDisplayNamePrefersOverride),
    ("store: clearing all session names persists", testStoreClearAllSessionNamesPersists),
    ("store: indicator styles cover every state and segment", testStoreIndicatorStylesCoverEveryStateAndSegment),
    ("store: row icons resolve per source", testStoreRowIconsResolvePerSource),
    ("store: codex app identity separates ChatGPT.app from Codex.app", testStoreCodexAppIdentitySeparatesChatGPTFromCodexApp),
    ("store: codex app identity looks up the shared id for the ChatGPT alias", testStoreCodexAppIdentityLooksUpTheSharedIDForTheChatGPTAlias),
]

// Tests/IslandTests/HerdrFeedTests.swift
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Helpers

@MainActor
private func testConfiguration(_ adjust: (inout HerdrFeed.Configuration) -> Void = { _ in }) -> HerdrFeed.Configuration {
    var configuration = HerdrFeed.Configuration.standard(hostname: "testhost")
    configuration.reconcileInterval = 0.05
    configuration.pingInterval = 0.2
    configuration.backoff = [0.01]
    configuration.disabledProbeInterval = 0.1
    adjust(&configuration)
    return configuration
}

/// Reconcile and ping only when a test asks, so request counts are exact.
@MainActor
private func quietConfiguration(_ adjust: (inout HerdrFeed.Configuration) -> Void = { _ in }) -> HerdrFeed.Configuration {
    testConfiguration { configuration in
        configuration.reconcileInterval = 60
        configuration.pingInterval = 60
        adjust(&configuration)
    }
}

private func fakePane(_ paneID: String, status: String = "working", agent: String? = "claude",
                      focused: Bool = false, seq: UInt64 = 1) -> FakeHerdrPane {
    let workspace = String(paneID.split(separator: ":").first ?? "w1")
    return FakeHerdrPane(paneID: paneID, workspaceID: workspace, tabID: "\(workspace):t1", agent: agent, status: status,
                         title: "fixture title \(paneID)", cwd: "/tmp/fixture-project", focused: focused,
                         stateChangeSeq: seq)
}

private func fakeState(_ panes: [FakeHerdrPane], focused: String? = nil) -> FakeHerdrState {
    var workspaces: [String: String] = ["w1": "ws-w1"]
    var tabs: [String: String] = ["w1:t1": "tab-1"]
    for pane in panes {
        workspaces[pane.workspaceID] = "ws-\(pane.workspaceID)"
        tabs[pane.tabID] = "tab-1"
    }
    return FakeHerdrState(panes: panes, workspaceLabels: workspaces, tabLabels: tabs, focusedPaneID: focused)
}

/// Adds the pane to the server state first (so its subscription is accepted), then announces it on G.
private func createPane(_ server: FakeHerdrServer, _ pane: FakeHerdrPane) {
    server.updateState { state in
        if !state.panes.contains(where: { $0.paneID == pane.paneID }) { state.panes.append(pane) }
    }
    server.emitPaneCreated(pane)
}

private func closePane(_ server: FakeHerdrServer, _ paneID: String) {
    server.updateState { state in state.panes.removeAll { $0.paneID == paneID } }
    server.emitPaneClosed(paneID: paneID)
}

private func params(_ record: FakeHerdrRequestRecord) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(record.paramsJSON.utf8)) as? [String: Any] else {
        return [:]
    }
    return object
}

/// The pane of a single per-pane status subscription, nil for G and for other methods.
private func subscribedPane(_ record: FakeHerdrRequestRecord) -> String? {
    guard record.method == "events.subscribe",
          let subscriptions = params(record)["subscriptions"] as? [[String: Any]],
          subscriptions.count == 1 else { return nil }
    return subscriptions[0]["pane_id"] as? String
}

private func subscribeCount(_ server: FakeHerdrServer, paneID: String) -> Int {
    server.requestLog.filter { subscribedPane($0) == paneID }.count
}

private func requestCount(_ server: FakeHerdrServer, _ method: String) -> Int {
    server.requestLog.filter { $0.method == method }.count
}

private func extraDescriptors(baseline: Int, server: FakeHerdrServer) -> Int {
    openFileDescriptorCount() - baseline - server.liveDescriptorCount
}

private func offlineReasons(_ values: [FeedHealth]) -> [String] {
    values.compactMap { health -> String? in
        if case .offline(let reason) = health { return reason }
        return nil
    }
}

@MainActor
private func settle(_ seconds: TimeInterval) {
    try? spinMainRunLoop(timeout: seconds) { false }
}

private let workspaceRenamedEvent =
    #"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"w1","label":"renamed"}}"#

private let paneUpdatedEvent =
    #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w1:p1","terminal_id":"term-w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"working","revision":2,"agent":"claude","terminal_title_stripped":"fixture title w1:p1","cwd":"/tmp/fixture-project"}}}"#

private func paneFocusedEvent(_ paneID: String) -> String {
    #"{"event":"pane_focused","data":{"type":"pane_focused","pane_id":""# + paneID + #"","workspace_id":"w1"}}"#
}

private final class EmitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
private final class HealthRecorder {
    var values: [FeedHealth] = []
}

@MainActor
private final class FeedHarness {
    let server: FakeHerdrServer
    let clock: ManualWallClock
    let activity: FakeAppActivity
    let feed: HerdrFeed
    private(set) var rows: [AgentRow] = []
    private(set) var health: [FeedHealth] = []
    private(set) var publishCount = 0

    init(state: FakeHerdrState, configuration: HerdrFeed.Configuration, serverVersion: String = "0.9.1-fake") throws {
        server = try FakeHerdrServer(version: serverVersion)
        server.setState(state)
        clock = ManualWallClock()
        activity = FakeAppActivity()
        activity.frontmost = "com.apple.finder"
        feed = HerdrFeed(client: HerdrClient(socketPath: server.socketPath), clock: clock, activity: activity,
                         configuration: configuration, scheduler: .manual)
    }

    var onlineCount: Int { health.filter { $0 == .online }.count }

    func start() {
        feed.observeHealth { [weak self] health in self?.health.append(health) }
        feed.start { [weak self] rows in
            self?.rows = rows
            self?.publishCount += 1
        }
    }

    func startOnline() throws {
        start()
        try spinMainRunLoop(timeout: 3) { self.health.last == .online }
    }

    func row(_ paneID: String) -> AgentRow? {
        rows.first { $0.id == RowID(source: .herdr, key: paneID) }
    }

    func shutdown() {
        feed.stop()
        try? spinMainRunLoop(timeout: 2) { self.feed.openPaneStreamCount == 0 && !self.feed.isGlobalStreamOpen }
        server.stop()
    }
}

// MARK: - Host name

func testHerdrFeedHostNameIsShortHostname() throws {
    var buffer = [CChar](repeating: 0, count: 256)
    try expect(gethostname(&buffer, buffer.count), equals: 0, "gethostname succeeds")
    let full = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    let short = HostName.short()
    try expectTrue(!short.isEmpty, "the short host name is not empty")
    try expectTrue(!short.contains("."), "the short host name has no domain part")
    try expectTrue(full.hasPrefix(short), "the short host name is a prefix of gethostname")
}

// MARK: - Server version

func testHerdrFeedServerVersionGatesJumps() throws {
    try expect(HerdrServerVersion.health(forServerVersion: "0.9.0"),
               equals: .degraded(reason: "server 0.9.0 predates 0.9.1, so a click cannot move the Herdr view; run herdr update --handoff"),
               "0.9.0 applies agent.focus to server state only")
    try expect(HerdrServerVersion.health(forServerVersion: "0.9"),
               equals: .degraded(reason: "server 0.9 predates 0.9.1, so a click cannot move the Herdr view; run herdr update --handoff"),
               "a missing patch component counts as zero")
    for version in ["0.9.1", "0.9.1-fake", "0.9.2", "0.10.0", "1.0", "", "dev"] {
        try expect(HerdrServerVersion.health(forServerVersion: version), equals: .online,
                   "\(version.isEmpty ? "an empty version" : version) is online (unparsable versions never warn)")
    }
}

@MainActor
func testHerdrFeedOldServerIsDegradedUntilUpgraded() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: testConfiguration(),
                                  serverVersion: "0.9.0")
    defer { harness.shutdown() }
    harness.start()
    let degraded = HerdrServerVersion.health(forServerVersion: "0.9.0")
    try spinMainRunLoop(timeout: 3) { harness.health.last == degraded }
    try expectTrue(harness.row("w1:p1") != nil, "a degraded feed still publishes its rows")
    try harness.server.restart(version: "0.9.1")
    try spinMainRunLoop(timeout: 3) { harness.health.last == .online }
    try expectTrue(harness.row("w1:p1") != nil, "rows survive the upgrade")
}

// MARK: - Bootstrap

@MainActor
func testHerdrFeedBootstrapRequestOrder() throws {
    let harness = try FeedHarness(
        state: fakeState([fakePane("w1:p1"), fakePane("w1:p2", status: "blocked"), fakePane("w1:p3", status: "unknown", agent: nil)]),
        configuration: quietConfiguration()
    )
    defer { harness.shutdown() }
    try harness.startOnline()
    let log = harness.server.requestLog
    try expectTrue(log.count >= 7, "bootstrap made at least 7 requests (saw \(log.count))")
    try expect(log.prefix(7).map(\.method),
               equals: ["ping", "events.subscribe", "session.snapshot",
                        "events.subscribe", "events.subscribe", "events.subscribe", "session.snapshot"],
               "ping, G, snapshot #1, one stream per pane, snapshot #2")
    let global = params(log[1])["subscriptions"] as? [[String: Any]] ?? []
    try expect(global.count, equals: 15, "G subscribes the 15 lifecycle and focus types")
    try expectTrue(global.allSatisfy { $0["pane_id"] == nil }, "G has no pane filter")
    try expect(Set(log[3...5].compactMap(subscribedPane)), equals: Set(["w1:p1", "w1:p2", "w1:p3"]),
               "one status stream per pane, the shell included")
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 3 && harness.feed.isGlobalStreamOpen }
    try expect(harness.rows.map(\.id.key).sorted(), equals: ["w1:p1", "w1:p2"], "rows only for agent panes")
    try expect(harness.health, equals: [.online], "a clean bootstrap reports online once")
}

@MainActor
func testHerdrFeedAppliesBufferedGlobalEventsAfterSnapshotTwo() throws {
    let harness = try FeedHarness(state: fakeState((1...6).map { fakePane("w1:p\($0)") }),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    let server = harness.server
    let emitted = EmitFlag()
    DispatchQueue.global().async {
        let deadline = DispatchTime.now() + 3
        while server.globalSubscriberCount == 0 && DispatchTime.now() < deadline { usleep(50) }
        // w1:p6 stays in the server state: if this event were applied before snapshot #2,
        // snapshot #2 would bring the row back and it would stay until the next reconcile (60 s).
        server.emitGlobal(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p6","workspace_id":"w1"}}"#)
        emitted.set()
    }
    harness.start()
    try spinMainRunLoop(timeout: 3) { emitted.isSet && harness.health.last == .online }
    try spinMainRunLoop(timeout: 1) { harness.row("w1:p6") == nil && harness.row("w1:p5") != nil }
    let expected = ["ping", "events.subscribe", "session.snapshot"]
        + Array(repeating: "events.subscribe", count: 6) + ["session.snapshot"]
    try expect(Array(harness.server.requestLog.prefix(10).map(\.method)), equals: expected,
               "bootstrap order holds while G events are buffered")
}

@MainActor
func testHerdrFeedHealthGoesFromSocketMissingToOnline() throws {
    let path = "/tmp/hf-\(getpid())-late.sock"
    unlink(path)
    let activity = FakeAppActivity()
    activity.frontmost = "com.apple.finder"
    let feed = HerdrFeed(client: HerdrClient(socketPath: path), clock: ManualWallClock(), activity: activity,
                         configuration: testConfiguration(), scheduler: .manual)
    let recorder = HealthRecorder()
    feed.observeHealth { recorder.values.append($0) }
    feed.start { _ in }
    defer { feed.stop() }
    try spinMainRunLoop(timeout: 2) { recorder.values.contains(.offline(reason: "reconnecting in 0.01 s")) }
    let server = try FakeHerdrServer(socketPath: path)
    defer { server.stop() }
    server.setState(fakeState([fakePane("w1:p1")]))
    try spinMainRunLoop(timeout: 3) { recorder.values.last == .online }
    try expect(recorder.values.first, equals: .offline(reason: "socket missing"), "the first report names the missing socket")
    try expectTrue(recorder.values.dropLast().allSatisfy { if case .offline = $0 { return true }; return false },
                   "offline until the bootstrap succeeds (saw \(recorder.values))")
}

// MARK: - Per-pane streams

@MainActor
func testHerdrFeedOpensAndClosesPaneStreams() throws {
    let baseline = openFileDescriptorCount()
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 1 }
    createPane(harness.server, fakePane("w1:p2", status: "idle"))
    try spinMainRunLoop(timeout: 2) {
        harness.server.subscriberCount(paneID: "w1:p2") == 1 && harness.row("w1:p2") != nil
    }
    try expect(subscribeCount(harness.server, paneID: "w1:p2"), equals: 1,
               "pane_created opens exactly one status subscription")
    try expect(harness.feed.openPaneStreamCount, equals: 2, "two pane streams are open")
    closePane(harness.server, "w1:p2")
    try spinMainRunLoop(timeout: 2) {
        harness.server.subscriberCount(paneID: "w1:p2") == 0 && harness.feed.openPaneStreamCount == 1
            && harness.row("w1:p2") == nil
    }
    try spinMainRunLoop(timeout: 2) { extraDescriptors(baseline: baseline, server: harness.server) <= 2 }
}

@MainActor
func testHerdrFeedPaneNotFoundDropsOnlyThatStream() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: testConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 2 }
    harness.server.rejectMethod("events.subscribe", code: "pane_not_found", message: "pane w1:p3 not found")
    createPane(harness.server, fakePane("w1:p3", status: "idle"))
    try spinMainRunLoop(timeout: 2) {
        harness.row("w1:p3") != nil && subscribeCount(harness.server, paneID: "w1:p3") >= 1
    }
    settle(0.1)
    try expect(harness.health.last, equals: .online, "a rejected pane does not take the feed down")
    try expect(harness.feed.openPaneStreamCount, equals: 2, "only the rejected pane has no stream")
    harness.server.emitStatus(paneID: "w1:p1", status: "blocked")
    harness.server.emitStatus(paneID: "w1:p2", status: "done")
    try spinMainRunLoop(timeout: 2) {
        harness.row("w1:p1")?.state == .waiting && harness.row("w1:p2")?.state == .doneUnseen
    }
    harness.server.clearRejections()
    try spinMainRunLoop(timeout: 2) { harness.server.subscriberCount(paneID: "w1:p3") == 1 }
}

@MainActor
func testHerdrFeedReconnectCyclesDoNotLeakDescriptors() throws {
    let baseline = openFileDescriptorCount()
    let paneCount = 6
    let harness = try FeedHarness(state: fakeState((1...paneCount).map { fakePane("w1:p\($0)") }),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    for _ in 0..<100 {
        let before = harness.onlineCount
        harness.server.dropAllConnections()
        try spinMainRunLoop(timeout: 3) { harness.onlineCount > before }
    }
    try spinMainRunLoop(timeout: 3) {
        harness.feed.openPaneStreamCount == paneCount
            && extraDescriptors(baseline: baseline, server: harness.server) <= paneCount + 2
    }
}

// MARK: - Reconcile

@MainActor
func testHerdrFeedReconcileRepairsSilentStream() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.server.subscriberCount(paneID: "w1:p1") == 1 }
    let opensBefore = subscribeCount(harness.server, paneID: "w1:p1")
    harness.server.silenceStatusStream(paneID: "w1:p1")
    harness.server.emitStatus(paneID: "w1:p1", status: "blocked")
    settle(0.1)
    try expect(harness.row("w1:p1")?.state, equals: .working, "the silenced stream delivered nothing")
    harness.feed.reconcileNow()
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.state == .waiting }
    try spinMainRunLoop(timeout: 2) {
        subscribeCount(harness.server, paneID: "w1:p1") == opensBefore + 1
            && harness.server.subscriberCount(paneID: "w1:p1") == 1
    }
}

@MainActor
func testHerdrFeedReconcileRepairsDroppedEvent() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.server.subscriberCount(paneID: "w1:p2") == 1 }
    let opensBefore = subscribeCount(harness.server, paneID: "w1:p2")
    harness.server.updateState { state in
        if let index = state.panes.firstIndex(where: { $0.paneID == "w1:p2" }) { state.panes[index].status = "done" }
    }
    harness.feed.reconcileNow()
    try spinMainRunLoop(timeout: 2) {
        harness.row("w1:p2")?.state == .doneUnseen
            && subscribeCount(harness.server, paneID: "w1:p2") == opensBefore + 1
            && harness.server.subscriberCount(paneID: "w1:p2") == 1
    }
}

@MainActor
func testHerdrFeedWorkspaceRenameTriggersReconcile() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try expect(harness.row("w1:p1")?.subtitle, equals: "ws-w1 › tab-1", "initial subtitle")
    let snapshotsBefore = requestCount(harness.server, "session.snapshot")
    harness.server.updateState { $0.workspaceLabels["w1"] = "renamed" }
    harness.server.emitGlobal(workspaceRenamedEvent)
    try spinMainRunLoop(timeout: 0.2) { requestCount(harness.server, "session.snapshot") > snapshotsBefore }
    try spinMainRunLoop(timeout: 1) { harness.row("w1:p1")?.subtitle == "renamed › tab-1" }
    try expect(harness.row("w1:p1")?.jump, equals: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "testhost: renamed"),
               "the Ghostty title prefix carries the new label")
}

// MARK: - Deadlines

@MainActor
func testHerdrFeedExitGraceRunsThroughTick() throws {
    let harness = try FeedHarness(
        state: fakeState([fakePane("w1:p1"), fakePane("w1:p2"), fakePane("w1:p3", status: "idle")]),
        configuration: quietConfiguration()
    )
    defer { harness.shutdown() }
    try harness.startOnline()

    harness.server.emitPaneExited(paneID: "w1:p1")
    // G delivers in order: once p3's focus is applied, the exit has been applied too.
    harness.server.emitGlobal(paneFocusedEvent("w1:p3"))
    try spinMainRunLoop(timeout: 2) { harness.feed.focusedPaneID == "w1:p3" }
    try expect(harness.row("w1:p1")?.state, equals: .working, "no error before the grace period")
    harness.clock.advance(by: 1.1)
    harness.feed.tick()
    try expect(harness.row("w1:p1")?.state, equals: .error, "exit while working is an error after 1 s")
    try expect(harness.row("w1:p1")?.detail?.kind, equals: .error, "the error row carries an error detail")

    harness.server.emitPaneExited(paneID: "w1:p2")
    closePane(harness.server, "w1:p2")
    harness.server.emitGlobal(paneFocusedEvent("w1:p1"))
    try spinMainRunLoop(timeout: 2) { harness.feed.focusedPaneID == "w1:p1" }
    harness.clock.advance(by: 1.1)
    harness.feed.tick()
    try expectTrue(harness.row("w1:p2") == nil, "pane_closed within 1 s leaves no row")
    try expect(harness.rows.filter { $0.state == .error }.map(\.id.key), equals: ["w1:p1"], "only the first pane errored")
}

// MARK: - Failure paths

@MainActor
func testHerdrFeedPingFailureClosesStreamsAndBacksOff() throws {
    let baseline = openFileDescriptorCount()
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: testConfiguration { $0.backoff = [0.01, 0.02, 0.04] })
    defer { harness.shutdown() }
    try harness.startOnline()
    harness.server.rejectMethod("ping", code: "internal_error", message: "fake ping failure")
    try spinMainRunLoop(timeout: 3) { offlineReasons(harness.health).contains("reconnecting in 0.04 s") }
    try spinMainRunLoop(timeout: 2) {
        harness.feed.openPaneStreamCount == 0 && !harness.feed.isGlobalStreamOpen
            && harness.server.subscriberCount(paneID: "w1:p1") == 0
            && harness.server.subscriberCount(paneID: "w1:p2") == 0
            && harness.server.globalSubscriberCount == 0
    }
    let reasons = offlineReasons(harness.health)
    guard let first = reasons.firstIndex(of: "reconnecting in 0.01 s"),
          let second = reasons.firstIndex(of: "reconnecting in 0.02 s"),
          let third = reasons.firstIndex(of: "reconnecting in 0.04 s") else {
        throw TestFailure.expectation("every backoff step is reported (saw \(reasons))")
    }
    try expectTrue(first < second && second < third, "backoff follows the configured schedule")
    var maxExtra = 0
    let pingsBefore = requestCount(harness.server, "ping")
    try? spinMainRunLoop(timeout: 0.3) {
        maxExtra = max(maxExtra, extraDescriptors(baseline: baseline, server: harness.server))
        return false
    }
    try expectTrue(maxExtra <= 1, "each reconnect attempt holds at most 1 fd (saw \(maxExtra))")
    try expectTrue(requestCount(harness.server, "ping") >= pingsBefore + 3, "attempts continue at the capped delay")
    harness.server.clearRejections()
    try spinMainRunLoop(timeout: 3) { harness.health.last == .online }

    let onlineBefore = harness.onlineCount
    harness.server.dropAllConnections()
    try spinMainRunLoop(timeout: 3) { harness.onlineCount > onlineBefore && harness.feed.openPaneStreamCount == 2 }
    try expectTrue(harness.health.contains(.offline(reason: "reconnecting in 0.01 s")), "EOF reports the first backoff step")
}

@MainActor
func testHerdrFeedProtocolChangeDisablesProbesAndReenables() throws {
    let server = try FakeHerdrServer()
    server.setState(fakeState([fakePane("w1:p1")]))
    let clock = ManualWallClock()
    let activity = FakeAppActivity()
    activity.frontmost = "com.apple.finder"
    let feed = HerdrFeed(client: HerdrClient(socketPath: server.socketPath), clock: clock, activity: activity,
                         configuration: testConfiguration(), scheduler: .manual)
    let spy = SpyInterruptDecider()
    let store = StateStore(feeds: [feed], clock: clock, focusProvider: FakeFocusContextProvider(),
                           jumpPerformer: RecordingJumpPerformer(),
                           jumpContextProvider: StaticJumpContextProvider(JumpContext()),
                           policy: spy, deadlineScheduler: .manual)
    store.start()
    defer { store.stop(); feed.stop(); server.stop() }
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online && store.rows.count == 1 }

    try server.restart(protocolVersion: 23)
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .disabled(reason: "protocol 23") }
    let subscribesAtDisable = requestCount(server, "events.subscribe")
    let pingsAtDisable = requestCount(server, "ping")
    try spinMainRunLoop(timeout: 2) { requestCount(server, "ping") >= pingsAtDisable + 2 }
    try expect(requestCount(server, "events.subscribe"), equals: subscribesAtDisable, "a disabled feed opens no streams")
    try spinMainRunLoop(timeout: 2) { feed.openPaneStreamCount == 0 && !feed.isGlobalStreamOpen }
    try expect(store.rows.map(\.id.key), equals: ["w1:p1"], "rows are kept (dimmed) while disabled")

    let quietBefore = spy.log.quietPeriods.count
    try server.restart(protocolVersion: 22)
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online }
    try expectTrue(spy.log.quietPeriods.count > quietBefore, "re-enabling starts a quiet period")
    try expect(spy.log.quietPeriods.last?.sources, equals: Set<SessionSource>([.herdr]), "only herdr goes quiet")
}

@MainActor
func testHerdrFeedUnsupportedMethodDisablesAndRecovers() throws {
    let baseline = openFileDescriptorCount()
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: testConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    harness.server.rejectMethod("session.snapshot")
    try harness.server.restart()
    try spinMainRunLoop(timeout: 3) {
        harness.health.last == .disabled(reason: "unsupported method session.snapshot")
    }
    try spinMainRunLoop(timeout: 2) {
        !harness.feed.isGlobalStreamOpen && harness.feed.openPaneStreamCount == 0
            && extraDescriptors(baseline: baseline, server: harness.server) <= 0
    }
    harness.server.clearRejections()
    try spinMainRunLoop(timeout: 1) { harness.health.last == .online }
}

// MARK: - Detection, focus and seen

@MainActor
func testHerdrFeedBlockedEpisodeReadsDetectionOnceAndRefreshesFocus() throws {
    let blockedText = try Fixtures.string("herdr/detection-blocked-1.txt")
    guard let prompt = DetectionTextParser.parseBlocked(blockedText) else {
        throw TestFailure.expectation("the masked blocked fixture parses")
    }
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2", status: "idle")], focused: "w1:p2"),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.setDetectionText(paneID: "w1:p1", blockedText)
    try harness.startOnline()
    try expect(harness.feed.focusedPaneID, equals: "w1:p2", "focus from the bootstrap snapshot")
    harness.server.updateState { $0.focusedPaneID = "w1:p1" }
    let readsBefore = requestCount(harness.server, "agent.read")
    let snapshotsBefore = requestCount(harness.server, "session.snapshot")
    harness.server.emitStatus(paneID: "w1:p1", status: "blocked")
    try spinMainRunLoop(timeout: 2) {
        harness.row("w1:p1")?.detail?.kind == .question && harness.feed.focusedPaneID == "w1:p1"
    }
    settle(0.2)
    try expect(requestCount(harness.server, "agent.read") - readsBefore, equals: 1, "exactly one detection read")
    try expect(requestCount(harness.server, "session.snapshot") - snapshotsBefore, equals: 1,
               "exactly one focus-refresh snapshot")
    try expect(harness.row("w1:p1")?.detail, equals: Detail(question: prompt.question, options: prompt.options, kind: .question),
               "the card question comes from the detection text")
    for record in harness.server.requestLog where record.method == "agent.read" {
        try expect(params(record)["source"] as? String, equals: "detection", "only detection reads are ever made")
    }
}

@MainActor
func testHerdrFeedRequestsProcessInfoOnBootstrapDetectionAndUpdate() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2", status: "unknown", agent: nil)]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.setProcessInfo(paneID: "w1:p1", foregroundPIDs: [4242])
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.processIDs == [4242] }
    let queried = harness.server.requestLog.filter { $0.method == "pane.process_info" }
        .compactMap { params($0)["pane_id"] as? String }
    try expectTrue(queried.contains("w1:p1"), "bootstrap queries the agent pane")
    try expectTrue(!queried.contains("w1:p2"), "shell panes are not queried")

    harness.server.setProcessInfo(paneID: "w1:p1", foregroundPIDs: [4243])
    harness.server.emitAgentDetected(paneID: "w1:p1", released: false)
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.processIDs == [4243] }

    harness.server.setProcessInfo(paneID: "w1:p1", foregroundPIDs: [4244])
    harness.server.emitGlobal(paneUpdatedEvent)
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.processIDs == [4244] }
}

@MainActor
func testHerdrFeedJumpSendsNoRequestAndClearsOverlay() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    harness.server.emitStatus(paneID: "w1:p1", status: "idle")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.state == .doneUnseen }
    settle(0.1)
    let requestsBefore = harness.server.requestLog.count
    guard let row = harness.row("w1:p1") else { throw TestFailure.expectation("row present") }
    let feed = harness.feed
    Task { @MainActor in try? await feed.jump(row) }
    try spinMainRunLoop(timeout: 1) { harness.row("w1:p1")?.state == .idle }
    settle(0.1)
    try expect(harness.server.requestLog.count, equals: requestsBefore, "jump sends no socket request")
    try expect(harness.server.focusRequests, equals: [], "the feed never sends agent.focus itself")
}

@MainActor
func testHerdrFeedLoadDetailReadsRecapOnceAndKeepsDoneUnseen() throws {
    let doneText = try Fixtures.string("herdr/detection-done-1.txt")
    let expectedRecap = DetectionTextParser.parseRecap(doneText)
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1", status: "done")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.setDetectionText(paneID: "w1:p1", doneText)
    try harness.startOnline()
    guard let row = harness.row("w1:p1") else { throw TestFailure.expectation("row present") }
    try expect(row.state, equals: .doneUnseen, "done is unseen")
    let readsBefore = requestCount(harness.server, "agent.read")
    harness.feed.loadDetail(for: row)
    harness.feed.loadDetail(for: row)
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.detail?.kind == .recap }
    settle(0.1)
    try expect(requestCount(harness.server, "agent.read") - readsBefore, equals: 1, "one detection read")
    try expect(harness.row("w1:p1")?.detail?.question, equals: expectedRecap, "recap text from the detection read")
    try expect(harness.row("w1:p1")?.state, equals: .doneUnseen, "loading the detail never marks the row seen")
    if let loaded = harness.row("w1:p1") { harness.feed.loadDetail(for: loaded) }
    settle(0.1)
    try expect(requestCount(harness.server, "agent.read") - readsBefore, equals: 1, "a loaded recap is not read again")
}

@MainActor
func testHerdrFeedCastsToHerdrFocusReporting() throws {
    let feed: any SessionFeed = HerdrFeed(client: HerdrClient(socketPath: "/tmp/hf-unused.sock"), clock: ManualWallClock(),
                                          activity: FakeAppActivity(), configuration: .standard(hostname: "testhost"))
    try expectTrue(feed is any HerdrFocusReporting, "the composition root's cast works")
    let feeds: [any SessionFeed] = [feed]
    try expectTrue(feeds.lazy.compactMap { $0 as? any HerdrFocusReporting }.first != nil, "the root finds the focus reporter")
    try expect(feed.source, equals: .herdr, "source is herdr")
    let standard = HerdrFeed.Configuration.standard(hostname: "h")
    try expect(standard.reconcileInterval, equals: IslandTiming.herdrReconcile, "reconcile interval")
    try expect(standard.pingInterval, equals: IslandTiming.herdrPing, "ping interval")
    try expect(standard.backoff, equals: IslandTiming.herdrBackoff, "backoff schedule")
    try expect(standard.disabledProbeInterval, equals: IslandTiming.herdrDisabledProbe, "disabled probe interval")
    try expect(standard.maxPaneStreams, equals: IslandTiming.herdrMaxPaneStreams, "stream cap")
    try expect(standard.maxConcurrentRequests, equals: IslandTiming.herdrMaxConcurrentRequests, "request gate")
    try expect(HerdrFeed.Configuration.standard().hostname, equals: HostName.short(), "default host name")
}

// MARK: - Hardening 1: server restart replaces the socket file

@MainActor
private final class OutageRecorder {
    var rowCounts: [Int] = []
}

private func socketInode(_ path: String) -> UInt64 {
    var info = stat()
    guard stat(path, &info) == 0 else { return 0 }
    return UInt64(info.st_ino)
}

@MainActor
func testHerdrFeedRecoversFromServerRestartWithNewInode() throws {
    let baseline = openFileDescriptorCount()
    let server = try FakeHerdrServer()
    defer { server.stop() }
    server.setState(fakeState((1...4).map { fakePane("w1:p\($0)") }))
    let clock = ManualWallClock()
    let activity = FakeAppActivity()
    activity.frontmost = "com.apple.finder"
    let feed = HerdrFeed(client: HerdrClient(socketPath: server.socketPath), clock: clock, activity: activity,
                         configuration: testConfiguration(), scheduler: .manual)
    let store = StateStore(feeds: [feed], clock: clock, focusProvider: FakeFocusContextProvider(),
                           jumpPerformer: RecordingJumpPerformer(),
                           jumpContextProvider: StaticJumpContextProvider(JumpContext()),
                           deadlineScheduler: .manual)
    let outage = OutageRecorder()
    store.addChangeObserver { change in
        if change.healthChanges.contains(where: { $0.source == .herdr && !$0.to.isOnline }) {
            outage.rowCounts.append(change.rows.count)
        }
    }
    store.start()
    defer { store.stop(); feed.stop() }
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online && store.rows.count == 4 }
    let inodeBefore = socketInode(server.socketPath)
    try server.restart()
    try expectTrue(socketInode(server.socketPath) != inodeBefore, "FakeHerdrServer.restart rebinds a new socket file")
    try spinMainRunLoop(timeout: 3) {
        !outage.rowCounts.isEmpty && store.feedHealth[.herdr] == .online && feed.openPaneStreamCount == 4
    }
    try expectTrue(outage.rowCounts.allSatisfy { $0 == 4 }, "offline rows are kept during the outage (saw \(outage.rowCounts))")
    try expect(store.rows.count, equals: 4, "every row is back after the restart")
    try spinMainRunLoop(timeout: 2) { extraDescriptors(baseline: baseline, server: server) <= 4 + 2 }
}

// MARK: - Hardening 2: 40+ panes created and closed in rapid succession

@MainActor
private final class DiagnosticRecorder {
    var messages: [String] = []
}

@MainActor
func testHerdrFeedSurvivesFortyFivePaneChurnWithinStreamCap() throws {
    let baseline = openFileDescriptorCount()
    let cap = 16
    let harness = try FeedHarness(
        state: FakeHerdrState(panes: [], workspaceLabels: ["w1": "ws-w1"], tabLabels: ["w1:t1": "tab-1"]),
        configuration: testConfiguration { $0.maxPaneStreams = cap }
    )
    defer { harness.shutdown() }
    let diagnostics = DiagnosticRecorder()
    harness.feed.observeDiagnostics { diagnostics.messages.append($0) }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { extraDescriptors(baseline: baseline, server: harness.server) <= 1 }
    let idleExtra = extraDescriptors(baseline: baseline, server: harness.server)   // G only

    var maxStreams = 0
    var remaining: [String] = []
    for index in 0..<45 {
        let pane = fakePane("w1:p\(index)")
        createPane(harness.server, pane)
        if index % 3 == 0 {
            // Closed before the feed has even seen pane_created, so the close lands before the stream's ack.
            closePane(harness.server, pane.paneID)
        } else {
            remaining.append(pane.paneID)
        }
        if index % 5 == 4 {
            try? spinMainRunLoop(timeout: 0.02) {
                maxStreams = max(maxStreams, harness.feed.openPaneStreamCount)
                return false
            }
        }
    }
    try spinMainRunLoop(timeout: 3) {
        maxStreams = max(maxStreams, harness.feed.openPaneStreamCount)
        return Set(harness.rows.map(\.id.key)) == Set(remaining) && harness.feed.openPaneStreamCount == cap
    }
    // 30 panes remain and 16 have streams: the cap bound, the other 14 rely on the reconcile, and it was reported.
    let capMessage = "pane stream cap reached (\(cap) streams)"
    try expect(diagnostics.messages.first, equals: capMessage, "reaching the stream cap is reported (saw \(diagnostics.messages))")
    try expectTrue(diagnostics.messages.allSatisfy { $0 == capMessage }, "the only diagnostic is the cap (saw \(diagnostics.messages))")
    try expectTrue(diagnostics.messages.count <= harness.onlineCount,
                   "at most one cap report per session (\(diagnostics.messages.count) reports, \(harness.onlineCount) sessions)")
    try expect(harness.health, equals: [.online], "the cap is a diagnostic, not a health change (saw \(harness.health))")
    for paneID in remaining { closePane(harness.server, paneID) }
    try spinMainRunLoop(timeout: 3) {
        maxStreams = max(maxStreams, harness.feed.openPaneStreamCount)
        return harness.feed.openPaneStreamCount == 0 && harness.rows.isEmpty
    }
    try expectTrue(maxStreams <= cap, "open pane streams never exceed maxPaneStreams (max \(maxStreams))")
    try spinMainRunLoop(timeout: 3) { extraDescriptors(baseline: baseline, server: harness.server) <= idleExtra }
}

// MARK: - Fixture replay (Task 5 masked logs and goldens, read-only)

@MainActor
private final class ReplayProgress {
    var onlineCount = 0
    /// The latest policy deadline the store asked for (its scheduler is .manual; the driver delivers it).
    var nextDeadline: Date?
    var decisions: [ReplayDecision] = []
}

/// One store policy decision, `offset` seconds after the replay start.
private struct ReplayDecision {
    let offset: TimeInterval
    let decision: PolicyDecision
}

private struct ReplayRun {
    let timeline: [String]
    let decisions: [ReplayDecision]
}

/// True when the store shows exactly the server's panes with their statuses and every pane has one live stream.
@MainActor
private func replayMirrors(_ store: StateStore, _ server: FakeHerdrServer, _ statuses: [String: String]) -> Bool {
    let keys = Set(store.rows.filter { $0.source == .herdr }.map(\.id.key))
    guard keys == Set(statuses.keys) else { return false }
    for (paneID, status) in statuses {
        guard store.row(RowID(source: .herdr, key: paneID))?.sourceStatus == status,
              server.subscriberCount(paneID: paneID) == 1 else { return false }
    }
    return true
}

@MainActor
private func runReplay(_ name: String) throws -> ReplayRun {
    let lines = try Fixtures.string("herdr/replay-\(name).jsonl")
        .split(separator: "\n").map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let server = try FakeHerdrServer()
    defer { server.stop() }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = ManualWallClock(start)
    let activity = FakeAppActivity()
    activity.frontmost = "com.apple.finder"   // Ghostty is never frontmost during a replay
    let feed = HerdrFeed(
        client: HerdrClient(socketPath: server.socketPath), clock: clock, activity: activity,
        configuration: testConfiguration { $0.reconcileInterval = 3_600; $0.pingInterval = 3_600 },
        scheduler: .manual
    )
    let store = StateStore(feeds: [feed], clock: clock, focusProvider: FakeFocusContextProvider(),
                           jumpPerformer: RecordingJumpPerformer(),
                           jumpContextProvider: StaticJumpContextProvider(JumpContext()),
                           policy: InterruptPolicy(), deadlineScheduler: .manual)
    let progress = ReplayProgress()
    store.addChangeObserver { change in
        progress.onlineCount += change.healthChanges.filter { $0.source == .herdr && $0.to == .online }.count
        progress.nextDeadline = change.decision.nextDeadline
        progress.decisions.append(ReplayDecision(offset: change.at.timeIntervalSince(start), decision: change.decision))
    }
    store.start()
    defer { store.stop(); feed.stop() }
    try spinMainRunLoop(timeout: 5) { progress.onlineCount >= 1 }

    var statuses: [String: String] = [:]   // what the server holds: pane_id → status
    var timeline: [String] = []
    for (index, line) in lines.enumerated() {
        let location = "replay-\(name) line \(index + 1)"
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let op = object["op"] as? String else {
            throw TestFailure.expectation("\(location) is not an op object")
        }
        if let at = (object["at"] as? NSNumber)?.doubleValue {
            let opTime = start.addingTimeInterval(at)
            // Deliver the store's policy deadlines that fall before this op, at their own time (the 1 s hold).
            while let due = progress.nextDeadline, due <= opTime {
                progress.nextDeadline = nil
                if due > clock.now() { clock.set(due) }
                store.tick()
            }
            clock.set(opTime)
        }
        switch op {
        case "state":
            var panes: [FakeHerdrPane] = []
            var workspaces: [String: String] = [:]
            var tabs: [String: String] = [:]
            for entry in (object["panes"] as? [[String: Any]]) ?? [] {
                guard let paneID = entry["pane_id"] as? String,
                      let workspace = entry["workspace_id"] as? String,
                      let status = entry["status"] as? String else {
                    throw TestFailure.expectation("\(location) has a malformed pane")
                }
                let seq = (entry["seq"] as? NSNumber)?.uint64Value ?? 0
                let focused = (entry["focused"] as? NSNumber)?.boolValue ?? false
                panes.append(FakeHerdrPane(paneID: paneID, workspaceID: workspace, tabID: "\(workspace):t1",
                                           agent: "claude", status: status, title: "pane \(paneID)", cwd: nil,
                                           focused: focused, stateChangeSeq: seq))
                workspaces[workspace] = "ws-\(workspace)"
                tabs["\(workspace):t1"] = "tab-1"
            }
            server.setState(FakeHerdrState(panes: panes, workspaceLabels: workspaces, tabLabels: tabs,
                                           focusedPaneID: object["focused_pane_id"] as? String))
            let changed = panes.filter { pane in statuses[pane.paneID].map { $0 != pane.status } ?? false }
            for pane in changed { server.emitStatus(paneID: pane.paneID, status: pane.status) }
            try spinMainRunLoop(timeout: 3) {
                changed.allSatisfy { store.row(RowID(source: .herdr, key: $0.paneID))?.sourceStatus == $0.status }
            }
            statuses = [:]
            for pane in panes { statuses[pane.paneID] = pane.status }
            let snapshotsBefore = requestCount(server, "session.snapshot")
            feed.reconcileNow()
            try spinMainRunLoop(timeout: 3) {
                requestCount(server, "session.snapshot") > snapshotsBefore && replayMirrors(store, server, statuses)
            }
        case "status":
            guard let paneID = object["pane_id"] as? String, let status = object["status"] as? String else {
                throw TestFailure.expectation("\(location) has a malformed status op")
            }
            server.emitStatus(paneID: paneID, status: status)
            if statuses[paneID] != nil {
                statuses[paneID] = status
                try spinMainRunLoop(timeout: 3) {
                    store.row(RowID(source: .herdr, key: paneID))?.sourceStatus == status
                }
            }
        case "created":
            guard let paneID = object["pane_id"] as? String, let workspace = object["workspace_id"] as? String else {
                throw TestFailure.expectation("\(location) has a malformed created op")
            }
            let pane = FakeHerdrPane(paneID: paneID, workspaceID: workspace, tabID: "\(workspace):t1", agent: "claude",
                                     status: "idle", title: "pane \(paneID)", cwd: nil, focused: false, stateChangeSeq: 1)
            server.updateState { state in
                if state.workspaceLabels[workspace] == nil { state.workspaceLabels[workspace] = "ws-\(workspace)" }
                if state.tabLabels["\(workspace):t1"] == nil { state.tabLabels["\(workspace):t1"] = "tab-1" }
                if !state.panes.contains(where: { $0.paneID == paneID }) { state.panes.append(pane) }
            }
            server.emitPaneCreated(pane)
            statuses[paneID] = "idle"
            try spinMainRunLoop(timeout: 3) { replayMirrors(store, server, statuses) }
        case "closed":
            guard let paneID = object["pane_id"] as? String else {
                throw TestFailure.expectation("\(location) has a malformed closed op")
            }
            server.updateState { state in state.panes.removeAll { $0.paneID == paneID } }
            server.emitPaneClosed(paneID: paneID)
            statuses[paneID] = nil
            try spinMainRunLoop(timeout: 3) {
                store.row(RowID(source: .herdr, key: paneID)) == nil && server.subscriberCount(paneID: paneID) == 0
            }
        case "reconnect":
            let before = progress.onlineCount
            server.dropAllConnections()
            try spinMainRunLoop(timeout: 5) { progress.onlineCount > before && replayMirrors(store, server, statuses) }
        default:
            throw TestFailure.expectation("\(location) has an unknown op")
        }
        timeline.append(store.summary.isEmpty ? "(none)" : store.summary.text)
    }
    var collapsed: [String] = []
    for entry in timeline where collapsed.last != entry { collapsed.append(entry) }
    return ReplayRun(timeline: collapsed, decisions: progress.decisions)
}

/// Runs the replay, throws on the first timeline line that differs from the golden, and returns the run.
@MainActor
@discardableResult
private func compareReplay(_ name: String) throws -> ReplayRun {
    let run = try runReplay(name)
    let actual = run.timeline
    let expected = try Fixtures.string("herdr/replay-\(name).expected.txt")
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard actual != expected else { return run }
    let shared = min(actual.count, expected.count)
    let index = (0..<shared).first { actual[$0] != expected[$0] } ?? shared
    let got = index < actual.count ? actual[index] : "<end of feed timeline>"
    let want = index < expected.count ? expected[index] : "<end of golden>"
    throw TestFailure.expectation(
        "replay-\(name): first difference at timeline line \(index + 1): feed '\(got)', golden '\(want)'"
    )
}

@MainActor
func testHerdrFeedReplaySub2MatchesGolden() throws {
    let run = try compareReplay("sub2")

    // §12.1: the recorded 0.3 s flicker gives one peek and one chime. In sub2, the flicker (631.82–632.58)
    // sits inside the w14:pB blocked episode that starts at 551.9. Each window opens a little before its first
    // transition, so float rounding of the offsets cannot drop a decision.
    let flickerPane = RowID(source: .herdr, key: "w14:pB")
    let episode = run.decisions.filter { $0.offset >= 551.5 && $0.offset < 643 }
    let flicker = run.decisions.filter { $0.offset >= 631.5 && $0.offset < 643 }
    let paneLabel = flickerPane.description
    let episodePeeks: [(offset: TimeInterval, peek: PeekEvent)] = episode.flatMap { entry in
        entry.decision.peeks.filter { $0.rowID == flickerPane }.map { (offset: entry.offset, peek: $0) }
    }
    try expect(episodePeeks.count, equals: 1, "the \(paneLabel) episode holding the flicker peeks exactly once")
    try expect(episodePeeks.first?.peek.kind, equals: .waiting, "a waiting peek")
    let peekOffset = episodePeeks.first?.offset ?? -1
    try expectTrue(abs(peekOffset - 552.9) < 0.01, "it peeks when the first blocked has held 1 s (at \(peekOffset))")
    let episodeChimes = episode.filter { $0.decision.chime }
    try expect(episodeChimes.count, equals: 1, "the episode chimes exactly once")
    try expectTrue(episodeChimes.first?.decision.peeks.contains(where: { $0.rowID == flickerPane }) ?? false,
                   "the chime goes with the \(paneLabel) peek")
    try expect(flicker.flatMap { $0.decision.peeks }.count, equals: 0, "the flicker itself adds no peek")
    try expect(flicker.filter { $0.decision.chime }.count, equals: 0, "the flicker itself adds no chime")
    let repeats = flicker.flatMap { $0.decision.notes }.filter { $0.rowID == flickerPane && $0.rule == .episodeRepeat }
    try expect(repeats.count, equals: 2, "each return to blocked within 10 s continues the announced episode")
    let allPanePeeks = run.decisions.flatMap { $0.decision.peeks }.filter { $0.rowID == flickerPane }
    try expect(allPanePeeks.count, equals: 1, "\(paneLabel) peeks once in the whole replay")
}

@MainActor
func testHerdrFeedReplayPollMatchesGolden() throws {
    try compareReplay("poll")
}

// MARK: - Controller rulings (Task 6 review) and restart/hover follow-ups

@MainActor
private final class PublishRecorder {
    var batches: [[AgentRow]] = []
}

/// A time stamp written on a background thread (the fake server's queue) and read on the main thread.
private final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval?
    func stamp() { lock.lock(); value = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    var time: TimeInterval? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Ruling (a): a reconcile snapshot requested before a pane's stream reported a status must not revert that
/// status. The fake server's queue is held so the order is fixed: the reconcile request is sent, then the
/// pane's stream reports idle, then the server state reverts to working (a snapshot that predates the event),
/// and a second hold keeps the snapshot request queued well behind the event. While a hold is active the main
/// thread never calls into the server (its accessors would wait for the held queue).
@MainActor
func testHerdrFeedSnapshotDoesNotRevertNewerStreamStatus() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2", status: "idle")]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { harness.server.subscriberCount(paneID: "w1:p1") == 1 }
    let server = harness.server
    let snapshotsBefore = requestCount(server, "session.snapshot")

    let held = EmitFlag()
    let secondHoldEnd = UptimeBox()
    DispatchQueue.global().async { server.updateState { _ in held.set(); usleep(300_000) } }
    try spinMainRunLoop(timeout: 2) { held.isSet }
    DispatchQueue.global().async { server.emitStatus(paneID: "w1:p1", status: "idle") }
    settle(0.03)
    DispatchQueue.global().async {
        server.updateState { state in
            if let index = state.panes.firstIndex(where: { $0.paneID == "w1:p1" }) { state.panes[index].status = "working" }
        }
    }
    settle(0.03)
    DispatchQueue.global().async { server.updateState { _ in usleep(200_000); secondHoldEnd.stamp() } }
    settle(0.03)
    harness.feed.reconcileNow()   // sent now; the server reads it only after both holds

    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.state == .doneUnseen }
    let eventApplied = ProcessInfo.processInfo.systemUptime
    try spinMainRunLoop(timeout: 2) { secondHoldEnd.time != nil }
    try expectTrue(eventApplied < (secondHoldEnd.time ?? 0),
                   "the stream event is applied while the snapshot request still waits behind the second hold")
    try spinMainRunLoop(timeout: 2) { requestCount(server, "session.snapshot") > snapshotsBefore }
    settle(0.2)
    try expect(harness.row("w1:p1")?.state, equals: .doneUnseen,
               "the older snapshot does not revert idle to working (no false finished-while-away churn)")
    try expect(harness.row("w1:p1")?.sourceStatus, equals: "idle", "the stream's status is kept")
    try expect(requestCount(server, "session.snapshot"), equals: snapshotsBefore + 1,
               "a status event alone does not discard the snapshot")
}

/// Ruling (b): Herdr went away right after reporting an exit (Ghostty quit: pane_exited, then EOF). The
/// pending exit belongs to the dead connection and never matures into an error row, even when the grace
/// deadline passes during the outage.
@MainActor
func testHerdrFeedLostConnectionDropsPendingExits() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2", status: "idle")]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    harness.server.emitPaneExited(paneID: "w1:p1")
    harness.server.emitGlobal(paneFocusedEvent("w1:p2"))   // G is ordered: focus applied means the exit was too
    try spinMainRunLoop(timeout: 2) { harness.feed.focusedPaneID == "w1:p2" }
    harness.server.updateState { state in state.panes.removeAll { $0.paneID == "w1:p1" } }
    harness.server.stop()
    try spinMainRunLoop(timeout: 2) { !harness.feed.isGlobalStreamOpen && harness.feed.openPaneStreamCount == 0 }
    harness.clock.advance(by: 1.1)
    harness.feed.tick()   // the grace deadline passes while Herdr is gone
    let onlineBefore = harness.onlineCount
    try harness.server.restart()
    try spinMainRunLoop(timeout: 3) { harness.onlineCount > onlineBefore }
    settle(0.1)
    try expect(harness.rows.filter { $0.state == .error }.map(\.id.key), equals: [],
               "no error row from an exit the dead connection reported")
    try expectTrue(harness.row("w1:p1") == nil, "the pane that went away with Herdr has no row")
}

/// Ruling (c): the reducer starts with Ghostty not frontmost; the feed must hand it the real value at start.
@MainActor
func testHerdrFeedAppliesInitialGhosttyFrontmost() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")], focused: "w1:p1"),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.activity.frontmost = KnownBundleIDs.ghostty
    try harness.startOnline()
    harness.server.emitStatus(paneID: "w1:p1", status: "idle")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.sourceStatus == "idle" }
    try expect(harness.row("w1:p1")?.state, equals: .idle,
               "finishing while Ghostty is frontmost from launch is not finished-while-away")
}

/// StateStore re-registers on restart: the latest observers win, the old ones hear nothing more, and the
/// restarted feed reports health and rows again even though nothing changed.
@MainActor
func testHerdrFeedRestartReportsToLatestObservers() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    harness.feed.stop()
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 0 && !harness.feed.isGlobalStreamOpen }
    let oldHealth = harness.health.count
    let oldPublishes = harness.publishCount
    let health = HealthRecorder()
    let published = PublishRecorder()
    harness.feed.observeHealth { health.values.append($0) }
    harness.feed.start { published.batches.append($0) }
    try spinMainRunLoop(timeout: 3) { health.values.last == .online && !published.batches.isEmpty }
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 1 && harness.feed.isGlobalStreamOpen }
    settle(0.1)
    try expect(health.values, equals: [.online], "the new observer hears online once")
    try expect(published.batches.last?.map(\.id.key), equals: ["w1:p1"], "the new publisher gets the rows")
    try expect(harness.health.count, equals: oldHealth, "the replaced health observer hears nothing")
    try expect(harness.publishCount, equals: oldPublishes, "the replaced publisher hears nothing")
}

/// Hover on a done row whose screen yields no recap: repeated hovers read once per done episode.
@MainActor
func testHerdrFeedRepeatedHoversReadOncePerDoneEpisode() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1", status: "done")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.setDetectionText(paneID: "w1:p1", "")
    try harness.startOnline()
    guard let row = harness.row("w1:p1") else { throw TestFailure.expectation("row present") }
    let readsBefore = requestCount(harness.server, "agent.read")
    for _ in 0..<5 {
        harness.feed.loadDetail(for: row)
        settle(0.05)
    }
    try expect(requestCount(harness.server, "agent.read") - readsBefore, equals: 1,
               "hovering the same done row again does not read again")
    harness.server.emitStatus(paneID: "w1:p1", status: "working")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.state == .working }
    harness.server.emitStatus(paneID: "w1:p1", status: "done")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.state == .doneUnseen }
    guard let next = harness.row("w1:p1") else { throw TestFailure.expectation("row present") }
    harness.feed.loadDetail(for: next)
    harness.feed.loadDetail(for: next)
    settle(0.1)
    try expect(requestCount(harness.server, "agent.read") - readsBefore, equals: 2, "a new done episode reads once more")
}

/// The server captures episode A's screen, then keeps that request open across the next episode.
@MainActor
func testHerdrFeedDelayedQuestionDoesNotCrossBlockedEpisodes() throws {
    let paneID = "w1:p1"
    let harness = try FeedHarness(state: fakeState([fakePane(paneID)]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.holdDetectionReads(paneID: paneID)
    harness.server.setDetectionText(paneID: paneID, "───\nOld question A?\n❯ 1. Yes\n───")
    try harness.startOnline()
    harness.server.emitStatus(paneID: paneID, status: "blocked")
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 1 }
    harness.server.emitStatus(paneID: paneID, status: "working")
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.state == .working }
    harness.server.setDetectionText(paneID: paneID, "───\nNew question B?\n❯ 1. Continue\n───")
    harness.server.emitStatus(paneID: paneID, status: "blocked")
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.state == .waiting }
    harness.server.releaseNextDetectionRead(paneID: paneID)
    settle(0.05)
    try expect(harness.row(paneID)?.detail, equals: nil, "episode A's reply cannot fill episode B's question")
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 2 }
    harness.server.releaseNextDetectionRead(paneID: paneID)
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.detail?.question == "New question B?" }
    try expect(harness.row(paneID)?.detail?.options, equals: ["Continue"], "the fresh episode supplies its own choices")
}

@MainActor
private func checkDelayedRecapAcrossEpisodes(oldText: String, recreatePane: Bool = false) throws {
    let paneID = "w1:p1"
    let harness = try FeedHarness(state: fakeState([fakePane(paneID, status: "done")]),
                                  configuration: quietConfiguration())
    defer { harness.shutdown() }
    harness.server.holdDetectionReads(paneID: paneID)
    harness.server.setDetectionText(paneID: paneID, oldText)
    try harness.startOnline()
    guard let first = harness.row(paneID) else { throw TestFailure.expectation("first done row present") }
    harness.feed.loadDetail(for: first)
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 1 }
    if recreatePane {
        closePane(harness.server, paneID)
        try spinMainRunLoop(timeout: 2) { harness.row(paneID) == nil }
        createPane(harness.server, fakePane(paneID, status: "done"))
    } else {
        harness.server.emitStatus(paneID: paneID, status: "working")
        try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.state == .working }
        harness.server.emitStatus(paneID: paneID, status: "done")
    }
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.state == .doneUnseen }
    harness.server.setDetectionText(paneID: paneID, "※ recap: New recap B.")
    guard let second = harness.row(paneID) else { throw TestFailure.expectation("second done row present") }
    harness.feed.loadDetail(for: second)
    harness.server.releaseNextDetectionRead(paneID: paneID)
    settle(0.05)
    try expect(harness.row(paneID)?.detail, equals: nil, "episode A's reply cannot fill episode B's recap")
    harness.feed.loadDetail(for: second)
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 2 }
    settle(0.05)
    try expect(requestCount(harness.server, "agent.read"), equals: 2,
               "an old completion neither caches nor clears the new episode's in-flight read")
    harness.server.releaseNextDetectionRead(paneID: paneID)
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.detail?.question == "New recap B." }
    try expect(harness.row(paneID)?.state, equals: .doneUnseen, "the fresh recap keeps done unseen")
}

@MainActor
func testHerdrFeedDelayedRecapDoesNotCrossDoneEpisodes() throws {
    try checkDelayedRecapAcrossEpisodes(oldText: "※ recap: Old recap A.")
}

@MainActor
func testHerdrFeedDelayedEmptyRecapDoesNotCacheNextEpisode() throws {
    try checkDelayedRecapAcrossEpisodes(oldText: "")
}

@MainActor
func testHerdrFeedDelayedRecapDoesNotReachRecreatedPane() throws {
    try checkDelayedRecapAcrossEpisodes(oldText: "※ recap: Old recap A.", recreatePane: true)
}

@MainActor
func testHerdrFeedQueuedDetectionSkipsAnEndedEpisode() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1"), fakePane("w1:p2")]),
                                  configuration: quietConfiguration { $0.maxConcurrentRequests = 1 })
    defer { harness.shutdown() }
    harness.server.holdDetectionReads(paneID: "w1:p1")
    harness.server.setDetectionText(paneID: "w1:p1", "───\nFirst question?\n❯ 1. Yes\n───")
    harness.server.setDetectionText(paneID: "w1:p2", "───\nCurrent question?\n❯ 1. Yes\n───")
    try harness.startOnline()
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "pane.process_info") == 2 }
    harness.server.emitStatus(paneID: "w1:p1", status: "blocked")
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 1 }
    harness.server.emitStatus(paneID: "w1:p2", status: "blocked")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p2")?.state == .waiting }
    harness.server.emitStatus(paneID: "w1:p2", status: "working")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p2")?.state == .working }
    harness.server.releaseNextDetectionRead(paneID: "w1:p1")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p1")?.detail?.question == "First question?" }
    settle(0.05)
    try expect(requestCount(harness.server, "agent.read"), equals: 1, "an ended episode never sends its queued read")
    harness.server.emitStatus(paneID: "w1:p2", status: "blocked")
    try spinMainRunLoop(timeout: 2) { harness.row("w1:p2")?.detail?.question == "Current question?" }
    try expect(requestCount(harness.server, "agent.read"), equals: 2, "the cancelled waiter releases its request slot")
}

@MainActor
func testHerdrFeedRestartCancelsDetectionAndReleasesItsSlot() throws {
    let paneID = "w1:p1"
    let harness = try FeedHarness(state: fakeState([fakePane(paneID, status: "done")]),
                                  configuration: quietConfiguration { $0.maxConcurrentRequests = 1 })
    defer { harness.shutdown() }
    harness.server.holdDetectionReads(paneID: paneID)
    harness.server.setDetectionText(paneID: paneID, "※ recap: Old session.")
    try harness.startOnline()
    guard let oldRow = harness.row(paneID) else { throw TestFailure.expectation("old row present") }
    harness.feed.loadDetail(for: oldRow)
    try spinMainRunLoop(timeout: 2) { requestCount(harness.server, "agent.read") == 1 }
    harness.feed.stop()
    try spinMainRunLoop(timeout: 2) { harness.feed.openPaneStreamCount == 0 && !harness.feed.isGlobalStreamOpen }
    harness.server.setDetectionText(paneID: paneID, "※ recap: New session.")
    harness.start()
    try spinMainRunLoop(timeout: 2) { harness.onlineCount == 2 }
    guard let newRow = harness.row(paneID) else { throw TestFailure.expectation("new row present") }
    harness.feed.loadDetail(for: newRow)
    try spinMainRunLoop(timeout: 0.5) { requestCount(harness.server, "agent.read") == 2 }
    harness.server.releaseNextDetectionRead(paneID: paneID)
    settle(0.05)
    try expect(harness.row(paneID)?.detail, equals: nil, "an old session's read cannot populate the restarted feed")
    harness.server.releaseNextDetectionRead(paneID: paneID)
    try spinMainRunLoop(timeout: 2) { harness.row(paneID)?.detail?.question == "New session." }
}

/// Pin: while offline the feed does not publish, so StateStore keeps and dims the old rows.
@MainActor
func testHerdrFeedDoesNotPublishWhileOffline() throws {
    let harness = try FeedHarness(state: fakeState([fakePane("w1:p1")]), configuration: quietConfiguration())
    defer { harness.shutdown() }
    try harness.startOnline()
    try expect(harness.row("w1:p1")?.state, equals: .working, "working at first")
    harness.server.stop()
    try spinMainRunLoop(timeout: 2) {
        !harness.feed.isGlobalStreamOpen && offlineReasons(harness.health).contains { $0.hasPrefix("reconnecting") }
    }
    let publishes = harness.publishCount
    harness.clock.advance(by: IslandTiming.staleAfter + 60)
    harness.feed.tick()
    settle(0.05)
    try expect(harness.publishCount, equals: publishes, "an offline tick publishes nothing")
    try expect(harness.row("w1:p1")?.state, equals: .working, "the kept row is unchanged while offline")
    let onlineBefore = harness.onlineCount
    try harness.server.restart()
    try spinMainRunLoop(timeout: 3) { harness.onlineCount > onlineBefore && harness.row("w1:p1")?.state == .stale }
}

/// A real HerdrFeed and a real StateStore over one FakeHerdrServer, for reconnect tests that need the
/// store's keep-and-dim rule in the loop.
@MainActor
private func storeOverFeed(_ server: FakeHerdrServer) -> (HerdrFeed, StateStore) {
    let clock = ManualWallClock()
    let activity = FakeAppActivity()
    activity.frontmost = "com.apple.finder"
    let feed = HerdrFeed(client: HerdrClient(socketPath: server.socketPath), clock: clock, activity: activity,
                         configuration: quietConfiguration(), scheduler: .manual)
    let store = StateStore(feeds: [feed], clock: clock, focusProvider: FakeFocusContextProvider(),
                           jumpPerformer: RecordingJumpPerformer(),
                           jumpContextProvider: StaticJumpContextProvider(JumpContext()),
                           deadlineScheduler: .manual)
    return (feed, store)
}

/// F1: the feed reports online before its first publish, so a reconnect that finds no agent panes clears
/// the kept (dimmed) rows instead of reviving them. Before the fix the empty publish landed while the store
/// still saw offline and was dropped, and the old rows came back undimmed.
@MainActor
func testHerdrFeedReconnectWithNoAgentsClearsKeptRows() throws {
    let server = try FakeHerdrServer()
    server.setState(fakeState([fakePane("w1:p1")]))
    let (feed, store) = storeOverFeed(server)
    store.start()
    defer { store.stop(); feed.stop(); server.stop() }
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online && store.rows.count == 1 }

    server.stop()
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr]?.dimsRows == true }
    try expect(store.rows.map(\.id.key), equals: ["w1:p1"], "rows are kept (dimmed) while offline")

    server.setState(fakeState([fakePane("w1:p2", status: "idle", agent: nil)]))
    try server.restart()
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online }
    settle(0.2)
    try expect(store.rows.map(\.id.key), equals: [], "a reconnect with only a shell pane leaves no Herdr rows")
}

/// F1, disabled variant: protocol 23 disables the feed (rows kept); protocol 22 with only a shell pane
/// re-enables it and the kept rows go away.
@MainActor
func testHerdrFeedReenableWithNoAgentsClearsKeptRows() throws {
    let server = try FakeHerdrServer()
    server.setState(fakeState([fakePane("w1:p1")]))
    let (feed, store) = storeOverFeed(server)
    store.start()
    defer { store.stop(); feed.stop(); server.stop() }
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online && store.rows.count == 1 }

    try server.restart(protocolVersion: 23)
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .disabled(reason: "protocol 23") }
    try expect(store.rows.map(\.id.key), equals: ["w1:p1"], "rows are kept (dimmed) while disabled")

    server.setState(fakeState([fakePane("w1:p2", status: "idle", agent: nil)]))
    try server.restart(protocolVersion: 22)
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online }
    settle(0.2)
    try expect(store.rows.map(\.id.key), equals: [], "re-enabling with only a shell pane leaves no Herdr rows")
}

/// F1, buffered variant: a G event that arrives during the reconnect bootstrap is replayed after snapshot #2
/// and publishes too, so online must be reported before that replay, not only before the final publish.
@MainActor
func testHerdrFeedReconnectWithBufferedEventClearsKeptRows() throws {
    let server = try FakeHerdrServer()
    server.setState(fakeState([fakePane("w1:p1")]))
    let (feed, store) = storeOverFeed(server)
    store.start()
    defer { store.stop(); feed.stop(); server.stop() }
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr] == .online && store.rows.count == 1 }

    server.stop()
    try spinMainRunLoop(timeout: 3) { store.feedHealth[.herdr]?.dimsRows == true && server.globalSubscriberCount == 0 }
    server.setState(fakeState([fakePane("w1:p2", status: "idle", agent: nil)]))
    let emitted = EmitFlag()
    DispatchQueue.global().async {
        let deadline = DispatchTime.now() + 3
        while server.globalSubscriberCount == 0 && DispatchTime.now() < deadline { usleep(50) }
        server.emitGlobal(paneFocusedEvent("w1:p2"))   // lands in the bootstrap buffer
        emitted.set()
    }
    try server.restart()
    try spinMainRunLoop(timeout: 3) { emitted.isSet && store.feedHealth[.herdr] == .online }
    try spinMainRunLoop(timeout: 2) { feed.focusedPaneID == "w1:p2" }
    settle(0.2)
    try expect(store.rows.map(\.id.key), equals: [], "a buffered event's publish does not precede online")
}

let herdrFeedTests: [TestCase] = [
    ("herdrFeed: host name is the short gethostname", testHerdrFeedHostNameIsShortHostname),
    ("herdrFeed: bootstrap request order is ping, G, snapshot, pane streams, snapshot", testHerdrFeedBootstrapRequestOrder),
    ("herdrFeed: G events during bootstrap apply after snapshot #2", testHerdrFeedAppliesBufferedGlobalEventsAfterSnapshotTwo),
    ("herdrFeed: health goes offline(socket missing) then online", testHerdrFeedHealthGoesFromSocketMissingToOnline),
    ("herdrFeed: pane_created opens one stream and pane_closed releases it", testHerdrFeedOpensAndClosesPaneStreams),
    ("herdrFeed: pane_not_found drops only that pane's stream", testHerdrFeedPaneNotFoundDropsOnlyThatStream),
    ("herdrFeed: 100 reconnect cycles keep fds within panes + 2", testHerdrFeedReconnectCyclesDoNotLeakDescriptors),
    ("herdrFeed: reconcile repairs a silent stream and reopens it", testHerdrFeedReconcileRepairsSilentStream),
    ("herdrFeed: reconcile repairs a dropped event", testHerdrFeedReconcileRepairsDroppedEvent),
    ("herdrFeed: workspace rename triggers a reconcile that relabels rows", testHerdrFeedWorkspaceRenameTriggersReconcile),
    ("herdrFeed: exit grace and user close run through tick", testHerdrFeedExitGraceRunsThroughTick),
    ("herdrFeed: ping failure closes streams and backs off on schedule", testHerdrFeedPingFailureClosesStreamsAndBacksOff),
    ("herdrFeed: protocol change disables, probes and re-enables with a quiet period", testHerdrFeedProtocolChangeDisablesProbesAndReenables),
    ("herdrFeed: unsupported method disables with no fds and recovers", testHerdrFeedUnsupportedMethodDisablesAndRecovers),
    ("herdrFeed: server version below 0.9.1 degrades jumps", testHerdrFeedServerVersionGatesJumps),
    ("herdrFeed: old server is degraded until a restart reports 0.9.1", testHerdrFeedOldServerIsDegradedUntilUpgraded),
    ("herdrFeed: blocked episode reads detection once and refreshes focus", testHerdrFeedBlockedEpisodeReadsDetectionOnceAndRefreshesFocus),
    ("herdrFeed: process_info on bootstrap, agent detection and pane update", testHerdrFeedRequestsProcessInfoOnBootstrapDetectionAndUpdate),
    ("herdrFeed: jump sends no request and clears the overlay", testHerdrFeedJumpSendsNoRequestAndClearsOverlay),
    ("herdrFeed: loadDetail reads a recap once and keeps done unseen", testHerdrFeedLoadDetailReadsRecapOnceAndKeepsDoneUnseen),
    ("herdrFeed: casts to HerdrFocusReporting; standard configuration", testHerdrFeedCastsToHerdrFocusReporting),
    ("herdrFeed: hardening 1 server restart with a new socket inode", testHerdrFeedRecoversFromServerRestartWithNewInode),
    ("herdrFeed: hardening 2 45-pane churn stays within the stream cap", testHerdrFeedSurvivesFortyFivePaneChurnWithinStreamCap),
    ("herdrFeed: replay sub2 matches its golden; the flicker episode peeks and chimes once", testHerdrFeedReplaySub2MatchesGolden),
    ("herdrFeed: replay poll matches its golden timeline", testHerdrFeedReplayPollMatchesGolden),
    ("herdrFeed: a snapshot requested before a stream status does not revert it", testHerdrFeedSnapshotDoesNotRevertNewerStreamStatus),
    ("herdrFeed: pending exits from a lost connection never become errors", testHerdrFeedLostConnectionDropsPendingExits),
    ("herdrFeed: the initial Ghostty frontmost state reaches the reducer", testHerdrFeedAppliesInitialGhosttyFrontmost),
    ("herdrFeed: restart reports health and rows to the latest observers only", testHerdrFeedRestartReportsToLatestObservers),
    ("herdrFeed: repeated hovers read a done row once per episode", testHerdrFeedRepeatedHoversReadOncePerDoneEpisode),
    ("herdrFeed: delayed question cannot cross blocked episodes", testHerdrFeedDelayedQuestionDoesNotCrossBlockedEpisodes),
    ("herdrFeed: delayed recap cannot cross done episodes", testHerdrFeedDelayedRecapDoesNotCrossDoneEpisodes),
    ("herdrFeed: delayed empty recap cannot cache the next episode", testHerdrFeedDelayedEmptyRecapDoesNotCacheNextEpisode),
    ("herdrFeed: delayed recap cannot reach a recreated pane", testHerdrFeedDelayedRecapDoesNotReachRecreatedPane),
    ("herdrFeed: queued detection skips an ended episode and releases its slot", testHerdrFeedQueuedDetectionSkipsAnEndedEpisode),
    ("herdrFeed: restart cancels detection and releases its request slot", testHerdrFeedRestartCancelsDetectionAndReleasesItsSlot),
    ("herdrFeed: no publish while offline; the next online publish catches up", testHerdrFeedDoesNotPublishWhileOffline),
    ("herdrFeed: a reconnect with no agent panes clears the kept rows", testHerdrFeedReconnectWithNoAgentsClearsKeptRows),
    ("herdrFeed: re-enabling with no agent panes clears the kept rows", testHerdrFeedReenableWithNoAgentsClearsKeptRows),
    ("herdrFeed: a reconnect with a buffered event and no agent panes clears the kept rows", testHerdrFeedReconnectWithBufferedEventClearsKeptRows),
]

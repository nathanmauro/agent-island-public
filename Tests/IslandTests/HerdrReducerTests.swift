// Tests/IslandTests/HerdrReducerTests.swift
import Foundation
import IslandCore
import IslandTestSupport

// MARK: - Wire-JSON builders (inputs always go through HerdrCodec, never the model initializers)

private let reducerStart = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    reducerStart.addingTimeInterval(seconds)
}

private struct TestPane {
    var id: String
    var workspace = "w1"
    var tab = "w1:t1"
    var agent: String? = "claude"
    var status = "working"
    var seq: UInt64 = 1
    var title: String? = "fixture title"
    var cwd: String? = "/tmp/fixture-project"
    var focused = false
}

private func jsonValue(_ value: String?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func paneJSON(_ pane: TestPane) -> [String: Any] {
    [
        "pane_id": pane.id,
        "terminal_id": "term-\(pane.id)",
        "workspace_id": pane.workspace,
        "tab_id": pane.tab,
        "focused": pane.focused,
        "agent_status": pane.status,
        "revision": 1,
        "agent": jsonValue(pane.agent),
        "terminal_title_stripped": jsonValue(pane.title),
        "cwd": jsonValue(pane.cwd),
        "label": NSNull(),
    ]
}

private func agentJSON(_ pane: TestPane) -> [String: Any] {
    var object = paneJSON(pane)
    object["display_agent"] = NSNull()
    object["name"] = NSNull()
    object["state_change_seq"] = NSNumber(value: pane.seq)
    return object
}

private func snapshot(
    _ panes: [TestPane],
    workspaces: [(id: String, label: String)] = [(id: "w1", label: "api")],
    tabs: [(id: String, workspace: String, label: String)] = [(id: "w1:t1", workspace: "w1", label: "main")],
    focused: String? = nil
) throws -> HerdrSnapshot {
    let workspaceObjects: [[String: Any]] = workspaces.enumerated().map { index, workspace in
        [
            "workspace_id": workspace.id, "number": index + 1, "label": workspace.label, "focused": false,
            "pane_count": 1, "tab_count": 1, "active_tab_id": "\(workspace.id):t1", "agent_status": "idle",
        ]
    }
    let tabObjects: [[String: Any]] = tabs.map { tab in
        [
            "tab_id": tab.id, "workspace_id": tab.workspace, "number": 1, "label": tab.label,
            "focused": false, "pane_count": 1, "agent_status": "idle",
        ]
    }
    let snapshotObject: [String: Any] = [
        "version": "0.9.1-fake",
        "protocol": 22,
        "focused_workspace_id": NSNull(),
        "focused_tab_id": NSNull(),
        "focused_pane_id": jsonValue(focused),
        "workspaces": workspaceObjects,
        "tabs": tabObjects,
        "panes": panes.map(paneJSON),
        "layouts": [Any](),
        "agents": panes.filter { $0.agent != nil }.map(agentJSON),
    ]
    let object: [String: Any] = [
        "id": "reducer-test",
        "result": ["type": "session_snapshot", "snapshot": snapshotObject] as [String: Any],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .success(_, .snapshot(let decoded))? = HerdrCodec.decodeResponse(data) else {
        throw TestFailure.expectation("test snapshot JSON did not decode through HerdrCodec")
    }
    return decoded
}

private func streamEvent(_ object: [String: Any]) throws -> HerdrEvent {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .event(let event)? = HerdrCodec.decodeStreamLine(data) else {
        throw TestFailure.expectation("test event JSON did not decode through HerdrCodec")
    }
    return event
}

private func statusEvent(_ paneID: String, _ status: String) throws -> HerdrEvent {
    try streamEvent([
        "event": "pane.agent_status_changed",
        "data": ["pane_id": paneID, "workspace_id": "w1", "agent_status": status, "agent": "claude"] as [String: Any],
    ])
}

private func paneEvent(_ type: String, _ pane: TestPane) throws -> HerdrEvent {
    try streamEvent(["event": type, "data": ["type": type, "pane": paneJSON(pane)] as [String: Any]])
}

private func movedEvent(from previousPaneID: String, to pane: TestPane) throws -> HerdrEvent {
    try streamEvent([
        "event": "pane_moved",
        "data": [
            "type": "pane_moved",
            "previous_pane_id": previousPaneID,
            "previous_workspace_id": "w1",
            "previous_tab_id": "w1:t1",
            "pane": paneJSON(pane),
        ] as [String: Any],
    ])
}

private func processInfo(_ paneID: String, _ pids: [Int32]) throws -> HerdrProcessInfo {
    let info: [String: Any] = [
        "pane_id": paneID,
        "shell_pid": 100,
        "tty": NSNull(),
        "foreground_process_group_id": pids.first.map { NSNumber(value: $0) as Any } ?? NSNull(),
        "foreground_processes": pids.map { ["pid": NSNumber(value: $0), "name": "claude"] as [String: Any] },
    ]
    let object: [String: Any] = [
        "id": "reducer-test",
        "result": ["type": "pane_process_info", "process_info": info] as [String: Any],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    guard case .success(_, .processInfo(let decoded))? = HerdrCodec.decodeResponse(data) else {
        throw TestFailure.expectation("test process_info JSON did not decode through HerdrCodec")
    }
    return decoded
}

private func makeReducer() -> HerdrReducer {
    HerdrReducer(configuration: HerdrReducer.Configuration(hostname: "testhost"))
}

private func row(_ reducer: HerdrReducer, _ paneID: String) throws -> AgentRow {
    guard let row = reducer.rows.first(where: { $0.id == RowID(source: .herdr, key: paneID) }) else {
        throw TestFailure.expectation("no row for \(paneID)")
    }
    return row
}

// MARK: - Status mapping

func testHerdrReducerMapsSnapshotStatuses() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([
        TestPane(id: "w1:p1", status: "working"),
        TestPane(id: "w1:p2", status: "blocked"),
        TestPane(id: "w1:p3", status: "done"),
        TestPane(id: "w1:p4", status: "idle"),
        TestPane(id: "w1:p5", status: "unknown"),
        TestPane(id: "w1:p6", agent: nil, status: "unknown"),
    ])), now: at(0))
    try expect(row(reducer, "w1:p1").state, equals: .working, "working maps to working")
    try expect(row(reducer, "w1:p2").state, equals: .waiting, "blocked maps to waiting")
    try expect(row(reducer, "w1:p3").state, equals: .doneUnseen, "done maps to doneUnseen")
    try expect(row(reducer, "w1:p4").state, equals: .idle, "idle maps to idle")
    try expect(row(reducer, "w1:p5").state, equals: .starting, "unknown maps to starting")
    try expect(reducer.rows.count, equals: 5, "rows exist only for agent panes")
    try expect(reducer.knownPaneIDs, equals: Set(["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"]),
               "the shell pane is tracked as a known pane")
    try expect(Summary(rows: reducer.rows).text, equals: "1 waiting · 1 working · 1 done",
               "starting and idle are never counted")
}

func testHerdrReducerMapsStatusEvents() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", status: "idle")])), now: at(0))
    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(1))
    try expect(row(reducer, "w1:p1").state, equals: .working, "event working")
    reducer.apply(.event(try statusEvent("w1:p1", "blocked")), now: at(2))
    try expect(row(reducer, "w1:p1").state, equals: .waiting, "event blocked")
    reducer.apply(.event(try statusEvent("w1:p1", "done")), now: at(3))
    try expect(row(reducer, "w1:p1").state, equals: .doneUnseen, "event done")
    reducer.apply(.event(try statusEvent("w1:p1", "unknown")), now: at(4))
    try expect(row(reducer, "w1:p1").state, equals: .starting, "event unknown")
    try expect(row(reducer, "w1:p1").sourceStatus, equals: "unknown", "sourceStatus carries the raw Herdr status")
}

func testHerdrReducerDoneThenViewedGoesIdleWithoutOverlay() throws {
    var reducer = makeReducer()
    reducer.apply(.ghosttyFrontmost(false), now: at(0))
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", status: "working")])), now: at(0))
    reducer.apply(.event(try statusEvent("w1:p1", "done")), now: at(5))
    try expect(row(reducer, "w1:p1").state, equals: .doneUnseen, "Herdr done is unseen")
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(9))
    try expect(row(reducer, "w1:p1").state, equals: .idle, "done then idle (viewed) is idle, no overlay")
}

// MARK: - Stale and since

func testHerdrReducerAgesUnchangedWorkingToStale() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", seq: 10), TestPane(id: "w1:p2", seq: 20)])), now: at(0))
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", seq: 10), TestPane(id: "w1:p2", seq: 21)])), now: at(1_000))
    reducer.apply(.tick, now: at(1_799))
    try expect(row(reducer, "w1:p1").state, equals: .working, "not stale before 30 min")
    reducer.apply(.tick, now: at(1_800.001))
    try expect(row(reducer, "w1:p1").state, equals: .stale, "unchanged status and seq for 1800 s + ε is stale")
    try expect(row(reducer, "w1:p1").since, equals: at(0), "a stale row keeps the time it started working")
    try expect(row(reducer, "w1:p2").state, equals: .working, "a seq change reset p2's stale clock")
    reducer.apply(.tick, now: at(2_800.001))
    try expect(row(reducer, "w1:p2").state, equals: .stale, "p2 goes stale 1800 s after its seq change")
    try expect(Summary(rows: reducer.rows).text, equals: "2 stale", "stale activity is reported separately")
}

func testHerdrReducerSinceIsIslandObservedChangeTime() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    try expect(row(reducer, "w1:p1").since, equals: at(0), "first observation")
    reducer.apply(.event(try statusEvent("w1:p1", "blocked")), now: at(5))
    try expect(row(reducer, "w1:p1").since, equals: at(5), "state change time")
    reducer.apply(.detection(paneID: "w1:p1", text: "", purpose: .blocked), now: at(7))
    try expect(row(reducer, "w1:p1").since, equals: at(5), "a detail change is not a state change")
    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(9))
    try expect(row(reducer, "w1:p1").since, equals: at(9), "next state change")
}

// MARK: - Error rule

func testHerdrReducerExitWhileWorkingBecomesErrorAfterGrace() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2", status: "blocked")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(10))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(10))
    try expect(reducer.nextDeadline(after: at(10)), equals: at(11), "the exit grace deadline is 1 s out")
    reducer.apply(.tick, now: at(10.5))
    try expect(row(reducer, "w1:p1").state, equals: .working, "no error inside the grace period")
    reducer.apply(.tick, now: at(11.1))
    let errored = try row(reducer, "w1:p1")
    try expect(errored.state, equals: .error, "exit while working is an error after 1 s")
    try expect(errored.detail?.kind, equals: .error, "the error row carries an error detail")
    try expect(row(reducer, "w1:p2").state, equals: .error, "exit while blocked is an error too")
    try expect(Summary(rows: reducer.rows).text, equals: "2 error", "errors are counted")
}

func testHerdrReducerCloseWithinGraceIsNotAnError() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(10))
    reducer.apply(.event(.paneClosed(paneID: "w1:p1", workspaceID: "w1")), now: at(10.4))
    reducer.apply(.tick, now: at(12))
    try expect(reducer.rows.count, equals: 0, "pane_closed within 1 s removes the row with no error")
    try expectTrue(!reducer.knownPaneIDs.contains("w1:p1"), "the closed pane is no longer known")
    try expect(reducer.nextDeadline(after: at(12)), equals: nil, "nothing left to schedule")
}

func testHerdrReducerFocusedPaneWithGhosttyFrontmostIsUserClose() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")], focused: "w1:p1")), now: at(0))
    reducer.apply(.ghosttyFrontmost(true), now: at(1))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(10))
    reducer.apply(.event(.paneFocused(paneID: "w1:p2", workspaceID: "w1")), now: at(11))
    reducer.apply(.event(.agentDetected(paneID: "w1:p2", agent: nil, released: true, finalStatus: nil)), now: at(11))
    reducer.apply(.tick, now: at(20))
    try expect(reducer.rows.filter { $0.state == .error }.count, equals: 0,
               "exit or release of the focused pane while Ghostty is frontmost is never an error")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p2" }, "the released pane no longer has an agent row")
}

func testHerdrReducerReleaseWhileWorkingIsError() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2", status: "idle")])), now: at(0))
    reducer.apply(.event(.agentDetected(paneID: "w1:p1", agent: nil, released: true, finalStatus: .working)), now: at(5))
    reducer.apply(.event(.agentDetected(paneID: "w1:p2", agent: nil, released: true, finalStatus: .idle)), now: at(5))
    reducer.apply(.tick, now: at(6.1))
    try expect(row(reducer, "w1:p1").state, equals: .error, "release while working is an error after the grace period")
    try expect(row(reducer, "w1:p1").detail?.kind, equals: .error, "error detail")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p2" }, "release while idle just removes the agent row")
}

func testHerdrReducerErrorTombstonePersistsUntilClickOrRetention() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(1))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(1))
    reducer.apply(.tick, now: at(3))
    reducer.apply(.event(.paneClosed(paneID: "w1:p1", workspaceID: "w1")), now: at(4))
    try expect(row(reducer, "w1:p1").state, equals: .error, "the error row survives pane_closed as a tombstone")
    reducer.apply(.rowClicked(paneID: "w1:p1", acknowledgmentID: try row(reducer, "w1:p1").acknowledgmentID), now: at(5))
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p1" }, "a click clears the tombstone")
    reducer.apply(.snapshot(try snapshot([])), now: at(6))
    try expect(row(reducer, "w1:p2").state, equals: .error, "a snapshot without the pane keeps the tombstone")
    let retentionEnd = at(3).addingTimeInterval(IslandTiming.seenExpiry)
    try expect(reducer.nextDeadline(after: at(6)), equals: retentionEnd, "the retention deadline is 12 h after the error")
    reducer.apply(.tick, now: retentionEnd)
    try expect(reducer.rows.count, equals: 0, "the tombstone expires after 12 h")
}

// MARK: - Overlay

func testHerdrReducerOldClickCannotClearNewOverlay() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(1))
    let old = try row(reducer, "w1:p1")
    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(1))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(1))
    reducer.apply(.rowClicked(paneID: old.id.key, acknowledgmentID: old.acknowledgmentID), now: at(1))
    try expect(row(reducer, "w1:p1").state, equals: .doneUnseen, "old click leaves newer overlay unseen")
}

func testHerdrReducerOldClickPreservesErrorCreatedAtDeadline() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(1))
    let old = try row(reducer, "w1:p1")
    reducer.apply(.event(.agentDetected(paneID: "w1:p1", agent: nil, released: true, finalStatus: .working)), now: at(2))
    reducer.apply(.rowClicked(paneID: old.id.key, acknowledgmentID: old.acknowledgmentID), now: at(4))
    let error = try row(reducer, "w1:p1")
    try expect(error.state, equals: .error, "the newly matured error remains unread")
    try expectTrue(error.acknowledgmentID != old.acknowledgmentID, "new error has its own identity")
    reducer.apply(.rowClicked(paneID: error.id.key, acknowledgmentID: error.acknowledgmentID), now: at(4))
    try expect(reducer.rows.count, equals: 0, "the current error can be acknowledged")
}

func testHerdrReducerAcknowledgmentSurvivesMetadataButNotResetOrReuse() throws {
    var reducer = makeReducer()
    func finish(_ reducer: inout HerdrReducer) throws -> AgentRow {
        reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
        reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(1))
        return try row(reducer, "w1:p1")
    }
    let original = try finish(&reducer)
    reducer.apply(.detection(paneID: "w1:p1", text: "⏺ Done.\n\n※ recap: Fixture recap.\n", purpose: .recap), now: at(1))
    try expect(try row(reducer, "w1:p1").acknowledgmentID, equals: original.acknowledgmentID,
               "detail loading preserves the identity")
    for reset in [HerdrInput.reset, .event(.paneClosed(paneID: "w1:p1", workspaceID: "w1"))] {
        reducer.apply(reset, now: at(1))
        let replacement = try finish(&reducer)
        try expectTrue(replacement.acknowledgmentID != original.acknowledgmentID, "reset and reuse cannot recycle tokens")
        reducer.apply(.rowClicked(paneID: original.id.key, acknowledgmentID: original.acknowledgmentID), now: at(1))
        try expect(try row(reducer, "w1:p1").state, equals: .doneUnseen, "replacement stays unread")
    }
}

func testHerdrReducerFinishedWhileAwayOverlay() throws {
    var reducer = makeReducer()
    reducer.apply(.ghosttyFrontmost(false), now: at(0))
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")], focused: "w1:p1")), now: at(0))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(10))
    try expect(row(reducer, "w1:p1").state, equals: .doneUnseen, "working → idle while away is done")
    reducer.apply(.rowClicked(paneID: "w1:p1", acknowledgmentID: try row(reducer, "w1:p1").acknowledgmentID), now: at(11))
    try expect(row(reducer, "w1:p1").state, equals: .idle, "a row click clears the overlay")

    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(12))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(13))
    try expect(row(reducer, "w1:p1").state, equals: .doneUnseen, "overlay set again")
    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(14))
    try expect(row(reducer, "w1:p1").state, equals: .working, "the next working clears the overlay")

    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(15))
    reducer.apply(.event(try statusEvent("w1:p2", "idle")), now: at(16))
    try expect(row(reducer, "w1:p2").state, equals: .doneUnseen, "p2 also finished while away")
    reducer.apply(.ghosttyFrontmost(true), now: at(17))
    try expect(row(reducer, "w1:p1").state, equals: .idle, "Ghostty frontmost with the pane focused clears it")
    try expect(row(reducer, "w1:p2").state, equals: .doneUnseen, "an unfocused pane keeps its overlay")

    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(18))
    reducer.apply(.event(try statusEvent("w1:p1", "idle")), now: at(19))
    try expect(row(reducer, "w1:p1").state, equals: .idle, "finishing while Ghostty is frontmost is plain idle")
}

// MARK: - Reconcile (#3124)

func testHerdrReducerReconcileRepairsSilentStream() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(0))
    try expect(reducer.takeReopenRequests(), equals: Set<String>(), "the first snapshot requests nothing")
    reducer.apply(.event(try statusEvent("w1:p2", "blocked")), now: at(1))
    let stale = try snapshot([TestPane(id: "w1:p1", status: "blocked"), TestPane(id: "w1:p2", status: "blocked")])
    reducer.apply(.snapshot(stale), now: at(12))
    try expect(row(reducer, "w1:p1").state, equals: .waiting, "the snapshot status wins")
    try expect(reducer.takeReopenRequests(), equals: Set(["w1:p1"]), "only the silent pane is reopened")
    try expect(reducer.takeReopenRequests(), equals: Set<String>(), "requests are handed out once")
    reducer.apply(.snapshot(stale), now: at(24))
    try expect(reducer.takeReopenRequests(), equals: Set<String>(), "an agreeing snapshot requests nothing")
}

func testHerdrReducerLabelsComeFromSnapshotsOnly() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    try expect(row(reducer, "w1:p1").subtitle, equals: "api › main", "subtitle is workspace › tab")
    try expect(row(reducer, "w1:p1").jump, equals: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "testhost: api"),
               "jump prefix is <host>: <workspace>")
    let before = reducer.rows
    reducer.apply(.event(.layoutChanged(name: "workspace_renamed")), now: at(1))
    try expect(reducer.rows, equals: before, "a layout event alone changes no row")
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")], workspaces: [(id: "w1", label: "api-v2")])), now: at(2))
    try expect(row(reducer, "w1:p1").subtitle, equals: "api-v2 › main", "a renamed workspace updates the subtitle")
    try expect(row(reducer, "w1:p1").jump, equals: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "testhost: api-v2"),
               "and the jump prefix")
}

// MARK: - Detection

func testHerdrReducerDetectionSetsQuestionFallbackAndRecap() throws {
    let blockedText = try Fixtures.string("herdr/detection-blocked-1.txt")
    let garbageText = try Fixtures.string("herdr/detection-garbage.txt")
    let doneText = try Fixtures.string("herdr/detection-done-1.txt")
    guard let prompt = DetectionTextParser.parseBlocked(blockedText) else {
        throw TestFailure.expectation("the masked blocked fixture parses")
    }
    guard let recap = DetectionTextParser.parseRecap(doneText) else {
        throw TestFailure.expectation("the masked done fixture parses")
    }
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([
        TestPane(id: "w1:p1", status: "blocked"),
        TestPane(id: "w1:p2", status: "blocked"),
        TestPane(id: "w1:p3", status: "done"),
        TestPane(id: "w1:p4", status: "working"),
    ])), now: at(0))
    reducer.apply(.detection(paneID: "w1:p1", text: blockedText, purpose: .blocked), now: at(1))
    try expect(row(reducer, "w1:p1").detail, equals: Detail(question: prompt.question, options: prompt.options, kind: .question),
               "blocked detection sets question and options")
    reducer.apply(.detection(paneID: "w1:p2", text: garbageText, purpose: .blocked), now: at(1))
    try expect(row(reducer, "w1:p2").detail, equals: Detail(question: "fixture title needs you", options: [], kind: .question),
               "unparseable text falls back to '<title> needs you'")
    reducer.apply(.detection(paneID: "w1:p3", text: doneText, purpose: .recap), now: at(1))
    try expect(row(reducer, "w1:p3").detail, equals: Detail(question: recap, options: [], kind: .recap),
               "recap detection sets a recap detail")
    reducer.apply(.detection(paneID: "w1:p4", text: blockedText, purpose: .blocked), now: at(1))
    try expect(row(reducer, "w1:p4").detail, equals: nil, "a pane that is not blocked ignores blocked detection")
    reducer.apply(.event(try statusEvent("w1:p1", "working")), now: at(2))
    try expect(row(reducer, "w1:p1").detail, equals: nil, "leaving blocked clears the question")
}

// MARK: - Titles, process info, lifecycle

func testHerdrReducerBuildsTitleSubtitleJumpAndProcessIDs() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([
        TestPane(id: "w1:p1", title: "✳ fixture   title…"),
        TestPane(id: "w1:p2", title: nil),
    ])), now: at(0))
    let first = try row(reducer, "w1:p1")
    try expect(first.title, equals: "fixture title", "terminal_title_stripped cleaned by SessionTitleFormatter")
    try expect(first.subtitle, equals: "api › main", "subtitle")
    try expect(first.jump, equals: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "testhost: api"), "jump target")
    try expect(first.cwd, equals: "/tmp/fixture-project", "cwd from the agent")
    try expect(first.source, equals: .herdr, "source")
    try expect(row(reducer, "w1:p2").title, equals: "claude", "no title falls back to the agent name")
    reducer.apply(.processInfo(try processInfo("w1:p1", [4242, 4243])), now: at(1))
    try expect(row(reducer, "w1:p1").processIDs, equals: [4242, 4243], "processInfo fills processIDs")
}

func testHerdrReducerTracksCreateMoveFocusAndShells() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2", agent: nil, status: "unknown")])), now: at(0))
    try expect(reducer.rows.map(\.id.key), equals: ["w1:p1"], "only the agent pane has a row")
    reducer.apply(.event(try paneEvent("pane_created", TestPane(id: "w1:p3", status: "idle"))), now: at(1))
    try expect(row(reducer, "w1:p3").state, equals: .idle, "pane_created with an agent adds a row")
    reducer.apply(.event(try paneEvent("pane_created", TestPane(id: "w1:p4", agent: nil, status: "unknown"))), now: at(1))
    try expectTrue(reducer.knownPaneIDs.contains("w1:p4"), "a new shell pane is known")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p4" }, "a shell has no row")
    reducer.apply(.event(.agentDetected(paneID: "w1:p4", agent: "claude", released: false, finalStatus: nil)), now: at(2))
    try expectTrue(reducer.rows.contains { $0.id.key == "w1:p4" }, "agent detection turns the shell into an agent row")
    reducer.apply(.event(.paneFocused(paneID: "w1:p3", workspaceID: "w1")), now: at(3))
    try expect(reducer.focusedPaneID, equals: "w1:p3", "pane_focused updates focusedPaneID")
    reducer.apply(.event(try movedEvent(from: "w1:p3", to: TestPane(id: "w2:p1", workspace: "w2", tab: "w2:t1", status: "idle"))), now: at(4))
    try expectTrue(reducer.rows.contains { $0.id.key == "w2:p1" }, "the moved pane has a row under its new id")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p3" }, "the old id is gone")
    try expect(reducer.focusedPaneID, equals: "w2:p1", "focus follows the move")
    try expectTrue(reducer.knownPaneIDs.contains("w2:p1") && !reducer.knownPaneIDs.contains("w1:p3"), "known ids follow the move")
}

func testHerdrReducerResetClearsEverything() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")], focused: "w1:p1")), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(1))
    reducer.apply(.event(try statusEvent("w1:p1", "blocked")), now: at(2))
    reducer.apply(.reset, now: at(3))
    try expect(reducer.rows.count, equals: 0, "no rows")
    try expect(reducer.knownPaneIDs, equals: Set<String>(), "no known panes")
    try expect(reducer.focusedPaneID, equals: nil, "no focus")
    try expect(reducer.nextDeadline(after: at(3)), equals: nil, "no deadlines")
    try expect(reducer.takeReopenRequests(), equals: Set<String>(), "no reopen requests")
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", status: "idle")])), now: at(4))
    try expect(row(reducer, "w1:p1").state, equals: .idle, "no memory of the earlier working status survives reset")
}

func testHerdrReducerNextDeadlineIsEarliest() throws {
    try expect(makeReducer().nextDeadline(after: at(0)), equals: nil, "an empty reducer has no deadline")
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    try expect(reducer.nextDeadline(after: at(0)), equals: at(1_800), "stale deadline")
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(100))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(100))
    try expect(reducer.nextDeadline(after: at(100)), equals: at(101), "exit grace is earliest")
    reducer.apply(.tick, now: at(101))
    try expect(reducer.nextDeadline(after: at(101)), equals: at(1_800), "stale before retention")
    reducer.apply(.tick, now: at(1_800))
    try expect(row(reducer, "w1:p1").state, equals: .stale, "stale at exactly the deadline")
    try expect(reducer.nextDeadline(after: at(1_800)), equals: at(101).addingTimeInterval(IslandTiming.seenExpiry),
               "retention is the only deadline left")
}

// MARK: - Hardening case 5: sleep/wake wall-clock jump

func testHerdrReducerWallClockJumpAgesAndExpiresWithoutNewAlerts() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(1))
    reducer.apply(.tick, now: at(3))
    try expect(row(reducer, "w1:p2").state, equals: .error, "a tombstone exists before the jump")

    // 7.5 h later: fresh activity; the closed pane is gone from the snapshot.
    let later: TimeInterval = 27_000
    reducer.apply(.snapshot(try snapshot([
        TestPane(id: "w1:p1", seq: 2),
        TestPane(id: "w1:p3", status: "blocked"),
        TestPane(id: "w1:p4", status: "idle"),
    ])), now: at(later))
    try expect(row(reducer, "w1:p1").state, equals: .working, "the seq change reset p1's stale clock")
    try expect(row(reducer, "w1:p2").state, equals: .error, "the tombstone is still inside 12 h")
    let waitingBefore = Set(reducer.rows.filter { $0.state == .waiting }.map(\.id))

    // The Mac sleeps; the wall clock jumps 5 h at once and the feed ticks on wake.
    reducer.apply(.tick, now: at(later + 18_000))
    try expect(row(reducer, "w1:p1").state, equals: .stale, "working ages to stale across the jump")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p2" }, "the tombstone expired (12 h since the error)")
    try expect(reducer.rows.filter { $0.state == .error }.count, equals: 0, "no new error rows appear")
    try expect(Set(reducer.rows.filter { $0.state == .waiting }.map(\.id)), equals: waitingBefore,
               "no new waiting rows appear")
}

// MARK: - Fix round 1: new agents clear tombstones; release uses final_status

/// Review probe A1: the reconcile snapshot sees a new agent in a tombstoned pane before
/// pane_agent_detected arrives (or instead of it, when the stream is silent, #3124).
func testHerdrReducerSnapshotNewAgentClearsTombstone() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    reducer.apply(.event(.agentDetected(paneID: "w1:p1", agent: nil, released: true, finalStatus: .working)), now: at(1))
    reducer.apply(.tick, now: at(3))
    try expect(row(reducer, "w1:p1").state, equals: .error, "release while working left a tombstone")

    let fresh = try snapshot([TestPane(id: "w1:p1", status: "blocked", seq: 2)])
    var states: [DisplayState] = []
    reducer.apply(.snapshot(fresh), now: at(12))
    states.append(try row(reducer, "w1:p1").state)
    reducer.apply(.event(.agentDetected(paneID: "w1:p1", agent: "claude", released: false, finalStatus: nil)), now: at(13))
    states.append(try row(reducer, "w1:p1").state)
    reducer.apply(.snapshot(fresh), now: at(24))
    states.append(try row(reducer, "w1:p1").state)
    try expect(states, equals: [.waiting, .waiting, .waiting], "the live agent replaces the tombstone")
    try expect(reducer.rows.filter { $0.id.key == "w1:p1" }.count, equals: 1, "one row per pane")
}

/// Review probe A3: a pane id comes back after pane_closed (for example after a Herdr restart)
/// with a new agent in it, seen by a snapshot (p1) or by pane_created plus agent_detected (p2).
func testHerdrReducerReusedPaneIDWithNewAgentClearsTombstone() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(1))
    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(1))
    reducer.apply(.tick, now: at(3))
    reducer.apply(.event(.paneClosed(paneID: "w1:p1", workspaceID: "w1")), now: at(4))
    reducer.apply(.event(.paneClosed(paneID: "w1:p2", workspaceID: "w1")), now: at(4))
    try expect(row(reducer, "w1:p1").state, equals: .error, "p1's tombstone outlives pane_closed")
    try expect(row(reducer, "w1:p2").state, equals: .error, "p2's tombstone outlives pane_closed")

    reducer.apply(.event(try paneEvent("pane_created", TestPane(id: "w1:p2", status: "idle"))), now: at(10))
    reducer.apply(.event(.agentDetected(paneID: "w1:p2", agent: "claude", released: false, finalStatus: nil)), now: at(10))
    try expect(row(reducer, "w1:p2").state, equals: .idle, "agent_detected on the reused id clears the tombstone")

    reducer.apply(.snapshot(try snapshot([
        TestPane(id: "w1:p1", status: "blocked"),
        TestPane(id: "w1:p2", status: "idle"),
    ])), now: at(12))
    try expect(row(reducer, "w1:p1").state, equals: .waiting,
               "a snapshot listing a new agent under the reused id clears the tombstone")
    try expect(reducer.rows.map(\.id.key).sorted(), equals: ["w1:p1", "w1:p2"], "one row per pane")
    try expect(reducer.rows.filter { $0.state == .error }.count, equals: 0, "no error rows remain")
}

/// Controller finding 2: the per-pane stream lost "→ idle" (#3124), so the tracked status is still
/// working; the release's final_status says idle, and that is what decides.
func testHerdrReducerReleaseUsesFinalStatus() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1")])), now: at(0))
    reducer.apply(.event(.agentDetected(paneID: "w1:p1", agent: nil, released: true, finalStatus: .idle)), now: at(5))
    reducer.apply(.tick, now: at(6.1))
    try expect(reducer.rows.filter { $0.state == .error }.count, equals: 0,
               "a release whose final_status is idle is not an error")
    try expectTrue(reducer.rows.allSatisfy { $0.id.key != "w1:p1" }, "the released pane has no agent row")
    try expect(reducer.nextDeadline(after: at(6.1)), equals: nil, "no pending exit was scheduled")
}

/// Controller ruling (b): Herdr went away (EOF, failed ping, protocol disable). Exits still inside their grace
/// period belong to the dead connection and never mature; one whose grace had already run out is an error.
/// The stream statuses died with the connection too, so the next snapshot asks for no reopen.
func testHerdrReducerConnectionLostDropsPendingExits() throws {
    var reducer = makeReducer()
    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1"), TestPane(id: "w1:p2")])), now: at(0))
    reducer.apply(.event(.paneExited(paneID: "w1:p1", workspaceID: "w1")), now: at(10))
    try expect(reducer.nextDeadline(after: at(10)), equals: at(11), "the exit grace deadline is pending")
    reducer.apply(.connectionLost, now: at(10.5))
    try expect(reducer.nextDeadline(after: at(10.5)), equals: at(0).addingTimeInterval(IslandTiming.staleAfter),
               "no exit deadline is left (only stale aging)")
    reducer.apply(.tick, now: at(12))
    try expect(row(reducer, "w1:p1").state, equals: .working, "the exit from the dead connection is not an error")
    try expect(reducer.rows.filter { $0.state == .error }.count, equals: 0, "no error rows")

    reducer.apply(.event(.paneExited(paneID: "w1:p2", workspaceID: "w1")), now: at(20))
    reducer.apply(.connectionLost, now: at(21.5))
    try expect(row(reducer, "w1:p2").state, equals: .error, "an exit whose grace ran out before the loss is an error")

    reducer.apply(.snapshot(try snapshot([TestPane(id: "w1:p1", status: "idle")])), now: at(30))
    try expect(reducer.takeReopenRequests(), equals: Set<String>(),
               "statuses from the dead connection's streams request no reopen of the new streams")
}

let herdrReducerTests: [TestCase] = [
    ("herdrReducer: maps snapshot statuses; shells are known panes without rows", testHerdrReducerMapsSnapshotStatuses),
    ("herdrReducer: maps status events", testHerdrReducerMapsStatusEvents),
    ("herdrReducer: done then viewed goes idle without overlay", testHerdrReducerDoneThenViewedGoesIdleWithoutOverlay),
    ("herdrReducer: old click preserves an error created at its deadline", testHerdrReducerOldClickPreservesErrorCreatedAtDeadline),
    ("herdrReducer: acknowledgment survives metadata but not reset or reuse", testHerdrReducerAcknowledgmentSurvivesMetadataButNotResetOrReuse),
    ("herdrReducer: old click cannot clear a newer overlay", testHerdrReducerOldClickCannotClearNewOverlay),
    ("herdrReducer: unchanged working ages to stale; seq change resets", testHerdrReducerAgesUnchangedWorkingToStale),
    ("herdrReducer: since is the island-observed change time", testHerdrReducerSinceIsIslandObservedChangeTime),
    ("herdrReducer: exit while working or blocked becomes error after 1 s", testHerdrReducerExitWhileWorkingBecomesErrorAfterGrace),
    ("herdrReducer: pane_closed within 1 s is not an error", testHerdrReducerCloseWithinGraceIsNotAnError),
    ("herdrReducer: focused pane with Ghostty frontmost is a user close", testHerdrReducerFocusedPaneWithGhosttyFrontmostIsUserClose),
    ("herdrReducer: release while working is an error", testHerdrReducerReleaseWhileWorkingIsError),
    ("herdrReducer: error tombstone persists until click or 12 h", testHerdrReducerErrorTombstonePersistsUntilClickOrRetention),
    ("herdrReducer: finished-while-away overlay sets and clears", testHerdrReducerFinishedWhileAwayOverlay),
    ("herdrReducer: reconcile repairs a silent stream and requests one reopen", testHerdrReducerReconcileRepairsSilentStream),
    ("herdrReducer: labels come from snapshots only", testHerdrReducerLabelsComeFromSnapshotsOnly),
    ("herdrReducer: detection sets question, fallback and recap", testHerdrReducerDetectionSetsQuestionFallbackAndRecap),
    ("herdrReducer: title, subtitle, jump and process ids", testHerdrReducerBuildsTitleSubtitleJumpAndProcessIDs),
    ("herdrReducer: create, move, focus and shells", testHerdrReducerTracksCreateMoveFocusAndShells),
    ("herdrReducer: reset clears everything", testHerdrReducerResetClearsEverything),
    ("herdrReducer: nextDeadline is the earliest pending deadline", testHerdrReducerNextDeadlineIsEarliest),
    ("herdrReducer: hardening 5 wall-clock jump ages and expires without new alerts", testHerdrReducerWallClockJumpAgesAndExpiresWithoutNewAlerts),
    ("herdrReducer: a snapshot that sees a new agent clears the tombstone", testHerdrReducerSnapshotNewAgentClearsTombstone),
    ("herdrReducer: a reused pane id with a new agent clears the tombstone", testHerdrReducerReusedPaneIDWithNewAgentClearsTombstone),
    ("herdrReducer: release uses final_status, so a release after a lost idle is not an error", testHerdrReducerReleaseUsesFinalStatus),
    ("herdrReducer: a lost connection drops pending exits and stream statuses", testHerdrReducerConnectionLostDropsPendingExits),
]

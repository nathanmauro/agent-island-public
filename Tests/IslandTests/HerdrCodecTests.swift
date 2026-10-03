import Foundation
import IslandCore
import IslandTestSupport

// MARK: - Helpers (file-private)

private func herdrCodecLine(_ text: String) -> Data { Data(text.utf8) }

/// Parses a JSON value with JSONSerialization so wire JSON is compared as data, never as text.
private func herdrCodecParsed(_ data: Data) throws -> NSObject {
    guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject else {
        throw TestFailure.expectation("not JSON: \(String(decoding: data, as: UTF8.self))")
    }
    return object
}

private func herdrCodecExpectRequest(_ request: HerdrRequest, method: String, params: String, _ message: String) throws {
    let line = HerdrCodec.encodeRequest(request, id: "req-1")
    try expectTrue(line.last == 0x0A, "\(message): request ends with a newline")
    try expectTrue(line.dropLast().firstIndex(of: 0x0A) == nil, "\(message): request is one line")
    let expected = "{\"id\":\"req-1\",\"method\":\"\(method)\",\"params\":\(params)}"
    try expectTrue(try herdrCodecParsed(line.dropLast()) == (try herdrCodecParsed(Data(expected.utf8))),
                   "\(message): got \(String(decoding: line, as: UTF8.self))")
}

private func herdrCodecEvent(_ text: String) throws -> HerdrEvent {
    guard case let .event(event)? = HerdrCodec.decodeStreamLine(herdrCodecLine(text)) else {
        throw TestFailure.expectation("not an event line: \(text)")
    }
    return event
}

private func herdrCodecRoundTrip(_ value: HerdrJSON, encodesTo json: String, _ message: String) throws {
    let encoded = try JSONEncoder().encode(value)
    try expectTrue(try herdrCodecParsed(encoded) == (try herdrCodecParsed(Data(json.utf8))),
                   "\(message): encoded \(String(decoding: encoded, as: UTF8.self))")
    try expect(try JSONDecoder().decode(HerdrJSON.self, from: encoded), equals: value, "\(message): round trip")
}

// MARK: - Tests

func testHerdrCodecNormalizesEventNames() throws {
    try expect(HerdrCodec.normalizeEventName("pane.agent_status_changed"), equals: "pane_agent_status_changed", "dotted")
    try expect(HerdrCodec.normalizeEventName("pane_created"), equals: "pane_created", "underscored")
}

func testHerdrCodecDecodesBothEnvelopeForms() throws {
    let status = try herdrCodecEvent(
        #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked","agent":"claude","title":"fixture title 1","state_labels":{}}}"#)
    try expect(status, equals: .agentStatusChanged(HerdrStatusChange(
        paneID: "w1:p1", workspaceID: "w1", status: .blocked, agent: "claude", title: "fixture title 1")),
        "dotted status event")

    let created = try herdrCodecEvent(
        #"{"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"w1:p3","terminal_id":"t-3","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"unknown","revision":0,"scroll":{"offset_from_bottom":0}}}}"#)
    try expect(created, equals: .paneCreated(HerdrPaneInfo(
        paneID: "w1:p3", workspaceID: "w1", tabID: "w1:t1", focused: true, agentStatus: .unknown, revision: 0)),
        "underscored lifecycle event with data.type")
}

func testHerdrCodecDecodesLifecycleAndFocusEvents() throws {
    try expect(try herdrCodecEvent(#"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p2","workspace_id":"w1"}}"#),
               equals: .paneClosed(paneID: "w1:p2", workspaceID: "w1"), "pane_closed")
    try expect(try herdrCodecEvent(#"{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w1:p2","workspace_id":"w1"}}"#),
               equals: .paneExited(paneID: "w1:p2", workspaceID: "w1"), "pane_exited")
    try expect(try herdrCodecEvent(#"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"w1:p2","workspace_id":"w1","agent":null,"released":true,"final_status":"working"}}"#),
               equals: .agentDetected(paneID: "w1:p2", agent: nil, released: true, finalStatus: .working), "released agent")
    try expect(try herdrCodecEvent(#"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"w1:p2","workspace_id":"w1","agent":"claude"}}"#),
               equals: .agentDetected(paneID: "w1:p2", agent: "claude", released: false, finalStatus: nil), "detected agent")
    try expect(try herdrCodecEvent(#"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"working","agent":"claude","terminal_title_stripped":"fixture title 2","revision":3}}}"#),
               equals: .paneUpdated(HerdrPaneInfo(paneID: "w1:p2", workspaceID: "w1", tabID: "w1:t1", agentStatus: .working,
                                                  agent: "claude", terminalTitleStripped: "fixture title 2", revision: 3)),
               "pane_updated")
    try expect(try herdrCodecEvent(#"{"event":"pane_moved","data":{"type":"pane_moved","previous_pane_id":"w1:p2","previous_workspace_id":"w1","previous_tab_id":"w1:t1","pane":{"pane_id":"w2:p5","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"idle","revision":1}}}"#),
               equals: .paneMoved(previousPaneID: "w1:p2", pane: HerdrPaneInfo(paneID: "w2:p5", workspaceID: "w2", tabID: "w2:t1",
                                                                               agentStatus: .idle, revision: 1)),
               "pane_moved")
    try expect(try herdrCodecEvent(#"{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w1:p1","workspace_id":"w1"}}"#),
               equals: .paneFocused(paneID: "w1:p1", workspaceID: "w1"), "pane_focused")
    try expect(try herdrCodecEvent(#"{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t2","workspace_id":"w1"}}"#),
               equals: .tabFocused(tabID: "w1:t2", workspaceID: "w1"), "tab_focused")
    try expect(try herdrCodecEvent(#"{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w2"}}"#),
               equals: .workspaceFocused(workspaceID: "w2"), "workspace_focused")
}

func testHerdrCodecMapsLayoutAndUnknownEvents() throws {
    try expect(try herdrCodecEvent(#"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"w1","label":"renamed"}}"#),
               equals: .layoutChanged(name: "workspace_renamed"), "workspace_renamed")
    try expect(try herdrCodecEvent(#"{"event":"tab_created","data":{"type":"tab_created","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"x","focused":false,"number":2,"pane_count":1,"agent_status":"idle"}}}"#),
               equals: .layoutChanged(name: "tab_created"), "tab_created")
    for name in ["workspace_created", "workspace_closed", "tab_closed", "tab_renamed"] {
        try expect(try herdrCodecEvent(#"{"event":"\#(name)","data":{"type":"\#(name)","workspace_id":"w1","tab_id":"w1:t1"}}"#),
                   equals: .layoutChanged(name: name), name)
    }
    try expect(try herdrCodecEvent(#"{"event":"layout.updated","data":{"type":"layout_updated","layout":{}}}"#),
               equals: .unknown(name: "layout_updated"), "unmodeled event")
    try expect(try herdrCodecEvent(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"napping"}}"#),
               equals: .agentStatusChanged(HerdrStatusChange(paneID: "w1:p1", workspaceID: "w1", status: .unknown)),
               "unrecognized agent_status maps to unknown")
    try expect(HerdrAgentStatus(wire: "sleeping"), equals: .unknown, "unknown wire status")
    try expect(HerdrAgentStatus(wire: nil), equals: .unknown, "missing wire status")
    try expect(HerdrAgentStatus(wire: "blocked"), equals: .blocked, "known wire status")
}

func testHerdrCodecEncodesExactParams() throws {
    try herdrCodecExpectRequest(.readDetection(paneID: "w1:p1"), method: "agent.read",
                                params: #"{"target":"w1:p1","source":"detection","strip_ansi":true}"#, "agent.read")
    try herdrCodecExpectRequest(.focus(paneID: "w1:p1"), method: "agent.focus", params: #"{"target":"w1:p1"}"#, "agent.focus")
    try herdrCodecExpectRequest(.processInfo(paneID: "w1:p1"), method: "pane.process_info",
                                params: #"{"pane_id":"w1:p1"}"#, "pane.process_info")
    try herdrCodecExpectRequest(.subscribe([.paneStatus(paneID: "w1:p1")]), method: "events.subscribe",
                                params: #"{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":"w1:p1"}]}"#,
                                "per-pane status subscription")
    try herdrCodecExpectRequest(.ping, method: "ping", params: "{}", "ping")
    try herdrCodecExpectRequest(.snapshot, method: "session.snapshot", params: "{}", "session.snapshot")
    try herdrCodecExpectRequest(.raw(method: "island.contract_unknown", params: ["n": .int(1)]),
                                method: "island.contract_unknown", params: #"{"n":1}"#, "raw")
}

func testHerdrCodecGlobalStreamIsTheFifteenSpecTypes() throws {
    let expected = [
        "pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "pane.updated", "pane.moved",
        "pane.focused", "tab.focused", "workspace.focused", "workspace.created", "workspace.closed",
        "workspace.renamed", "tab.created", "tab.closed", "tab.renamed",
    ]
    try expect(HerdrSubscription.globalStream, equals: expected.map { HerdrSubscription.event($0) }, "globalStream")
    let params = expected.map { #"{"type":"\#($0)"}"# }.joined(separator: ",")
    try herdrCodecExpectRequest(.subscribe(HerdrSubscription.globalStream), method: "events.subscribe",
                                params: #"{"subscriptions":[\#(params)]}"#, "global stream G")
}

func testHerdrCodecHerdrJSONIsBareJSON() throws {
    try herdrCodecRoundTrip(.string("a"), encodesTo: #""a""#, "string")
    try herdrCodecRoundTrip(.object(["k": .int(1)]), encodesTo: #"{"k":1}"#, "object")
    try herdrCodecRoundTrip(.bool(true), encodesTo: "true", "bool")
    try herdrCodecRoundTrip(.null, encodesTo: "null", "null")
    try herdrCodecRoundTrip(.int(-7), encodesTo: "-7", "int")
    try herdrCodecRoundTrip(.double(1.5), encodesTo: "1.5", "double")
    try herdrCodecRoundTrip(.array([.int(1), .string("x"), .null, .bool(false)]), encodesTo: #"[1,"x",null,false]"#, "array")
    try herdrCodecRoundTrip(.object(["nested": .object(["list": .array([.double(0.25)])])]),
                            encodesTo: #"{"nested":{"list":[0.25]}}"#, "nested")
    try expect(try JSONDecoder().decode(HerdrJSON.self, from: Data("true".utf8)), equals: .bool(true), "true stays a bool")
    try expect(try JSONDecoder().decode(HerdrJSON.self, from: Data("1".utf8)), equals: .int(1), "1 stays an int")
}

func testHerdrCodecDecodesParseLevelAndPaneErrors() throws {
    let unsupported = HerdrCodec.decodeResponse(herdrCodecLine(
        #"{"id":"","error":{"code":"invalid_request","message":"unknown variant `x`, expected one of `ping`"}}"#))
    guard case let .failure(id, error)? = unsupported else {
        throw TestFailure.expectation("parse-level error did not decode: \(String(describing: unsupported))")
    }
    try expect(id, equals: "", "parse-level errors carry id \"\"")
    try expectTrue(error.isUnsupportedMethod, "unknown variant means unsupported method")
    try expectTrue(!error.isPaneNotFound, "not pane_not_found")

    let missing = HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"req-2","error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#))
    guard case let .failure(_, paneError)? = missing else { throw TestFailure.expectation("pane_not_found did not decode") }
    try expectTrue(paneError.isPaneNotFound, "isPaneNotFound")
    try expectTrue(!paneError.isUnsupportedMethod, "pane_not_found is not an unsupported method")

    try expect(HerdrCodec.decodeStreamLine(herdrCodecLine(#"{"id":"s1","error":{"code":"pane_not_found","message":"gone"}}"#)),
               equals: .rejected(HerdrError(code: "pane_not_found", message: "gone")), "stream rejection")
    try expect(HerdrCodec.decodeStreamLine(herdrCodecLine(#"{"id":"s1","result":{"type":"subscription_started"}}"#)),
               equals: .ack(id: "s1"), "stream ack")
    try expect(HerdrCodec.decodeResponse(herdrCodecLine("not json")), equals: nil, "garbage reply")
    try expect(HerdrCodec.decodeStreamLine(herdrCodecLine(#"{"hello":1}"#)), equals: nil, "unrelated object")
}

func testHerdrCodecDecodesResults() throws {
    try expect(HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"a","result":{"type":"pong","version":"0.9.1","protocol":22,"capabilities":{"live_handoff":true}}}"#)),
               equals: .success(id: "a", result: .pong(version: "0.9.1", protocolVersion: 22)), "pong")
    try expect(HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"b","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":501,"foreground_process_group_id":777,"foreground_processes":[{"pid":777,"name":"claude"},{"pid":778,"name":"node"}]}}}"#)),
               equals: .success(id: "b", result: .processInfo(HerdrProcessInfo(paneID: "w1:p1", shellPID: 501, foregroundPIDs: [777, 778]))),
               "process info")
    try expect(HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"c","result":{"type":"pane_read","read":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","source":"detection","format":"text","text":"line one\nline two","revision":4,"truncated":false}}}"#)),
               equals: .success(id: "c", result: .read(HerdrRead(paneID: "w1:p1", text: "line one\nline two", truncated: false, revision: 4))),
               "detection read")
    try expect(HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"d","result":{"type":"subscription_started"}}"#)),
               equals: .success(id: "d", result: .subscriptionStarted), "subscription ack as a reply")
    try expect(HerdrCodec.decodeResponse(herdrCodecLine(#"{"id":"e","result":{"type":"agent_info","agent":{}}}"#)),
               equals: .success(id: "e", result: .ok(type: "agent_info")), "other success type")
}

func testHerdrCodecDecodesSnapshotFixture() throws {
    guard case let .success(_, .snapshot(snapshot))? = HerdrCodec.decodeResponse(try Fixtures.data("herdr/snapshot-sample.json")) else {
        throw TestFailure.expectation("snapshot-sample.json did not decode as a session_snapshot")
    }
    try expect(snapshot.protocolVersion, equals: 22, "protocol")
    try expect(snapshot.version, equals: "0.9.1-fake", "version")
    try expect(snapshot.focusedPaneID, equals: "w1:p1", "focused pane")
    try expect(snapshot.workspaces.map(\.label), equals: ["api", "web"], "workspace labels")
    try expect(snapshot.tabs.map(\.tabID), equals: ["w1:t1", "w2:t1"], "tabs")
    try expect(snapshot.panes.count, equals: 5, "panes, including the shell")
    try expect(snapshot.panes.first { $0.paneID == "w2:p3" }?.agent, equals: nil, "the shell pane has no agent")
    try expect(snapshot.agents.map(\.paneID), equals: ["w1:p1", "w1:p2", "w2:p1", "w2:p2"], "agent panes")
    try expect(snapshot.agents.map(\.agentStatus), equals: [.working, .blocked, .done, .unknown], "agent statuses")
    try expect(snapshot.agents.map(\.stateChangeSeq), equals: [10, 11, 12, 13], "agents[].state_change_seq")
    try expect(snapshot.agents.map(\.terminalTitleStripped),
               equals: ["fixture title 1", "fixture title 2", "fixture title 3", "fixture title 4"], "titles")
    try expect(snapshot.agents.first?.cwd, equals: "/tmp/fixture-project", "cwd")
}

func testHerdrCodecTakeLinesKeepsPartialTrailingLine() throws {
    var buffer = Data("{\"a\":1}\n{\"b\":2}\r\n\n{\"c\"".utf8)
    let lines = HerdrCodec.takeLines(from: &buffer)
    try expect(lines.map { String(decoding: $0, as: UTF8.self) }, equals: [#"{"a":1}"#, #"{"b":2}"#], "complete lines only")
    try expect(String(decoding: buffer, as: UTF8.self), equals: #"{"c""#, "partial line stays")
    buffer.append(Data(":3}\n".utf8))
    try expect(HerdrCodec.takeLines(from: &buffer).map { String(decoding: $0, as: UTF8.self) }, equals: [#"{"c":3}"#], "completed later")
    try expect(buffer.isEmpty, equals: true, "buffer drained")
}

let herdrCodecTests: [TestCase] = [
    ("herdrCodec: normalizes dotted and underscored event names", testHerdrCodecNormalizesEventNames),
    ("herdrCodec: decodes the dotted status and underscored lifecycle envelopes", testHerdrCodecDecodesBothEnvelopeForms),
    ("herdrCodec: decodes lifecycle and focus events", testHerdrCodecDecodesLifecycleAndFocusEvents),
    ("herdrCodec: maps layout events and unknown names and statuses", testHerdrCodecMapsLayoutAndUnknownEvents),
    ("herdrCodec: encodes exact request params", testHerdrCodecEncodesExactParams),
    ("herdrCodec: global stream is the fifteen spec types", testHerdrCodecGlobalStreamIsTheFifteenSpecTypes),
    ("herdrCodec: HerdrJSON encodes and decodes bare JSON", testHerdrCodecHerdrJSONIsBareJSON),
    ("herdrCodec: decodes parse-level and pane errors", testHerdrCodecDecodesParseLevelAndPaneErrors),
    ("herdrCodec: decodes pong, process info, read and other results", testHerdrCodecDecodesResults),
    ("herdrCodec: decodes the snapshot fixture", testHerdrCodecDecodesSnapshotFixture),
    ("herdrCodec: takeLines keeps a partial trailing line", testHerdrCodecTakeLinesKeepsPartialTrailingLine),
]

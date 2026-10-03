import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Shared helpers (Task 8)

private let registryKeyFixtureName = "123.c08d6cabb2efa98d4d72b88ef2ed93ec84ccc3a2582444024f081db14b43f5c8.key"
private let registryTemplateProcStart = "Fri Sep 25 13:02:11 2026"
/// Synthetic Claude Remote Control bridge id with the live shape: "session_" plus 24 ASCII letters and digits.
private let registryBridgeSessionID = "session_01FixtureBridge000000001"

/// The committed synthetic template with `overrides` applied. An NSNull value removes the key.
private func registryJSON(_ overrides: [String: Any] = [:]) throws -> Data {
    let template = try Fixtures.data("claude-sessions/template.json")
    guard var object = try JSONSerialization.jsonObject(with: template) as? [String: Any] else {
        throw TestFailure.expectation("claude-sessions/template.json must be a JSON object")
    }
    for (key, value) in overrides {
        if value is NSNull { object.removeValue(forKey: key) } else { object[key] = value }
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func registryEntry(_ overrides: [String: Any] = [:]) throws -> RegistryEntry {
    guard let entry = RegistryEntry.decode(try registryJSON(overrides)) else {
        throw TestFailure.expectation("template with overrides \(overrides.keys.sorted()) must decode")
    }
    return entry
}

private func registryMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

// MARK: - Entry and path filter

func testRegistryPathFilterAcceptsOnlyDigitsDotJSON() throws {
    try expectTrue(RegistryPathFilter.accepts(fileName: "123.json"), "123.json is a registry entry")
    for rejected in ["123.abc.key", "123.json.key", ".json", "abc.json", "123.JSON", "12a.json", "123.json.tmp",
                     registryKeyFixtureName, "template.json", ""] {
        try expectTrue(!RegistryPathFilter.accepts(fileName: rejected), "\(rejected) must be rejected")
    }
}

func testRegistryEntryDecodesTheLiveShapedTemplate() throws {
    let entry = try registryEntry()
    try expect(entry.pid, equals: 123, "pid")
    try expect(entry.sessionId, equals: "538fcc11-00c0-4f00-be55-114d73ca51c6", "sessionId")
    try expect(entry.cwd, equals: "/tmp/fixture-project", "cwd")
    try expect(entry.procStart, equals: registryTemplateProcStart, "procStart")
    try expect(entry.kind, equals: "interactive", "kind")
    try expect(entry.entrypoint, equals: "cli", "entrypoint")
    try expect(entry.name, equals: "fixture session", "name")
    try expect(entry.status, equals: "busy", "status")
    try expect(entry.waitingFor, equals: nil, "waitingFor is absent from the template")
    try expect(entry.statusUpdatedAt, equals: 1_800_000_000_000, "statusUpdatedAt in epoch ms")
    try expect(entry.tmux, equals: nil, "tmux is absent from the template")
}

func testRegistryEntryDecodingIsTolerantOfOptionalFields() throws {
    let tolerant = try registryEntry(["tmux": ["unexpected": "object"], "statusUpdatedAt": 1_800_000_000_500.0,
                                      "waitingFor": "input needed", "name": 42])
    try expect(tolerant.tmux, equals: nil, "a wrongly typed optional field decodes as nil")
    try expect(tolerant.name, equals: nil, "a numeric name decodes as nil")
    try expect(tolerant.statusUpdatedAt, equals: 1_800_000_000_500, "a floating-point timestamp is accepted")
    try expect(tolerant.waitingFor, equals: "input needed", "waitingFor")
    try expect(RegistryEntry.decode(try registryJSON(["pid": NSNull()])), equals: nil, "pid is required")
    try expect(RegistryEntry.decode(try registryJSON(["sessionId": NSNull()])), equals: nil, "sessionId is required")
    try expect(RegistryEntry.decode(Data("{\"pid\": 12".utf8)), equals: nil, "truncated JSON")
    try expect(RegistryEntry.decode(Data("[1, 2]".utf8)), equals: nil, "a JSON array")
}

func testRegistryRowKeyCollapsesProcStartWhitespace() throws {
    try expect(try registryEntry().rowKey, equals: "123@Fri Sep 25 13:02:11 2026", "template key")
    try expect(try registryEntry(["procStart": "Sat Sep  5 09:03:04 2026  "]).rowKey,
               equals: "123@Sat Sep 5 09:03:04 2026", "whitespace runs collapse")
    try expect(try registryEntry(["procStart": NSNull()]).rowKey, equals: "123@?", "missing procStart")
    try expect(try registryEntry(["procStart": "   "]).rowKey, equals: "123@?", "blank procStart")
}

func testRegistryEntryDecodesTheRemoteControlBridgeSessionID() throws {
    try expect(try registryEntry().bridgeSessionId, equals: nil, "the template's JSON null decodes as nil")
    try expect(try registryEntry(["bridgeSessionId": NSNull()]).bridgeSessionId, equals: nil, "a missing key decodes as nil")
    try expect(try registryEntry(["bridgeSessionId": registryBridgeSessionID]).bridgeSessionId, equals: registryBridgeSessionID,
               "\"session_\" plus 24 letters and digits (the live shape)")
    let longest = "session_" + String(repeating: "A1", count: 32)
    try expect(try registryEntry(["bridgeSessionId": longest]).bridgeSessionId, equals: longest,
               "a 64-character suffix is still accepted")
}

func testRegistryEntryDecodesMalformedBridgeSessionIDsAsNil() throws {
    let overlong = "session_" + String(repeating: "A", count: 65)
    let malformed: [Any] = [
        "",
        "session_",
        "cse_01FixtureBridge000000001",
        "Session_01FixtureBridge000000001",
        "01FixtureBridge000000001",
        " session_01FixtureBridge000000001",
        "session_01FixtureBridge000000001 ",
        "session_01FixtureBridge000000001\n",
        "session_01Fixture-Bridge00000001",
        "session_01Fixture_Bridge00000001",
        "session_../01FixtureBridge000001",
        "session_01FixtureBridge00%2F0001",
        "session_01FixtureBridge001?x=1&y",
        "session_01FixtureBr\u{EF}dge000000001",
        overlong,
        42,
        true,
        ["id": registryBridgeSessionID],
        [registryBridgeSessionID],
    ]
    for value in malformed {
        try expect(try registryEntry(["bridgeSessionId": value]).bridgeSessionId, equals: nil,
                   "\(String(reflecting: value)) decodes as nil without failing the entry")
    }
}

// MARK: - Liveness

private struct RegistryStubProbe: ProcessProbing {
    var alive: Bool
    var start: Date?
    func exists(_ pid: Int32) -> Bool { alive }
    func startTime(of pid: Int32) -> Date? { start }
}

private func registryLocalDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                        hour: hour, minute: minute, second: second)) else {
        throw TestFailure.expectation("could not build a local date")
    }
    return date
}

private func registryLstart(of pid: Int32, environment: [String: String]?) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "lstart=", "-p", String(pid)]
    if let environment { process.environment = environment }
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !text.isEmpty else {
        throw TestFailure.expectation("ps -o lstart= failed for pid \(pid)")
    }
    return text
}

func testRegistryParseProcStartReadsLstartText() throws {
    try expect(RegistryLiveness.parseProcStart("Fri Sep 25 13:02:11 2026"), equals: try registryLocalDate(2026, 9, 25, 13, 2, 11),
               "two-digit day, local time")
    try expect(RegistryLiveness.parseProcStart("Sat Sep  5 09:03:04 2026"), equals: try registryLocalDate(2026, 9, 5, 9, 3, 4),
               "single-digit day padded with a double space")
    try expect(RegistryLiveness.parseProcStart("  Fri Sep 25 13:02:11 2026    \n"),
               equals: try registryLocalDate(2026, 9, 25, 13, 2, 11), "surrounding whitespace, as ps prints it")
    let utc = try registryTimeZone("UTC")
    try expect(RegistryLiveness.parseProcStart("Fri Sep 25 13:02:11 2026", timeZone: utc),
               equals: Date(timeIntervalSince1970: 1_790_341_331), "the same text read as UTC")
    try expect(RegistryLiveness.parseProcStart("Sat Sep  5 09:03:04 2026", timeZone: utc),
               equals: Date(timeIntervalSince1970: 1_788_598_984), "single-digit day read as UTC")
}

private func registryTimeZone(_ identifier: String) throws -> TimeZone {
    guard let zone = TimeZone(identifier: identifier) else { throw TestFailure.expectation("no time zone \(identifier)") }
    return zone
}

func testRegistryParseProcStartRejectsMalformedText() throws {
    for bad in ["", "Fri Sep 25 13:02:11", "Fri Sep 31 13:02:11 2026", "Fri Sept 25 13:02:11 2026",
                "Xyz Sep 25 13:02:11 2026", "Fri Sep 25 24:00:00 2026", "Fri Sep 25 13:2:11 2026",
                "Fri Sep 25 13:02:11 2026 extra", "2026-09-25T13:02:11Z"] {
        try expect(RegistryLiveness.parseProcStart(bad), equals: nil, "\"\(bad)\" must not parse")
    }
}

func testRegistryLivenessRequiresExistenceAndMatchingStart() throws {
    let entry = try registryEntry()
    guard let local = RegistryLiveness.parseProcStart(registryTemplateProcStart),
          let utc = RegistryLiveness.parseProcStart(registryTemplateProcStart, timeZone: try registryTimeZone("UTC")) else {
        throw TestFailure.expectation("template procStart must parse")
    }
    try expectTrue(RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: true, start: local.addingTimeInterval(0.8))),
                   "a start time within 1 s of local procStart is live")
    try expectTrue(RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: true, start: utc.addingTimeInterval(0.4))),
                   "procStart written in UTC (as Claude Code writes it) is live")
    try expectTrue(!RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: true, start: local.addingTimeInterval(90))),
                   "a procStart mismatch (pid reuse) is not live")
    try expectTrue(!RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: true, start: local.addingTimeInterval(-1.5))),
                   "a start time 1.5 s early is not live")
    try expectTrue(!RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: false, start: local)),
                   "a pid that does not exist is not live")
    try expectTrue(!RegistryLiveness.isLive(entry, probe: RegistryStubProbe(alive: true, start: nil)),
                   "an unreadable start time is not live")
    try expectTrue(!RegistryLiveness.isLive(try registryEntry(["procStart": NSNull()]),
                                            probe: RegistryStubProbe(alive: true, start: local)),
                   "an entry without procStart is not live")
}

func testRegistryLivenessAcceptsTheRunnersOwnProcess() throws {
    let pid = getpid()
    let probe = LiveProcessProbe()
    try expectTrue(probe.exists(pid), "the runner exists")
    try expectTrue(probe.startTime(of: pid) != nil, "the runner has a kernel start time")
    let local = try registryLstart(of: pid, environment: nil)
    try expectTrue(RegistryLiveness.isLive(try registryEntry(["pid": Int(pid), "procStart": local]), probe: probe),
                   "ps -o lstart= in local time matches the runner's start time")
    let utc = try registryLstart(of: pid, environment: ["TZ": "UTC"])
    try expectTrue(RegistryLiveness.isLive(try registryEntry(["pid": Int(pid), "procStart": utc]), probe: probe),
                   "TZ=UTC ps -o lstart= (Claude Code's format) matches the runner's start time")
}

func testRegistryLiveProcessProbeRejectsDeadAndInvalidPids() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    let probe = LiveProcessProbe()
    try expectTrue(!probe.exists(child.processIdentifier), "an exited, reaped child does not exist")
    try expect(probe.startTime(of: child.processIdentifier), equals: nil, "an exited child has no start time")
    try expectTrue(!probe.exists(0), "pid 0 is never probed")
    try expectTrue(!probe.exists(-1), "a negative pid is never probed")
    try expect(probe.startTime(of: 0), equals: nil, "pid 0 has no start time")
}

// MARK: - Reducer

func testRegistryReducerFiltersNonInteractiveAndSDKEntrypoints() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let rows = reducer.apply([
        try registryEntry(["pid": 201, "kind": "interactive", "entrypoint": "cli"]),
        try registryEntry(["pid": 202, "kind": "background"]),
        try registryEntry(["pid": 203, "kind": NSNull()]),
        try registryEntry(["pid": 204, "entrypoint": "sdk-cli"]),
        try registryEntry(["pid": 205, "entrypoint": "sdk-ts"]),
        try registryEntry(["pid": 206, "entrypoint": "sdk-future"]),
        try registryEntry(["pid": 207, "entrypoint": "claude-desktop"]),
    ], now: now)
    try expect(rows.map(\.processIDs), equals: [[201], [207]], "only interactive, non-sdk entries become rows")
}

func testRegistryReducerMapsBusyToWorkingAndAgesToStale() throws {
    let clock = ManualWallClock()
    var reducer = ClaudeRegistryReducer()
    let fresh = try registryEntry(["status": "busy", "statusUpdatedAt": registryMilliseconds(clock.now())])
    try expect(reducer.apply([fresh], now: clock.now()).map(\.state), equals: [.working], "busy is working")
    clock.advance(by: 29 * 60)
    try expect(reducer.apply([fresh], now: clock.now()).map(\.state), equals: [.working], "29 min without an update")
    clock.advance(by: 2 * 60)
    let aged = reducer.apply([fresh], now: clock.now())
    try expect(aged.map(\.state), equals: [.stale], "31 min without a status update is stale")
    try expect(aged.first?.since, equals: clock.now().addingTimeInterval(-31 * 60),
               "since stays at statusUpdatedAt so the board can show the stale age")
    let noTimestamp = try registryEntry(["pid": 300, "status": "busy", "statusUpdatedAt": NSNull()])
    try expect(reducer.apply([noTimestamp], now: clock.now()).map(\.state), equals: [.working],
               "busy without statusUpdatedAt never ages")
}

func testRegistryReducerMapsWaitingForToDetailKind() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let cases: [(String, Detail.Kind)] = [("permission prompt", .permission), ("input needed", .question), ("dialog open", .question)]
    for (index, (waitingFor, kind)) in cases.enumerated() {
        let rows = reducer.apply([try registryEntry(["pid": 400 + index, "status": "waiting", "waitingFor": waitingFor])], now: now)
        try expect(rows.map(\.state), equals: [.waiting], "\(waitingFor) is waiting")
        try expect(rows.first?.detail?.kind, equals: kind, "\(waitingFor) detail kind")
        let question = rows.first?.detail?.question ?? ""
        try expectTrue(question.contains(waitingFor), "question text contains waitingFor (\(question))")
        try expectTrue(question.contains("fixture session"), "question text contains the session name (\(question))")
        try expect(rows.first?.detail?.options, equals: [], "registry questions carry no options")
    }
    let bare = reducer.apply([try registryEntry(["status": "waiting", "waitingFor": NSNull(), "name": NSNull()])], now: now)
    try expect(bare.first?.detail, equals: Detail(question: "needs you", kind: .question), "no waitingFor, no name")
}

func testRegistryReducerMarksBusyToIdleDoneUnseenUntilSeen() throws {
    let clock = ManualWallClock()
    var reducer = ClaudeRegistryReducer()
    let busy = try registryEntry(["status": "busy"])
    let idle = try registryEntry(["status": "idle", "statusUpdatedAt": registryMilliseconds(clock.now().addingTimeInterval(5))])
    _ = reducer.apply([busy], now: clock.now())
    clock.advance(by: 5)
    let done = reducer.apply([idle], now: clock.now())
    try expect(done.map(\.state), equals: [.doneUnseen], "busy → idle is doneUnseen")
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.doneUnseen], "stays doneUnseen while idle")
    guard let row = done.first else { throw TestFailure.expectation("expected a row") }
    reducer.markSeen(AgentRow.fixture(source: .herdr, key: row.id.key))
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.doneUnseen], "a herdr RowID is ignored")
    reducer.markSeen(row)
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.idle], "markSeen clears doneUnseen")
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.idle], "re-applying idle stays idle")
}

func testRegistryReducerOldCompletionCannotClearNewCompletion() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let busy = try registryEntry(["status": "busy", "statusUpdatedAt": NSNull()])
    let idle = try registryEntry(["status": "idle", "statusUpdatedAt": NSNull()])
    _ = reducer.apply([busy], now: now)
    let old = reducer.apply([idle], now: now)[0]
    _ = reducer.apply([busy], now: now)
    let latest = reducer.apply([idle], now: now)[0]
    reducer.markSeen(old)
    try expect(reducer.apply([idle], now: now).first?.state, equals: .doneUnseen,
               "old completion cannot acknowledge a new episode with the same timestamp")
    reducer.markSeen(latest)
    try expect(reducer.apply([idle], now: now).first?.state, equals: .idle, "current completion can be acknowledged")
}

func testRegistryReducerClearsDoneUnseenOnNextBusyAndAfterTwelveHours() throws {
    let clock = ManualWallClock()
    var reducer = ClaudeRegistryReducer()
    let busy = try registryEntry(["status": "busy", "statusUpdatedAt": NSNull()])
    let idle = try registryEntry(["status": "idle", "statusUpdatedAt": NSNull()])
    _ = reducer.apply([busy], now: clock.now())
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.doneUnseen], "first completion")
    try expect(reducer.apply([busy], now: clock.now()).map(\.state), equals: [.working], "the next busy clears it")
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.doneUnseen], "second completion")
    clock.advance(by: IslandTiming.seenExpiry - 1)
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.doneUnseen], "still unseen just before 12 h")
    clock.advance(by: 2)
    try expect(reducer.apply([idle], now: clock.now()).map(\.state), equals: [.idle], "expired after 12 h")
}

func testRegistryReducerMapsIdleAndShellToIdle() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let rows = reducer.apply([
        try registryEntry(["pid": 501, "status": "idle"]),
        try registryEntry(["pid": 502, "status": "shell"]),
        try registryEntry(["pid": 503, "status": NSNull()]),
        try registryEntry(["pid": 504, "status": "something-new"]),
    ], now: now)
    try expect(rows.map(\.state), equals: [.idle, .idle, .idle, .idle], "first-seen idle, shell and unknown are idle")
    let busyThenShell = try registryEntry(["pid": 505, "status": "busy"])
    _ = reducer.apply([busyThenShell], now: now)
    try expect(reducer.apply([try registryEntry(["pid": 505, "status": "shell"])], now: now).map(\.state), equals: [.idle],
               "busy → shell is idle, never doneUnseen")
}

func testRegistryReducerRowCarriesIdentityAndSourceFields() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let rows = reducer.apply([try registryEntry(["status": "busy"])], now: now)
    guard let row = rows.first, rows.count == 1 else { throw TestFailure.expectation("expected one row") }
    try expect(row.id, equals: RowID(source: .claudeRegistry, key: "123@Fri Sep 25 13:02:11 2026"), "RowID")
    try expect(row.source, equals: .claudeRegistry, "source")
    try expect(row.title, equals: "fixture session", "title is the session name")
    try expect(row.subtitle, equals: "fixture-project", "subtitle is the cwd basename")
    try expect(row.sourceStatus, equals: "busy", "sourceStatus is the raw registry status")
    try expect(row.processIDs, equals: [123], "processIDs == [pid]")
    try expect(row.cwd, equals: "/tmp/fixture-project", "cwd")
    try expect(row.since, equals: Date(timeIntervalSince1970: 1_800_000_000), "since is statusUpdatedAt")
    let unnamed = reducer.apply([try registryEntry(["name": NSNull()])], now: now)
    try expect(unnamed.first?.title, equals: "fixture-project", "an unnamed session is titled by its folder")
    let waiting = reducer.apply([try registryEntry(["status": "waiting", "waitingFor": "input needed"])], now: now)
    try expect(waiting.first?.sourceStatus, equals: "waiting", "sourceStatus follows the raw status")
}

func testRegistryReducerChoosesJumpTargets() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let tmux = "fixture:@3.%7"
    let rows = reducer.apply([
        try registryEntry(["pid": 601, "entrypoint": "claude-desktop", "tmux": tmux]),
        try registryEntry(["pid": 602, "entrypoint": "claude-desktop"]),
        try registryEntry(["pid": 603, "entrypoint": "cli", "tmux": tmux]),
        try registryEntry(["pid": 604, "entrypoint": "cli"]),
        try registryEntry(["pid": 605, "entrypoint": "cli", "tmux": ""]),
    ], now: now)
    try expect(rows.map(\.jump), equals: [
        .claudeDesktop(sessionID: "538fcc11-00c0-4f00-be55-114d73ca51c6", tmuxTarget: tmux),
        .claudeDesktop(sessionID: "538fcc11-00c0-4f00-be55-114d73ca51c6", tmuxTarget: nil),
        .terminal(tmuxTarget: tmux),
        .terminal(tmuxTarget: nil),
        .terminal(tmuxTarget: nil),
    ], "jump targets by entrypoint and tmux")
}

func testRegistryRowIsDroppedWhenHerdrOwnsItsPid() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let registryRows = reducer.apply([
        try registryEntry(["pid": 4242, "status": "busy"]),
        try registryEntry(["pid": 4243, "status": "idle"]),
    ], now: now)
    let herdrRow = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .working, processIDs: [4242])
    let merged = RowMerger.merge([.herdr: [herdrRow], .claudeRegistry: registryRows])
    try expect(merged.rows.map(\.id), equals: [herdrRow.id, RowID(source: .claudeRegistry, key: "4243@Fri Sep 25 13:02:11 2026")],
               "the registry row for a Herdr foreground pid is removed; the other stays")
    try expect(merged.registryShadow, equals: [herdrRow.id: "busy"], "the dropped row's raw status is shadowed")
}

func testRegistryReducerKeepsInteractiveSDKCLIEntriesWithABridgeID() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let bridge = registryBridgeSessionID
    let rows = reducer.apply([
        try registryEntry(["pid": 701, "entrypoint": "sdk-cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 702, "entrypoint": "sdk-cli"]),
        try registryEntry(["pid": 703, "entrypoint": "sdk-cli", "bridgeSessionId": NSNull()]),
        try registryEntry(["pid": 704, "entrypoint": "sdk-cli", "bridgeSessionId": ""]),
        try registryEntry(["pid": 705, "entrypoint": "sdk-cli", "bridgeSessionId": "cse_01FixtureBridge000000001"]),
        try registryEntry(["pid": 706, "entrypoint": "sdk-ts", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 707, "entrypoint": "sdk-future", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 708, "kind": "background", "entrypoint": "sdk-cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 709, "kind": NSNull(), "entrypoint": "sdk-cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 710, "entrypoint": "cli"]),
        try registryEntry(["pid": 711, "entrypoint": "cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 712, "entrypoint": "claude-desktop"]),
        try registryEntry(["pid": 713, "entrypoint": "claude-desktop", "bridgeSessionId": bridge]),
    ], now: now)
    try expect(rows.map(\.processIDs), equals: [[701], [710], [711], [712], [713]],
               "only the interactive sdk-cli entry with a well-formed bridge id joins the cli and claude-desktop rows")
}

func testRegistryReducerRoutesRemoteControlRowsByBridgeID() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let bridge = registryBridgeSessionID
    let tmux = "fixture:@3.%7"
    let rows = reducer.apply([
        try registryEntry(["pid": 801, "entrypoint": "sdk-cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 802, "entrypoint": "sdk-cli", "bridgeSessionId": bridge, "tmux": tmux]),
        try registryEntry(["pid": 803, "entrypoint": "cli", "bridgeSessionId": bridge, "tmux": tmux]),
        try registryEntry(["pid": 804, "entrypoint": "cli", "bridgeSessionId": bridge]),
        try registryEntry(["pid": 805, "entrypoint": "claude-desktop", "bridgeSessionId": bridge]),
    ], now: now)
    try expect(rows.map(\.jump), equals: [
        .claudeRemoteControl(bridgeSessionID: bridge),
        .claudeRemoteControl(bridgeSessionID: bridge),
        .terminal(tmuxTarget: tmux),
        .terminal(tmuxTarget: nil),
        .claudeDesktop(sessionID: "538fcc11-00c0-4f00-be55-114d73ca51c6", tmuxTarget: nil),
    ], "sdk-cli jumps by bridge id, never by the native id or tmux; cli stays in the terminal; claude-desktop keeps its route")
    guard let remote = rows.first else { throw TestFailure.expectation("expected the Remote Control row") }
    try expect(remote.id, equals: RowID(source: .claudeRegistry, key: "801@Fri Sep 25 13:02:11 2026"),
               "the row keeps the registry pid@procStart identity")
    try expect(remote.processIDs, equals: [801], "processIDs == [pid], so Herdr deduplication still applies")
    try expect(remote.title, equals: "fixture session", "title is the session name")
}

func testRegistryRemoteControlWaitingRowPeeksUnlessClaudeIsFrontmost() throws {
    var reducer = ClaudeRegistryReducer()
    let now = ManualWallClock().now()
    let rows = reducer.apply([try registryEntry(["entrypoint": "sdk-cli", "bridgeSessionId": registryBridgeSessionID,
                                                 "status": "waiting", "waitingFor": "input needed"])], now: now)
    guard let row = rows.first, rows.count == 1 else { throw TestFailure.expectation("expected the Remote Control row") }
    let held = now.addingTimeInterval(InterruptPolicy.Configuration.standard.blockedHold)

    var away = InterruptPolicy()
    let ghostty = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty)
    _ = away.decide(prev: [], next: rows, focus: ghostty, now: now)
    let peek = away.decide(prev: rows, next: rows, focus: ghostty, now: held)
    try expect(peek.peeks.map(\.rowID), equals: [row.id], "a waiting Remote Control session peeks after the hold")
    try expect(peek.chime, equals: true, "with its one chime")

    var watching = InterruptPolicy()
    let claude = FocusContext(frontmostBundleID: KnownBundleIDs.claudeDesktop)
    _ = watching.decide(prev: [], next: rows, focus: claude, now: now)
    let quiet = watching.decide(prev: rows, next: rows, focus: claude, now: held)
    try expect(quiet.peeks, equals: [], "no card while Claude, which shows that conversation, is frontmost")
    try expectTrue(quiet.notes.contains { $0.rowID == row.id && $0.rule == .looking }, "suppressed as looking")
}

// MARK: - Feed

/// Every pid in `startTimes` exists and started at that time; any other pid does not exist.
private final class RegistryFakeProbe: ProcessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var startTimes: [Int32: Date] = [:]

    func setAlive(_ pid: Int32, startedAt: Date) {
        lock.lock()
        startTimes[pid] = startedAt
        lock.unlock()
    }

    func setDead(_ pid: Int32) {
        lock.lock()
        startTimes[pid] = nil
        lock.unlock()
    }

    func exists(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startTimes[pid] != nil
    }

    func startTime(of pid: Int32) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return startTimes[pid]
    }
}

/// Collects what a feed publishes and reports.
@MainActor
private final class RegistryFeedRecorder {
    var published: [[AgentRow]] = []
    var health: [FeedHealth] = []
    var jumped = false
    var lastRows: [AgentRow] { published.last ?? [] }
}

private func registryTemplateStart() throws -> Date {
    guard let date = RegistryLiveness.parseProcStart(registryTemplateProcStart) else {
        throw TestFailure.expectation("template procStart must parse")
    }
    return date
}

private func writeRegistryEntry(in directory: URL, pid: Int32, _ overrides: [String: Any] = [:]) throws {
    var fields = overrides
    fields["pid"] = Int(pid)
    try registryJSON(fields).write(to: directory.appendingPathComponent("\(pid).json"), options: .atomic)
}

/// Starts the feed and waits for its first (deferred) sweep to publish.
@MainActor
private func startRegistryFeed(_ feed: ClaudeRegistryFeed, _ recorder: RegistryFeedRecorder) throws {
    feed.observeHealth { recorder.health.append($0) }
    feed.start { recorder.published.append($0) }
    try spinMainRunLoop(timeout: 2) { !recorder.published.isEmpty }
}

@MainActor
func testRegistryFeedNeverReadsKeyFiles() throws {
    let directory = try TemporaryDirectory()
    let fixtureKey = Fixtures.url("claude-sessions/\(registryKeyFixtureName)")
    try FileManager.default.copyItem(at: fixtureKey, to: directory.file(registryKeyFixtureName))
    try FileManager.default.copyItem(at: fixtureKey, to: directory.file("456.json.key"))
    try writeRegistryEntry(in: directory.url, pid: 123)
    try writeRegistryEntry(in: directory.url, pid: 456, ["status": "idle"])
    let probe = RegistryFakeProbe()
    probe.setAlive(123, startedAt: try registryTemplateStart())
    probe.setAlive(456, startedAt: try registryTemplateStart())
    let spy = FileAccessSpy()
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: spy, processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    for _ in 0..<3 { feed.sweepNow() }

    try expect(recorder.lastRows.map(\.processIDs), equals: [[123], [456]], "both .json entries become rows")
    try expectTrue(spy.listedDirectories.count >= 4, "every sweep lists the directory")
    try expectTrue(!spy.readPaths.isEmpty, "the spy saw the reads")
    try expectTrue(spy.readPaths.allSatisfy { !$0.hasSuffix(".key") }, "no path ending in .key was ever read")
    try expectTrue(spy.readPaths.allSatisfy { RegistryPathFilter.accepts(fileName: URL(fileURLWithPath: $0).lastPathComponent) },
                   "every read path passes the filter")
    try expect(Set(spy.readPaths.map { URL(fileURLWithPath: $0).lastPathComponent }), equals: ["123.json", "456.json"],
               "only the two registry entries were read")
}

@MainActor
func testRegistryFeedKeepsPreviousEntryWhenAReadFails() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(777, startedAt: try registryTemplateStart())
    probe.setAlive(778, startedAt: try registryTemplateStart())
    try writeRegistryEntry(in: directory.url, pid: 777, ["status": "busy"])
    let spy = FileAccessSpy()
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: spy, processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.lastRows.map(\.state), equals: [.working], "busy row exists")
    let busyRows = recorder.lastRows
    let publishCount = recorder.published.count

    try writeRegistryEntry(in: directory.url, pid: 777, ["status": "idle"])
    spy.failNextReads = ["777.json"]
    feed.sweepNow()
    try expect(recorder.published.count, equals: publishCount, "a failed read publishes nothing new")
    try expect(recorder.lastRows, equals: busyRows, "the row and its state are unchanged; no doneUnseen appears")
    try expect(spy.failNextReads, equals: [], "the injected failure was consumed")
    feed.sweepNow()
    try expect(recorder.lastRows.map(\.state), equals: [.doneUnseen], "the next sweep reads normally and sees busy → idle")

    try writeRegistryEntry(in: directory.url, pid: 777, ["status": "busy"])
    feed.sweepNow()
    let workingRows = recorder.lastRows
    try expect(workingRows.map(\.state), equals: [.working], "busy again")
    try Data("{\"pid\": 777, \"sessionId\": ".utf8).write(to: directory.file("777.json"))
    feed.sweepNow()
    try expect(recorder.lastRows, equals: workingRows, "a half-written file (decode failure) keeps the previous entry")

    try writeRegistryEntry(in: directory.url, pid: 777, ["status": "idle"])
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: directory.file("777.json").path)
    feed.sweepNow()
    try expect(recorder.lastRows, equals: workingRows, "an insecure (group-writable) file keeps the previous entry")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.file("777.json").path)
    try Data("not json".utf8).write(to: directory.file("778.json"))
    feed.sweepNow()
    try expect(recorder.lastRows.map(\.processIDs), equals: [[777]], "a pid that never decoded produces no row")
    try expect(recorder.lastRows.map(\.state), equals: [.doneUnseen], "the readable file is picked up again")

    try FileManager.default.removeItem(at: directory.file("777.json"))
    feed.sweepNow()
    try expect(recorder.lastRows, equals: [], "a file absent from the listing removes its row")
}

@MainActor
func testRegistryFeedDropsDeadAndReusedPids() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(801, startedAt: try registryTemplateStart())
    probe.setAlive(802, startedAt: try registryTemplateStart().addingTimeInterval(600))
    try writeRegistryEntry(in: directory.url, pid: 801)
    try writeRegistryEntry(in: directory.url, pid: 802)
    try writeRegistryEntry(in: directory.url, pid: 803)
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.lastRows.map(\.processIDs), equals: [[801]], "reused pid 802 and dead pid 803 have no row")
    probe.setDead(801)
    feed.sweepNow()
    try expect(recorder.lastRows, equals: [], "a session whose process exits disappears on the next sweep")
}

@MainActor
func testRegistryFeedReportsMissingDirectoryAsInactive() throws {
    let parent = try TemporaryDirectory()
    let directory = parent.url.appendingPathComponent("sessions")
    let probe = RegistryFakeProbe()
    probe.setAlive(901, startedAt: try registryTemplateStart())
    let feed = ClaudeRegistryFeed(directory: directory, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 0.05)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.health, equals: [.inactive(reason: "registry dir missing")], "missing dir is inactive")
    try expectTrue(!(recorder.health.last?.showsWarning ?? true), "inactive shows no warning glyph")
    try expect(recorder.lastRows, equals: [], "no rows")

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeRegistryEntry(in: directory, pid: 901)
    try spinMainRunLoop(timeout: 3) { recorder.lastRows.count == 1 }
    try expect(recorder.health.last, equals: .online, "a directory created later comes online")
}

@MainActor
func testRegistryFeedReflectsFileChangesWithoutManualSweeps() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(1001, startedAt: try registryTemplateStart())
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.lastRows, equals: [], "empty directory")
    try expect(recorder.health, equals: [.online], "an existing directory is online")

    // sweepInterval is 3_600 s, so only the FSEvents stream (never the periodic timer) can make these
    // spins observe the change within the 3 s timeout below.
    try writeRegistryEntry(in: directory.url, pid: 1001, ["status": "busy"])
    try spinMainRunLoop(timeout: 3) { recorder.lastRows.map(\.state) == [.working] }
    try writeRegistryEntry(in: directory.url, pid: 1001, ["status": "waiting", "waitingFor": "permission prompt"])
    try spinMainRunLoop(timeout: 3) { recorder.lastRows.map(\.state) == [.waiting] }
    try expect(recorder.lastRows.first?.detail?.kind, equals: .permission, "the change carried its detail")
}

@MainActor
func testRegistryFeedSweepTimerAgesRowsWithTheClock() throws {
    let directory = try TemporaryDirectory()
    let clock = ManualWallClock()
    let probe = RegistryFakeProbe()
    probe.setAlive(1101, startedAt: try registryTemplateStart())
    try writeRegistryEntry(in: directory.url, pid: 1101, ["status": "busy", "statusUpdatedAt": registryMilliseconds(clock.now())])
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: clock, sweepInterval: 0.05)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.lastRows.map(\.state), equals: [.working], "fresh busy")
    clock.advance(by: 31 * 60)
    try spinMainRunLoop(timeout: 2) { recorder.lastRows.map(\.state) == [.stale] }
}

@MainActor
func testRegistryFeedJumpClearsTheSeenFlag() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(1201, startedAt: try registryTemplateStart())
    try writeRegistryEntry(in: directory.url, pid: 1201, ["status": "busy"])
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try writeRegistryEntry(in: directory.url, pid: 1201, ["status": "idle"])
    feed.sweepNow()
    guard let row = recorder.lastRows.first, row.state == .doneUnseen else {
        throw TestFailure.expectation("busy → idle must publish doneUnseen, got \(recorder.lastRows.map(\.state))")
    }
    feed.loadDetail(for: row)
    feed.sweepNow()
    try expect(recorder.lastRows.map(\.state), equals: [.doneUnseen], "loadDetail never marks seen")

    Task { @MainActor in
        try await feed.jump(row)
        recorder.jumped = true
    }
    try spinMainRunLoop(timeout: 2) { recorder.jumped }
    try expect(recorder.lastRows.map(\.state), equals: [.idle], "jump(row) clears doneUnseen and republishes")
    feed.sweepNow()
    try expect(recorder.lastRows.map(\.state), equals: [.idle], "a later sweep does not resurrect it")
}

@MainActor
func testRegistryFeedStopHaltsTimerAndEvents() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(1301, startedAt: try registryTemplateStart())
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 0.05)
    let recorder = RegistryFeedRecorder()
    try startRegistryFeed(feed, recorder)
    feed.stop()
    feed.stop()
    let count = recorder.published.count
    try writeRegistryEntry(in: directory.url, pid: 1301)
    _ = try? spinMainRunLoop(timeout: 0.5) { false }
    try expect(recorder.published.count, equals: count, "nothing is published after stop()")
}

@MainActor
func testRegistryFeedPublishesRemoteControlSessionsFromDisk() throws {
    let directory = try TemporaryDirectory()
    let probe = RegistryFakeProbe()
    probe.setAlive(1401, startedAt: try registryTemplateStart())
    probe.setAlive(1402, startedAt: try registryTemplateStart())
    probe.setAlive(1403, startedAt: try registryTemplateStart())
    try writeRegistryEntry(in: directory.url, pid: 1401, ["entrypoint": "sdk-cli", "bridgeSessionId": registryBridgeSessionID,
                                                          "status": "waiting", "waitingFor": "input needed"])
    try writeRegistryEntry(in: directory.url, pid: 1402, ["entrypoint": "sdk-cli"])
    try writeRegistryEntry(in: directory.url, pid: 1403, ["entrypoint": "cli"])
    let feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
    let recorder = RegistryFeedRecorder()
    defer { feed.stop() }
    try startRegistryFeed(feed, recorder)
    try expect(recorder.lastRows.map(\.processIDs), equals: [[1401], [1403]],
               "the bridged sdk-cli session is published; the bridgeless sdk-cli one is not")
    try expect(recorder.lastRows.map(\.jump), equals: [
        .claudeRemoteControl(bridgeSessionID: registryBridgeSessionID),
        .terminal(tmuxTarget: nil),
    ], "the bridged row jumps by bridge id; the cli row stays in the terminal")
    try expect(recorder.lastRows.first?.state, equals: .waiting, "a Remote Control session waiting for input is waiting")
}

private let registryClaudeAppPath = "/Applications/Claude.app"

/// A Remote Control session in a real registry feed, wired into a StateStore the way the app wires it: board rows
/// and peek cards both click through `StateStore.focus`.
@MainActor
private final class RegistryRemoteControlScene {
    let directory: TemporaryDirectory
    let feed: ClaudeRegistryFeed
    let performer: RecordingJumpPerformer
    let store: StateStore

    init(context: JumpContext) throws {
        directory = try TemporaryDirectory()
        let probe = RegistryFakeProbe()
        probe.setAlive(1501, startedAt: try registryTemplateStart())
        feed = ClaudeRegistryFeed(directory: directory.url, fileReader: LiveFileReader(), processProbe: probe,
                                  clock: ManualWallClock(), sweepInterval: 3_600)
        performer = RecordingJumpPerformer()
        store = StateStore(feeds: [feed], clock: ManualWallClock(), focusProvider: FakeFocusContextProvider(),
                           jumpPerformer: performer, jumpContextProvider: StaticJumpContextProvider(context),
                           deadlineScheduler: .manual)
        try writeSession(status: "busy")
    }

    /// Starts the store, then lets the session finish a turn (busy → idle). Returns its doneUnseen row.
    func startWithAFinishedTurn() throws -> AgentRow {
        store.start()
        try spinMainRunLoop(timeout: 2) { self.store.rows.map(\.state) == [.working] }
        try writeSession(status: "idle")
        feed.sweepNow()
        guard let row = store.rows.first, store.rows.count == 1, row.state == .doneUnseen else {
            throw TestFailure.expectation("busy → idle must leave one doneUnseen row, got \(store.rows.map(\.state))")
        }
        return row
    }

    private func writeSession(status: String) throws {
        try writeRegistryEntry(in: directory.url, pid: 1501,
                               ["entrypoint": "sdk-cli", "bridgeSessionId": registryBridgeSessionID, "status": status])
    }
}

@MainActor
private final class RegistryFocusOutcome {
    var finished = false
    var error: Error?
}

/// Runs `store.focus(id)` as the UI does (a main-actor Task) and spins the main run loop until it settles.
@MainActor
private func runRegistryFocus(_ store: StateStore, _ id: RowID) throws -> Error? {
    let outcome = RegistryFocusOutcome()
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

@MainActor
func testRegistryRemoteControlClickOpensItsClaudeConversation() throws {
    let scene = try RegistryRemoteControlScene(context: JumpContext(claudeAppPath: registryClaudeAppPath))
    defer { scene.store.stop() }
    let row = try scene.startWithAFinishedTurn()
    let open = JumpAction.openURL("claude://claude.ai/epitaxy/session_01FixtureBridge000000001",
                                  appPath: registryClaudeAppPath, onlyIfPreviousFailed: false)
    try expect(scene.store.plannedJumps(), equals: [row.id: [open]], "the planned jump, as the state dump shows it")
    let error = try runRegistryFocus(scene.store, row.id)
    try expectTrue(error == nil, "the click succeeds (\(String(describing: error)))")
    try expect(scene.performer.performedLog, equals: [[open]], "a board or card click runs exactly that one action")
    try expect(scene.store.rows.map(\.state), equals: [.idle], "the click marks the finished turn seen")
}

@MainActor
func testRegistryRemoteControlClickWithoutClaudeRunningFailsVisibly() throws {
    let scene = try RegistryRemoteControlScene(context: JumpContext())
    defer { scene.store.stop() }
    let row = try scene.startWithAFinishedTurn()
    try expect(scene.store.plannedJumps(), equals: [row.id: []], "nothing to plan without the running Claude app")
    let error = try runRegistryFocus(scene.store, row.id)
    try expect(error as? JumpError, equals: .noActions, "the click fails with the existing could-not-jump error")
    try expect(scene.performer.performedLog, equals: [], "no Terminal, Ghostty or generic Claude fallback runs")
    try expect(scene.store.rows.map(\.state), equals: [.doneUnseen], "a failed click leaves the turn unseen")
}

/// Opt-in, read-only check against the real registry: CLAUDE_REGISTRY_CONTRACT=1. Prints counts only, never
/// names, paths or ids. Proves the real procStart format still matches LiveProcessProbe start times.
@MainActor
func testRegistryLiveRegistrySmoke() throws {
    guard ProcessInfo.processInfo.environment["CLAUDE_REGISTRY_CONTRACT"] == "1" else {
        throw TestSkipped(reason: "set CLAUDE_REGISTRY_CONTRACT=1 to read the real ~/.claude/sessions (read-only)")
    }
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    let spy = FileAccessSpy()
    let names = (try? spy.fileNames(in: directory)) ?? []
    let probe = LiveProcessProbe()
    var existing = 0
    var live = 0
    for name in names where RegistryPathFilter.accepts(fileName: name) {
        guard let data = try? spy.read(directory.appendingPathComponent(name), maximumSize: 262_144),
              let entry = RegistryEntry.decode(data) else { continue }
        if probe.exists(entry.pid) { existing += 1 }
        if RegistryLiveness.isLive(entry, probe: probe) { live += 1 }
    }
    print("registry smoke: \(names.count) names, \(spy.readPaths.count) reads, \(existing) existing pids, \(live) live")
    try expectTrue(spy.readPaths.allSatisfy { !$0.hasSuffix(".key") }, "no .key file was read")
    try expectTrue(existing == 0 || live > 0, "existing pids must be live; procStart format or time zone changed")
}

let claudeRegistryTests: [TestCase] = [
    ("registry: path filter accepts only <digits>.json", testRegistryPathFilterAcceptsOnlyDigitsDotJSON),
    ("registry: entry decodes the live-shaped template", testRegistryEntryDecodesTheLiveShapedTemplate),
    ("registry: entry decoding tolerates odd optional fields", testRegistryEntryDecodingIsTolerantOfOptionalFields),
    ("registry: rowKey collapses procStart whitespace", testRegistryRowKeyCollapsesProcStartWhitespace),
    ("registry: remote control bridge id decodes the live shape", testRegistryEntryDecodesTheRemoteControlBridgeSessionID),
    ("registry: remote control malformed bridge ids decode as nil", testRegistryEntryDecodesMalformedBridgeSessionIDsAsNil),
    ("registry: parseProcStart reads ps lstart text", testRegistryParseProcStartReadsLstartText),
    ("registry: parseProcStart rejects malformed text", testRegistryParseProcStartRejectsMalformedText),
    ("registry: liveness needs existence and a matching start", testRegistryLivenessRequiresExistenceAndMatchingStart),
    ("registry: liveness accepts the runner's own process", testRegistryLivenessAcceptsTheRunnersOwnProcess),
    ("registry: live probe rejects dead and invalid pids", testRegistryLiveProcessProbeRejectsDeadAndInvalidPids),
    ("registry: reducer drops non-interactive and sdk-* entries", testRegistryReducerFiltersNonInteractiveAndSDKEntrypoints),
    ("registry: old completion cannot clear a new completion", testRegistryReducerOldCompletionCannotClearNewCompletion),
    ("registry: busy is working, stale after 30 min", testRegistryReducerMapsBusyToWorkingAndAgesToStale),
    ("registry: waitingFor maps to the detail kind", testRegistryReducerMapsWaitingForToDetailKind),
    ("registry: busy then idle is doneUnseen until seen", testRegistryReducerMarksBusyToIdleDoneUnseenUntilSeen),
    ("registry: doneUnseen clears on next busy and after 12 h", testRegistryReducerClearsDoneUnseenOnNextBusyAndAfterTwelveHours),
    ("registry: idle, shell and unknown statuses are idle", testRegistryReducerMapsIdleAndShellToIdle),
    ("registry: row carries identity and source fields", testRegistryReducerRowCarriesIdentityAndSourceFields),
    ("registry: jump targets follow entrypoint and tmux", testRegistryReducerChoosesJumpTargets),
    ("registry: RowMerger drops a row whose pid Herdr owns", testRegistryRowIsDroppedWhenHerdrOwnsItsPid),
    ("registry: remote control sdk-cli entries with a bridge id are rows", testRegistryReducerKeepsInteractiveSDKCLIEntriesWithABridgeID),
    ("registry: remote control rows jump by bridge id; cli and desktop unchanged", testRegistryReducerRoutesRemoteControlRowsByBridgeID),
    ("registry: remote control waiting row peeks unless Claude is frontmost", testRegistryRemoteControlWaitingRowPeeksUnlessClaudeIsFrontmost),
    ("registry: feed never reads .key files", testRegistryFeedNeverReadsKeyFiles),
    ("registry: failed reads keep the previous entry", testRegistryFeedKeepsPreviousEntryWhenAReadFails),
    ("registry: dead and reused pids have no row", testRegistryFeedDropsDeadAndReusedPids),
    ("registry: missing directory is inactive, then online", testRegistryFeedReportsMissingDirectoryAsInactive),
    ("registry: file changes arrive without sweepNow", testRegistryFeedReflectsFileChangesWithoutManualSweeps),
    ("registry: sweep timer ages rows with the clock", testRegistryFeedSweepTimerAgesRowsWithTheClock),
    ("registry: jump clears the seen flag", testRegistryFeedJumpClearsTheSeenFlag),
    ("registry: stop halts the timer and events", testRegistryFeedStopHaltsTimerAndEvents),
    ("registry: remote control feed publishes bridged sessions from disk", testRegistryFeedPublishesRemoteControlSessionsFromDisk),
    ("registry: remote control click opens its Claude conversation", testRegistryRemoteControlClickOpensItsClaudeConversation),
    ("registry: remote control click without Claude running fails visibly", testRegistryRemoteControlClickWithoutClaudeRunningFailsVisibly),
    ("registry: live registry smoke (opt-in)", testRegistryLiveRegistrySmoke),
]

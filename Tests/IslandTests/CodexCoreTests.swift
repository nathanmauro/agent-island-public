import Foundation
import IslandCore
import IslandTestSupport

// MARK: - Shared helpers

private let codexCoreStart = Date(timeIntervalSince1970: 1_790_000_000)

private func codexCoreAt(_ seconds: TimeInterval) -> Date {
    codexCoreStart.addingTimeInterval(seconds)
}

private func codexCoreRecord(_ line: String) -> CodexRolloutRecord? {
    CodexRolloutParser.parse(line: Data(line.utf8))
}

private func codexCoreMeta(_ line: String) throws -> CodexSessionMeta {
    guard case .sessionMeta(let meta)? = codexCoreRecord(line) else {
        throw TestFailure.expectation("expected a session_meta record")
    }
    return meta
}

// MARK: - Parser

func testCodexCoreParserMapsSessionAndTurnEvents() throws {
    let id = "0199f000-0000-7000-8000-000000000101"
    let records = [
        RolloutLine.sessionMeta(id: id, cwd: "/tmp/codex-project", at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.filler(approximateBytes: 300, at: codexCoreAt(2)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexCoreAt(3)),
    ].compactMap(codexCoreRecord)

    try expect(records.count, equals: 3, "session_meta, task_started and task_complete map; the filler line does not")
    guard case .sessionMeta(let meta) = records[0] else {
        throw TestFailure.expectation("first record is session_meta")
    }
    try expect(meta.id, equals: id, "session id")
    try expect(meta.cwd, equals: "/tmp/codex-project", "cwd")
    try expect(meta.originator, equals: "Codex Desktop", "originator")
    try expect(meta.threadSource, equals: "user", "thread_source")
    try expect(meta.startedAt, equals: codexCoreAt(0), "startedAt comes from payload.timestamp")
    try expect(records[1], equals: .taskStarted(turnID: "turn-1", at: codexCoreAt(1)), "task_started")
    try expect(records[2], equals: .taskComplete(turnID: "turn-1", lastAgentMessage: "Fixture recap.", at: codexCoreAt(3)),
               "task_complete carries last_agent_message")
}

func testCodexCoreParserIgnoresMalformedAndUnknownLines() throws {
    let ignored = [
        "not-json",
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"future_event","payload":{}}"#,
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"event_msg","payload":{"type":"token_count"}}"#,
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"cwd":"/tmp/project"}}"#,
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t"#,
        RolloutLine.functionCall(name: "js", callID: "call-js", question: "Unused?", options: [], at: codexCoreAt(0)),
    ]
    for (index, line) in ignored.enumerated() {
        try expect(codexCoreRecord(line) == nil, equals: true, "ignored line #\(index)")
    }
    var invalidUTF8 = Data([0xC3, 0x28, 0xFF])
    invalidUTF8.append(Data(#""task_started""#.utf8))
    try expect(CodexRolloutParser.parse(line: invalidUTF8) == nil, equals: true, "invalid UTF-8 is skipped")

    let badTimestamp = #"{"timestamp":"not-a-date","type":"session_meta","payload":{"id":"invalid-time","cwd":"/tmp/project"}}"#
    let meta = try codexCoreMeta(badTimestamp)
    try expect(meta.id, equals: "invalid-time", "an unparseable timestamp keeps the record")
    try expect(meta.startedAt == nil, equals: true, "an unparseable timestamp gives a nil date")
}

func testCodexCoreSourceDecodesStringAndObject() throws {
    let named = try codexCoreMeta(RolloutLine.sessionMeta(id: "s1", sourceJSON: #""vscode""#, at: codexCoreAt(0)))
    try expect(named.source, equals: .named("vscode"), "a string source")
    let subagent = try codexCoreMeta(RolloutLine.sessionMeta(
        id: "s2", sourceJSON: #"{"subagent":{"kind":"fixture"}}"#, at: codexCoreAt(0)))
    try expect(subagent.source, equals: .subagent, "an object with a subagent key")
    let object = try codexCoreMeta(RolloutLine.sessionMeta(
        id: "s3", sourceJSON: #"{"zeta":1,"alpha":"x"}"#, at: codexCoreAt(0)))
    try expect(object.source, equals: .object(keys: ["alpha", "zeta"]), "any other object keeps its sorted keys")
    let null = try codexCoreMeta(RolloutLine.sessionMeta(id: "s4", sourceJSON: "null", at: codexCoreAt(0)))
    try expect(null.source, equals: .missing, "a null source")
    let number = try codexCoreMeta(RolloutLine.sessionMeta(id: "s5", sourceJSON: "42", at: codexCoreAt(0)))
    try expect(number.source, equals: .object(keys: []), "an unexpected shape never drops the meta line")
    let absent = try codexCoreMeta(
        #"{"timestamp":"2026-09-21T12:53:20.000Z","type":"session_meta","payload":{"id":"s6","cwd":"/tmp/fixture-project"}}"#)
    try expect(absent.source, equals: .missing, "an absent source")
    try expect(absent.threadSource == nil, equals: true, "an absent thread_source")
}

func testCodexCoreParserFunctionCallsAndOutputs() throws {
    let line = RolloutLine.functionCall(name: "request_user_input", callID: "call-1", question: "Fixture question?",
                                        options: ["Option A", "Option B"], at: codexCoreAt(5))
    guard case .functionCall(let name, let callID, let arguments, let at)? = codexCoreRecord(line) else {
        throw TestFailure.expectation("expected a function_call record")
    }
    try expect(name, equals: "request_user_input", "name")
    try expect(callID, equals: "call-1", "call_id")
    try expect(at, equals: codexCoreAt(5), "timestamp")
    let question = CodexRolloutParser.question(fromArguments: arguments)
    try expect(question?.question, equals: "Fixture question?", "arguments carry the question")
    try expect(question?.options ?? [], equals: ["Option A", "Option B"], "arguments carry the option labels")

    let asyncLine = RolloutLine.functionCall(name: "request_user_input_async", callID: "call-2",
                                             question: "Fixture async question?", options: [], at: codexCoreAt(6))
    guard case .functionCall(let asyncName, let asyncCallID, _, _)? = codexCoreRecord(asyncLine) else {
        throw TestFailure.expectation("expected an async function_call record")
    }
    try expect(asyncName, equals: "request_user_input_async", "async name")
    try expect(asyncCallID, equals: "call-2", "async call_id")

    try expect(codexCoreRecord(RolloutLine.functionCallOutput(callID: "call-1", at: codexCoreAt(7))),
               equals: .functionCallOutput(callID: "call-1", at: codexCoreAt(7)), "function_call_output carries call_id")
}

func testCodexCoreQuestionReadsFirstQuestionAndFourLabels() throws {
    let arguments = #"{"questions":[{"header":"H","id":"q1","question":"First fixture question?","options":[{"label":"One"},{"label":"Two"},{"label":"Three"},{"label":"Four"},{"label":"Five"},{"label":"Six"}]},{"question":"Second fixture question?"}]}"#
    let question = CodexRolloutParser.question(fromArguments: arguments)
    try expect(question?.question, equals: "First fixture question?", "questions[0].question")
    try expect(question?.options ?? [], equals: ["One", "Two", "Three", "Four"], "at most 4 labels")
    try expect(CodexRolloutParser.question(fromArguments: "not json") == nil, equals: true, "malformed arguments")
    try expect(CodexRolloutParser.question(fromArguments: #"{"questions":[]}"#) == nil, equals: true, "no questions")
}

func testCodexCoreParserErrorsAndAborts() throws {
    try expect(codexCoreRecord(RolloutLine.errorEvent(message: "Fixture error.", at: codexCoreAt(1))),
               equals: .error(message: "Fixture error.", at: codexCoreAt(1)), "error event")
    try expect(codexCoreRecord(RolloutLine.errorEvent(type: "stream_error", message: "Fixture stream error.", at: codexCoreAt(2))),
               equals: .error(message: "Fixture stream error.", at: codexCoreAt(2)), "stream_error event")
    try expect(codexCoreRecord(RolloutLine.turnAborted(turnID: "turn-1", at: codexCoreAt(3))),
               equals: .turnAborted(turnID: "turn-1", reason: "interrupted", at: codexCoreAt(3)), "turn_aborted")
}

/// Fix round 1, Finding 3: real request_user_input_async arguments use `title` (not `question`)
/// and options as a plain array of strings (or absent), not `[{label}]` objects.
func testCodexCoreQuestionDecodesRealAsyncShapeWithTitleAndStringOptions() throws {
    let arguments = #"{"questions":[{"title":"Fixture async title?","options":["Yes","No","Maybe","Later","Never"]}]}"#
    let question = CodexRolloutParser.question(fromArguments: arguments)
    try expect(question?.question, equals: "Fixture async title?", "falls back to title when question is absent")
    try expect(question?.options ?? [], equals: ["Yes", "No", "Maybe", "Later"], "string options, capped at 4")

    let noOptions = #"{"questions":[{"title":"Fixture title with no options?"}]}"#
    try expect(CodexRolloutParser.question(fromArguments: noOptions)?.options ?? [], equals: [],
               "absent options is empty, not nil")

    let questionWins = #"{"questions":[{"question":"Exact question wins?","title":"Ignored title?"}]}"#
    try expect(CodexRolloutParser.question(fromArguments: questionWins)?.question, equals: "Exact question wins?",
               "question, when present, still wins over title")
}

/// Fix round 1, Finding 2: a task_complete carrying a non-null `error` object is a failed turn,
/// not a silent doneUnseen. These event names were not observed in any real rollout, unlike the
/// inferred event_msg `error`/`stream_error` names below, which the parser also still recognizes.
func testCodexCoreParserTaskCompleteWithErrorProducesTaskFailed() throws {
    let withMessage = RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                                      message: "Fixture usage limit message.", at: codexCoreAt(1))
    try expect(codexCoreRecord(withMessage),
               equals: .taskFailed(turnID: "turn-1", at: codexCoreAt(1), message: "Fixture usage limit message."),
               "task_complete with a non-null error becomes taskFailed")

    let withoutMessage = RolloutLine.taskCompleteFailed(turnID: "turn-2", codexErrorInfo: "context_window_exceeded",
                                                         message: nil, at: codexCoreAt(2))
    try expect(codexCoreRecord(withoutMessage),
               equals: .taskFailed(turnID: "turn-2", at: codexCoreAt(2), message: "Codex turn failed: context_window_exceeded"),
               "a missing message falls back to codex_error_info")

    let ordinaryComplete = RolloutLine.taskComplete(turnID: "turn-3", message: "Fixture recap.", at: codexCoreAt(3))
    try expect(codexCoreRecord(ordinaryComplete),
               equals: .taskComplete(turnID: "turn-3", lastAgentMessage: "Fixture recap.", at: codexCoreAt(3)),
               "a task_complete with no error is unaffected")
}

private let codexCoreParserCases: [TestCase] = [
    ("codexCore: parser maps session and turn events", testCodexCoreParserMapsSessionAndTurnEvents),
    ("codexCore: parser ignores malformed and unknown lines", testCodexCoreParserIgnoresMalformedAndUnknownLines),
    ("codexCore: source decodes from a string and from an object", testCodexCoreSourceDecodesStringAndObject),
    ("codexCore: function_call carries name, call_id and arguments", testCodexCoreParserFunctionCallsAndOutputs),
    ("codexCore: question reads questions[0] and at most 4 labels", testCodexCoreQuestionReadsFirstQuestionAndFourLabels),
    ("codexCore: parser maps error, stream_error and turn_aborted", testCodexCoreParserErrorsAndAborts),
    ("codexCore: question decodes the real async shape (title, string options)", testCodexCoreQuestionDecodesRealAsyncShapeWithTitleAndStringOptions),
    ("codexCore: task_complete with a non-null error becomes taskFailed", testCodexCoreParserTaskCompleteWithErrorProducesTaskFailed),
]

// MARK: - Filters and session index

private func codexCoreFilterMeta(sourceJSON: String = #""vscode""#, originator: String = "Codex Desktop",
                                 threadSource: String? = "user") throws -> CodexSessionMeta {
    try codexCoreMeta(RolloutLine.sessionMeta(id: "filter-thread", originator: originator, sourceJSON: sourceJSON,
                                              threadSource: threadSource, at: codexCoreAt(0)))
}

func testCodexCoreFilterHidesGuardianSubagentChromeAndNil() throws {
    let hidden: [(String, CodexSessionMeta?)] = [
        ("guardian_review thread_source", try codexCoreFilterMeta(threadSource: "guardian_review")),
        ("subagent thread_source", try codexCoreFilterMeta(threadSource: "subagent")),
        ("subagent source object", try codexCoreFilterMeta(sourceJSON: #"{"subagent":{"kind":"fixture"}}"#)),
        ("chrome originator", try codexCoreFilterMeta(originator: "Codex Chrome Extension")),
        ("nil meta", nil),
    ]
    for (label, meta) in hidden {
        try expect(CodexThreadFilter.isVisible(meta, showExec: true), equals: false, "hidden: \(label)")
    }
}

func testCodexCoreFilterShowsExecOnlyWithSetting() throws {
    let byOriginator = try codexCoreFilterMeta(originator: "codex_exec")
    let bySource = try codexCoreFilterMeta(sourceJSON: #""exec""#)
    try expect(CodexThreadFilter.isVisible(byOriginator, showExec: false), equals: false, "codex_exec hidden by default")
    try expect(CodexThreadFilter.isVisible(bySource, showExec: false), equals: false, "source exec hidden by default")
    try expect(CodexThreadFilter.isVisible(byOriginator, showExec: true), equals: true, "codex_exec shown with the setting")
    try expect(CodexThreadFilter.isVisible(bySource, showExec: true), equals: true, "source exec shown with the setting")
}

func testCodexCoreFilterKeepsUserFacingThreadSources() throws {
    let visible: [String?] = ["user", "agent_created_thread", "voice_chat", "automation", "realtime_voice", nil]
    for threadSource in visible {
        let meta = try codexCoreFilterMeta(threadSource: threadSource)
        try expect(CodexThreadFilter.isVisible(meta, showExec: false), equals: true,
                   "visible: \(threadSource ?? "missing thread_source")")
    }
}

func testCodexCoreSessionIndexLastLineWins() throws {
    let text = [
        #"{"id":"thread-a","thread_name":"First name","updated_at":"2026-09-21T10:00:00.000Z"}"#,
        "garbage",
        #"{"id":"thread-b","thread_name":"   ","updated_at":"2026-09-21T10:00:01.000Z"}"#,
        #"{"id":"thread-a","thread_name":"Renamed","updated_at":"2026-09-21T10:00:02.000Z"}"#,
        #"{"id":"thread-c","thread_name":"Third"}"#,
    ].joined(separator: "\n")
    try expect(CodexSessionIndex.parse(Data(text.utf8)), equals: ["thread-a": "Renamed", "thread-c": "Third"],
               "last line wins; blank names and malformed lines are skipped")
}

private let codexCoreFilterCases: [TestCase] = [
    ("codexCore: filter hides guardian, subagent, chrome and nil meta", testCodexCoreFilterHidesGuardianSubagentChromeAndNil),
    ("codexCore: filter shows exec only with the setting", testCodexCoreFilterShowsExecOnlyWithSetting),
    ("codexCore: filter keeps user-facing thread sources", testCodexCoreFilterKeepsUserFacingThreadSources),
    ("codexCore: session index last line wins", testCodexCoreSessionIndexLastLineWins),
]

// MARK: - Seen store (hardening 5)

func testCodexCoreSeenStoreLoadOfMissingFileIsNil() throws {
    let directory = try TemporaryDirectory(prefix: "codex-seen")
    try expect(CodexSeenStore.load(from: directory.file("codex-seen.json")) == nil, equals: true,
               "a missing file means first launch")
}

func testCodexCoreSeenStoreRoundTripsFlatJSONWithMode0600() throws {
    let directory = try TemporaryDirectory(prefix: "codex-seen")
    let url = directory.url.appendingPathComponent("support", isDirectory: true).appendingPathComponent("codex-seen.json")
    var store = CodexSeenStore()
    store.markSeen(threadID: "thread-a", turnID: "turn-2")
    store.markSeen(threadID: "thread-b", turnID: "turn-7")
    try store.save(to: url)

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
    try expect(object ?? [:], equals: ["thread-a": "turn-2", "thread-b": "turn-7"], "file shape is {threadId: turnId}")
    let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    try expect(mode, equals: 0o600, "file mode")
    try expect(CodexSeenStore.load(from: url), equals: store, "load after save round-trips")
}

/// Hardening 5: expiry is measured on the injected wall clock, with no replay of any line.
func testCodexCoreSeenStoreUnseenRulesUseWallClock() throws {
    let clock = ManualWallClock()
    let completedAt = clock.now()
    var store = CodexSeenStore()
    try expect(store.isUnseen(threadID: "t", turnID: nil, completedAt: completedAt, now: clock.now()), equals: false,
               "no completed turn is never unseen")
    try expect(store.isUnseen(threadID: "t", turnID: "turn-1", completedAt: completedAt, now: clock.now()), equals: true,
               "a fresh completion is unseen")
    clock.advance(by: IslandTiming.seenExpiry - 1)
    try expect(store.isUnseen(threadID: "t", turnID: "turn-1", completedAt: completedAt, now: clock.now()), equals: true,
               "still unseen just before 12 h")
    clock.advance(by: 1.001)
    try expect(store.isUnseen(threadID: "t", turnID: "turn-1", completedAt: completedAt, now: clock.now()), equals: false,
               "expired after 12 h + epsilon")
    clock.set(completedAt)
    store.markSeen(threadID: "t", turnID: "turn-1")
    try expect(store.isSeen(threadID: "t", turnID: "turn-1"), equals: true, "isSeen after markSeen")
    try expect(store.isUnseen(threadID: "t", turnID: "turn-1", completedAt: completedAt, now: clock.now()), equals: false,
               "not unseen after markSeen")
    try expect(store.isUnseen(threadID: "t", turnID: "turn-2", completedAt: completedAt, now: clock.now()), equals: true,
               "a newer turn of the same thread is unseen")
}

private let codexCoreSeenCases: [TestCase] = [
    ("codexCore: seen store load of a missing file is nil", testCodexCoreSeenStoreLoadOfMissingFileIsNil),
    ("codexCore: seen store round-trips flat JSON with mode 0600", testCodexCoreSeenStoreRoundTripsFlatJSONWithMode0600),
    ("codexCore: seen expiry uses the wall clock (hardening 5)", testCodexCoreSeenStoreUnseenRulesUseWallClock),
]

// MARK: - Reducer

private func codexCoreLines(_ lines: [String]) -> [Data] {
    lines.map { Data($0.utf8) }
}

private let codexCoreFileThreadID = "0199f000-0000-7000-8000-00000000aaaa"
private let codexCoreFile = CodexRolloutFile(
    path: "/tmp/fixture-sessions/2026/09/21/rollout-2026-09-21T12-53-20-\(codexCoreFileThreadID).jsonl"
)

/// A rollout file named for `id`, matching how Codex actually names a thread's own file. Fix
/// round 1, Finding 1: thread identity is anchored to the file name, so a reducer test whose
/// session id doesn't match its file's embedded UUID would be hidden (the meta would never be
/// applied to the thread the file resolves to).
private func codexCoreFile(forThreadID id: String) -> CodexRolloutFile {
    CodexRolloutFile(path: "/tmp/fixture-sessions/2026/09/21/rollout-2026-09-21T12-53-20-\(id).jsonl")
}

private func codexCoreRows(_ reducer: CodexReducer, seen: CodexSeenStore = CodexSeenStore(),
                           titles: [String: String] = [:], showExec: Bool = false,
                           codexRunning: Bool = true, now: Date) -> [AgentRow] {
    CodexReducer.rows(threads: Array(reducer.threads.values), seen: seen, titles: titles,
                      showExec: showExec, codexRunning: codexRunning, now: now)
}

func testCodexCorePairingWorkingThenDoneUnseen() throws {
    let id = "0199f000-0000-7000-8000-000000000201"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(10)),
    ]), file: file)
    var rows = codexCoreRows(reducer, now: codexCoreAt(20))
    try expect(rows.map(\.state), equals: [.working], "task_started → working")
    try expect(rows[0].id, equals: RowID(source: .codexDesktop, key: id), "row id is the thread id")
    try expect(rows[0].jump, equals: .codexThread(id: id), "jump target is the session_meta id")
    try expect(rows[0].title, equals: "fixture-project", "title falls back to the cwd basename")
    try expect(rows[0].cwd, equals: "/tmp/fixture-project", "cwd")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskComplete(turnID: "turn-9", message: "Wrong turn.", at: codexCoreAt(30)),
    ]), file: file)
    rows = codexCoreRows(reducer, now: codexCoreAt(35))
    try expect(rows.map(\.state), equals: [.working], "a mismatched turn_id is ignored")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexCoreAt(40)),
    ]), file: file)
    rows = codexCoreRows(reducer, now: codexCoreAt(50))
    try expect(rows.map(\.state), equals: [.doneUnseen], "task_complete → doneUnseen")
    try expect(rows[0].detail, equals: Detail(question: "Fixture recap.", kind: .recap), "recap equals last_agent_message")
    try expect(rows[0].since, equals: codexCoreAt(40), "since is the completion time")
}

func testCodexCoreExactWaitingWhileTurnOpen() throws {
    let id = "0199f000-0000-7000-8000-000000000202"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.functionCall(name: "request_user_input", callID: "call-1", question: "Fixture question?",
                                 options: ["Option A", "Option B"], at: codexCoreAt(2)),
    ]), file: file)
    var rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.waiting], "an open request_user_input wins over the open turn")
    try expect(rows[0].detail, equals: Detail(question: "Fixture question?", options: ["Option A", "Option B"], kind: .question),
               "question and options")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.functionCallOutput(callID: "call-1", at: codexCoreAt(3)),
    ]), file: file)
    rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.working], "the matching function_call_output clears waiting")
}

func testCodexCoreAsyncQuestionHeuristic() throws {
    let id = "0199f000-0000-7000-8000-000000000203"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.functionCall(name: "request_user_input_async", callID: "call-2", question: "Fixture async question?",
                                 options: ["Option A"], at: codexCoreAt(2)),
        RolloutLine.functionCallOutput(callID: "call-2", at: codexCoreAt(3)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexCoreAt(100)),
    ]), file: file)

    let rows = codexCoreRows(reducer, now: codexCoreAt(200))
    try expect(rows.map(\.state), equals: [.waiting], "completed turn with an _async call → waiting")
    try expect(rows[0].detail, equals: Detail(question: "Fixture async question?", options: ["Option A"], kind: .question),
               "async question detail")

    let expired = codexCoreRows(reducer, now: codexCoreAt(100 + IslandTiming.seenExpiry + 1))
    try expect(expired.map(\.state), equals: [.idle], "clears after 12 h")

    var seen = CodexSeenStore()
    seen.markSeen(threadID: id, turnID: "turn-1")
    try expect(codexCoreRows(reducer, seen: seen, now: codexCoreAt(200)).map(\.state), equals: [.idle], "clears on markSeen")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskStarted(turnID: "turn-2", at: codexCoreAt(300)),
    ]), file: file)
    try expect(codexCoreRows(reducer, now: codexCoreAt(310)).map(\.state), equals: [.working], "clears on the next task_started")
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskComplete(turnID: "turn-2", message: nil, at: codexCoreAt(320)),
    ]), file: file)
    try expect(codexCoreRows(reducer, now: codexCoreAt(330)).map(\.state), equals: [.doneUnseen],
               "a later turn without an _async call is plain done")
}

func testCodexCoreTurnAbortedIsIdle() throws {
    let id = "0199f000-0000-7000-8000-000000000204"
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-0", at: codexCoreAt(1)),
        RolloutLine.taskComplete(turnID: "turn-0", message: "Earlier recap.", at: codexCoreAt(2)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(3)),
        RolloutLine.turnAborted(turnID: "turn-1", at: codexCoreAt(4)),
    ]), file: codexCoreFile(forThreadID: id))
    let rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.idle], "turn_aborted → idle; the earlier completion was superseded")
    try expect(rows[0].detail == nil, equals: true, "no detail when idle")
}

/// Fix round 1, Finding 1 (hardening for the priority order, "over the cap" case): a large rollout
/// can be read up to a byte cap that lands mid-thread, so the first parsed meta in a batch is not
/// guaranteed to belong to this file's own thread. The file name is the anchor of thread identity;
/// a meta for a different id is parsed but never applied to this thread.
func testCodexCoreThreadKeyedByFileNameEvenWhenFirstMetaHasADifferentID() throws {
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: "0199f000-0000-7000-8000-000000000299", at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
    ]), file: codexCoreFile)
    try expect(reducer.threads[codexCoreFileThreadID]?.openTurnID, equals: "turn-1",
               "keyed by the file-name UUID even though the first meta's id differs")
    try expect(reducer.threads["0199f000-0000-7000-8000-000000000299"] == nil, equals: true,
               "no separate thread is created for the mismatched meta id")
    try expect(codexCoreRows(reducer, now: codexCoreAt(5)).isEmpty, equals: true,
               "hidden: a meta for a different id is never applied to this thread")
}

func testCodexCoreErrorUntilNextTaskStarted() throws {
    let id = "0199f000-0000-7000-8000-000000000205"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.functionCall(name: "request_user_input", callID: "call-1", question: "Fixture question?",
                                 options: [], at: codexCoreAt(2)),
        RolloutLine.errorEvent(message: "Fixture error.", at: codexCoreAt(3)),
    ]), file: file)
    var rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error], "error wins over waiting")
    try expect(rows[0].detail, equals: Detail(question: "Fixture error.", kind: .error), "error detail")
    try expect(rows[0].since, equals: codexCoreAt(3), "since is the error time")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskStarted(turnID: "turn-2", at: codexCoreAt(20)),
    ]), file: file)
    rows = codexCoreRows(reducer, now: codexCoreAt(30))
    try expect(rows.map(\.state), equals: [.working], "the next task_started clears the error")

    let streamID = "0199f000-0000-7000-8000-000000000206"
    var streamReducer = CodexReducer()
    _ = streamReducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: streamID, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.errorEvent(type: "stream_error", message: "Fixture stream error.", at: codexCoreAt(2)),
    ]), file: codexCoreFile(forThreadID: streamID))
    try expect(codexCoreRows(streamReducer, now: codexCoreAt(10)).map(\.state), equals: [.error], "stream_error → error")
}

func testCodexCoreWorkingBecomesStaleWhenCodexNotRunning() throws {
    let id = "0199f000-0000-7000-8000-000000000207"
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
    ]), file: codexCoreFile(forThreadID: id))
    try expect(codexCoreRows(reducer, codexRunning: false, now: codexCoreAt(10)).map(\.state), equals: [.stale],
               "working → stale when Codex is not running")
    try expect(codexCoreRows(reducer, codexRunning: true, now: codexCoreAt(10)).map(\.state), equals: [.working],
               "working while Codex runs")
}

/// Fix round 1, Finding 2: a failed task_complete (non-null `error`) puts the thread in error,
/// same as a plain event_msg error, and clears on the next task_started.
func testCodexCoreTaskFailedPutsThreadInErrorState() throws {
    let id = "0199f000-0000-7000-8000-000000000209"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: codexCoreAt(2)),
    ]), file: file)
    let rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error], "a failed task_complete puts the thread in error")
    try expect(rows[0].detail, equals: Detail(question: "Fixture usage limit message.", kind: .error),
               "the failure message is the error detail")
    try expect(rows[0].since, equals: codexCoreAt(2), "since is the failure time")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskStarted(turnID: "turn-2", at: codexCoreAt(20)),
    ]), file: file)
    try expect(codexCoreRows(reducer, now: codexCoreAt(30)).map(\.state), equals: [.working],
               "the next task_started clears the failure")
}

/// NEW RULING (Task 10): a failed turn is a closed turn, exactly like a completion — it clears to
/// idle once its turn id is marked seen, or once 12 h have passed, using the same
/// lastCompletedTurnID/lastCompletedAt/seen machinery a successful task_complete uses. This is
/// distinct from the standalone event_msg error/stream_error case (testCodexCoreErrorUntilNextTaskStarted),
/// which has no turn id and keeps its original "only the next task_started clears it" behavior.
func testCodexCoreTaskFailedClearsToIdleWhenSeen() throws {
    let id = "0199f000-0000-7000-8000-000000000210"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: codexCoreAt(2)),
    ]), file: file)
    var rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error], "unseen failure is an error row")

    let expired = codexCoreRows(reducer, now: codexCoreAt(2 + IslandTiming.seenExpiry + 1))
    try expect(expired.map(\.state), equals: [.idle], "a failed turn clears after 12 h, same as a completion")

    var seen = CodexSeenStore()
    seen.markSeen(threadID: id, turnID: "turn-1")
    rows = codexCoreRows(reducer, seen: seen, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.idle], "markSeen clears a failed turn's row to idle")
    try expect(rows[0].detail == nil, equals: true, "no detail once idle")
}

// Fix round 1 (Task 10 review): the `openTurnID != nil || completionUnseen` gate silenced a
// standalone error whenever no turn happened to be open and nothing tied it to an unseen closed
// turn — three regressions (A, B, C below), all previously `.error`. The fix adds an explicit
// `lastErrorTurnID`, set only by `.taskFailed`, and nil for every standalone `.error`/`.taskStarted`,
// so the gate (`lastErrorTurnID == nil || completionUnseen`) never depends on `openTurnID`.

/// Regression A: a standalone error before any turn has ever started.
func testCodexCoreStandaloneErrorBeforeAnyTurnStaysVisible() throws {
    let id = "0199f000-0000-7000-8000-000000000214"
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.errorEvent(message: "Fixture error before any turn.", at: codexCoreAt(1)),
    ]), file: codexCoreFile(forThreadID: id))
    let rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error], "a standalone error with no turn ever open is not silenced")
}

/// Regression B: a standalone error mid-turn, then the turn is aborted (which clears openTurnID
/// but must not clear the error).
func testCodexCoreStandaloneErrorSurvivesTurnAborted() throws {
    let id = "0199f000-0000-7000-8000-000000000215"
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.errorEvent(message: "Fixture mid-turn error.", at: codexCoreAt(2)),
        RolloutLine.turnAborted(turnID: "turn-1", at: codexCoreAt(3)),
    ]), file: codexCoreFile(forThreadID: id))
    let rows = codexCoreRows(reducer, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error], "turn_aborted clears openTurnID but must not silence the error")
}

/// Regression C: a standalone error arrives after an earlier completion that is already seen —
/// the error must never be silently dropped just because the unrelated prior completion is seen.
func testCodexCoreStandaloneErrorAfterASeenCompletionStaysVisible() throws {
    let id = "0199f000-0000-7000-8000-000000000216"
    let file = codexCoreFile(forThreadID: id)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: id, at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexCoreAt(2)),
    ]), file: file)
    var seen = CodexSeenStore()
    seen.markSeen(threadID: id, turnID: "turn-1")
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.errorEvent(message: "Fixture post-completion error.", at: codexCoreAt(3)),
    ]), file: file)
    let rows = codexCoreRows(reducer, seen: seen, now: codexCoreAt(10))
    try expect(rows.map(\.state), equals: [.error],
               "a standalone error is shown even though the earlier, unrelated completion is already seen")
}

func testCodexCoreThreadIDFromFileNameWhenMetaMissing() throws {
    try expect(codexCoreFile.threadIDFromFileName, equals: codexCoreFileThreadID, "UUID from rollout-<date>-<uuid>.jsonl")
    try expect(CodexRolloutFile(path: "/tmp/other.jsonl").threadIDFromFileName == nil, equals: true, "other names")

    var reducer = CodexReducer()
    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
    ]), file: codexCoreFile)
    try expect(reducer.threads[codexCoreFileThreadID]?.openTurnID, equals: "turn-1", "keyed by the file-name UUID")
    try expect(codexCoreRows(reducer, now: codexCoreAt(5)).isEmpty, equals: true, "hidden while meta is missing")

    _ = reducer.ingest(lines: codexCoreLines([
        RolloutLine.sessionMeta(id: codexCoreFileThreadID, at: codexCoreAt(0)),
    ]), file: codexCoreFile)
    try expect(codexCoreRows(reducer, now: codexCoreAt(5)).map(\.state), equals: [.working], "visible once meta arrives")
}

func testCodexCoreResetAndRemoveFileForgetThread() throws {
    var reducer = CodexReducer()
    let lines = codexCoreLines([
        RolloutLine.sessionMeta(id: "0199f000-0000-7000-8000-000000000208", at: codexCoreAt(0)),
        RolloutLine.taskStarted(turnID: "turn-1", at: codexCoreAt(1)),
    ])
    try expect(reducer.ingest(lines: lines, file: codexCoreFile).count, equals: 1, "one thread")
    reducer.resetFile(codexCoreFile)
    try expect(reducer.threads.isEmpty, equals: true, "resetFile forgets the thread")
    _ = reducer.ingest(lines: lines, file: codexCoreFile)
    reducer.removeFile(codexCoreFile)
    try expect(reducer.threads.isEmpty, equals: true, "removeFile forgets the thread")
}

private let codexCoreReducerCases: [TestCase] = [
    ("codexCore: task_started → working, task_complete → doneUnseen, mismatched turn ignored", testCodexCorePairingWorkingThenDoneUnseen),
    ("codexCore: open request_user_input → waiting until its output", testCodexCoreExactWaitingWhileTurnOpen),
    ("codexCore: _async heuristic waits and clears", testCodexCoreAsyncQuestionHeuristic),
    ("codexCore: turn_aborted → idle", testCodexCoreTurnAbortedIsIdle),
    ("codexCore: thread keyed by file name even when the first meta id differs (over the cap)", testCodexCoreThreadKeyedByFileNameEvenWhenFirstMetaHasADifferentID),
    ("codexCore: error and stream_error until the next task_started", testCodexCoreErrorUntilNextTaskStarted),
    ("codexCore: working → stale when Codex is not running", testCodexCoreWorkingBecomesStaleWhenCodexNotRunning),
    ("codexCore: a failed task_complete puts the thread in error", testCodexCoreTaskFailedPutsThreadInErrorState),
    ("codexCore: a failed turn clears to idle when seen or after 12 h (NEW RULING)", testCodexCoreTaskFailedClearsToIdleWhenSeen),
    ("codexCore: a standalone error before any turn stays visible (fix round 1, regression A)", testCodexCoreStandaloneErrorBeforeAnyTurnStaysVisible),
    ("codexCore: a standalone error survives turn_aborted (fix round 1, regression B)", testCodexCoreStandaloneErrorSurvivesTurnAborted),
    ("codexCore: a standalone error after a seen completion stays visible (fix round 1, regression C)", testCodexCoreStandaloneErrorAfterASeenCompletionStaysVisible),
    ("codexCore: thread id from the file name when meta is missing", testCodexCoreThreadIDFromFileNameWhenMetaMissing),
    ("codexCore: resetFile and removeFile forget the thread", testCodexCoreResetAndRemoveFileForgetThread),
]

// MARK: - Committed synthetic fixtures (Tests/Fixtures/codex)

private enum CodexFixtureCatalog {
    static func at(_ seconds: TimeInterval) -> Date { codexCoreAt(seconds) }

    static let turnCompleteID = "0199f000-0000-7000-8000-000000000001"
    static let questionOpenID = "0199f000-0000-7000-8000-000000000002"
    static let questionAnsweredID = "0199f000-0000-7000-8000-000000000003"
    static let asyncQuestionID = "0199f000-0000-7000-8000-000000000004"
    static let abortedID = "0199f000-0000-7000-8000-000000000005"
    static let errorID = "0199f000-0000-7000-8000-000000000006"
    static let guardianID = "0199f000-0000-7000-8000-000000000007"
    static let subagentSpawnID = "0199f000-0000-7000-8000-000000000008"
    static let execID = "0199f000-0000-7000-8000-000000000009"
    static let chromeID = "0199f000-0000-7000-8000-000000000010"
    static let sourceStringID = "0199f000-0000-7000-8000-000000000011"
    static let taskFailedID = "0199f000-0000-7000-8000-000000000012"
    static let subagentForkChildID = "0199f000-0000-7000-8000-000000000013"
    static let subagentForkParentID = "0199f000-0000-7000-8000-000000000014"

    static func completedTurn(_ meta: String) -> [String] {
        [
            meta,
            RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
            RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: at(3)),
        ]
    }

    static var rollouts: [(name: String, lines: [String])] {
        [
            ("rollout-turn-complete.jsonl", [
                RolloutLine.sessionMeta(id: turnCompleteID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.filler(approximateBytes: 240, at: at(2)),
                RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap for thread one.", at: at(3)),
            ]),
            ("rollout-plan-question-open.jsonl", [
                RolloutLine.sessionMeta(id: questionOpenID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.functionCall(name: "request_user_input", callID: "call-1", question: "Fixture question?",
                                         options: ["Option A", "Option B"], at: at(2)),
            ]),
            ("rollout-plan-question-answered.jsonl", [
                RolloutLine.sessionMeta(id: questionAnsweredID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.functionCall(name: "request_user_input", callID: "call-1", question: "Fixture question?",
                                         options: ["Option A", "Option B"], at: at(2)),
                RolloutLine.functionCallOutput(callID: "call-1", at: at(3)),
            ]),
            ("rollout-async-question.jsonl", [
                // Fix round 1, Finding 3: real request_user_input_async arguments use `title`
                // (not `question`) and plain string options, not [{label}] objects.
                RolloutLine.sessionMeta(id: asyncQuestionID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.functionCallAsync(callID: "call-2", title: "Fixture async question?",
                                              options: ["Option A", "Option B"], at: at(2)),
                RolloutLine.functionCallOutput(callID: "call-2", at: at(3)),
                RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap with a question.", at: at(4)),
            ]),
            ("rollout-aborted.jsonl", [
                RolloutLine.sessionMeta(id: abortedID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.turnAborted(turnID: "turn-1", at: at(2)),
            ]),
            ("rollout-error.jsonl", [
                RolloutLine.sessionMeta(id: errorID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.errorEvent(message: "Fixture error message.", at: at(2)),
            ]),
            ("rollout-guardian.jsonl", completedTurn(RolloutLine.sessionMeta(
                id: guardianID, sourceJSON: #"{"subagent":{"kind":"fixture"}}"#, threadSource: "guardian_review", at: at(0)))),
            ("rollout-subagent-spawn.jsonl", completedTurn(RolloutLine.sessionMeta(
                id: subagentSpawnID, threadSource: "subagent", at: at(0)))),
            ("rollout-exec.jsonl", completedTurn(RolloutLine.sessionMeta(
                id: execID, originator: "codex_exec", sourceJSON: #""exec""#, at: at(0)))),
            ("rollout-chrome.jsonl", completedTurn(RolloutLine.sessionMeta(
                id: chromeID, originator: "Codex Chrome Extension", at: at(0)))),
            ("rollout-source-string.jsonl", completedTurn(RolloutLine.sessionMeta(
                id: sourceStringID, sourceJSON: #""vscode""#, threadSource: "agent_created_thread", at: at(0)))),
            // Fix round 1, Finding 2: a task_complete carrying a non-null error (real shape:
            // {codex_error_info, message}) is a failed turn, not a silent doneUnseen.
            ("rollout-task-failed.jsonl", [
                RolloutLine.sessionMeta(id: taskFailedID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                               message: "Fixture usage limit message.", at: at(3)),
            ]),
            // Fix round 1, Finding 1: a forked subagent's own session_meta (source {subagent},
            // thread_source subagent, forked_from_id P) is followed by the parent's session_meta
            // (id P, visible). The parent meta must never overwrite the child thread's meta.
            ("rollout-subagent-fork.jsonl", [
                RolloutLine.sessionMeta(id: subagentForkChildID, sourceJSON: #"{"subagent":{"kind":"fixture"}}"#,
                                        threadSource: "subagent", forkedFromID: subagentForkParentID, at: at(0)),
                RolloutLine.sessionMeta(id: subagentForkParentID, at: at(0)),
                RolloutLine.taskStarted(turnID: "turn-1", at: at(1)),
                RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: at(3)),
            ]),
        ]
    }

    static let sessionIndexLines = [
        #"{"id":"0199f000-0000-7000-8000-000000000001","thread_name":"Fixture thread one","updated_at":"2026-09-21T12:53:20.000Z"}"#,
        #"{"id":"0199f000-0000-7000-8000-000000000002","thread_name":"Fixture thread two","updated_at":"2026-09-21T12:53:21.000Z"}"#,
        #"{"id":"0199f000-0000-7000-8000-000000000004","thread_name":"Fixture thread four","updated_at":"2026-09-21T12:53:22.000Z"}"#,
        #"{"id":"0199f000-0000-7000-8000-000000000001","thread_name":"Fixture thread one renamed","updated_at":"2026-09-21T12:53:23.000Z"}"#,
    ]

    static func contents(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    static var allFiles: [(name: String, text: String)] {
        rollouts.map { ($0.name, contents($0.lines)) } + [("session_index.jsonl", contents(sessionIndexLines))]
    }
}

private func codexCoreFixtureRows(_ name: String, showExec: Bool = false, titles: [String: String] = [:]) throws -> [AgentRow] {
    let lines = try Fixtures.data("codex/\(name)").split(separator: 0x0A).map { Data($0) }
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: lines, file: CodexRolloutFile(path: Fixtures.url("codex/\(name)").path))
    return codexCoreRows(reducer, titles: titles, showExec: showExec, now: CodexFixtureCatalog.at(60))
}

/// Regenerate with: CODEX_FIXTURES_WRITE=1 swift run island-tests --filter "codexCore: committed fixtures"
func testCodexCoreCommittedFixturesMatchGenerator() throws {
    let directory = Fixtures.root.appendingPathComponent("codex", isDirectory: true)
    if ProcessInfo.processInfo.environment["CODEX_FIXTURES_WRITE"] == "1" {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in CodexFixtureCatalog.allFiles {
            try Data(file.text.utf8).write(to: directory.appendingPathComponent(file.name))
        }
    }
    for file in CodexFixtureCatalog.allFiles {
        try expect(try Fixtures.string("codex/\(file.name)"), equals: file.text,
                   "Tests/Fixtures/codex/\(file.name) matches its RolloutLine definition")
    }
}

func testCodexCoreFixtureStates() throws {
    let expectations: [(String, [DisplayState])] = [
        ("rollout-turn-complete.jsonl", [.doneUnseen]),
        ("rollout-plan-question-open.jsonl", [.waiting]),
        ("rollout-plan-question-answered.jsonl", [.working]),
        ("rollout-async-question.jsonl", [.waiting]),
        ("rollout-aborted.jsonl", [.idle]),
        ("rollout-error.jsonl", [.error]),
        ("rollout-guardian.jsonl", []),
        ("rollout-subagent-spawn.jsonl", []),
        ("rollout-exec.jsonl", []),
        ("rollout-chrome.jsonl", []),
        ("rollout-source-string.jsonl", [.doneUnseen]),
        ("rollout-task-failed.jsonl", [.error]),
        ("rollout-subagent-fork.jsonl", []),
    ]
    for (name, states) in expectations {
        try expect(try codexCoreFixtureRows(name).map(\.state), equals: states, name)
    }
    try expect(try codexCoreFixtureRows("rollout-turn-complete.jsonl").first?.detail,
               equals: Detail(question: "Fixture recap for thread one.", kind: .recap), "fixture recap")
    try expect(try codexCoreFixtureRows("rollout-plan-question-open.jsonl").first?.detail,
               equals: Detail(question: "Fixture question?", options: ["Option A", "Option B"], kind: .question), "fixture question")
    try expect(try codexCoreFixtureRows("rollout-async-question.jsonl").first?.detail,
               equals: Detail(question: "Fixture async question?", options: ["Option A", "Option B"], kind: .question),
               "fixture async question (real shape: title + string options)")
    try expect(try codexCoreFixtureRows("rollout-error.jsonl").first?.detail,
               equals: Detail(question: "Fixture error message.", kind: .error), "fixture error")
    try expect(try codexCoreFixtureRows("rollout-task-failed.jsonl").first?.detail,
               equals: Detail(question: "Fixture usage limit message.", kind: .error), "fixture failed task_complete")
    try expect(try codexCoreFixtureRows("rollout-exec.jsonl", showExec: true).map(\.state), equals: [.doneUnseen],
               "exec thread shown with the setting")
}

func testCodexCoreFixtureTitlesFromSessionIndex() throws {
    let titles = CodexSessionIndex.parse(try Fixtures.data("codex/session_index.jsonl"))
    try expect(titles.count, equals: 3, "three synthetic ids")
    try expect(titles[CodexFixtureCatalog.turnCompleteID], equals: "Fixture thread one renamed", "last line wins")
    try expect(try codexCoreFixtureRows("rollout-turn-complete.jsonl", titles: titles).first?.title,
               equals: "Fixture thread one renamed", "title from session_index")
    try expect(try codexCoreFixtureRows("rollout-aborted.jsonl", titles: titles).first?.title,
               equals: "fixture-project", "no index entry → cwd basename")
}

private let codexCoreFixtureCases: [TestCase] = [
    ("codexCore: committed fixtures match RolloutLine output", testCodexCoreCommittedFixturesMatchGenerator),
    ("codexCore: fixture rollouts map to the expected states", testCodexCoreFixtureStates),
    ("codexCore: fixture titles come from session_index", testCodexCoreFixtureTitlesFromSessionIndex),
]

let codexCoreTests: [TestCase] = [
    codexCoreParserCases,
    codexCoreFilterCases,
    codexCoreSeenCases,
    codexCoreReducerCases,
    codexCoreFixtureCases,
].flatMap { $0 }

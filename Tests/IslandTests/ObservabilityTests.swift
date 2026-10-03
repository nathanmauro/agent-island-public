import Foundation

import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Helpers

private let observabilityT0 = Date(timeIntervalSince1970: 1_800_000_000)

private func herdrID(_ key: String) -> RowID { RowID(source: .herdr, key: key) }

private func storeChange(previous: [AgentRow] = [], rows: [AgentRow] = [], decision: PolicyDecision = .none,
                         shadow: [RowID: String] = [:], health: [HealthChange] = []) -> StoreChange {
    StoreChange(at: observabilityT0, previousRows: previous, rows: rows, decision: decision,
                registryShadow: shadow, healthChanges: health)
}

private func record(ts: Date = observabilityT0, rowKey: String, filler: String = "") -> TransitionRecord {
    TransitionRecord(ts: ts, kind: .state, source: "herdr", rowID: "herdr:\(rowKey)", from: filler.isEmpty ? nil : filler,
                     to: "working")
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

// MARK: - TransitionRecord.records(for:)

func testObservabilityStateChangeEmitsOneRecord() throws {
    let before = AgentRow.fixture(key: "w1:p1", state: .working)
    let after = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    let records = TransitionRecord.records(for: storeChange(previous: [before], rows: [after]))
    try expect(records, equals: [
        TransitionRecord(ts: observabilityT0, kind: .state, source: "herdr", rowID: "herdr:w1:p1",
                         from: "working", to: "doneUnseen"),
    ], "one state record with ts, source, rowID, from, to and no rule")
    try expect(TransitionRecord.records(for: storeChange(previous: [before], rows: [before])), equals: [],
               "an unchanged state emits nothing")
}

func testObservabilityNewAndRemovedRows() throws {
    let appeared = AgentRow.fixture(source: .codexDesktop, key: "t-1", state: .working)
    let vanished = AgentRow.fixture(key: "w1:p2", state: .idle)
    let records = TransitionRecord.records(for: storeChange(previous: [vanished], rows: [appeared]))
    try expect(records, equals: [
        TransitionRecord(ts: observabilityT0, kind: .state, source: "codexDesktop", rowID: "codexDesktop:t-1",
                         from: nil, to: "working"),
        TransitionRecord(ts: observabilityT0, kind: .state, source: "herdr", rowID: "herdr:w1:p2",
                         from: "idle", to: TransitionRecord.removedState),
    ], "a new row has from nil; a removed row has to \"removed\"")
}

func testObservabilityWaitingStateCarriesTruncatedQuestion() throws {
    let question = String(repeating: "q", count: 500)
    let waiting = AgentRow.fixture(key: "w1:p1", state: .waiting, detail: Detail(question: question, kind: .question))
    let records = TransitionRecord.records(for: storeChange(previous: [], rows: [waiting]))
    try expect(records.first?.question, equals: String(repeating: "q", count: 200), "question truncated to 200")
    let done = AgentRow.fixture(key: "w1:p1", state: .doneUnseen, detail: Detail(question: "recap", kind: .recap))
    try expect(TransitionRecord.records(for: storeChange(previous: [waiting], rows: [done])).first?.question,
               equals: nil, "recaps of done rows are not logged")
}

func testObservabilityPeekRecords() throws {
    let question = String(repeating: "é", count: 300)
    let waitingPeek = PeekEvent(rowID: herdrID("w1:p1"), kind: .waiting, question: question, at: observabilityT0)
    let errorPeek = PeekEvent(rowID: RowID(source: .codexDesktop, key: "t-1"), kind: .error, question: nil,
                              at: observabilityT0)
    let records = TransitionRecord.records(for: storeChange(decision: PolicyDecision(peeks: [waitingPeek, errorPeek])))
    try expect(records, equals: [
        TransitionRecord(ts: observabilityT0, kind: .peek, source: "herdr", rowID: "herdr:w1:p1",
                         rule: "peek.waiting", question: String(repeating: "é", count: 200)),
        TransitionRecord(ts: observabilityT0, kind: .peek, source: "codexDesktop", rowID: "codexDesktop:t-1",
                         rule: "peek.error"),
    ], "peek records carry their rule and a question truncated to 200 characters")
}

func testObservabilityChimeAndSuppressionRecords() throws {
    let row = AgentRow.fixture(key: "w1:p1", state: .waiting, detail: Detail(question: "Proceed?", kind: .permission))
    let peek = PeekEvent(rowID: row.id, kind: .waiting, question: "Proceed?", at: observabilityT0)
    let quiet = herdrID("w1:p9")
    let decision = PolicyDecision(peeks: [peek], chime: true, notes: [
        PolicyNote(rowID: row.id, rule: .peekWaiting, at: observabilityT0),
        PolicyNote(rowID: row.id, rule: .chime, at: observabilityT0),
        PolicyNote(rowID: quiet, rule: .quietPeriod, at: observabilityT0),
        PolicyNote(rowID: row.id, rule: .looking, at: observabilityT0),
    ])
    let records = TransitionRecord.records(for: storeChange(previous: [row], rows: [row], decision: decision))
    try expect(records.map(\.kind), equals: [.peek, .chime, .suppressed, .suppressed],
               "peek, chime, then one record per suppression note (peek/chime notes are not duplicated)")
    // Controller ruling: every chime carries its rule and the (truncated) question that
    // triggered it, not just its rule, so the log alone answers "what made that sound?".
    try expect(records[1], equals: TransitionRecord(ts: observabilityT0, kind: .chime, source: "herdr",
                                                    rowID: "herdr:w1:p1", rule: "chime", question: "Proceed?"),
               "chime record")
    try expect(records[2].rule, equals: "suppressed.quiet", "quiet period keeps its rule")
    try expect(records[2].rowID, equals: "herdr:w1:p9", "suppression names its row")
    try expect(records[3].rule, equals: "suppressed.looking", "looking keeps its rule")
    try expect(records[3].question, equals: "Proceed?", "a suppression shows the question it hid")
}

func testObservabilityRegistryShadowOnHerdrRows() throws {
    let before = AgentRow.fixture(key: "w1:p1", state: .working)
    let after = AgentRow.fixture(key: "w1:p1", state: .waiting)
    let records = TransitionRecord.records(for: storeChange(previous: [before], rows: [after],
                                                            shadow: [after.id: "busy"]))
    try expect(records.first?.registryStatus, equals: "busy", "the herdr row carries the registry status shadow")
    let unshadowed = TransitionRecord.records(for: storeChange(previous: [before], rows: [after]))
    try expect(unshadowed.first?.registryStatus, equals: nil, "no shadow, no registryStatus")
}

func testObservabilityFeedHealthRecords() throws {
    let first = FeedHealth.offline(reason: "reconnecting in 0.5 s")
    let second = FeedHealth.offline(reason: "reconnecting in 1 s")
    let one = TransitionRecord.records(for: storeChange(health: [
        HealthChange(source: .herdr, from: .online, to: first),
    ]))
    let two = TransitionRecord.records(for: storeChange(health: [
        HealthChange(source: .herdr, from: first, to: second),
    ]))
    try expect(one + two, equals: [
        TransitionRecord(ts: observabilityT0, kind: .feed, source: "herdr", from: FeedHealth.online.summary,
                         to: first.summary),
        TransitionRecord(ts: observabilityT0, kind: .feed, source: "herdr", from: first.summary, to: second.summary),
    ], "each backoff step is its own feed record with from/to summaries")
    let initial = TransitionRecord.records(for: storeChange(health: [
        HealthChange(source: .claudeRegistry, from: nil, to: .inactive(reason: "directory missing")),
    ]))
    try expect(initial.first?.from, equals: nil, "a first report has no from")
}

func testObservabilityTruncateQuestion() throws {
    try expect(TransitionRecord.truncateQuestion("short"), equals: "short", "short text unchanged")
    let long = String(repeating: "a", count: 199) + "🙂" + String(repeating: "b", count: 50)
    let truncated = TransitionRecord.truncateQuestion(long)
    try expect(truncated.count, equals: 200, "200 characters")
    try expectTrue(truncated.hasSuffix("🙂"), "counts characters, not bytes")
}

func testObservabilityRecordLineEncoding() throws {
    let original = TransitionRecord(ts: Date(timeIntervalSince1970: 1_800_000_000.25), kind: .peek, source: "herdr",
                                    rowID: "herdr:w1:p1", rule: "peek.waiting", question: "Run tests?")
    let data = try TransitionRecord.makeEncoder().encode(original)
    let text = String(decoding: data, as: UTF8.self)
    try expectTrue(!text.contains("\n"), "one line per record")
    try expectTrue(text.contains(#""ts":"2027-01-15T08:00:00.250Z""#), "ISO 8601 timestamp with milliseconds: \(text)")
    try expectTrue(!text.contains("registryStatus"), "nil fields are omitted: \(text)")
    try expect(try TransitionRecord.makeDecoder().decode(TransitionRecord.self, from: data), equals: original,
               "round-trips")
}

// MARK: - TransitionRecord.jumpFailure (controller ruling)

func testObservabilityJumpFailureRecordIsTypedAndTruncated() throws {
    let long = String(repeating: "x", count: 300)
    let failure = TransitionRecord.jumpFailure(rowID: herdrID("w1:p1"), description: long, at: observabilityT0)
    try expect(failure.kind, equals: .jump, "a distinct kind, never mistaken for a real state change")
    try expect(failure.source, equals: "herdr", "source")
    try expect(failure.rowID, equals: "herdr:w1:p1", "rowID")
    try expect(failure.to, equals: String(repeating: "x", count: 200), "the error description, truncated like a question")
    try expect(failure.from, equals: nil, "not a state transition")
    try expect(failure.rule, equals: nil, "not a policy rule")
}

// MARK: - TransitionRecord.diagnostic (controller ruling, fix round 1)

func testObservabilityDiagnosticRecordIsDiscriminatedFromAHealthReport() throws {
    // Finding: a diagnostic and a feed's first health report are both kind .feed with no
    // `from`, so without a discriminator they read as the same thing.
    let diagnostic = TransitionRecord.diagnostic(source: .herdr, message: "pane stream cap reached (64 streams)",
                                                 at: observabilityT0)
    try expect(diagnostic.kind, equals: .feed, "still shaped like a feed-health record")
    try expect(diagnostic.rule, equals: TransitionRecord.diagnosticRule, "discriminated by rule")
    try expect(diagnostic.from, equals: nil, "no from, same shape as a first health report...")
    try expect(diagnostic.to, equals: "pane stream cap reached (64 streams)", "...but the message lands in to")

    let firstHealthReport = TransitionRecord.records(for: storeChange(health: [
        HealthChange(source: .herdr, from: nil, to: .online),
    ])).first
    try expect(firstHealthReport?.from, equals: nil, "a real first health report also has no from")
    try expect(firstHealthReport?.rule, equals: nil, "...but never carries the diagnostic rule")
}

// MARK: - TransitionLog

func testObservabilityTransitionLogAppendsJSONLines() throws {
    let directory = try TemporaryDirectory()
    let url = directory.url.appendingPathComponent("log/transitions.jsonl")
    let log = TransitionLog(fileURL: url)
    let batch = [record(rowKey: "w1:p1"), record(rowKey: "w1:p2")]
    log.append(batch)
    log.append([record(rowKey: "w1:p3")])
    log.append([])
    let decoder = TransitionRecord.makeDecoder()
    let decoded = try lines(of: url).map { try decoder.decode(TransitionRecord.self, from: Data($0.utf8)) }
    try expect(decoded, equals: batch + [record(rowKey: "w1:p3")], "one line per record, in order")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    try expect(permissions, equals: 0o600, "the log is private")
}

func testObservabilityTransitionLogRotatesPastTenMegabytes() throws {
    let directory = try TemporaryDirectory()
    let url = directory.file("transitions.jsonl")
    let log = TransitionLog(fileURL: url)   // defaults: 10 MB, 3 files
    try expect(IslandTiming.logRotateBytes, equals: 10_485_760, "10 MB")
    let filler = String(repeating: "x", count: 4_000)
    var sequence = 0
    // About 33 MB: more than three files' worth, so the oldest file must have been dropped.
    for _ in 0..<80 {
        var batch: [TransitionRecord] = []
        for _ in 0..<100 {
            batch.append(record(rowKey: "p\(sequence)", filler: filler))
            sequence += 1
        }
        log.append(batch)
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()
    try expect(names, equals: ["transitions.1.jsonl", "transitions.2.jsonl", "transitions.jsonl"], "exactly 3 files")
    let decoder = TransitionRecord.makeDecoder()
    var allRowIDs: [String] = []
    for name in ["transitions.2.jsonl", "transitions.1.jsonl", "transitions.jsonl"] {
        let fileURL = directory.file(name)
        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        try expectTrue(size <= IslandTiming.logRotateBytes, "\(name) stays under 10 MB (\(size))")
        for line in try lines(of: fileURL) {
            allRowIDs.append(try decoder.decode(TransitionRecord.self, from: Data(line.utf8)).rowID ?? "")
        }
    }
    try expect(allRowIDs.last, equals: "herdr:p\(sequence - 1)", "the newest record ends transitions.jsonl")
    try expectTrue(!allRowIDs.contains("herdr:p0"), "the oldest records were rotated away")
    let indices = allRowIDs.compactMap { Int($0.dropFirst("herdr:p".count)) }
    try expect(indices, equals: Array(indices.sorted()), "files are ordered oldest (.2) to newest")
}

func testObservabilityTransitionLogKeepsConfiguredFileCount() throws {
    let directory = try TemporaryDirectory()
    let url = directory.file("transitions.jsonl")
    let log = TransitionLog(fileURL: url, rotateBytes: 1_000, keepFiles: 3)
    for index in 0..<60 {
        log.append([record(rowKey: "p\(index)")])
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()
    try expect(names, equals: ["transitions.1.jsonl", "transitions.2.jsonl", "transitions.jsonl"],
               "rotation keeps keepFiles files")
    try expect(log.rotatedFileURL(index: 2).lastPathComponent, equals: "transitions.2.jsonl", "rotated name")
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    try expectTrue(size <= 1_000, "the current file respects rotateBytes (\(size))")
}

// MARK: - StateDumpSnapshot and StateDump

private func dumpSnapshot(rowCount: Int, chimes: Int = 0) -> StateDumpSnapshot {
    let rows = (0..<rowCount).map { index in
        AgentRow.fixture(key: "w1:p\(index)", state: index.isMultiple(of: 3) ? .waiting : .working,
                         detail: Detail(question: "Question \(index)?", options: ["Yes", "No"], kind: .question),
                         jump: .herdrPane(paneID: "w1:p\(index)", windowTitlePrefix: "host: ws"))
    }
    let planned = Dictionary(uniqueKeysWithValues: rows.map { row in
        (row.id, JumpPlanner.plan(row.jump, context: JumpContext()))
    })
    return StateDumpSnapshot(
        generatedAt: observabilityT0,
        rows: rows,
        summary: Summary(rows: rows),
        feedHealth: [.herdr: .online, .codexDesktop: .offline(reason: "sessions directory missing")],
        peekQueue: PeekQueueSnapshot(current: rows.first?.id, pending: [], moreCount: 0),
        chimePlayedCount: chimes,
        plannedJumps: planned,
        performedJumps: [[.openURL("codex://threads/t-1", appPath: "/Applications/Codex.app", onlyIfPreviousFailed: false)]],
        ui: UISnapshot(boardExpanded: true, cardVisible: true, cardDisplayID: 2, pillDisplayIDs: [1],
                       pillIgnoresMouseEvents: false, primaryDisplayID: 1)
    )
}

func testObservabilityStateDumpSnapshotKeys() throws {
    let snapshot = dumpSnapshot(rowCount: 3)
    try expect(snapshot.summaryText, equals: "1 waiting · 2 working", "summary text")
    try expect(snapshot.segments, equals: [Summary.Segment(kind: .waiting, count: 1), Summary.Segment(kind: .working, count: 2)],
               "segments")
    try expect(Set(snapshot.feedHealth.keys), equals: ["herdr", "codexDesktop"], "health keyed by SessionSource.rawValue")
    try expect(snapshot.plannedJumps["herdr:w1:p0"]?.first, equals: .herdrFocus(paneID: "w1:p0"),
               "plans keyed by RowID.description")
    let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
    // Controller ruling: feedErrorCounts is an additional top-level key (Codex I/O errors
    // the trial run must be able to see) beside the brief's original set.
    try expect(Set(json.keys), equals: ["generatedAt", "rows", "summaryText", "segments", "feedHealth", "peekQueue",
                                        "chimePlayedCount", "plannedJumps", "performedJumps", "feedErrorCounts", "ui"],
               "top-level keys the end-to-end driver reads")
    let ui = json["ui"] as? [String: Any] ?? [:]
    try expect(Set(ui.keys), equals: ["boardExpanded", "cardVisible", "cardDisplayID", "pillDisplayIDs",
                                      "pillIgnoresMouseEvents", "primaryDisplayID"], "ui keys")
}

func testObservabilityStateDumpSnapshotFeedErrorCounts() throws {
    // Controller ruling: the Codex feed's swallowed I/O errors must be visible in the dump.
    let snapshot = StateDumpSnapshot(generatedAt: observabilityT0, rows: [], summary: Summary(rows: []),
                                     feedHealth: [:], peekQueue: PeekQueueSnapshot(), chimePlayedCount: 0,
                                     plannedJumps: [:], performedJumps: [], feedErrorCounts: [.codexDesktop: 3],
                                     ui: UISnapshot())
    try expect(snapshot.feedErrorCounts, equals: ["codexDesktop": 3], "keyed by SessionSource.rawValue")
    let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
    try expect(json["feedErrorCounts"] as? [String: Int], equals: ["codexDesktop": 3], "present at the top level")
}

func testObservabilityStateDumpSnapshotLastErrorDescription() throws {
    // Controller ruling (fix round 1): a jump failure must reach the state dump, not just
    // the transition log, and must clear from the dump once resolved.
    let withError = StateDumpSnapshot(generatedAt: observabilityT0, rows: [], summary: Summary(rows: []),
                                      feedHealth: [:], peekQueue: PeekQueueSnapshot(), chimePlayedCount: 0,
                                      plannedJumps: [:], performedJumps: [],
                                      lastErrorDescription: "raiseGhostty: commandFailed(exit 1)", ui: UISnapshot())
    let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withError)) as? [String: Any] ?? [:]
    try expect(json["lastErrorDescription"] as? String, equals: "raiseGhostty: commandFailed(exit 1)",
               "present at the top level when there is a failure to report")

    let cleared = StateDumpSnapshot(generatedAt: observabilityT0, rows: [], summary: Summary(rows: []),
                                    feedHealth: [:], peekQueue: PeekQueueSnapshot(), chimePlayedCount: 0,
                                    plannedJumps: [:], performedJumps: [], ui: UISnapshot())
    let clearedJSON = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(cleared)) as? [String: Any] ?? [:]
    try expectTrue(clearedJSON["lastErrorDescription"] == nil, "omitted, not null, once there is nothing to report")
}

func testObservabilityStateDumpRoundTripsThroughPlainDecoder() throws {
    let directory = try TemporaryDirectory()
    let url = directory.url.appendingPathComponent("nested/state.json")
    let snapshot = dumpSnapshot(rowCount: 5, chimes: 2)
    StateDump(url: url).write(snapshot)
    let decoded = try JSONDecoder().decode(StateDumpSnapshot.self, from: Data(contentsOf: url))
    try expect(decoded, equals: snapshot, "a plain JSONDecoder reads the dump back unchanged")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    try expect(permissions, equals: 0o600, "the dump is private")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    try expect(leftovers, equals: ["state.json"], "no temporary files are left behind")
}

private final class DumpReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private(set) var goodReads = 0
    private(set) var badReads = 0
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
    func stop() { lock.lock(); stopRequested = true; lock.unlock() }
    func count(good: Bool) { lock.lock(); if good { goodReads += 1 } else { badReads += 1 }; lock.unlock() }
}

func testObservabilityStateDumpWriteIsAtomic() throws {
    let directory = try TemporaryDirectory()
    let url = directory.file("state.json")
    let dump = StateDump(url: url)
    let small = dumpSnapshot(rowCount: 1)
    let large = dumpSnapshot(rowCount: 400)
    dump.write(small)
    let probe = DumpReadProbe()
    let readerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        while !probe.shouldStop {
            guard let data = try? Data(contentsOf: url) else { continue }
            probe.count(good: (try? JSONDecoder().decode(StateDumpSnapshot.self, from: data)) != nil)
        }
        readerDone.signal()
    }
    for index in 0..<40 {
        dump.write(index.isMultiple(of: 2) ? large : small)
    }
    probe.stop()
    guard readerDone.wait(timeout: .now() + 5) == .success else {
        throw TestFailure.expectation("reader thread did not stop")
    }
    try expect(probe.badReads, equals: 0, "a concurrent reader never sees a partial dump")
    try expectTrue(probe.goodReads > 0, "the reader actually read the dump")
}

// MARK: - StateStore hooks (controller rulings)

@MainActor
private final class JumpFocusOutcome {
    var error: Error?
    var finished = false
}

@MainActor
private func runFocus(_ store: StateStore, _ id: RowID) throws -> Error? {
    let outcome = JumpFocusOutcome()
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
private final class FailingJumpPerformer: JumpPerforming {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var performedLog: [[JumpAction]] = []
    private let failureDescription: String
    /// Flips to false so a test can exercise a later, successful focus (controller ruling,
    /// fix round 1: lastErrorDescription must clear once that happens).
    var shouldFail = true

    init(failureDescription: String) {
        self.failureDescription = failureDescription
    }

    func perform(_ actions: [JumpAction]) async throws {
        performedLog.append(actions)
        if shouldFail {
            throw Failure(description: failureDescription)
        }
    }
}

/// A minimal SessionFeed a test can build directly, without pulling in Herdr or Codex
/// I/O. Extended below to opt into `FeedDiagnosticsReporting` and `FeedIOErrorCounting`.
@MainActor
private class MinimalFeed: SessionFeed {
    let source: SessionSource
    init(source: SessionSource) { self.source = source }
    func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {}
    func stop() {}
    func jump(_ row: AgentRow) async throws {}
    func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {}
    func loadDetail(for row: AgentRow) {}
}

@MainActor
private final class DiagnosticFeed: MinimalFeed, FeedDiagnosticsReporting {
    private var diagnosticHandler: (@MainActor (String) -> Void)?

    func observeDiagnostics(_ report: @escaping @MainActor (String) -> Void) {
        diagnosticHandler = report
    }

    func emit(_ message: String) {
        diagnosticHandler?(message)
    }
}

@MainActor
private final class ErrorCountingFeed: MinimalFeed, FeedIOErrorCounting {
    var ioErrorCount = 0
}

@MainActor
private func makeObservabilityStore(feeds: [any SessionFeed], performer: (any JumpPerforming)? = nil) -> StateStore {
    StateStore(
        feeds: feeds,
        clock: ManualWallClock(),
        focusProvider: FakeFocusContextProvider(),
        jumpPerformer: performer ?? RecordingJumpPerformer(),
        jumpContextProvider: StaticJumpContextProvider(JumpContext())
    )
}

@MainActor
func testObservabilityStoreRecordsAndReportsJumpPerformerFailures() throws {
    // Controller ruling: a failure from jumpPerformer.perform must not be silent.
    let herdr = FakeSessionFeed(source: .herdr)
    let performer = FailingJumpPerformer(failureDescription: "raiseGhostty: commandFailed(exit 1)")
    let store = makeObservabilityStore(feeds: [herdr], performer: performer)
    store.start()
    defer { store.stop() }
    let row = AgentRow.fixture(key: "w1:p1", state: .waiting,
                               jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "host: api"))
    herdr.publish([row])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }

    var reportedRowID: RowID?
    var reportedDescription: String?
    store.onJumpFailure = { rowID, description in
        reportedRowID = rowID
        reportedDescription = description
    }

    let error = try runFocus(store, row.id)
    try expectTrue(error != nil, "the failure is rethrown, never swallowed")
    try expect(herdr.jumpedRows, equals: [], "failed navigation leaves the result unread")
    // NotchWidgetView's own message stays generic; this is recorded for the state dump and
    // the transition log (fix round 1: the README/test wording claiming otherwise was wrong).
    try expect(store.lastErrorDescription, equals: "raiseGhostty: commandFailed(exit 1)",
               "recorded for the state dump and transition log, even though the board's own message stays generic")
    try expect(reportedRowID, equals: row.id, "the transition-log hook sees the row")
    try expect(reportedDescription, equals: "raiseGhostty: commandFailed(exit 1)", "and the same description")
}

@MainActor
func testObservabilityStoreClearsLastErrorDescriptionAfterALaterSuccessfulFocus() throws {
    // Controller ruling (fix round 1); fix round 2's ruling calls this the "Sequential"
    // case: A fails, then a later focus (started after A's error was recorded) succeeds
    // and clears it. lastErrorDescription must not linger forever, or the dump would keep
    // reporting a stale error.
    let herdr = FakeSessionFeed(source: .herdr)
    let performer = FailingJumpPerformer(failureDescription: "raiseGhostty: commandFailed(exit 1)")
    let store = makeObservabilityStore(feeds: [herdr], performer: performer)
    store.start()
    defer { store.stop() }
    let row = AgentRow.fixture(key: "w1:p1", state: .waiting,
                               jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "host: api"))
    herdr.publish([row])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }

    _ = try runFocus(store, row.id)
    try expect(store.lastErrorDescription, equals: "raiseGhostty: commandFailed(exit 1)", "the first failure is recorded")

    performer.shouldFail = false
    let secondError = try runFocus(store, row.id)
    try expectTrue(secondError == nil, "the second focus succeeds")
    try expect(store.lastErrorDescription, equals: nil,
               "a later focus (started after the error was recorded) clears it once it succeeds")
}

/// A feed whose jump(_:) (mark-seen) always fails, so a test can exercise the other half of
/// the same-call race (fix round 2): a mark-seen failure followed by a successful perform,
/// within one `focus` call.
@MainActor
private final class MarkSeenFailingFeed: SessionFeed {
    let source: SessionSource
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let failureDescription: String
    private var publishHandler: (@MainActor ([AgentRow]) -> Void)?

    init(source: SessionSource, failureDescription: String) {
        self.source = source
        self.failureDescription = failureDescription
    }

    func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {
        publishHandler = publish
    }
    func stop() {}
    func jump(_ row: AgentRow) async throws {
        throw Failure(description: failureDescription)
    }
    func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {}
    func loadDetail(for row: AgentRow) {}

    func publish(_ rows: [AgentRow]) {
        publishHandler?(rows)
    }
}

@MainActor
func testObservabilityStoreKeepsAMarkSeenFailureAfterSuccessfulPerform() throws {
    // Navigation succeeds, then acknowledgment throws. The final success cleanup must
    // preserve that failure because it was recorded after this call started.
    let feed = MarkSeenFailingFeed(source: .herdr, failureDescription: "mark-seen failed")
    let store = makeObservabilityStore(feeds: [feed])
    store.start()
    defer { store.stop() }
    let row = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .waiting,
                               jump: .herdrPane(paneID: "w1:p1", windowTitlePrefix: "host: api"))
    feed.publish([row])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }

    let error = try runFocus(store, row.id)
    try expectTrue(error == nil, "the default RecordingJumpPerformer never throws, so focus itself succeeds")
    try expect(store.lastErrorDescription, equals: "mark-seen failed",
               "the mark-seen failure survives this call's own successful perform")
}

/// Lets a test suspend an async call until it manually resumes it, keyed by a caller-chosen
/// token, so two `focus` calls can be interleaved deterministically (fix round 2; no sleeps).
@MainActor
private final class AsyncGate {
    private var waiting: [String: [CheckedContinuation<Void, Error>]] = [:]

    func wait(_ token: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiting[token, default: []].append(continuation)
        }
    }

    /// Resumes the oldest still-suspended call for `token`.
    func resume(_ token: String, throwing error: Error? = nil) {
        guard var queue = waiting[token], !queue.isEmpty else { return }
        let continuation = queue.removeFirst()
        waiting[token] = queue.isEmpty ? nil : queue
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// True once a call is suspended waiting for `token`.
    func isWaiting(_ token: String) -> Bool {
        !(waiting[token]?.isEmpty ?? true)
    }
}

/// A performer whose `perform(_:)` suspends on `gate`, keyed by the actions themselves (two
/// different rows plan different actions, so no manual key bookkeeping is needed).
@MainActor
private final class GatedJumpPerformer: JumpPerforming {
    private(set) var performedLog: [[JumpAction]] = []
    private let gate: AsyncGate

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func perform(_ actions: [JumpAction]) async throws {
        performedLog.append(actions)
        try await gate.wait(Self.token(for: actions))
    }

    static func token(for actions: [JumpAction]) -> String {
        String(describing: actions)
    }
}

@MainActor
func testObservabilityStoreKeepsAnEarlierErrorWhenAConcurrentlyStartedFocusLaterSucceeds() throws {
    // Finding (fix round 2), "Interleaved": A starts, B starts, A fails, then B succeeds. B
    // started before A's failure was recorded, so B's success must not clear it — only a
    // focus that STARTS after the error was recorded may clear it (see the Sequential test).
    let herdr = FakeSessionFeed(source: .herdr)
    let gate = AsyncGate()
    let performer = GatedJumpPerformer(gate: gate)
    let store = makeObservabilityStore(feeds: [herdr], performer: performer)
    store.start()
    defer { store.stop() }
    let rowA = AgentRow.fixture(key: "w1:pA", state: .waiting,
                               jump: .herdrPane(paneID: "w1:pA", windowTitlePrefix: "host: api"))
    let rowB = AgentRow.fixture(key: "w1:pB", state: .waiting,
                               jump: .herdrPane(paneID: "w1:pB", windowTitlePrefix: "host: api"))
    herdr.publish([rowA, rowB])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 2 }

    let outcomeA = JumpFocusOutcome()
    let outcomeB = JumpFocusOutcome()
    Task { @MainActor in
        do { try await store.focus(rowA.id) } catch { outcomeA.error = error }
        outcomeA.finished = true
    }
    Task { @MainActor in
        do { try await store.focus(rowB.id) } catch { outcomeB.error = error }
        outcomeB.finished = true
    }

    let tokenA = GatedJumpPerformer.token(for: JumpPlanner.plan(rowA.jump, context: JumpContext()))
    let tokenB = GatedJumpPerformer.token(for: JumpPlanner.plan(rowB.jump, context: JumpContext()))
    // Both calls are now "in flight": each has captured its own `started` sequence number and
    // is suspended inside perform(_:), waiting on the gate.
    try spinMainRunLoop(timeout: 1) { gate.isWaiting(tokenA) && gate.isWaiting(tokenB) }

    struct RaiseFailure: Error, CustomStringConvertible { let description: String }
    gate.resume(tokenA, throwing: RaiseFailure(description: "raiseGhostty: commandFailed(exit 1)"))
    try spinMainRunLoop(timeout: 1) { outcomeA.finished }
    try expect(store.lastErrorDescription, equals: "raiseGhostty: commandFailed(exit 1)", "A's failure is recorded")

    gate.resume(tokenB)
    try spinMainRunLoop(timeout: 1) { outcomeB.finished }

    try expectTrue(outcomeA.error != nil, "A's own focus call still throws")
    try expectTrue(outcomeB.error == nil, "B's focus call succeeds")
    try expect(store.lastErrorDescription, equals: "raiseGhostty: commandFailed(exit 1)",
               "B started before A's error was recorded, so B's success must not clear it")
}

@MainActor
func testObservabilityStoreExposesFeedIOErrorCounts() throws {
    // Finding (fix round 1): a feed that never opts in must be OMITTED, not reported as
    // zero — an absent key means "not tracked"; a false zero would read as "no errors".
    let herdr = FakeSessionFeed(source: .herdr)
    let counting = ErrorCountingFeed(source: .codexDesktop)
    counting.ioErrorCount = 3
    let store = makeObservabilityStore(feeds: [herdr, counting])
    try expect(store.feedIOErrorCounts, equals: [.codexDesktop: 3],
               "a feed that does not opt in is omitted entirely; one that does reports its count")
}

@MainActor
func testObservabilityStoreFeedIOErrorCountsNeverTrapsOnADuplicateSource() throws {
    // Finding (fix round 1): Dictionary(uniquingKeysWith:) instead of uniqueKeysWithValues,
    // so two feeds sharing a source (should never happen) keep the first instead of trapping.
    let first = ErrorCountingFeed(source: .codexDesktop)
    first.ioErrorCount = 1
    let second = ErrorCountingFeed(source: .codexDesktop)
    second.ioErrorCount = 9
    let store = makeObservabilityStore(feeds: [first, second])
    try expect(store.feedIOErrorCounts, equals: [.codexDesktop: 1],
               "the first feed for a duplicated source wins; the dictionary never traps")
}

@MainActor
func testObservabilityStoreWiresFeedDiagnosticsBySource() throws {
    // Controller ruling: HerdrFeed.observeDiagnostics must reach an external observer,
    // attributed to the feed's own source.
    let diagnosing = DiagnosticFeed(source: .herdr)
    let store = makeObservabilityStore(feeds: [diagnosing])
    var receivedSources: [SessionSource] = []
    var receivedMessages: [String] = []
    store.observeFeedDiagnostics { source, message in
        receivedSources.append(source)
        receivedMessages.append(message)
    }
    diagnosing.emit("pane stream cap reached (64 streams)")
    try expect(receivedSources, equals: [.herdr], "the message is attributed to the feed's source")
    try expect(receivedMessages, equals: ["pane stream cap reached (64 streams)"], "the message text passes through")
}

// MARK: - Heartbeat-silence regression (controller ruling d, permanent per fix round 1)

@MainActor
func testObservabilityHeartbeatsAndIdenticalRepublishesAppendNoBytes() throws {
    // Permanent regression for ruling (d): the real StateStore, the real
    // WakeGuardedPolicy(InterruptPolicy()) heartbeat (StoreChange at least every 10 s) and a
    // real TransitionLog — no fakes standing in for the pieces that must cooperate. After
    // the desk settles, many heartbeat ticks and many identical republishes must append 0
    // bytes. If records(for:) ever stops filtering out a no-op StoreChange, this fails.
    let directory = try TemporaryDirectory()
    let url = directory.file("transitions.jsonl")
    let log = TransitionLog(fileURL: url)
    let clock = ManualWallClock()
    let herdr = FakeSessionFeed(source: .herdr)
    let store = StateStore(
        feeds: [herdr],
        clock: clock,
        focusProvider: FakeFocusContextProvider(),
        jumpPerformer: RecordingJumpPerformer(),
        jumpContextProvider: StaticJumpContextProvider(JumpContext()),
        policy: WakeGuardedPolicy(InterruptPolicy()),
        deadlineScheduler: .manual
    )
    // The same pipeline ObservabilityWiring.attach wires, minus the background queue (this
    // test wants a deterministic, synchronous file size right after each call).
    store.addChangeObserver { change in
        let records = TransitionRecord.records(for: change)
        guard !records.isEmpty else { return }
        log.append(records)
    }
    store.start()
    defer { store.stop() }

    let settled = AgentRow.fixture(key: "w1:p1", state: .working)
    herdr.publish([settled])
    try spinMainRunLoop(timeout: 1) { store.rows.count == 1 }
    let sizeAfterSettle = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    try expectTrue(sizeAfterSettle > 0, "sanity check: the settle-phase publish is itself logged")

    for _ in 0..<50 {
        clock.advance(by: WakeGuardedPolicy.heartbeat + 1)
        store.tick()
    }
    for _ in 0..<50 {
        herdr.publish([settled])
    }

    let finalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    try expect(finalSize, equals: sizeAfterSettle, "50 heartbeats and 50 identical republishes append 0 bytes")
}

// MARK: - Codex feed I/O error counting (controller ruling)

@MainActor
func testObservabilityCodexFeedCountsSeenStoreSaveFailures() throws {
    let directory = try TemporaryDirectory()
    let sessionsDirectory = directory.url.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    // The parent of seenStoreURL is a regular file, so CodexSeenStore.save's
    // createDirectory(at:) must fail every time persistSeen() runs.
    let blocker = directory.file("blocker")
    try Data("not a directory".utf8).write(to: blocker)
    let seenStoreURL = blocker.appendingPathComponent("codex-seen.json")

    let feed = CodexDesktopFeed(sessionsDirectory: sessionsDirectory,
                                sessionIndexURL: directory.file("session_index.jsonl"),
                                seenStoreURL: seenStoreURL, activity: FakeAppActivity(), clock: ManualWallClock(),
                                showExecThreads: { false })
    defer { feed.stop() }
    try expect(feed.ioErrorCount, equals: 0, "no errors before start")
    feed.start { _ in }
    try expect(feed.ioErrorCount, equals: 1, "the swallowed seen-store save failure (first-launch baseline) is counted")
}

@MainActor
func testObservabilityCodexFeedCountsSessionIndexReadFailures() throws {
    // Finding (fix round 1): reloadTitlesIfNeeded's bare `try?` on session_index.jsonl was
    // not counted.
    let directory = try TemporaryDirectory()
    let sessionsDirectory = directory.url.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    let sessionIndexURL = directory.file("session_index.jsonl")
    try Data(#"{"id":"t-1","title":"hi"}"#.utf8).write(to: sessionIndexURL)
    // World-writable, so SecureFileReader.read's isSecure check rejects it on every poll.
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: sessionIndexURL.path)

    let feed = CodexDesktopFeed(sessionsDirectory: sessionsDirectory, sessionIndexURL: sessionIndexURL,
                                seenStoreURL: directory.file("codex-seen.json"), activity: FakeAppActivity(),
                                clock: ManualWallClock(), showExecThreads: { false })
    defer { feed.stop() }
    try expect(feed.ioErrorCount, equals: 0, "no errors before start")
    feed.start { _ in }
    try expect(feed.ioErrorCount, equals: 1, "the swallowed session-index read failure is counted")
}

// MARK: - Claude registry feed I/O error counting (controller ruling, fix round 1)

private struct NeverLiveProcessProbe: ProcessProbing {
    func exists(_ pid: Int32) -> Bool { false }
    func startTime(of pid: Int32) -> Date? { nil }
}

@MainActor
func testObservabilityClaudeRegistryFeedCountsReadAndDecodeFailures() throws {
    // Finding: the registry feed swallows per-file read and decode failures without
    // counting them, so feedIOErrorCounts read a false zero for it.
    let directory = try TemporaryDirectory()
    let registryDirectory = directory.url.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)

    // Valid JSON, but missing the required pid/sessionId: RegistryEntry.decode returns nil.
    let undecodable = registryDirectory.appendingPathComponent("111.json")
    try Data("{}".utf8).write(to: undecodable)
    // Read fails once, injected by the spy.
    let unreadable = registryDirectory.appendingPathComponent("222.json")
    try Data(#"{"pid": 222, "sessionId": "s"}"#.utf8).write(to: unreadable)

    let spy = FileAccessSpy()
    spy.failNextReads = ["222.json"]
    let feed = ClaudeRegistryFeed(directory: registryDirectory, fileReader: spy,
                                  processProbe: NeverLiveProcessProbe(), clock: ManualWallClock())
    try expect(feed.ioErrorCount, equals: 0, "no errors before the first sweep")
    feed.sweepNow()
    try expect(feed.ioErrorCount, equals: 2, "one undecodable entry and one read failure, each counted")
}

// MARK: - Packaging

private func runScript(_ relativePath: String, arguments: [String], home: URL, path: String,
                       extraEnvironment: [String: String] = [:]) throws -> (status: Int32, output: String) {
    let script = Fixtures.repositoryRoot.appendingPathComponent(relativePath).path
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [script] + arguments,
        environment: ["HOME": home.path, "PATH": path].merging(extraEnvironment) { _, extra in extra },
        timeout: 10
    )
    return (result.status, String(decoding: result.output, as: UTF8.self))
}

/// A PATH directory whose launchctl, swift, ditto and defaults only record that they were
/// called. `launchctl print` also exits 113 (launchd's "service not found"), so install.sh's
/// wait for the old job to unload ends at once.
private func makeRecordingBin(in directory: TemporaryDirectory) throws -> (path: String, callLog: URL) {
    let bin = directory.url.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let callLog = directory.file("calls.log")
    for tool in ["launchctl", "swift", "ditto", "defaults"] {
        let toolURL = bin.appendingPathComponent(tool)
        var stub = "#!/bin/sh\necho \"$(basename \"$0\") $*\" >> '\(callLog.path)'\n"
        if tool == "launchctl" {
            stub += "if [ \"$1\" = print ]; then exit 113; fi\n"
        }
        try stub.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }
    return ("\(bin.path):/usr/bin:/bin:/usr/sbin", callLog)
}

private func recordedCalls(_ callLog: URL) throws -> [String] {
    try String(contentsOf: callLog, encoding: .utf8).split(separator: "\n").map(String.init)
}

/// The full (non-dry) script runs below are safe only while every system-changing tool is
/// reached through PATH, where the recording stubs sit first, and while install.sh lets the
/// test replace the real build. This check runs before either script does.
private func expectScriptsReachSystemToolsThroughPath() throws {
    let absoluteTool = try NSRegularExpression(pattern: #"/(launchctl|ditto|defaults|swift)\b"#)
    for relativePath in ["scripts/install.sh", "scripts/uninstall.sh"] {
        let text = try String(contentsOf: Fixtures.repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
        let matches = absoluteTool.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        try expect(matches, equals: 0, "\(relativePath) calls launchctl, ditto, defaults and swift by name only")
    }
    let install = try String(contentsOf: Fixtures.repositoryRoot.appendingPathComponent("scripts/install.sh"),
                             encoding: .utf8)
    try expectTrue(install.contains("AGENT_ISLAND_BUILD_SCRIPT"), "install.sh lets the test replace the real build")
}

func testObservabilityRenderPlistHasAbsolutePathsAndNoSideEffects() throws {
    let directory = try TemporaryDirectory()
    let home = directory.url.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let bin = try makeRecordingBin(in: directory)
    let rendered = directory.file("ai.plist")
    let result = try runScript("scripts/install.sh", arguments: ["--render-plist", rendered.path], home: home,
                               path: bin.path)
    try expect(result.status, equals: 0, "--render-plist exits 0")
    try expectTrue(!FileManager.default.fileExists(atPath: bin.callLog.path),
                   "--render-plist never builds, copies or calls launchctl")
    try expect(try FileManager.default.contentsOfDirectory(atPath: home.path), equals: [],
               "--render-plist creates nothing under HOME")
    let text = try String(contentsOf: rendered, encoding: .utf8)
    try expectTrue(!text.contains("__HOME__") && !text.contains("~"), "no placeholder or tilde remains")
    guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: rendered), format: nil)
            as? [String: Any] else {
        throw TestFailure.expectation("rendered plist is a dictionary")
    }
    try expect(plist["Label"] as? String, equals: "com.nathan.agent-island", "label")
    try expect(plist["ProgramArguments"] as? [String],
               equals: [home.path + "/Applications/AgentIsland.app/Contents/MacOS/AgentIsland"], "absolute program path")
    try expect(plist["RunAtLoad"] as? Bool, equals: true, "RunAtLoad")
    try expect((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, equals: false,
               "KeepAlive restarts only after a crash or non-zero exit")
    try expect(plist["ProcessType"] as? String, equals: "Interactive", "ProcessType")
    try expect(plist["StandardErrorPath"] as? String, equals: home.path + "/.local/state/agent-island/stderr.log",
               "absolute stderr path")
}

func testObservabilityRenderPlistEscapesHomePath() throws {
    let directory = try TemporaryDirectory()
    let home = directory.url.appendingPathComponent("home & <preview> '")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let bin = try makeRecordingBin(in: directory)
    let rendered = directory.file("escaped.plist")
    let result = try runScript("scripts/install.sh", arguments: ["--render-plist", rendered.path],
                               home: home, path: bin.path)
    try expect(result.status, equals: 0, "special home path renders valid XML: \(result.output)")
    guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: rendered), format: nil)
            as? [String: Any] else { throw TestFailure.expectation("rendered dictionary") }
    try expect(plist["ProgramArguments"] as? [String],
               equals: [home.path + "/Applications/AgentIsland.app/Contents/MacOS/AgentIsland"],
               "program path survives XML encoding exactly")
    try expect(plist["StandardErrorPath"] as? String,
               equals: home.path + "/.local/state/agent-island/stderr.log", "log path round-trips")
    try expectTrue(!FileManager.default.fileExists(atPath: bin.callLog.path), "rendering has no live effects")
}

func testObservabilityInstallRejectsUnknownArguments() throws {
    let directory = try TemporaryDirectory()
    let bin = try makeRecordingBin(in: directory)
    let result = try runScript("scripts/install.sh", arguments: ["--bogus"], home: directory.url, path: bin.path)
    try expect(result.status, equals: 64, "usage error")
    try expectTrue(!FileManager.default.fileExists(atPath: bin.callLog.path), "nothing ran")
}

func testObservabilityUninstallDryRunPurgeListsOnlyIslandFiles() throws {
    let directory = try TemporaryDirectory()
    let home = directory.url.appendingPathComponent("home")
    let bin = try makeRecordingBin(in: directory)
    let result = try runScript("scripts/uninstall.sh", arguments: ["--dry-run", "--purge"], home: home, path: bin.path)
    try expect(result.status, equals: 0, "dry run exits 0")
    try expectTrue(!FileManager.default.fileExists(atPath: bin.callLog.path), "dry run calls nothing")
    let output = result.output
    try expectTrue(output.contains("\(home.path)/Library/LaunchAgents/com.nathan.agent-island.plist"), "removes the plist")
    try expectTrue(output.contains("\(home.path)/Applications/AgentIsland.app"), "removes the app")
    try expectTrue(output.contains("\(home.path)/Library/Application Support/AgentIsland"), "purges app support")
    try expectTrue(output.contains("\(home.path)/.local/state/agent-island/transitions.jsonl"), "purges the log")
    let stateDirectoryLines = output.split(separator: "\n").filter { $0.hasSuffix("/.local/state/agent-island") }
    try expect(stateDirectoryLines.count, equals: 0, "never removes the shared state directory itself")
    let keep = try runScript("scripts/uninstall.sh", arguments: ["--dry-run"], home: home, path: bin.path)
    try expectTrue(!keep.output.contains("Application Support"), "without --purge, state is kept")
}

func testObservabilityUninstallPurgeInFakeHomeRemovesOnlyIslandFiles() throws {
    try expectScriptsReachSystemToolsThroughPath()
    let fileManager = FileManager.default
    let directory = try TemporaryDirectory()
    let home = directory.url.appendingPathComponent("home")
    let agents = home.appendingPathComponent("Library/LaunchAgents")
    let plist = agents.appendingPathComponent("com.nathan.agent-island.plist")
    let otherAgent = agents.appendingPathComponent("com.example.other.plist")
    let app = home.appendingPathComponent("Applications/AgentIsland.app")
    let support = home.appendingPathComponent("Library/Application Support/AgentIsland")
    let state = home.appendingPathComponent(".local/state/agent-island")
    let islandStateFiles = ["transitions.jsonl", "transitions.1.jsonl", "transitions.2.jsonl", "stderr.log"]
        .map { state.appendingPathComponent($0) }
    let unrelatedStateFile = state.appendingPathComponent("unrelated-notes.txt")
    for folder in [agents, app.appendingPathComponent("Contents"), support, state] {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    for file in [plist, otherAgent, app.appendingPathComponent("Contents/Info.plist"),
                 support.appendingPathComponent("app.lock"), unrelatedStateFile] + islandStateFiles {
        try Data("x".utf8).write(to: file)
    }
    let bin = try makeRecordingBin(in: directory)

    let result = try runScript("scripts/uninstall.sh", arguments: ["--purge"], home: home, path: bin.path)

    try expect(result.status, equals: 0, "uninstall --purge exits 0")
    for removed in [plist, app, support] + islandStateFiles {
        try expectTrue(!fileManager.fileExists(atPath: removed.path), "removed \(removed.lastPathComponent)")
    }
    try expectTrue(fileManager.fileExists(atPath: state.path), "the shared state directory itself stays")
    try expectTrue(fileManager.fileExists(atPath: unrelatedStateFile.path), "a state file the island did not write stays")
    try expectTrue(fileManager.fileExists(atPath: otherAgent.path), "another LaunchAgent stays")
    try expect(try recordedCalls(bin.callLog), equals: [
        "launchctl bootout gui/\(getuid())/com.nathan.agent-island",
        "defaults delete com.nathan.agent-island",
    ], "unloads the job first, then deletes only the island's preferences")
}

func testObservabilityInstallInFakeHomeRendersPlistThenReloads() throws {
    try expectScriptsReachSystemToolsThroughPath()
    let fileManager = FileManager.default
    let directory = try TemporaryDirectory()
    let home = directory.url.appendingPathComponent("home")
    let staleBundle = home.appendingPathComponent("Applications/AgentIsland.app")
    try fileManager.createDirectory(at: staleBundle, withIntermediateDirectories: true)
    let staleMarker = staleBundle.appendingPathComponent("stale-marker")
    try Data("old".utf8).write(to: staleMarker)
    let bin = try makeRecordingBin(in: directory)
    // Stands in for scripts/build-app.sh, which would rebuild and re-sign the repo's real bundle.
    let buildStub = directory.file("build-app-stub.sh")
    try "#!/bin/sh\necho build-app >> '\(bin.callLog.path)'\n".write(to: buildStub, atomically: true, encoding: .utf8)

    let result = try runScript("scripts/install.sh", arguments: [], home: home, path: bin.path,
                               extraEnvironment: ["AGENT_ISLAND_BUILD_SCRIPT": buildStub.path])

    try expect(result.status, equals: 0, "install exits 0; output:\n\(result.output)")
    let label = "com.nathan.agent-island"
    let domain = "gui/\(getuid())"
    let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    let text = try String(contentsOf: plist, encoding: .utf8)
    try expectTrue(!text.contains("__HOME__"), "the installed plist is rendered")
    guard let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
            as? [String: Any] else {
        throw TestFailure.expectation("installed plist is a dictionary")
    }
    try expect(parsed["ProgramArguments"] as? [String],
               equals: [home.path + "/Applications/AgentIsland.app/Contents/MacOS/AgentIsland"],
               "the installed plist points into HOME/Applications")
    var isDirectory: ObjCBool = false
    try expectTrue(fileManager.fileExists(atPath: home.appendingPathComponent(".local/state/agent-island").path,
                                          isDirectory: &isDirectory) && isDirectory.boolValue,
                   "creates the StandardErrorPath directory, which launchd will not")
    try expectTrue(!fileManager.fileExists(atPath: staleMarker.path), "removes the old bundle before copying")

    let calls = try recordedCalls(bin.callLog)
    try expect(calls.count, equals: 6,
               "build, bootout, unload probe, copy, bootstrap, kickstart:\n\(calls.joined(separator: "\n"))")
    try expect(calls[0], equals: "build-app", "builds first, through AGENT_ISLAND_BUILD_SCRIPT")
    try expect(calls[1], equals: "launchctl bootout \(domain)/\(label)", "boots out the old job (errors ignored)")
    try expect(calls[2], equals: "launchctl print \(domain)/\(label)", "waits until launchd no longer knows the job")
    try expectTrue(calls[3].hasPrefix("ditto ")
                   && calls[3].hasSuffix("/.build/AgentIsland.app \(home.path)/Applications/AgentIsland.app"),
                   "copies the built bundle into HOME/Applications: \(calls[3])")
    try expect(calls[4], equals: "launchctl bootstrap \(domain) \(plist.path)", "bootstraps the rendered plist")
    try expect(calls[5], equals: "launchctl kickstart -k \(domain)/\(label)", "then restarts it with kickstart -k")
}

func testObservabilityScriptsNeverTouchAgentConfiguration() throws {
    let forbidden = try NSRegularExpression(pattern: #"\.claude|\.codex|herdr/config|settings\.json"#)
    for relativePath in ["scripts/install.sh", "scripts/uninstall.sh", "config/com.nathan.agent-island.plist"] {
        let text = try String(contentsOf: Fixtures.repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
        let matches = forbidden.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        try expect(matches, equals: 0, "\(relativePath) mentions no agent configuration")
    }
}

// MARK: - Test list

let observabilityTests: [TestCase] = [
    ("observability: a state change emits one record", testObservabilityStateChangeEmitsOneRecord),
    ("observability: new rows have no from; removed rows go to removed", testObservabilityNewAndRemovedRows),
    ("observability: a waiting state carries its truncated question", testObservabilityWaitingStateCarriesTruncatedQuestion),
    ("observability: peeks log peek.waiting/peek.error with a truncated question", testObservabilityPeekRecords),
    ("observability: chime and suppression records keep their rules", testObservabilityChimeAndSuppressionRecords),
    ("observability: herdr rows carry the registry status shadow", testObservabilityRegistryShadowOnHerdrRows),
    ("observability: every health change is a feed record", testObservabilityFeedHealthRecords),
    ("observability: truncateQuestion keeps 200 characters", testObservabilityTruncateQuestion),
    ("observability: a record is one JSON line with an ISO timestamp", testObservabilityRecordLineEncoding),
    ("observability: a jump failure record is typed and truncated", testObservabilityJumpFailureRecordIsTypedAndTruncated),
    ("observability: a diagnostic record is discriminated from a health report",
     testObservabilityDiagnosticRecordIsDiscriminatedFromAHealthReport),
    ("observability: transition log appends one JSON line per record", testObservabilityTransitionLogAppendsJSONLines),
    ("observability: transition log rotates past 10 MB to exactly 3 files",
     testObservabilityTransitionLogRotatesPastTenMegabytes),
    ("observability: transition log keeps the configured file count", testObservabilityTransitionLogKeepsConfiguredFileCount),
    ("observability: state dump snapshot keys", testObservabilityStateDumpSnapshotKeys),
    ("observability: state dump snapshot carries feed error counts", testObservabilityStateDumpSnapshotFeedErrorCounts),
    ("observability: state dump snapshot carries and clears lastErrorDescription",
     testObservabilityStateDumpSnapshotLastErrorDescription),
    ("observability: state dump round-trips through a plain decoder", testObservabilityStateDumpRoundTripsThroughPlainDecoder),
    ("observability: state dump write is atomic", testObservabilityStateDumpWriteIsAtomic),
    ("observability: the store records and reports jumpPerformer failures",
     testObservabilityStoreRecordsAndReportsJumpPerformerFailures),
    ("observability: a later successful focus clears lastErrorDescription",
     testObservabilityStoreClearsLastErrorDescriptionAfterALaterSuccessfulFocus),
    ("observability: a mark-seen failure survives that same call's successful perform",
     testObservabilityStoreKeepsAMarkSeenFailureAfterSuccessfulPerform),
    ("observability: an earlier error survives a concurrently started focus's later success",
     testObservabilityStoreKeepsAnEarlierErrorWhenAConcurrentlyStartedFocusLaterSucceeds),
    ("observability: the store exposes feed I/O error counts", testObservabilityStoreExposesFeedIOErrorCounts),
    ("observability: feedIOErrorCounts never traps on a duplicate source",
     testObservabilityStoreFeedIOErrorCountsNeverTrapsOnADuplicateSource),
    ("observability: the store wires feed diagnostics by source", testObservabilityStoreWiresFeedDiagnosticsBySource),
    ("observability: heartbeats and identical republishes append no bytes (permanent regression)",
     testObservabilityHeartbeatsAndIdenticalRepublishesAppendNoBytes),
    ("observability: the codex feed counts seen-store save failures",
     testObservabilityCodexFeedCountsSeenStoreSaveFailures),
    ("observability: the codex feed counts session-index read failures",
     testObservabilityCodexFeedCountsSessionIndexReadFailures),
    ("observability: the claude registry feed counts read and decode failures",
     testObservabilityClaudeRegistryFeedCountsReadAndDecodeFailures),
    ("observability: rendered plist has absolute paths and no side effects",
     testObservabilityRenderPlistHasAbsolutePathsAndNoSideEffects),
    ("observability: rendered plist escapes home path", testObservabilityRenderPlistEscapesHomePath),
    ("observability: install rejects unknown arguments", testObservabilityInstallRejectsUnknownArguments),
    ("observability: uninstall --dry-run --purge lists only the island's files",
     testObservabilityUninstallDryRunPurgeListsOnlyIslandFiles),
    ("observability: uninstall --purge in a fake HOME removes only the island's files",
     testObservabilityUninstallPurgeInFakeHomeRemovesOnlyIslandFiles),
    ("observability: install in a fake HOME renders the plist, then bootout, bootstrap, kickstart",
     testObservabilityInstallInFakeHomeRendersPlistThenReloads),
    ("observability: scripts never touch agent configuration", testObservabilityScriptsNeverTouchAgentConfiguration),
]

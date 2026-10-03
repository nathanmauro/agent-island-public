import Darwin
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Shared helpers

private let codexFeedStart = Date(timeIntervalSince1970: 1_790_000_000)

private func codexFeedAppend(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func codexFeedText(_ lines: [String]) -> Data {
    Data(lines.map { $0 + "\n" }.joined().utf8)
}

// MARK: - RolloutTailReader (hardening 3)

func testCodexFeedTailReaderBuffersPartialLine() throws {
    let directory = try TemporaryDirectory(prefix: "codex-tail")
    let url = directory.file("rollout.jsonl")
    try Data().write(to: url)
    var reader = RolloutTailReader(url: url, startOffset: 0)
    let line = RolloutLine.taskStarted(turnID: "turn-1", at: codexFeedStart)
    let bytes = Data((line + "\n").utf8)
    let half = bytes.count / 2

    try codexFeedAppend(bytes.prefix(half), to: url)
    try expect(try reader.readNewLines(), equals: .lines([]), "half a line yields nothing")
    try expect(reader.bufferedByteCount, equals: half, "the partial line is buffered")

    try codexFeedAppend(bytes.suffix(from: half), to: url)
    try expect(try reader.readNewLines(), equals: .lines([Data(line.utf8)]), "the rest yields exactly one line")
    try expect(reader.bufferedByteCount, equals: 0, "nothing left buffered")
    try expect(reader.offset, equals: UInt64(bytes.count), "offset is at EOF")
    try expect(try reader.readNewLines(), equals: .lines([]), "no new bytes, no lines")
}

func testCodexFeedTailReaderResetsOnTruncateAndReplace() throws {
    let directory = try TemporaryDirectory(prefix: "codex-tail")
    let url = directory.file("rollout.jsonl")
    let lines = [
        RolloutLine.taskStarted(turnID: "turn-1", at: codexFeedStart),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexFeedStart),
    ]
    try codexFeedText(lines).write(to: url)
    var reader = RolloutTailReader(url: url, startOffset: 0)
    try expect(try reader.readNewLines(), equals: .lines(lines.map { Data($0.utf8) }), "initial read")

    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 10)
    try handle.close()
    try expect(try reader.readNewLines(), equals: .reset, "a file shrunk below the offset resets")

    try codexFeedText(lines).write(to: url)
    var second = RolloutTailReader(url: url, startOffset: 0)
    _ = try second.readNewLines()
    let replacement = directory.file("replacement.tmp")
    try codexFeedText(lines + lines).write(to: replacement)
    try expect(Darwin.rename(replacement.path, url.path), equals: 0, "rename over the rollout")
    try expect(try second.readNewLines(), equals: .reset, "a replaced file (new inode) resets")
}

func testCodexFeedTailReaderSkipsOverlongLine() throws {
    let directory = try TemporaryDirectory(prefix: "codex-tail")
    let url = directory.file("rollout.jsonl")
    try Data().write(to: url)
    let limit = IslandTiming.codexMaxLineBytes
    var reader = RolloutTailReader(url: url, startOffset: 0)

    try codexFeedAppend(Data(repeating: UInt8(ascii: "x"), count: limit / 2), to: url)
    try expect(try reader.readNewLines(), equals: .lines([]), "first half of the long line")
    try expectTrue(reader.bufferedByteCount <= limit, "buffer stays within the cap")

    try codexFeedAppend(Data(repeating: UInt8(ascii: "x"), count: limit / 2 + 1), to: url)
    try expect(try reader.readNewLines(), equals: .lines([]), "the 1 MB + 1 line is not emitted")
    try expectTrue(reader.bufferedByteCount <= limit, "never buffers more than 1 MB (got \(reader.bufferedByteCount))")

    let valid = RolloutLine.taskStarted(turnID: "turn-2", at: codexFeedStart)
    try codexFeedAppend(Data(("tail of the long line\n" + valid + "\n").utf8), to: url)
    try expect(try reader.readNewLines(), equals: .lines([Data(valid.utf8)]), "the next line after the long one is read")
}

private let codexFeedReaderCases: [TestCase] = [
    ("codexFeed: tail reader buffers a partial line (hardening 3)", testCodexFeedTailReaderBuffersPartialLine),
    ("codexFeed: tail reader resets on truncate and replace (hardening 3)", testCodexFeedTailReaderResetsOnTruncateAndReplace),
    ("codexFeed: tail reader skips a 1 MB + 1 line (hardening 3)", testCodexFeedTailReaderSkipsOverlongLine),
]

// MARK: - Cold start

func testCodexFeedColdStartScanFindsLastTaskStarted() throws {
    let directory = try TemporaryDirectory(prefix: "codex-scan")
    let url = directory.file("rollout.jsonl")
    let meta = RolloutLine.sessionMeta(id: "0199f000-0000-7000-8000-00000000c001", at: codexFeedStart)
    let started2 = RolloutLine.taskStarted(turnID: "turn-2", at: codexFeedStart.addingTimeInterval(4))
    let filler = RolloutLine.filler(approximateBytes: 150, at: codexFeedStart.addingTimeInterval(5))
    let complete = [
        meta,
        RolloutLine.taskStarted(turnID: "turn-1", at: codexFeedStart.addingTimeInterval(1)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: codexFeedStart.addingTimeInterval(2)),
        RolloutLine.filler(approximateBytes: 300, at: codexFeedStart.addingTimeInterval(3)),
        started2,
        filler,
    ]
    var data = codexFeedText(complete)
    let endOfCompleteLines = UInt64(data.count)
    data.append(Data(#"{"timestamp":"2026-09-21T14:13:30.000Z","type":"event_"#.utf8))
    try data.write(to: url)

    let scan = try CodexColdStartScanner.scan(url: url, chunk: 64)
    try expect(scan.firstLine, equals: Data(meta.utf8), "line 1 is read separately")
    try expect(scan.tail, equals: [Data(started2.utf8), Data(filler.utf8)], "tail starts at the last task_started")
    try expect(scan.endOffset, equals: endOfCompleteLines, "the trailing partial line is left for the tail reader")
    let prefix = codexFeedText(Array(complete.prefix(4)))
    try expect(scan.resumeOffset, equals: UInt64(prefix.count), "resumeOffset is the task_started line start")

    let noTurn = directory.file("no-turn.jsonl")
    try codexFeedText([meta, filler]).write(to: noTurn)
    let noTurnScan = try CodexColdStartScanner.scan(url: noTurn, chunk: 64)
    try expect(noTurnScan.tail, equals: [Data(filler.utf8)], "without task_started the tail is every line after line 1")

    let partialOnly = directory.file("partial.jsonl")
    try Data(#"{"timestamp":"2026-09-21T14"#.utf8).write(to: partialOnly)
    let partialScan = try CodexColdStartScanner.scan(url: partialOnly)
    try expect(partialScan.firstLine == nil && partialScan.tail.isEmpty && partialScan.endOffset == 0, equals: true,
               "an unfinished first line is left for the tail reader")
}

private func codexFeedOversizedMetaLine(id: String) -> String {
    let padding = String(repeating: "x", count: IslandTiming.codexFirstLineCap + 50_000)
    return #"{"timestamp":"2026-09-21T14:13:20.000Z","type":"session_meta","payload":{"id":""# + id
        + #"","cwd":"/tmp/fixture-project","originator":"Codex Desktop","source":"vscode","thread_source":"user","base_instructions":{"text":""#
        + padding + #""}}}"#
}

func testCodexFeedColdStartCapsFirstLineAndUsesFileNameID() throws {
    let directory = try TemporaryDirectory(prefix: "codex-scan")
    let threadID = "0199f000-0000-7000-8000-00000000c002"
    let url = directory.file(RolloutLine.fileName(threadID: threadID, at: codexFeedStart))
    let started = RolloutLine.taskStarted(turnID: "turn-1", at: codexFeedStart.addingTimeInterval(1))
    try codexFeedText([codexFeedOversizedMetaLine(id: threadID), started]).write(to: url)

    let scan = try CodexColdStartScanner.scan(url: url)
    try expect(scan.firstLine == nil, equals: true, "a session_meta over 1 MB is capped")
    try expect(scan.tail, equals: [Data(started.utf8)], "the over-long line 1 never reaches the tail")

    var reducer = CodexReducer()
    _ = reducer.ingest(lines: scan.tail, file: CodexRolloutFile(path: url.path))
    try expect(reducer.threads[threadID]?.openTurnID, equals: "turn-1", "thread id comes from the file-name UUID")
    try expect(reducer.threads[threadID]?.meta == nil, equals: true, "meta stays missing")
    let rows = CodexReducer.rows(threads: Array(reducer.threads.values), seen: CodexSeenStore(), titles: [:],
                                 showExec: true, codexRunning: true, now: codexFeedStart.addingTimeInterval(60))
    try expect(rows.isEmpty, equals: true, "the thread is hidden rather than misclassified")
}

func testCodexFeedColdStartOf200MBFileUnder300ms() throws {
    let directory = try TemporaryDirectory(prefix: "codex-large")
    let threadID = "0199f000-0000-7000-8000-00000000c200"
    let url = directory.file(RolloutLine.fileName(threadID: threadID, at: codexFeedStart))
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data((RolloutLine.sessionMeta(id: threadID, at: codexFeedStart) + "\n").utf8))
    let fillerLine = RolloutLine.filler(approximateBytes: 65_536, at: codexFeedStart) + "\n"
    let block = Data(String(repeating: fillerLine, count: 16).utf8)
    for _ in 0..<192 {
        try handle.write(contentsOf: block)
    }
    let started = RolloutLine.taskStarted(turnID: "turn-big", at: codexFeedStart.addingTimeInterval(1))
    try handle.write(contentsOf: Data((started + "\n").utf8))
    try handle.write(contentsOf: Data(String(repeating: fillerLine, count: 86).utf8))
    try handle.close()
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    try expectTrue(size >= 200_000_000, "synthetic rollout is at least 200 MB (got \(size))")

    let begin = DispatchTime.now().uptimeNanoseconds
    let scan = try CodexColdStartScanner.scan(url: url)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: (scan.firstLine.map { [$0] } ?? []) + scan.tail, file: CodexRolloutFile(path: url.path))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
    try expectTrue(elapsed < 300, "scan + ingest took \(Int(elapsed)) ms (limit 300)")

    try expect(reducer.threads[threadID]?.meta?.id, equals: threadID, "session_meta found")
    try expect(reducer.threads[threadID]?.openTurnID, equals: "turn-big", "in-progress turn found")
    try expect(scan.tail.count, equals: 87, "tail = task_started + 86 filler lines (about 5.6 MB)")
    let rows = CodexReducer.rows(threads: Array(reducer.threads.values), seen: CodexSeenStore(), titles: [:],
                                 showExec: false, codexRunning: true, now: codexFeedStart.addingTimeInterval(60))
    try expect(rows.map(\.state), equals: [.working], "the in-progress turn is working")
}

/// Pre-flight ruling S3: the backward scan runs to the last task_started even when the file's
/// last event is a task_complete (no trailing in-progress turn) — the scan still has to walk the
/// same distance back from EOF, so this is a distinct perf case from the in-progress one above.
func testCodexFeedColdStartOf200MBFileEndingInTaskCompleteUnder300ms() throws {
    let directory = try TemporaryDirectory(prefix: "codex-large")
    let threadID = "0199f000-0000-7000-8000-00000000c201"
    let url = directory.file(RolloutLine.fileName(threadID: threadID, at: codexFeedStart))
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data((RolloutLine.sessionMeta(id: threadID, at: codexFeedStart) + "\n").utf8))
    let fillerLine = RolloutLine.filler(approximateBytes: 65_536, at: codexFeedStart) + "\n"
    let block = Data(String(repeating: fillerLine, count: 16).utf8)
    for _ in 0..<192 {
        try handle.write(contentsOf: block)
    }
    let started = RolloutLine.taskStarted(turnID: "turn-big", at: codexFeedStart.addingTimeInterval(1))
    try handle.write(contentsOf: Data((started + "\n").utf8))
    try handle.write(contentsOf: Data(String(repeating: fillerLine, count: 85).utf8))
    let completed = RolloutLine.taskComplete(turnID: "turn-big", message: "Fixture recap.",
                                             at: codexFeedStart.addingTimeInterval(2))
    try handle.write(contentsOf: Data((completed + "\n").utf8))
    try handle.close()
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    try expectTrue(size >= 200_000_000, "synthetic rollout is at least 200 MB (got \(size))")

    let begin = DispatchTime.now().uptimeNanoseconds
    let scan = try CodexColdStartScanner.scan(url: url)
    var reducer = CodexReducer()
    _ = reducer.ingest(lines: (scan.firstLine.map { [$0] } ?? []) + scan.tail, file: CodexRolloutFile(path: url.path))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
    try expectTrue(elapsed < 300, "scan + ingest took \(Int(elapsed)) ms (limit 300)")

    try expect(reducer.threads[threadID]?.meta?.id, equals: threadID, "session_meta found")
    try expect(reducer.threads[threadID]?.lastCompletedTurnID, equals: "turn-big", "the completed turn is found")
    let rows = CodexReducer.rows(threads: Array(reducer.threads.values), seen: CodexSeenStore(), titles: [:],
                                 showExec: false, codexRunning: true, now: codexFeedStart.addingTimeInterval(60))
    try expect(rows.map(\.state), equals: [.doneUnseen], "the completed turn is doneUnseen")
}

private let codexFeedColdStartCases: [TestCase] = [
    ("codexFeed: cold start reads line 1 and scans back to the last task_started", testCodexFeedColdStartScanFindsLastTaskStarted),
    ("codexFeed: cold start caps line 1 and keys the thread by file name", testCodexFeedColdStartCapsFirstLineAndUsesFileNameID),
    ("codexFeed: cold start of a 200 MB rollout takes under 300 ms", testCodexFeedColdStartOf200MBFileUnder300ms),
    ("codexFeed: cold start of a 200 MB rollout ending in task_complete takes under 300 ms (pre-flight ruling S3)", testCodexFeedColdStartOf200MBFileEndingInTaskCompleteUnder300ms),
]

// MARK: - Feed

@MainActor
private final class CodexFeedHarness {
    let root: TemporaryDirectory
    let sessions: URL
    let indexURL: URL
    let seenURL: URL
    let clock: ManualWallClock
    let activity = FakeAppActivity()
    var showExec = false
    var rows: [AgentRow] = []
    var health: [FeedHealth] = []
    private(set) var feed: CodexDesktopFeed!

    init(createSessions: Bool = true, pollInterval: TimeInterval = 600) throws {
        root = try TemporaryDirectory(prefix: "codex-feed")
        sessions = root.url.appendingPathComponent("sessions", isDirectory: true)
        indexURL = root.url.appendingPathComponent("session_index.jsonl")
        seenURL = root.url.appendingPathComponent("support", isDirectory: true).appendingPathComponent("codex-seen.json")
        clock = ManualWallClock(Date())
        if createSessions {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
        activity.running = [KnownBundleIDs.codex]
        feed = makeFeed(pollInterval: pollInterval)
    }

    func makeFeed(pollInterval: TimeInterval = 600) -> CodexDesktopFeed {
        var configuration = CodexDesktopFeed.Configuration.standard
        configuration.statPollInterval = pollInterval
        return CodexDesktopFeed(sessionsDirectory: sessions, sessionIndexURL: indexURL, seenStoreURL: seenURL,
                                activity: activity, clock: clock, showExecThreads: { [unowned self] in self.showExec },
                                configuration: configuration)
    }

    func start() {
        feed.observeHealth { [unowned self] health in self.health.append(health) }
        feed.start { [unowned self] rows in self.rows = rows }
    }

    /// A time `secondsAgo` before the harness clock.
    func ago(_ secondsAgo: TimeInterval) -> Date {
        clock.now().addingTimeInterval(-secondsAgo)
    }

    @discardableResult
    func writeRollout(threadID: String, lines: [String], day: String = "2026/09/25") throws -> URL {
        let directory = sessions.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(RolloutLine.fileName(threadID: threadID, at: ago(3_600)))
        try codexFeedText(lines).write(to: url)
        return url
    }

    func append(_ lines: [String], to url: URL) throws {
        try codexFeedAppend(codexFeedText(lines), to: url)
    }

    var states: [DisplayState] { rows.map(\.state) }

    func row(_ threadID: String) -> AgentRow? {
        rows.first { $0.id == RowID(source: .codexDesktop, key: threadID) }
    }
}

@MainActor
func testCodexFeedFSEventsSeesNestedAppendWithin2s() throws {
    let harness = try CodexFeedHarness(pollInterval: 600)
    defer { harness.feed.stop() }
    harness.start()
    try expect(harness.rows.isEmpty, equals: true, "empty sessions dir")

    let threadID = "0199f000-0000-7000-8000-00000000d001"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(59)),
    ], day: "2026/09/26")
    try spinMainRunLoop(timeout: 2) { harness.row(threadID)?.state == .working }

    try harness.append([RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(10))], to: url)
    try spinMainRunLoop(timeout: 2) { harness.row(threadID)?.state == .doneUnseen }
}

@MainActor
func testCodexFeedPollTimerRepublishesWithoutFileEvents() throws {
    let harness = try CodexFeedHarness(pollInterval: 0.1)
    defer { harness.feed.stop() }
    let workingID = "0199f000-0000-7000-8000-00000000d002"
    let doneID = "0199f000-0000-7000-8000-00000000d015"
    try harness.writeRollout(threadID: workingID, lines: [
        RolloutLine.sessionMeta(id: workingID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(59)),
    ])
    let doneURL = try harness.writeRollout(threadID: doneID, lines: [
        RolloutLine.sessionMeta(id: doneID, at: harness.ago(60)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(30)),
        RolloutLine.taskComplete(turnID: "turn-1", message: nil, at: harness.ago(20)),
    ], to: doneURL)
    try spinMainRunLoop(timeout: 2) { harness.row(doneID)?.state == .doneUnseen }
    try expect(harness.row(workingID)?.state, equals: .working, "open turn")

    harness.activity.running = []
    try spinMainRunLoop(timeout: 2) { harness.row(workingID)?.state == .stale }
    harness.clock.advance(by: IslandTiming.seenExpiry + 1)
    try spinMainRunLoop(timeout: 2) { harness.row(doneID)?.state == .idle }
}

@MainActor
func testCodexFeedIgnoresFilesOlderThan24h() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let oldID = "0199f000-0000-7000-8000-00000000d003"
    let freshID = "0199f000-0000-7000-8000-00000000d004"
    let old = try harness.writeRollout(threadID: oldID, lines: [
        RolloutLine.sessionMeta(id: oldID, at: harness.ago(100_000)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(99_999)),
    ], day: "2026/09/23")
    try FileManager.default.setAttributes([.modificationDate: harness.ago(25 * 3_600)], ofItemAtPath: old.path)
    try harness.writeRollout(threadID: freshID, lines: [
        RolloutLine.sessionMeta(id: freshID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(59)),
    ])
    harness.start()
    try expect(harness.rows.map(\.id.key), equals: [freshID], "only files modified in the last 24 h")
}

@MainActor
func testCodexFeedTruncateAndReplaceRerunColdStart() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d005"
    let meta = RolloutLine.sessionMeta(id: threadID, at: harness.ago(600))
    let url = try harness.writeRollout(threadID: threadID, lines: [
        meta,
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(590)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(580)),
    ])
    harness.start()
    try harness.append([RolloutLine.taskStarted(turnID: "turn-2", at: harness.ago(500))], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.working], "appended task_started")

    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: codexFeedText([
        meta,
        RolloutLine.taskStarted(turnID: "turn-3", at: harness.ago(400)),
        RolloutLine.taskComplete(turnID: "turn-3", message: "Fixture recap three.", at: harness.ago(390)),
    ]))
    try handle.close()
    harness.feed.pollNow()
    try expect(harness.states, equals: [.doneUnseen], "a shrunk file is cold-started again")
    try expect(harness.row(threadID)?.detail?.question, equals: "Fixture recap three.", "state comes from the new content")

    let replacement = harness.root.file("replacement.tmp")
    try codexFeedText([
        meta,
        RolloutLine.taskStarted(turnID: "turn-4", at: harness.ago(300)),
        RolloutLine.filler(approximateBytes: 2_000, at: harness.ago(299)),
    ]).write(to: replacement)
    try expect(Darwin.rename(replacement.path, url.path), equals: 0, "replace the rollout")
    harness.feed.pollNow()
    try expect(harness.states, equals: [.working], "a replaced file is cold-started again")
    try expect(harness.rows.count, equals: 1, "no duplicate thread or turn")
}

@MainActor
func testCodexFeedSkipsInvalidUTF8AndJSONLines() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d006"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
        "{not json",
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
    ])
    harness.start()
    try expect(harness.states, equals: [.working], "a malformed line during cold start is skipped")
    var garbage = Data([0xC3, 0x28, 0xFF, 0xFE])
    garbage.append(Data(#""task_complete""#.utf8))
    garbage.append(0x0A)
    try codexFeedAppend(garbage, to: url)
    try harness.append([RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(40))], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.doneUnseen], "an invalid UTF-8 line is skipped; the next line applies")
}

@MainActor
func testCodexFeedSeenBaselineThenLaterCompletion() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d007"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(590)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(580)),
    ])
    try expect(FileManager.default.fileExists(atPath: harness.seenURL.path), equals: false, "first launch")
    harness.start()
    try expect(harness.states, equals: [.idle], "first launch: completed turns are baselined as seen")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: true,
               "codex-seen.json is written with the baseline")

    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-2", at: harness.ago(100)),
        RolloutLine.taskComplete(turnID: "turn-2", message: "Fixture recap two.", at: harness.ago(90)),
    ], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.doneUnseen], "a later completion is unseen")
}

@MainActor
func testCodexFeedCodexActivationPreservesUnseenCompletions() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d008"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(90)),
    ], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.doneUnseen], "unseen completion")

    harness.activity.activate("com.apple.finder")
    try expect(harness.states, equals: [.doneUnseen], "another app's activation changes nothing")
    harness.activity.activate(KnownBundleIDs.codex)
    try expect(harness.states, equals: [.doneUnseen], "app activation does not identify the viewed thread")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: false,
               "activation does not persist acknowledgment")
}

@MainActor
func testCodexFeedAcknowledgmentIsThreadSpecificAcrossRestart() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let ids = (1...5).map { "0199f000-0000-7000-8000-00000000a00\($0)" }
    let files = try ids.map { id in
        try harness.writeRollout(threadID: id, lines: [RolloutLine.sessionMeta(id: id, at: harness.ago(600))])
    }
    harness.start() // Establish the baseline before any of these turns finish.
    for (index, file) in files.enumerated() {
        var lines = [RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100))]
        if index == 2 {
            lines += [RolloutLine.functionCallAsync(callID: "question-1", title: "Choose a fixture?",
                                                   options: ["A", "B"], at: harness.ago(95)),
                      RolloutLine.functionCallOutput(callID: "question-1", at: harness.ago(94))]
        }
        if index == 3 {
            lines.append(RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "fixture_error",
                                                        message: "Fixture failed.", at: harness.ago(90)))
        } else if index != 4 {
            lines.append(RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(90)))
        }
        try harness.append(lines, to: file)
    }
    harness.feed.pollNow()
    let before = Dictionary(uniqueKeysWithValues: harness.rows.map { ($0.id.key, $0) })
    try expect(ids.map { before[$0]?.state }, equals: [.doneUnseen, .doneUnseen, .waiting, .error, .working],
               "two completions, a question, a failure and active work")
    harness.activity.activate(KnownBundleIDs.codex)
    try expect(Dictionary(uniqueKeysWithValues: harness.rows.map { ($0.id.key, $0) }), equals: before,
               "app activation preserves every row and its details")
    for id in ids {
        try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: id, turnID: "turn-1"),
                   equals: false, "no completion was silently acknowledged")
    }
    guard let selected = before[ids[0]] else { throw TestFailure.expectation("selected row exists") }
    let feed = harness.feed!
    var jumpFinished = false
    var jumpError: Error?
    Task { @MainActor in
        do { try await feed.jump(selected) } catch { jumpError = error }
        jumpFinished = true
    }
    try spinMainRunLoop(timeout: 2) { jumpFinished }
    try expectTrue(jumpError == nil, "row acknowledgment succeeds")
    harness.activity.activate(KnownBundleIDs.codex)
    feed.stop()
    let restarted = harness.makeFeed()
    defer { restarted.stop() }
    var restored: [AgentRow] = []
    restarted.start { restored = $0 }
    let after = Dictionary(uniqueKeysWithValues: restored.map { ($0.id.key, $0) })
    try expect(after[ids[0]]?.state, equals: .idle, "only the selected result is acknowledged")
    for id in ids.dropFirst() {
        try expect(after[id], equals: before[id], "other results and details survive activation and restart")
    }
    for (index, id) in ids.enumerated() {
        try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: id, turnID: "turn-1"),
                   equals: index == 0, "persisted acknowledgment belongs only to the selected thread")
    }
}

@MainActor
func testCodexFeedOlderRowCannotAcknowledgeNewerCompletion() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let id = "0199f000-0000-7000-8000-00000000b001"
    let file = try harness.writeRollout(threadID: id, lines: [RolloutLine.sessionMeta(id: id, at: harness.ago(600))])
    harness.start()
    func complete(_ turn: String) throws {
        try harness.append([RolloutLine.taskStarted(turnID: turn, at: harness.ago(100)),
                            RolloutLine.taskComplete(turnID: turn, message: turn, at: harness.ago(90))], to: file)
        harness.feed.pollNow()
    }
    try complete("turn-A")
    guard let selected = harness.row(id) else { throw TestFailure.expectation("row A exists") }
    try complete("turn-B") // Deliberately equal timestamps: identity must not depend on time.
    let feed = harness.feed!
    var finished = false
    var failure: Error?
    Task { @MainActor in
        do { try await feed.jump(selected) } catch { failure = error }
        finished = true
    }
    try spinMainRunLoop(timeout: 2) { finished }
    try expectTrue(failure == nil, "old acknowledgment is harmless")
    try expect(harness.row(id)?.state, equals: .doneUnseen, "new completion stays unread")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: id, turnID: "turn-B"), equals: false,
               "a click on A cannot persist B as seen")
    guard let current = harness.row(id) else { throw TestFailure.expectation("B exists") }
    finished = false
    Task { @MainActor in
        do { try await feed.jump(current); try await feed.jump(selected) } catch { failure = error }
        finished = true
    }
    try spinMainRunLoop(timeout: 2) { finished }
    try expectTrue(failure == nil, "current and delayed acknowledgment finish")
    try expect(harness.row(id)?.state, equals: .idle, "B stays acknowledged")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: id, turnID: "turn-B"), equals: true,
               "late A does not overwrite B's persisted seen identity")
}

@MainActor
func testCodexFeedCapturedWorkingAndSupersededErrorDoNotAcknowledge() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let id = "0199f000-0000-7000-8000-00000000b002"
    let file = try harness.writeRollout(threadID: id, lines: [
        RolloutLine.sessionMeta(id: id, at: harness.ago(600)),
        RolloutLine.taskStarted(turnID: "turn-A", at: harness.ago(100))])
    harness.start()
    guard let working = harness.row(id) else { throw TestFailure.expectation("working row exists") }
    func acknowledge(_ captured: AgentRow) throws {
        var finished = false
        var failure: Error?
        let feed = harness.feed!
        Task { @MainActor in
            do { try await feed.jump(captured) } catch { failure = error }
            finished = true
        }
        try spinMainRunLoop(timeout: 2) { finished }
        try expectTrue(failure == nil, "invalidated acknowledgment is harmless")
    }
    try harness.append([RolloutLine.taskComplete(turnID: "turn-A", message: "A", at: harness.ago(90))], to: file)
    harness.feed.pollNow()
    try acknowledge(working)
    try expect(harness.row(id)?.state, equals: .doneUnseen, "clicking working does not acknowledge a future result")
    guard let completed = harness.row(id) else { throw TestFailure.expectation("completed row exists") }
    try harness.append([RolloutLine.errorEvent(message: "Standalone error", at: harness.ago(80))], to: file)
    harness.feed.pollNow()
    try acknowledge(completed)
    try expect(harness.row(id)?.state, equals: .error, "a superseding standalone error stays visible")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: id, turnID: "turn-A"), equals: false,
               "superseded result is not acknowledged")
}

@MainActor
func testCodexFeedJumpMarksSeenLoadDetailDoesNot() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d009"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100)),
        RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(90)),
    ], to: url)
    harness.feed.pollNow()
    guard let row = harness.row(threadID) else { throw TestFailure.expectation("row exists") }

    harness.feed.loadDetail(for: row)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.doneUnseen], "loadDetail never marks seen")

    let feed = harness.feed!
    Task { @MainActor in try await feed.jump(row) }
    try spinMainRunLoop(timeout: 2) { harness.states == [.idle] }
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: true,
               "jump persists seen")
}

@MainActor
func testCodexFeedSecondInstanceSeesPersistedSeenState() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let firstID = "0199f000-0000-7000-8000-00000000d010"
    let secondID = "0199f000-0000-7000-8000-00000000d011"
    let first = try harness.writeRollout(threadID: firstID, lines: [RolloutLine.sessionMeta(id: firstID, at: harness.ago(600))])
    let second = try harness.writeRollout(threadID: secondID, lines: [RolloutLine.sessionMeta(id: secondID, at: harness.ago(600))])
    harness.start()
    for url in [first, second] {
        try harness.append([
            RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100)),
            RolloutLine.taskComplete(turnID: "turn-1", message: "Fixture recap.", at: harness.ago(90)),
        ], to: url)
    }
    harness.feed.pollNow()
    guard let firstRow = harness.row(firstID) else { throw TestFailure.expectation("first row exists") }
    let feed = harness.feed!
    Task { @MainActor in try await feed.jump(firstRow) }
    try spinMainRunLoop(timeout: 2) { harness.row(firstID)?.state == .idle }
    feed.stop()

    let secondFeed = harness.makeFeed()
    defer { secondFeed.stop() }
    var rows: [AgentRow] = []
    secondFeed.start { rows = $0 }
    let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.key, $0.state) })
    try expect(states[firstID], equals: .idle, "the seen mark persisted across instances")
    try expect(states[secondID], equals: .doneUnseen, "no re-baseline: an unseen completion stays unseen")
}

@MainActor
func testCodexFeedHealthForMissingSessionsDirectory() throws {
    let harness = try CodexFeedHarness(createSessions: false)
    defer { harness.feed.stop() }
    harness.activity.running = []
    harness.start()
    try expect(harness.health.last, equals: .inactive(reason: "sessions dir missing"), "no glyph before Codex was seen running")
    harness.activity.running = [KnownBundleIDs.codex]
    harness.feed.pollNow()
    try expect(harness.health.last, equals: .offline(reason: "sessions dir missing"), "glyph once Codex has run")
    harness.activity.running = []
    harness.feed.pollNow()
    try expect(harness.health.last, equals: .offline(reason: "sessions dir missing"), "stays offline after Codex quits")
    try FileManager.default.createDirectory(at: harness.sessions, withIntermediateDirectories: true)
    harness.feed.pollNow()
    try expect(harness.health.last, equals: .online, "online once the directory exists")
}

@MainActor
func testCodexFeedWorkingBecomesStaleWhenCodexNotRunning() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d012"
    try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
    ])
    harness.activity.running = []
    harness.start()
    try expect(harness.states, equals: [.stale], "working → stale while Codex is not running")
    harness.activity.running = [KnownBundleIDs.codex]
    harness.feed.pollNow()
    try expect(harness.states, equals: [.working], "working again once Codex runs")
}

@MainActor
func testCodexFeedShowExecThreadsToggles() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d013"
    try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, originator: "codex_exec", sourceJSON: #""exec""#, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
    ])
    harness.start()
    try expect(harness.rows.isEmpty, equals: true, "exec threads hidden by default")
    harness.showExec = true
    harness.feed.pollNow()
    try expect(harness.states, equals: [.working], "shown when showExecThreads is on")
    harness.showExec = false
    harness.feed.pollNow()
    try expect(harness.rows.isEmpty, equals: true, "hidden again when it is off")
}

@MainActor
func testCodexFeedTitlesFollowSessionIndex() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d014"
    try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
    ])
    harness.start()
    try expect(harness.row(threadID)?.title, equals: "fixture-project", "cwd basename without an index")
    try Data((#"{"id":""# + threadID + #"","thread_name":"Fixture title","updated_at":"2026-09-21T14:13:20.000Z"}"# + "\n").utf8)
        .write(to: harness.indexURL)
    harness.feed.pollNow()
    try expect(harness.row(threadID)?.title, equals: "Fixture title", "title from session_index.jsonl")
}

// MARK: - Feed: re-registration (Task 3's StateStore re-observes after stop() then start())

@MainActor
func testCodexFeedReRegistrationAfterStopStartHasNoDuplicateCallbacks() throws {
    let harness = try CodexFeedHarness()
    let threadID = "0199f000-0000-7000-8000-00000000d016"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
    ])
    var firstHealthCount = 0
    var firstPublishCount = 0
    harness.feed.observeHealth { _ in firstHealthCount += 1 }
    harness.feed.start { _ in firstPublishCount += 1 }
    harness.feed.stop()

    var secondHealthCount = 0
    var secondPublishCount = 0
    harness.feed.observeHealth { _ in secondHealthCount += 1 }
    harness.feed.start { _ in secondPublishCount += 1 }
    defer { harness.feed.stop() }

    try harness.append([RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(30))], to: url)
    harness.feed.pollNow()

    try expect(firstPublishCount, equals: 1, "the stale publish callback from before stop() never fires again")
    try expectTrue(secondPublishCount >= 1, "the latest publish callback receives the refreshed rows")
    try expect(firstHealthCount, equals: 1, "the stale health callback from before stop() never fires again")
    try expectTrue(secondHealthCount >= 1, "the latest health callback is the one that keeps firing")
}

/// Fix round 1 (Task 10 review, Minor): stop() must clear lastRows, so a subscriber that
/// registers after a restart gets an initial publish even when the rows have not changed since
/// before stop() — otherwise `rows != lastRows` compares the fresh rows against a stale value the
/// new subscriber never saw, and the republish is silently skipped.
@MainActor
func testCodexFeedRestartRepublishesUnchangedRowsToNewSubscriber() throws {
    let harness = try CodexFeedHarness()
    let threadID = "0199f000-0000-7000-8000-00000000d022"
    try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
    ])
    harness.start()
    try expect(harness.states, equals: [.working], "initial state before the restart")
    harness.feed.stop()

    var rows: [AgentRow]?
    harness.feed.start { rows = $0 }
    defer { harness.feed.stop() }
    try expect(rows != nil, equals: true,
               "a new subscriber gets an initial publish even though rows are unchanged from before stop()")
    try expect(rows?.map(\.state), equals: [.working], "same rows as before the restart")
}

// MARK: - Feed: failed turns are closed turns (seen covers completed OR failed)

@MainActor
func testCodexFeedJumpClearsFailedTurnToIdle() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d017"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: harness.ago(90)),
    ], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.error], "unseen failure is an error row")
    guard let row = harness.row(threadID) else { throw TestFailure.expectation("row exists") }

    let feed = harness.feed!
    Task { @MainActor in try await feed.jump(row) }
    try spinMainRunLoop(timeout: 2) { harness.states == [.idle] }
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: true,
               "jump persists the failed turn as seen")
}

@MainActor
func testCodexFeedActivationPreservesFailedTurn() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d018"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(100)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: harness.ago(90)),
    ], to: url)
    harness.feed.pollNow()
    try expect(harness.states, equals: [.error], "unseen failure is an error row")

    harness.activity.activate("com.apple.finder")
    try expect(harness.states, equals: [.error], "another app's activation changes nothing")
    harness.activity.activate(KnownBundleIDs.codex)
    try expect(harness.states, equals: [.error], "app activation must not acknowledge another thread failure")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: false,
               "activation does not persist acknowledgment")
}

@MainActor
func testCodexFeedSeenBaselineCoversAPreExistingFailure() throws {
    let harness = try CodexFeedHarness()
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d019"
    try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(600)),
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(590)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: harness.ago(580)),
    ])
    try expect(FileManager.default.fileExists(atPath: harness.seenURL.path), equals: false, "first launch")
    harness.start()
    try expect(harness.states, equals: [.idle], "first launch: a pre-existing failure is baselined as seen, same as a completion")
    try expect(CodexSeenStore.load(from: harness.seenURL)?.isSeen(threadID: threadID, turnID: "turn-1"), equals: true,
               "codex-seen.json is written with the baseline")
}

@MainActor
func testCodexFeedFailedTurnExpiresAfter12h() throws {
    let harness = try CodexFeedHarness(pollInterval: 0.1)
    defer { harness.feed.stop() }
    let threadID = "0199f000-0000-7000-8000-00000000d020"
    let url = try harness.writeRollout(threadID: threadID, lines: [
        RolloutLine.sessionMeta(id: threadID, at: harness.ago(60)),
    ])
    harness.start()
    try harness.append([
        RolloutLine.taskStarted(turnID: "turn-1", at: harness.ago(50)),
        RolloutLine.taskCompleteFailed(turnID: "turn-1", codexErrorInfo: "usage_limit_exceeded",
                                       message: "Fixture usage limit message.", at: harness.ago(40)),
    ], to: url)
    try spinMainRunLoop(timeout: 2) { harness.states == [.error] }
    harness.clock.advance(by: IslandTiming.seenExpiry + 1)
    try spinMainRunLoop(timeout: 2) { harness.states == [.idle] }
}

private let codexFeedFeedCases: [TestCase] = [
    ("codexFeed: FSEvents sees a nested YYYY/MM/DD rollout and its append within 2 s", testCodexFeedFSEventsSeesNestedAppendWithin2s),
    ("codexFeed: the poll timer republishes within 2 s without file events", testCodexFeedPollTimerRepublishesWithoutFileEvents),
    ("codexFeed: files older than 24 h are ignored", testCodexFeedIgnoresFilesOlderThan24h),
    ("codexFeed: truncate and replace re-run the cold start (hardening 3)", testCodexFeedTruncateAndReplaceRerunColdStart),
    ("codexFeed: invalid UTF-8 and JSON lines are skipped (hardening 3)", testCodexFeedSkipsInvalidUTF8AndJSONLines),
    ("codexFeed: first launch baselines seen; a later completion is unseen", testCodexFeedSeenBaselineThenLaterCompletion),
    ("codexFeed: working and superseded error cannot acknowledge", testCodexFeedCapturedWorkingAndSupersededErrorDoNotAcknowledge),
    ("codexFeed: older row cannot acknowledge a newer completion", testCodexFeedOlderRowCannotAcknowledgeNewerCompletion),
    ("codexFeed: acknowledgment is thread-specific across restart", testCodexFeedAcknowledgmentIsThreadSpecificAcrossRestart),
    ("codexFeed: Codex activation preserves unseen completions", testCodexFeedCodexActivationPreservesUnseenCompletions),
    ("codexFeed: jump marks seen, loadDetail does not", testCodexFeedJumpMarksSeenLoadDetailDoesNot),
    ("codexFeed: a second instance sees the persisted seen state", testCodexFeedSecondInstanceSeesPersistedSeenState),
    ("codexFeed: missing sessions dir is inactive until Codex was seen running", testCodexFeedHealthForMissingSessionsDirectory),
    ("codexFeed: working → stale when Codex is not running", testCodexFeedWorkingBecomesStaleWhenCodexNotRunning),
    ("codexFeed: showExecThreads toggles exec rows", testCodexFeedShowExecThreadsToggles),
    ("codexFeed: titles follow session_index.jsonl", testCodexFeedTitlesFollowSessionIndex),
    ("codexFeed: re-registration after stop() then start() has no duplicate callbacks", testCodexFeedReRegistrationAfterStopStartHasNoDuplicateCallbacks),
    ("codexFeed: a restart republishes unchanged rows to the new subscriber (fix round 1, Minor)", testCodexFeedRestartRepublishesUnchangedRowsToNewSubscriber),
    ("codexFeed: jump clears a failed turn to idle (closed turns, not just completions)", testCodexFeedJumpClearsFailedTurnToIdle),
    ("codexFeed: Codex activation preserves a failed turn", testCodexFeedActivationPreservesFailedTurn),
    ("codexFeed: first-launch baseline covers a pre-existing failure", testCodexFeedSeenBaselineCoversAPreExistingFailure),
    ("codexFeed: a failed turn's error row expires after 12 h", testCodexFeedFailedTurnExpiresAfter12h),
]

let codexFeedTests: [TestCase] = [
    codexFeedReaderCases,
    codexFeedColdStartCases,
    codexFeedFeedCases,
].flatMap { $0 }

import Darwin
import Foundation
import IslandCore

/// Codex Desktop threads from `<sessions>/YYYY/MM/DD/rollout-*.jsonl`: recursive FSEvents plus a
/// stat poll over tracked files modified within the recent window, byte-offset tail reads,
/// first-line + backward-scan cold start, session_index titles, and the persisted seen store.
@MainActor
public final class CodexDesktopFeed: SessionFeed, FeedIOErrorCounting {
    public struct Configuration: Sendable {
        public var statPollInterval: TimeInterval
        public var recentWindow: TimeInterval
        public var firstLineCap: Int
        public var scanChunk: Int

        public static let standard = Configuration(
            statPollInterval: IslandTiming.codexStatPoll,
            recentWindow: IslandTiming.codexRecentWindow,
            firstLineCap: IslandTiming.codexFirstLineCap,
            scanChunk: IslandTiming.codexScanChunk
        )
    }

    public nonisolated let source: SessionSource = .codexDesktop

    static let missingDirectoryReason = "sessions dir missing"
    /// The timer poll stats tracked files only; every Nth poll also re-enumerates the tree to catch
    /// a file FSEvents missed.
    static let pollsPerFullRescan = 30
    static let sessionIndexMaximumBytes = 32 * 1_048_576
    private static let eventQueue = DispatchQueue(label: "agent-island.codex-fsevents")

    private struct FileStamp: Equatable {
        let size: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let identity: RolloutFileIdentity

        init?(path: String) {
            var metadata = stat()
            guard fstatat(AT_FDCWD, path, &metadata, 0) == 0 else { return nil }
            size = UInt64(max(0, metadata.st_size))
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            identity = RolloutFileIdentity(metadata)
        }

        var modified: Date {
            Date(timeIntervalSince1970: TimeInterval(modifiedSeconds) + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
        }
    }

    private struct TrackedRollout {
        let file: CodexRolloutFile
        var reader: RolloutTailReader
        var stamp: FileStamp
    }

    private let sessionsDirectory: URL
    private let sessionIndexURL: URL
    private let seenStoreURL: URL
    private let activity: any AppActivityObserving
    private let clock: any WallClock
    private let showExecThreads: @MainActor () -> Bool
    private let configuration: Configuration

    private var publish: (@MainActor ([AgentRow]) -> Void)?
    private var reportHealth: (@MainActor (FeedHealth) -> Void)?
    private var lastHealth: FeedHealth?
    private var lastRows: [AgentRow]?
    private var reducer = CodexReducer()
    private var seen = CodexSeenStore()
    private var titles: [String: String] = [:]
    private var titlesStamp: FileStamp?
    private var tracked: [String: TrackedRollout] = [:]
    private var rootPath: String?
    private var eventStream: FileSystemEventStream?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var rescanRequested = false
    private var codexSeenRunning = false
    private var isStarted = false
    /// Seen-store save failures, cold-scan failures and tail-read errors this feed would
    /// otherwise swallow (controller ruling, Task 16), surfaced through
    /// `FeedIOErrorCounting` in the state dump. Never blocks the feed.
    public private(set) var ioErrorCount = 0

    public init(sessionsDirectory: URL, sessionIndexURL: URL, seenStoreURL: URL, activity: any AppActivityObserving,
                clock: any WallClock, showExecThreads: @escaping @MainActor () -> Bool,
                configuration: Configuration = .standard) {
        self.sessionsDirectory = sessionsDirectory
        self.sessionIndexURL = sessionIndexURL
        self.seenStoreURL = seenStoreURL
        self.activity = activity
        self.clock = clock
        self.showExecThreads = showExecThreads
        self.configuration = configuration
    }

    // MARK: SessionFeed

    public func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {
        reportHealth = report
        if let lastHealth { report(lastHealth) }
    }

    public func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.publish = publish
        let stored = CodexSeenStore.load(from: seenStoreURL)
        seen = stored ?? CodexSeenStore()
        refresh(fullRescan: true)
        if stored == nil {
            applySeenBaseline()
        }
        republish()
        let timer = Timer(timeInterval: configuration.statPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        eventStream?.stop()
        eventStream = nil
        rootPath = nil
        publish = nil
        isStarted = false
        // Fix round 1 (Task 10 review, Minor): forget the last-published rows too, so a fresh
        // start() always republishes to its new subscriber even when nothing has changed since
        // before stop() — otherwise republish()'s `rows != lastRows` dedup compares against a
        // value the new subscriber never saw and silently skips the initial publish.
        lastRows = nil
    }

    /// Island seen-state only: marks the row's last closed (completed or failed) turn seen and
    /// persists it.
    public func jump(_ row: AgentRow) async throws {
        guard row.source == .codexDesktop,
              let capturedID = row.acknowledgmentID,
              let thread = reducer.threads[row.id.key],
              let turnID = thread.lastCompletedTurnID,
              turnID == capturedID,
              CodexReducer.rows(threads: [thread], seen: seen, titles: titles,
                                showExec: showExecThreads(),
                                codexRunning: activity.isRunning(bundleID: KnownBundleIDs.codex),
                                now: clock.now()).first?.acknowledgmentID == capturedID,
              !seen.isSeen(threadID: thread.threadID, turnID: turnID)
        else { return }
        seen.markSeen(threadID: thread.threadID, turnID: turnID)
        persistSeen()
        republish()
    }

    /// Rows already carry their detail; hover never marks anything seen.
    public func loadDetail(for row: AgentRow) {}

    /// Synchronous full rescan + stat pass + publish (tests; the timer runs the same pass).
    package func pollNow() {
        guard isStarted else { return }
        refresh(fullRescan: true)
        republish()
    }

    // MARK: Refresh

    private func timerFired() {
        guard isStarted else { return }
        pollCount += 1
        refresh(fullRescan: pollCount % Self.pollsPerFullRescan == 0)
        republish()
    }

    private func refresh(fullRescan: Bool) {
        let now = clock.now()
        if activity.isRunning(bundleID: KnownBundleIDs.codex) {
            codexSeenRunning = true
        }
        let appeared = updateDirectoryState()
        if rootPath != nil {
            if fullRescan || appeared || rescanRequested {
                rescanRequested = false
                discoverFiles(now: now)
            }
            for path in tracked.keys.sorted() {
                refreshFile(atPath: path, now: now)
            }
        }
        reloadTitlesIfNeeded()
    }

    /// Returns true when the sessions directory just appeared.
    private func updateDirectoryState() -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        guard exists else {
            if rootPath != nil {
                eventStream?.stop()
                eventStream = nil
                rootPath = nil
            }
            setHealth(codexSeenRunning
                ? .offline(reason: Self.missingDirectoryReason)
                : .inactive(reason: Self.missingDirectoryReason))
            return false
        }
        var appeared = false
        if rootPath == nil {
            rootPath = Self.canonicalPath(sessionsDirectory.path)
            startEventStream()
            appeared = true
        }
        setHealth(.online)
        return appeared
    }

    private func startEventStream() {
        guard eventStream == nil, let rootPath else { return }
        let stream = FileSystemEventStream(paths: [rootPath], latency: 0.1, fileEvents: true, queue: Self.eventQueue) {
            [weak self] paths in
            Task { @MainActor [weak self] in
                self?.handleFileEvents(paths)
            }
        }
        if stream.start() {
            eventStream = stream
        }
    }

    private func handleFileEvents(_ paths: [String]) {
        guard isStarted, let rootPath else { return }
        let now = clock.now()
        for rawPath in paths {
            let path = Self.canonicalPath(rawPath)
            guard path.hasPrefix(rootPath) else { continue }
            if Self.isRolloutFileName(URL(fileURLWithPath: path).lastPathComponent) {
                refreshFile(atPath: path, now: now)
            } else {
                rescanRequested = true
            }
        }
        if rescanRequested {
            rescanRequested = false
            discoverFiles(now: now)
        }
        republish()
    }

    private func discoverFiles(now: Date) {
        guard let rootPath,
              let enumerator = FileManager.default.enumerator(
                  at: URL(fileURLWithPath: rootPath, isDirectory: true),
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles])
        else { return }
        for case let url as URL in enumerator {
            guard Self.isRolloutFileName(url.lastPathComponent) else { continue }
            let path = url.path.hasPrefix(rootPath) ? url.path : Self.canonicalPath(url.path)
            if tracked[path] == nil {
                refreshFile(atPath: path, now: now)
            }
        }
    }

    private func refreshFile(atPath path: String, now: Date) {
        guard let stamp = FileStamp(path: path),
              now.timeIntervalSince(stamp.modified) <= configuration.recentWindow
        else {
            forgetFile(atPath: path)
            return
        }
        guard var entry = tracked[path] else {
            coldStart(path: path, stamp: stamp)
            return
        }
        guard entry.stamp != stamp else { return }
        do {
            switch try entry.reader.readNewLines() {
            case .lines(let lines):
                if !lines.isEmpty {
                    _ = reducer.ingest(lines: lines, file: entry.file)
                }
                entry.stamp = stamp
                tracked[path] = entry
            case .reset:
                coldStart(path: path, stamp: stamp)
            }
        } catch {
            // Keep the old stamp so the next poll retries.
            ioErrorCount += 1
        }
    }

    private func coldStart(path: String, stamp: FileStamp) {
        let file = CodexRolloutFile(path: path)
        reducer.resetFile(file)
        tracked.removeValue(forKey: path)
        let url = URL(fileURLWithPath: path)
        let scan: (firstLine: Data?, resumeOffset: UInt64, tail: [Data], endOffset: UInt64)
        do {
            scan = try CodexColdStartScanner.scan(url: url, firstLineCap: configuration.firstLineCap,
                                                  chunk: configuration.scanChunk)
        } catch {
            ioErrorCount += 1
            return
        }
        var lines: [Data] = []
        if let firstLine = scan.firstLine {
            lines.append(firstLine)
        }
        lines.append(contentsOf: scan.tail)
        _ = reducer.ingest(lines: lines, file: file)
        tracked[path] = TrackedRollout(file: file, reader: RolloutTailReader(url: url, startOffset: scan.endOffset),
                                       stamp: stamp)
    }

    private func forgetFile(atPath path: String) {
        guard let entry = tracked.removeValue(forKey: path) else { return }
        reducer.removeFile(entry.file)
    }

    private func reloadTitlesIfNeeded() {
        let stamp = FileStamp(path: sessionIndexURL.path)
        guard stamp != titlesStamp else { return }
        guard stamp != nil else {
            titlesStamp = nil
            titles = [:]
            return
        }
        let data: Data
        do {
            data = try SecureFileReader.read(at: sessionIndexURL, maximumSize: Self.sessionIndexMaximumBytes)
        } catch {
            ioErrorCount += 1
            return   // titlesStamp unchanged, so the next poll retries
        }
        titlesStamp = stamp
        titles = CodexSessionIndex.parse(data)
    }

    // MARK: Seen

    // App activation cannot identify which thread was viewed. Only an explicit row
    // selection acknowledges that thread; unrelated completions and failures stay visible.

    /// First launch (no seen file): every closed (completed or failed) turn counts as seen, so
    /// the board does not flood.
    private func applySeenBaseline() {
        for thread in reducer.threads.values where CodexThreadFilter.isVisible(thread.meta, showExec: true) {
            if let turnID = thread.lastCompletedTurnID {
                seen.markSeen(threadID: thread.threadID, turnID: turnID)
            }
        }
        persistSeen()
    }

    private func persistSeen() {
        do {
            try seen.save(to: seenStoreURL)
        } catch {
            ioErrorCount += 1
        }
    }

    // MARK: Publish

    private func republish() {
        guard let publish else { return }
        let rows = CodexReducer.rows(
            threads: Array(reducer.threads.values),
            seen: seen,
            titles: titles,
            showExec: showExecThreads(),
            codexRunning: activity.isRunning(bundleID: KnownBundleIDs.codex),
            now: clock.now()
        )
        guard rows != lastRows else { return }
        lastRows = rows
        publish(rows)
    }

    private func setHealth(_ health: FeedHealth) {
        guard health != lastHealth else { return }
        lastHealth = health
        reportHealth?(health)
    }

    // MARK: Paths

    static func isRolloutFileName(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// realpath(3), so FSEvents paths (/private/var/…) and enumerated paths agree.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

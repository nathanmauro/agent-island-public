import Foundation
import IslandCore

/// Claude sessions outside Herdr, from `~/.claude/sessions/<pid>.json`. Only names accepted by
/// RegistryPathFilter are ever opened. FSEvents on the directory plus a periodic sweep (liveness, stale aging,
/// seen expiry) trigger `sweepNow()`.
@MainActor
public final class ClaudeRegistryFeed: SessionFeed, FeedIOErrorCounting {
    public nonisolated let source: SessionSource = .claudeRegistry

    /// Registry records are a few hundred bytes; anything larger is not a registry record.
    static let maximumEntryBytes = 262_144

    private let directory: URL
    private let fileReader: any FileReading
    private let processProbe: any ProcessProbing
    private let clock: any WallClock
    private let sweepInterval: TimeInterval
    private let eventQueue = DispatchQueue(label: "agent-island.claude-registry.events")

    private var reducer = ClaudeRegistryReducer()
    private var entriesByFileName: [String: RegistryEntry] = [:]
    private var liveEntries: [RegistryEntry] = []
    private var loggedReadFailures: Set<String> = []
    private var publish: (@MainActor ([AgentRow]) -> Void)?
    private var reportHealth: (@MainActor (FeedHealth) -> Void)?
    private var lastHealth: FeedHealth?
    private var lastRows: [AgentRow] = []
    private var hasPublished = false
    private var isStarted = false
    private var sweepTimer: Timer?
    private var eventStream: FileSystemEventStream?
    private var eventSweepPending = false
    /// Per-file read and decode failures this feed swallows (controller ruling, Task 16,
    /// fix round 1), surfaced through `FeedIOErrorCounting` in the state dump. Never blocks
    /// the feed — the previous decoded entry is kept and the next sweep retries.
    public private(set) var ioErrorCount = 0

    public init(directory: URL, fileReader: any FileReading, processProbe: any ProcessProbing, clock: any WallClock,
                sweepInterval: TimeInterval = IslandTiming.registrySweep) {
        self.directory = directory
        self.fileReader = fileReader
        self.processProbe = processProbe
        self.clock = clock
        self.sweepInterval = sweepInterval
    }

    public func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {
        reportHealth = report
        if let lastHealth { report(lastHealth) }
    }

    /// The first sweep runs on the next main-queue turn, not inside start(), so StateStore has begun its launch
    /// quiet period before any registry row reaches the policy.
    public func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        self.publish = publish
        let timer = Timer(timeInterval: sweepInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.isStarted { self.sweepNow() }
            }
        }
        timer.tolerance = sweepInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.sweepNow()
            }
        }
    }

    public func stop() {
        isStarted = false
        sweepTimer?.invalidate()
        sweepTimer = nil
        stopEventStream()
        publish = nil
        hasPublished = false
    }

    /// Clears the island's doneUnseen flag for this row. The OS-level jump is planned and run by StateStore.
    public func jump(_ row: AgentRow) async throws {
        guard row.source == .claudeRegistry else { return }
        reducer.markSeen(row)
        publishIfChanged(reducer.apply(liveEntries, now: clock.now()))
    }

    public func loadDetail(for row: AgentRow) {}

    /// One synchronous list + read + liveness pass; publishes if rows changed. A file absent from the listing
    /// removes its entry. A read or decode failure for a listed file keeps that pid's previous decoded entry until
    /// the next successful read (logged once per pid), so a mid-write read never flickers a row or mints a
    /// spurious doneUnseen. A pid that never decoded produces no row.
    public func sweepNow() {
        let names: [String]
        do {
            names = try fileReader.fileNames(in: directory)
        } catch {
            stopEventStream()
            entriesByFileName = [:]
            liveEntries = []
            loggedReadFailures = []
            let exists = FileManager.default.fileExists(atPath: directory.path)
            setHealth(.inactive(reason: exists ? "registry dir unreadable" : "registry dir missing"))
            publishIfChanged(reducer.apply([], now: clock.now()))
            return
        }
        setHealth(.online)
        startEventStreamIfNeeded()

        var next: [String: RegistryEntry] = [:]
        for name in names.filter({ RegistryPathFilter.accepts(fileName: $0) }).sorted() {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                let data = try fileReader.read(url, maximumSize: Self.maximumEntryBytes)
                if let entry = RegistryEntry.decode(data) {
                    next[name] = entry
                    loggedReadFailures.remove(name)
                    continue
                }
                if let previous = entriesByFileName[name] { next[name] = previous }
                ioErrorCount += 1
                if loggedReadFailures.insert(name).inserted {
                    NSLog("agent-island: registry entry %@ unreadable (undecodable); keeping its previous state", name)
                }
            } catch {
                if let previous = entriesByFileName[name] { next[name] = previous }
                ioErrorCount += 1
                if loggedReadFailures.insert(name).inserted {
                    NSLog("agent-island: registry entry %@ unreadable (%@); keeping its previous state", name, String(describing: error))
                }
            }
        }
        entriesByFileName = next
        liveEntries = next.keys.sorted().compactMap { next[$0] }
            .filter { RegistryLiveness.isLive($0, probe: processProbe) }
        publishIfChanged(reducer.apply(liveEntries, now: clock.now()))
    }

    private func publishIfChanged(_ rows: [AgentRow]) {
        guard let publish else {
            lastRows = rows
            return
        }
        guard !hasPublished || rows != lastRows else { return }
        lastRows = rows
        hasPublished = true
        publish(rows)
    }

    private func setHealth(_ health: FeedHealth) {
        guard health != lastHealth else { return }
        lastHealth = health
        reportHealth?(health)
    }

    private func startEventStreamIfNeeded() {
        guard isStarted, eventStream == nil else { return }
        let stream = FileSystemEventStream(paths: [directory.path], latency: 0.1, fileEvents: true,
                                           queue: eventQueue) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.scheduleEventSweep() }
            }
        }
        guard stream.start() else { return }
        eventStream = stream
    }

    private func stopEventStream() {
        eventStream?.stop()
        eventStream = nil
    }

    /// Coalesces a burst of FSEvents callbacks into one sweep on the next main-queue turn.
    private func scheduleEventSweep() {
        guard isStarted, !eventSweepPending else { return }
        eventSweepPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.eventSweepPending = false
                if self.isStarted { self.sweepNow() }
            }
        }
    }
}

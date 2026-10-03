import Darwin
import Foundation
import Observation

/// Optional: a feed that can report a diagnostic message unrelated to a health change
/// (controller ruling, Task 16 — today only Herdr's pane-stream-cap message). StateStore
/// relays it to `observeFeedDiagnostics`; ObservabilityWiring logs it as a feed-health
/// event, since a diagnostic is not itself a StoreChange. The composition root casts
/// feeds to find it, the same pattern as `HerdrFocusReporting`.
@MainActor
public protocol FeedDiagnosticsReporting: AnyObject {
    func observeDiagnostics(_ report: @escaping @MainActor (String) -> Void)
}

/// Optional: a feed that counts I/O errors it would otherwise swallow (controller ruling,
/// Task 16 — today only the Codex feed's seen-store save, cold-scan and tail-read
/// failures), surfaced through `feedIOErrorCounts` in the state dump so a trial run can
/// see them without the feed's own tests needing to change.
@MainActor
public protocol FeedIOErrorCounting: AnyObject {
    var ioErrorCount: Int { get }
}

/// The island's single source of truth for the UI.
///
/// Every feed publishes its full row set on the main actor. The store keeps
/// the latest set per source, merges and deduplicates them with `RowMerger`
/// (Herdr is authoritative for Herdr panes), asks the interrupt policy what
/// to do about the transition, and hands every change observer one
/// `StoreChange` per merge, tick or health change.
///
/// A source that reports offline or disabled keeps its last rows on screen
/// (the UI dims them). While it is in that state an empty publish is ignored:
/// a feed that lost its connection cannot see agents end, so an empty set
/// then means "no view", not "nothing running". The first publish after the
/// feed reports online again is authoritative.
@MainActor
@Observable
public final class StateStore {
    public private(set) var rows: [AgentRow] = []
    public private(set) var summary = Summary(rows: [])
    public private(set) var feedHealth: [SessionSource: FeedHealth] = [:]
    public private(set) var nameOverrides = SessionNameOverrides()
    public private(set) var lastErrorDescription: String?
    /// Runs after `focus` records a `jumpPerformer.perform` failure into
    /// `lastErrorDescription`, just before the error is rethrown (controller ruling,
    /// Task 16). IslandCore never touches a file itself; ObservabilityWiring uses this to
    /// append the failure to the transition log. Not itself part of the observed state
    /// (assigned once by the composition root), so it is excluded from Observation.
    @ObservationIgnored
    public var onJumpFailure: ((RowID, String) -> Void)?

    private let feeds: [any SessionFeed]
    private let clock: any WallClock
    private let focusProvider: any FocusContextProviding
    private let jumpPerformer: any JumpPerforming
    private let jumpContextProvider: any JumpContextProviding
    private let nameOverridesFileURL: URL?
    private let deadlineScheduler: DeadlineScheduler
    @ObservationIgnored private var policy: any InterruptDeciding
    @ObservationIgnored private var rowsBySource: [SessionSource: [AgentRow]] = [:]
    @ObservationIgnored private var publishedSources: Set<SessionSource> = []
    @ObservationIgnored private var changeObservers: [@MainActor (StoreChange) -> Void] = []
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingDeadline: Date?
    /// Monotonic counter guarding `lastErrorDescription` against concurrent `focus` calls
    /// (controller ruling, Task 16 fix round 2): every call captures its own tick at entry,
    /// and every error record captures another. A focus clears the field on success only
    /// when its own tick is newer than the most recent error's, so a focus that started
    /// before that error was recorded — whether a concurrent call or this call's own
    /// earlier mark-seen failure — can never wipe it.
    @ObservationIgnored private var focusSequence = 0
    @ObservationIgnored private var lastErrorSequence = 0

    /// The overrides file lives in the app's support directory, never inside
    /// a directory a feed watches.
    public init(
        feeds: [any SessionFeed],
        clock: any WallClock,
        focusProvider: any FocusContextProviding,
        jumpPerformer: any JumpPerforming,
        jumpContextProvider: any JumpContextProviding,
        policy: any InterruptDeciding = NoInterrupts(),
        nameOverridesFileURL: URL? = nil,
        deadlineScheduler: DeadlineScheduler = .mainQueue
    ) {
        self.feeds = feeds
        self.clock = clock
        self.focusProvider = focusProvider
        self.jumpPerformer = jumpPerformer
        self.jumpContextProvider = jumpContextProvider
        self.policy = policy
        self.nameOverridesFileURL = nameOverridesFileURL
        self.deadlineScheduler = deadlineScheduler
        if let nameOverridesFileURL,
           let data = try? SecureFileReader.read(at: nameOverridesFileURL),
           let stored = try? JSONDecoder().decode(SessionNameOverrides.self, from: data) {
            nameOverrides = stored
        }
    }

    // MARK: Lifecycle

    /// Begins the launch quiet period for every source, then wires health
    /// and rows for each feed (health first, as `SessionFeed` requires).
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let startGeneration = generation
        policy.beginQuietPeriod(for: Set(SessionSource.allCases), at: clock.now())
        for feed in feeds {
            let source = feed.source
            feed.observeHealth { [weak self] health in
                guard let self, self.generation == startGeneration else { return }
                self.receiveHealth(health, from: source)
            }
            feed.start { [weak self] rows in
                guard let self, self.generation == startGeneration else { return }
                self.receive(rows, from: source)
            }
        }
    }

    /// Stops every feed. Publishes and health reports that arrive afterwards
    /// are ignored, and a pending policy deadline no longer ticks.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        pendingDeadline = nil
        for feed in feeds {
            feed.stop()
        }
    }

    /// Observers run in registration order, once per merge, tick or health
    /// change, after the observable properties are updated.
    public func addChangeObserver(_ observer: @escaping @MainActor (StoreChange) -> Void) {
        changeObservers.append(observer)
    }

    // MARK: Rows

    public func row(_ id: RowID) -> AgentRow? {
        rows.first { $0.id == id }
    }

    public var warningSources: [SessionSource] {
        SessionSource.allCases.filter { feedHealth[$0]?.showsWarning == true }
    }

    public func plannedJumps() -> [RowID: [JumpAction]] {
        let context = jumpContextProvider.currentJumpContext()
        return Dictionary(
            rows.map { ($0.id, JumpPlanner.plan($0.jump, context: context)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// A row click. Only successful navigation acknowledges the captured result.
    /// The feed validates its episode identity before marking it seen. The OS-level actions come
    /// from `JumpPlanner` and run through the injected performer, which keeps
    /// subprocess and AppleScript work off the main actor. A failure there
    /// (controller ruling, Task 16) is also recorded, reported through
    /// `onJumpFailure`, and rethrown — it must never be silent.
    ///
    /// A focus that completes without throwing clears `lastErrorDescription`, so a stale
    /// failure never lingers past a later successful jump — but only when this call
    /// actually started after the most recent error was recorded (controller ruling, fix
    /// round 2). Two `focus` calls can interleave across their own awaits, and this call's
    /// own successful perform and its later mark-seen failure are themselves two separate
    /// events in sequence; either way, a success must never wipe a *different or later*
    /// error than the one it could actually have superseded.
    public func focus(_ row: AgentRow) async throws {
        let started = nextSequence()
        let id = row.id
        guard let current = self.row(id), let feed = feed(for: id.source) else {
            throw JumpError.rowNotFound
        }
        let plan = JumpPlanner.plan(current.jump, context: jumpContextProvider.currentJumpContext())
        guard !plan.isEmpty else { throw JumpError.noActions }
        do {
            try await jumpPerformer.perform(plan)
        } catch {
            let description = String(describing: error)
            recordError(description)
            onJumpFailure?(id, description)
            throw error
        }
        do {
            try await feed.jump(row)
        } catch {
            recordError(String(describing: error))
        }
        if started > lastErrorSequence {
            lastErrorDescription = nil
        }
    }

    /// Programmatic selection of the current row. UI handlers pass their captured AgentRow
    /// instead, so a feed update before an asynchronous task starts cannot replace the result.
    public func focus(_ id: RowID) async throws {
        guard let row = row(id) else { throw JumpError.rowNotFound }
        try await focus(row)
    }

    /// The next tick of the counter that orders `focus` starts against error records
    /// (controller ruling, Task 16 fix round 2).
    private func nextSequence() -> Int {
        focusSequence += 1
        return focusSequence
    }

    private func recordError(_ description: String) {
        lastErrorDescription = description
        lastErrorSequence = nextSequence()
    }

    /// Wires every feed that opts into `FeedDiagnosticsReporting` (controller ruling,
    /// Task 16) into one (source, message) observer.
    public func observeFeedDiagnostics(_ report: @escaping @MainActor (SessionSource, String) -> Void) {
        for feed in feeds {
            guard let reporting = feed as? any FeedDiagnosticsReporting else { continue }
            let source = feed.source
            reporting.observeDiagnostics { message in report(source, message) }
        }
    }

    /// I/O errors each feed swallowed rather than surfacing as a health change (controller
    /// ruling, Task 16), keyed by source. A feed that does not opt into
    /// `FeedIOErrorCounting` is omitted entirely — an absent key means "not tracked", never
    /// a false zero that would read as "this feed has no errors". `uniquingKeysWith` (not
    /// `uniqueKeysWithValues`) so two feeds sharing a source, which should never happen,
    /// keep the first instead of trapping.
    public var feedIOErrorCounts: [SessionSource: Int] {
        Dictionary(feeds.compactMap { feed in
            (feed as? any FeedIOErrorCounting).map { (feed.source, $0.ioErrorCount) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Hover on a done row asks its feed for lazy detail. Never marks seen.
    public func requestDetail(_ id: RowID) {
        guard let row = row(id), let feed = feed(for: id.source) else { return }
        feed.loadDetail(for: row)
    }

    // MARK: Names

    /// Renames a row for display; a blank name restores the row's own title.
    public func rename(_ id: RowID, to name: String) {
        nameOverrides.rename(id, to: name)
        persistNameOverrides()
    }

    /// A manual rename always wins; otherwise the feed's title, capped so a
    /// runaway title never bloats layout or accessibility labels.
    public func displayName(for row: AgentRow) -> String {
        nameOverrides.displayName(for: row.id)
            ?? SessionTitleFormatter.truncate(row.title, to: SessionTitleFormatter.maximumTitleLength)
    }

    /// Drops every custom session name, in memory and on disk — the reset
    /// offered from Settings.
    public func clearAllSessionNames() {
        nameOverrides = SessionNameOverrides()
        persistNameOverrides()
    }

    // MARK: Policy

    /// Also invoked automatically when a feed's health goes from offline or
    /// disabled back to online (a reconnect).
    public func beginQuietPeriod(for sources: Set<SessionSource>) {
        policy.beginQuietPeriod(for: sources, at: clock.now())
    }

    /// Re-runs the policy at `clock.now()` against the current rows. The
    /// deadline scheduler calls this; tests call it after advancing the clock.
    public func tick() {
        pendingDeadline = nil
        recompute(healthChanges: [])
    }

    // MARK: Private

    private func feed(for source: SessionSource) -> (any SessionFeed)? {
        feeds.first { $0.source == source }
    }

    private func receive(_ newRows: [AgentRow], from source: SessionSource) {
        if newRows.isEmpty, feedHealth[source]?.dimsRows == true, rowsBySource[source]?.isEmpty == false {
            return
        }
        rowsBySource[source] = newRows
        publishedSources.insert(source)
        pruneNameOverrides()
        recompute(healthChanges: [])
    }

    private func receiveHealth(_ health: FeedHealth, from source: SessionSource) {
        let previous = feedHealth[source]
        guard previous != health else { return }
        var updated = feedHealth
        updated[source] = health
        publish(updated, to: \.feedHealth)
        if previous?.dimsRows == true, health.isOnline {
            beginQuietPeriod(for: [source])
        }
        pruneNameOverrides()
        recompute(healthChanges: [HealthChange(source: source, from: previous, to: health)])
    }

    private func recompute(healthChanges: [HealthChange]) {
        let now = clock.now()
        let merge = RowMerger.merge(rowsBySource)
        let previousRows = rows
        if publish(merge.rows, to: \.rows) {
            publish(Summary(rows: merge.rows), to: \.summary)
        }
        let decision = policy.decide(
            prev: previousRows,
            next: merge.rows,
            focus: focusProvider.currentFocus(),
            now: now
        )
        schedule(decision.nextDeadline, now: now)
        let change = StoreChange(
            at: now,
            previousRows: previousRows,
            rows: merge.rows,
            decision: decision,
            registryShadow: merge.registryShadow,
            healthChanges: healthChanges
        )
        for observer in changeObservers {
            observer(change)
        }
    }

    /// Keeps at most one pending wake-up: an earlier deadline replaces a
    /// later one, and a superseded wake-up finds its deadline gone and exits.
    private func schedule(_ deadline: Date?, now: Date) {
        guard isStarted, let deadline else { return }
        if let pendingDeadline, pendingDeadline <= deadline, pendingDeadline > now {
            return
        }
        pendingDeadline = deadline
        let scheduledGeneration = generation
        deadlineScheduler.schedule(after: max(0, deadline.timeIntervalSince(now))) { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration,
                  self.pendingDeadline == deadline else { return }
            self.tick()
        }
    }

    /// Runs on every publish and health change. Names are pruned only for
    /// sources that have published at least once and are online (a source
    /// that never reported health counts as online), so a slow or
    /// disconnected feed never costs anyone their custom names. Rows the
    /// merger dropped as duplicates still count as live for their source.
    private func pruneNameOverrides() {
        let prunableSources = publishedSources.filter { feedHealth[$0]?.isOnline ?? true }
        guard !prunableSources.isEmpty else { return }
        let liveIDs = Set(rowsBySource.values.joined().map(\.id))
        var pruned = nameOverrides
        pruned.prune(keeping: liveIDs, sources: prunableSources)
        if publish(pruned, to: \.nameOverrides) {
            persistNameOverrides()
        }
    }

    /// Assigns only when the value actually differs, reporting whether it did.
    ///
    /// Observation invalidates observers on assignment, not on change, and
    /// feeds republish their full row set on every event — most of which
    /// change nothing. Writing unconditionally would rebuild the widget's view
    /// tree and relay the notch window for nothing.
    @discardableResult
    private func publish<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<StateStore, Value>
    ) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    /// Persistence failures only cost the custom names on the next launch;
    /// they must never take down a merge or a rename, so they are logged and
    /// swallowed here.
    private func persistNameOverrides() {
        guard let nameOverridesFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let parentDirectory = nameOverridesFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
            var metadata = stat()
            if Darwin.lstat(parentDirectory.path, &metadata) == 0,
               metadata.st_mode & 0o777 != 0o700 {
                guard Darwin.chmod(parentDirectory.path, 0o700) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            try SecureFileWriter.writeAtomically(
                try encoder.encode(nameOverrides),
                to: nameOverridesFileURL
            )
        } catch {
            NSLog(
                "Agent Island could not persist session names: %@",
                String(describing: error)
            )
        }
    }
}

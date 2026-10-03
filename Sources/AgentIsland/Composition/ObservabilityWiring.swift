import AppKit
import IslandCore
import IslandIO

extension ObservabilityWiring {
    /// Coalesces bursts of changes into one state-dump write at most 50 ms after the first.
    static let stateDumpDebounce: TimeInterval = 0.05
    /// Dump mode only: how often jump, peek and pill state are sampled for changes that
    /// arrive without a store change (a queue advancing on its timer, a dry-run jump).
    static let stateDumpPollInterval: TimeInterval = 0.25

    /// Transition log always; the state dump only when AGENT_ISLAND_STATE_DUMP is set.
    static func attach(store: StateStore, env: WiringEnvironment, peekStatus: (any PeekStatusProviding)?,
                       jumpPerformer: any JumpPerforming, panelController: NotchPanelController) {
        let log = TransitionLog(fileURL: env.paths.transitionLogFile)
        let logQueue = DispatchQueue(label: "com.nathan.agent-island.transition-log", qos: .utility)
        store.addChangeObserver { change in
            let records = TransitionRecord.records(for: change)
            guard !records.isEmpty else { return }
            logQueue.async { log.append(records) }
        }
        // Controller ruling: a failure from jumpPerformer.perform (the labelled JumpError
        // that reaches here after StateStore.focus rethrows) must not be silent.
        store.onJumpFailure = { rowID, description in
            let ts = env.clock.now()
            logQueue.async {
                log.append([TransitionRecord.jumpFailure(rowID: rowID, description: description, at: ts)])
            }
        }
        // Controller ruling: HerdrFeed.observeDiagnostics (the pane-stream-cap message)
        // was not wired anywhere; log it as a feed-health event, discriminated by `rule`
        // from a real first health report (fix round 1: both have no `from`).
        store.observeFeedDiagnostics { source, message in
            let ts = env.clock.now()
            logQueue.async {
                log.append([TransitionRecord.diagnostic(source: source, message: message, at: ts)])
            }
        }

        guard let dumpURL = env.flags.stateDumpURL else { return }
        let writer = StateDumpWriter(
            dump: StateDump(url: dumpURL),
            store: store,
            clock: env.clock,
            peekStatus: peekStatus,
            jumpPerformer: jumpPerformer,
            panelController: panelController
        )
        store.addChangeObserver { _ in writer.scheduleWrite() }
        UIStateReporter.shared.onChange = { writer.scheduleWrite() }
        panelController.reportUIState()
        writer.startPolling()
        writer.scheduleWrite()
    }
}

/// Builds and writes the state dump. Retained by the store observer and the UI hook.
@MainActor
private final class StateDumpWriter {
    /// Everything the dump's content depends on, apart from `generatedAt` (controller
    /// ruling: the policy heartbeat ticks the store at least every 10 s even when nothing
    /// visible changed, so the dump must compare content, not just react to being asked).
    private struct Fingerprint: Equatable {
        var rows: [AgentRow]
        var feedHealth: [SessionSource: FeedHealth]
        var feedIOErrorCounts: [SessionSource: Int]
        var lastErrorDescription: String?
        var peekQueue: PeekQueueSnapshot
        var chimePlayedCount: Int
        var plannedJumps: [RowID: [JumpAction]]
        var performedJumps: [[JumpAction]]
        var ui: UISnapshot
    }

    private let dump: StateDump
    private let store: StateStore
    private let clock: any WallClock
    private let peekStatus: (any PeekStatusProviding)?
    private let jumpPerformer: any JumpPerforming
    private let panelController: NotchPanelController
    private var writeScheduled = false
    private var lastFingerprint: Fingerprint?
    private var pollTimer: Timer?

    init(dump: StateDump, store: StateStore, clock: any WallClock, peekStatus: (any PeekStatusProviding)?,
         jumpPerformer: any JumpPerforming, panelController: NotchPanelController) {
        self.dump = dump
        self.store = store
        self.clock = clock
        self.peekStatus = peekStatus
        self.jumpPerformer = jumpPerformer
        self.panelController = panelController
    }

    func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ObservabilityWiring.stateDumpDebounce) { [weak self] in
            MainActor.assumeIsolated {
                self?.writeNow()
            }
        }
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        let interval = ObservabilityWiring.stateDumpPollInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        timer.tolerance = interval * 0.2
        pollTimer = timer
    }

    private func poll() {
        panelController.reportUIState()
        if currentFingerprint() != lastFingerprint {
            scheduleWrite()
        }
    }

    /// Only actually writes when the content changed (controller ruling): the heartbeat
    /// and the poll both call `scheduleWrite()` far more often than the dump's content
    /// changes, and `StateDumpSnapshot` is cheap to compare.
    private func writeNow() {
        writeScheduled = false
        let fingerprint = currentFingerprint()
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        dump.write(StateDumpSnapshot(
            generatedAt: clock.now(),
            rows: fingerprint.rows,
            summary: store.summary,
            feedHealth: fingerprint.feedHealth,
            peekQueue: fingerprint.peekQueue,
            chimePlayedCount: fingerprint.chimePlayedCount,
            plannedJumps: fingerprint.plannedJumps,
            performedJumps: fingerprint.performedJumps,
            feedErrorCounts: fingerprint.feedIOErrorCounts,
            lastErrorDescription: fingerprint.lastErrorDescription,
            ui: fingerprint.ui
        ))
    }

    private func currentFingerprint() -> Fingerprint {
        Fingerprint(
            rows: store.rows,
            feedHealth: store.feedHealth,
            feedIOErrorCounts: store.feedIOErrorCounts,
            lastErrorDescription: store.lastErrorDescription,
            peekQueue: peekStatus?.peekQueueSnapshot ?? PeekQueueSnapshot(),
            chimePlayedCount: peekStatus?.chimePlayedCount ?? 0,
            plannedJumps: store.plannedJumps(),
            performedJumps: jumpPerformer.performedLog,
            ui: UIStateReporter.shared.snapshot
        )
    }
}

import Foundation
import IslandCore

/// Herdr socket feed. Bootstrap, one status stream per pane up to `maxPaneStreams`, periodic reconcile and ping,
/// backoff, protocol and unsupported-method guard, lazy detection reads and a per-session process_info cache.
/// Panes beyond the stream cap update only on the reconcile; hitting the cap is a diagnostic, not a health change.
/// Every piece of state lives on the main actor; socket I/O runs inside HerdrClient.
@MainActor
public final class HerdrFeed: SessionFeed, HerdrFocusReporting, FeedDiagnosticsReporting {
    public struct Configuration: Sendable {
        public var reconcileInterval: TimeInterval
        public var pingInterval: TimeInterval
        public var backoff: [TimeInterval]
        public var disabledProbeInterval: TimeInterval
        public var maxPaneStreams: Int
        public var maxConcurrentRequests: Int
        public var hostname: String

        public static func standard(hostname: String = HostName.short()) -> Configuration {
            Configuration(
                reconcileInterval: IslandTiming.herdrReconcile,
                pingInterval: IslandTiming.herdrPing,
                backoff: IslandTiming.herdrBackoff,
                disabledProbeInterval: IslandTiming.herdrDisabledProbe,
                maxPaneStreams: IslandTiming.herdrMaxPaneStreams,
                maxConcurrentRequests: IslandTiming.herdrMaxConcurrentRequests,
                hostname: hostname
            )
        }
    }

    private enum SessionEnd: Sendable {
        case stopped
        case failed(cause: String?)
        case disabled(reason: String)
    }

    private enum Phase {
        case idle, bootstrapping, online, waiting
    }

    private struct SessionAbort: Error {
        let end: SessionEnd
    }

    @MainActor
    private final class PaneStream {
        let paneID: String
        let session: Int
        var task: Task<Void, Never>?
        var detached = false

        init(paneID: String, session: Int) {
            self.paneID = paneID
            self.session = session
        }
    }

    /// Identity lasts for one blocked or done episode, even when a pane ID is reused later.
    @MainActor
    private final class DetectionEpisode {
        let purpose: HerdrDetectionPurpose
        let sourceStatus: String?
        var task: Task<Void, Never>?
        var recapRead = false

        init(purpose: HerdrDetectionPurpose, sourceStatus: String?) {
            self.purpose = purpose
            self.sourceStatus = sourceStatus
        }
    }

    public nonisolated let source: SessionSource = .herdr
    public private(set) var focusedPaneID: String?
    public var openPaneStreamCount: Int { liveStreams.count }
    public var isGlobalStreamOpen: Bool { globalStreamSession != nil }

    private let client: HerdrClient
    private let clock: any WallClock
    private let activity: any AppActivityObserving
    private let configuration: Configuration
    private let scheduler: DeadlineScheduler
    private var reducer: HerdrReducer

    private var publishRows: (@MainActor ([AgentRow]) -> Void)?
    private var reportHealth: (@MainActor (FeedHealth) -> Void)?
    private var reportDiagnostic: (@MainActor (String) -> Void)?
    private var lastHealth: FeedHealth?
    private var streamCapReported = false
    private var lastPublished: [AgentRow]?
    private var isRunning = false
    private var observingActivation = false

    private var loopTask: Task<Void, Never>?
    private var sessionID = 0
    private var phase: Phase = .idle
    private var sessionReachedOnline = false
    private var needsReset = false
    private var pendingEnd: SessionEnd?
    private var endContinuation: CheckedContinuation<SessionEnd, Never>?

    private var bufferedEvents: [HerdrEvent] = []
    private var globalTask: Task<Void, Never>?
    private var globalStreamSession: Int?
    private var paneStreams: [String: PaneStream] = [:]
    private var liveStreams: [ObjectIdentifier: PaneStream] = [:]
    private var timerTasks: [Task<Void, Never>] = []

    private var reconcileInFlight = false
    private var reconcilePending = false
    /// Counts every applied event. A snapshot remembers the value when it is requested.
    private var eventSerial = 0
    /// Counts applied events other than pane status changes (lifecycle, focus, layout).
    private var structuralSerial = 0
    /// Per pane: the serial and status of the last status event applied. A snapshot requested before that
    /// serial keeps the stream's status for the pane (see `keepingNewerStreamStatuses`).
    private var lastStatusEvents: [String: (serial: Int, status: HerdrAgentStatus)] = [:]

    private var processInfoRequested: Set<String> = []
    private var detectionEpisodes: [String: DetectionEpisode] = [:]
    private var inFlightRequests = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var scheduledDeadline: Date?

    public init(client: HerdrClient, clock: any WallClock, activity: any AppActivityObserving, configuration: Configuration,
                scheduler: DeadlineScheduler = .mainQueue) {
        self.client = client
        self.clock = clock
        self.activity = activity
        self.configuration = configuration
        self.scheduler = scheduler
        self.reducer = HerdrReducer(configuration: HerdrReducer.Configuration(hostname: configuration.hostname))
    }

    // MARK: SessionFeed

    public func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {
        reportHealth = report
    }

    /// Non-health diagnostics (today only the pane stream cap). Each message is also written with NSLog.
    public func observeDiagnostics(_ report: @escaping @MainActor (String) -> Void) {
        reportDiagnostic = report
    }

    public func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {
        guard !isRunning else { return }
        publishRows = publish
        isRunning = true
        lastHealth = nil        // a restart reports health and rows afresh to the latest observers
        lastPublished = nil
        if !observingActivation {
            observingActivation = true
            activity.addActivationObserver { [weak self] bundleID in
                self?.frontmostChanged(bundleID)
            }
        }
        // The reducer assumes Ghostty is not frontmost until told otherwise.
        apply(.ghosttyFrontmost(activity.frontmostBundleID() == KnownBundleIDs.ghostty))
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        finishSession(.stopped, session: sessionID)
        teardownSession()
    }

    /// Island seen-state only: clears the away overlay and an error tombstone. No socket request.
    public func jump(_ row: AgentRow) async throws {
        guard row.source == .herdr else { return }
        apply(.rowClicked(paneID: row.id.key, acknowledgmentID: row.acknowledgmentID))
        publishIfChanged()
    }

    /// Lazy recap for a done row (hover). Never marks the row seen. One read per done episode: a read in
    /// flight or one that already completed (even without a recap) is not repeated for the same episode.
    public func loadDetail(for row: AgentRow) {
        guard row.source == .herdr, row.state == .doneUnseen, row.detail?.kind != .recap else { return }
        requestDetection(paneID: row.id.key, purpose: .recap)
    }

    /// Immediate snapshot reconcile, coalesced: at most one in flight plus one pending.
    public func reconcileNow() {
        guard isRunning, phase == .online else { return }
        if reconcileInFlight {
            reconcilePending = true
            return
        }
        reconcileInFlight = true
        let session = sessionID
        Task { [weak self] in
            await self?.runReconcile(session: session)
        }
    }

    /// Applies HerdrInput.tick at clock.now() and republishes (deadline scheduler or tests).
    public func tick() {
        apply(.tick)
        publishIfChanged()
    }

    // MARK: Session loop

    private func runLoop() async {
        var attempt = 0
        while isRunning, !Task.isCancelled {
            let end = await runSession()
            teardownSession()
            guard isRunning, !Task.isCancelled else { return }
            switch end {
            case .stopped:
                return
            case .disabled(let reason):
                attempt = 0
                needsReset = true
                report(.disabled(reason: reason))
                await pause(configuration.disabledProbeInterval)
            case .failed(let cause):
                if sessionReachedOnline { attempt = 0 }
                if let cause, !isReportedOffline {
                    report(.offline(reason: cause))
                }
                let steps = configuration.backoff.isEmpty ? IslandTiming.herdrBackoff : configuration.backoff
                let delay = steps[min(attempt, steps.count - 1)]
                attempt += 1
                report(.offline(reason: "reconnecting in \(String(format: "%g", delay)) s"))
                await pause(delay)
            }
        }
    }

    private func runSession() async -> SessionEnd {
        sessionID += 1
        let session = sessionID
        phase = .bootstrapping
        sessionReachedOnline = false
        pendingEnd = nil
        bufferedEvents = []
        lastStatusEvents = [:]
        streamCapReported = false   // the cap diagnostic is emitted at most once per session
        do {
            // 1. ping: protocol guard.
            let pong = try await perform(.ping)
            try ensureCurrent(session)
            guard case .pong(let serverVersion, let protocolVersion) = pong else { throw HerdrClientError.malformedReply }
            guard protocolVersion == HerdrCodec.supportedProtocol else {
                return .disabled(reason: "protocol \(protocolVersion)")
            }
            // A server older than 0.9.1 cannot move the attached view on a jump: online, but degraded.
            let onlineHealth = HerdrServerVersion.health(forServerVersion: serverVersion)
            // 2. G; its events are buffered until snapshot #2 is applied.
            let global = try await subscribe(HerdrSubscription.globalStream)
            try ensureCurrent(session)
            startGlobalConsumer(global, session: session)
            // 3. Snapshot #1, then one status stream per pane (shells included), acknowledged in sequence.
            let first = try await takeSnapshot()
            try ensureCurrent(session)
            let agentPanes = Set(first.agents.map(\.paneID))
            for paneID in streamOrder(first.panes.map(\.paneID), agents: agentPanes) {
                guard let stream = reserveStream(paneID) else { break }
                try await establish(stream)
                try ensureCurrent(session)
            }
            // 4. Snapshot #2, then the buffered events in arrival order.
            let second = try await takeSnapshot()
            try ensureCurrent(session)
            if needsReset {
                needsReset = false
                apply(.reset)
                apply(.ghosttyFrontmost(activity.frontmostBundleID() == KnownBundleIDs.ghostty))
            }
            processInfoRequested = []
            phase = .online
            sessionReachedOnline = true
            apply(.snapshot(second), fromSnapshot: true)
            // Online is reported before the first publish of the session (the buffered replay below publishes
            // too): StateStore drops an empty publish while the source still dims, so a reconnect that finds
            // no agent panes would otherwise revive the kept rows.
            report(onlineHealth)
            let buffered = bufferedEvents
            bufferedEvents = []
            for event in buffered { handleEvent(event) }
            publishIfChanged()
            startTimers(session: session)
        } catch let abort as SessionAbort {
            return abort.end
        } catch {
            return .failed(cause: HerdrFeed.causeReason(error))
        }
        return await waitForSessionEnd()
    }

    private func ensureCurrent(_ session: Int) throws {
        if session == sessionID, let end = pendingEnd { throw SessionAbort(end: end) }
        guard session == sessionID, isRunning, !Task.isCancelled else { throw SessionAbort(end: .stopped) }
    }

    private func waitForSessionEnd() async -> SessionEnd {
        if let end = pendingEnd {
            pendingEnd = nil
            return end
        }
        return await withCheckedContinuation { continuation in
            endContinuation = continuation
        }
    }

    /// Ends the current session (G EOF, ping failure, unsupported method, stop). Stale sessions are ignored.
    /// The end takes effect at once, in the same main-actor turn: no later event is applied, and exits the
    /// dead connection reported are dropped before any tick can mature them into error rows.
    private func finishSession(_ end: SessionEnd, session: Int) {
        guard session == sessionID else { return }
        if phase == .online || phase == .bootstrapping {
            phase = .waiting
            apply(.connectionLost)
        }
        if let continuation = endContinuation {
            endContinuation = nil
            continuation.resume(returning: end)
        } else if pendingEnd == nil {
            pendingEnd = end
        }
    }

    /// Cancels timers and closes G and every pane stream. Runs before any backoff wait.
    private func teardownSession() {
        phase = isRunning ? .waiting : .idle
        for task in timerTasks { task.cancel() }
        timerTasks = []
        globalTask?.cancel()
        globalTask = nil
        for stream in paneStreams.values {
            stream.detached = true
            stream.task?.cancel()
        }
        paneStreams = [:]
        bufferedEvents = []
        reconcileInFlight = false
        reconcilePending = false
        // Exits the dead connection reported (Ghostty quitting: pane_exited, then EOF) never mature into
        // error rows after the reconnect. finishSession already did this for an ended session; this also
        // covers a bootstrap that failed on a request error.
        apply(.connectionLost)
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: HerdrFeed.nanoseconds(seconds))
    }

    private nonisolated static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private nonisolated static func causeReason(_ error: Error) -> String? {
        guard let clientError = error as? HerdrClientError else { return nil }
        switch clientError {
        case .socketMissing:
            return "socket missing"
        case .connectFailed(let code):
            return code == ENOENT ? "socket missing" : "connection refused"
        default:
            return nil
        }
    }

    private var isReportedOffline: Bool {
        if case .offline? = lastHealth { return true }
        return false
    }

    // MARK: Requests

    /// One-shot request; an unsupported-method rejection becomes a disabled session end.
    private func perform(_ request: HerdrRequest) async throws -> HerdrResult {
        do {
            return try await client.request(request)
        } catch HerdrClientError.server(let error) where error.isUnsupportedMethod {
            throw SessionAbort(end: .disabled(reason: "unsupported method \(request.method)"))
        }
    }

    private func subscribe(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, Error> {
        do {
            return try await client.subscribe(subscriptions)
        } catch HerdrClientError.server(let error) where error.isUnsupportedMethod {
            throw SessionAbort(end: .disabled(reason: "unsupported method \(HerdrRequest.subscribe(subscriptions).method)"))
        }
    }

    private func takeSnapshot() async throws -> HerdrSnapshot {
        guard case .snapshot(let snapshot) = try await perform(.snapshot) else {
            throw HerdrClientError.malformedReply
        }
        return snapshot
    }

    private func acquireSlot() async {
        if inFlightRequests < max(1, configuration.maxConcurrentRequests) {
            inFlightRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    /// Hands the slot to the next waiter, or frees it.
    private func releaseSlot() {
        if requestWaiters.isEmpty {
            inFlightRequests -= 1
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    // MARK: Streams

    private func startGlobalConsumer(_ stream: AsyncThrowingStream<HerdrEvent, Error>, session: Int) {
        globalStreamSession = session
        globalTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.receive(event, session: session)
                }
            } catch {
                // EOF (.streamEnded) or cancellation; both end the session below.
            }
            guard let self else { return }
            if self.globalStreamSession == session { self.globalStreamSession = nil }
            self.finishSession(.failed(cause: nil), session: session)
        }
    }

    private func streamOrder(_ paneIDs: [String], agents: Set<String>) -> [String] {
        paneIDs.sorted { lhs, rhs in
            let lhsAgent = agents.contains(lhs)
            let rhsAgent = agents.contains(rhs)
            return lhsAgent != rhsAgent ? lhsAgent : lhs < rhs
        }
    }

    /// Reserves a counted stream slot, or nil at the cap or when the pane already has a stream.
    /// A refusal at the cap leaves the pane to the reconcile and reports the cap once per session.
    private func reserveStream(_ paneID: String) -> PaneStream? {
        guard paneStreams[paneID] == nil else { return nil }
        guard liveStreams.count < configuration.maxPaneStreams else {
            if !streamCapReported {
                streamCapReported = true
                diagnose("pane stream cap reached (\(configuration.maxPaneStreams) streams)")
            }
            return nil
        }
        let stream = PaneStream(paneID: paneID, session: sessionID)
        paneStreams[paneID] = stream
        liveStreams[ObjectIdentifier(stream)] = stream
        return stream
    }

    private func release(_ stream: PaneStream) {
        liveStreams[ObjectIdentifier(stream)] = nil
        if paneStreams[stream.paneID] === stream { paneStreams[stream.paneID] = nil }
    }

    private func closeStream(_ paneID: String) {
        guard let stream = paneStreams.removeValue(forKey: paneID) else { return }
        stream.detached = true
        stream.task?.cancel()
    }

    /// Subscribes the pane's status stream and starts its consumer. pane_not_found drops only this stream.
    /// Throws for session-level failures (bootstrap treats them as fatal; runtime callers drop the stream).
    private func establish(_ stream: PaneStream) async throws {
        let events: AsyncThrowingStream<HerdrEvent, Error>
        do {
            events = try await subscribe([.paneStatus(paneID: stream.paneID)])
        } catch HerdrClientError.server(let error) where error.isPaneNotFound {
            release(stream)
            return
        } catch {
            release(stream)
            if stream.detached { return }
            throw error
        }
        guard !stream.detached, stream.session == sessionID, isRunning else {
            release(stream)
            return   // `events` is dropped here, which closes its fd
        }
        stream.task = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, !stream.detached else { break }
                    self.receive(event, session: stream.session)
                }
            } catch {
                // Stream ended; the next snapshot reopens it if the pane still exists.
            }
            self?.release(stream)
        }
    }

    /// Opens streams for known panes without one (agent panes first, up to the cap) and closes streams for gone panes.
    private func syncStreams() {
        let known = reducer.knownPaneIDs
        for paneID in Array(paneStreams.keys) where !known.contains(paneID) {
            closeStream(paneID)
        }
        let agentPanes = Set(reducer.rows.map(\.id.key))
        for paneID in streamOrder(Array(known), agents: agentPanes) where paneStreams[paneID] == nil {
            guard let stream = reserveStream(paneID) else { break }
            let session = sessionID
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.establish(stream)
                } catch let abort as SessionAbort {
                    self.finishSession(abort.end, session: session)
                } catch {
                    // Dropped; the next snapshot reopens it.
                }
            }
        }
    }

    // MARK: Events and inputs

    private func receive(_ event: HerdrEvent, session: Int) {
        guard session == sessionID, isRunning else { return }
        switch phase {
        case .bootstrapping:
            bufferedEvents.append(event)
        case .online:
            handleEvent(event)
        case .idle, .waiting:
            break
        }
    }

    private func handleEvent(_ event: HerdrEvent) {
        eventSerial += 1
        switch event {
        case .agentStatusChanged(let change):
            lastStatusEvents[change.paneID] = (serial: eventSerial, status: change.status)
        case .agentDetected(let paneID, _, _, _):
            structuralSerial += 1
            processInfoRequested.remove(paneID)
        case .paneUpdated(let info):
            structuralSerial += 1
            processInfoRequested.remove(info.paneID)
        default:
            structuralSerial += 1
        }
        apply(.event(event))
        publishIfChanged()
        if case .layoutChanged = event {
            reconcileNow()
        }
    }

    private func frontmostChanged(_ bundleID: String) {
        guard isRunning else { return }
        apply(.ghosttyFrontmost(bundleID == KnownBundleIDs.ghostty))
        publishIfChanged()
    }

    private func apply(_ input: HerdrInput, fromSnapshot: Bool = false) {
        _ = reducer.apply(input, now: clock.now())
        focusedPaneID = reducer.focusedPaneID
        if phase == .online {
            for paneID in reducer.takeReopenRequests().sorted() {
                closeStream(paneID)   // #3124: syncStreams below reopens it on a new connection
            }
            syncStreams()
            syncDetectionEpisodes(fromSnapshot: fromSnapshot)
            requestMissingProcessInfo()
        } else {
            for episode in detectionEpisodes.values { episode.task?.cancel() }
            detectionEpisodes = [:]
        }
        scheduleDeadline()
    }

    private func syncDetectionEpisodes(fromSnapshot: Bool) {
        let eligible = reducer.rows.filter {
            ($0.state == .waiting && $0.sourceStatus == HerdrAgentStatus.blocked.rawValue) || $0.state == .doneUnseen
        }
        let paneIDs = Set(eligible.map(\.id.key))
        for paneID in Array(detectionEpisodes.keys) where !paneIDs.contains(paneID) {
            detectionEpisodes.removeValue(forKey: paneID)?.task?.cancel()
        }
        var started = false
        for row in eligible {
            let purpose: HerdrDetectionPurpose = row.state == .waiting ? .blocked : .recap
            if let episode = detectionEpisodes[row.id.key], episode.purpose == purpose,
               episode.sourceStatus == row.sourceStatus { continue }
            detectionEpisodes[row.id.key]?.task?.cancel()
            detectionEpisodes[row.id.key] = DetectionEpisode(purpose: purpose, sourceStatus: row.sourceStatus)
            if purpose == .blocked {
                requestDetection(paneID: row.id.key, purpose: purpose)
                started = true
            }
        }
        if started, !fromSnapshot {
            reconcileNow()   // fresh focusedPaneID for the "looking" suppression
        }
    }

    private func requestMissingProcessInfo() {
        let live = Set(reducer.rows.filter { $0.state != .error }.map(\.id.key))
        processInfoRequested.formIntersection(live)
        for paneID in live.sorted() where !processInfoRequested.contains(paneID) {
            processInfoRequested.insert(paneID)
            let session = sessionID
            Task { [weak self] in
                guard let self else { return }
                await self.acquireSlot()
                guard session == self.sessionID, self.phase == .online else {
                    self.releaseSlot()
                    return
                }
                var info: HerdrProcessInfo?
                var abortEnd: SessionEnd?
                do {
                    if case .processInfo(let result) = try await self.perform(.processInfo(paneID: paneID)) {
                        info = result
                    }
                } catch let abort as SessionAbort {
                    abortEnd = abort.end
                } catch {
                    info = nil   // pane gone or transient; the next agentDetected/paneUpdated refetches
                }
                self.releaseSlot()
                guard session == self.sessionID else { return }
                if let abortEnd {
                    self.finishSession(abortEnd, session: session)
                    return
                }
                guard self.phase == .online, let info else { return }
                self.apply(.processInfo(info))
                self.publishIfChanged()
            }
        }
    }

    private func requestDetection(paneID: String, purpose: HerdrDetectionPurpose) {
        guard phase == .online, let episode = detectionEpisodes[paneID], episode.purpose == purpose,
              episode.task == nil, !episode.recapRead else { return }
        let session = sessionID
        episode.task = Task { [weak self] in
            guard let self else { return }
            await self.acquireSlot()
            defer {
                self.releaseSlot()
                if self.detectionEpisodes[paneID] === episode { episode.task = nil }
            }
            guard session == self.sessionID, self.phase == .online, !Task.isCancelled,
                  self.detectionEpisodes[paneID] === episode else { return }
            var text: String?
            var abortEnd: SessionEnd?
            do {
                if case .read(let read) = try await self.perform(.readDetection(paneID: paneID)) {
                    text = read.text
                }
            } catch let abort as SessionAbort {
                abortEnd = abort.end
            } catch {
                text = nil
            }
            guard session == self.sessionID, self.phase == .online, !Task.isCancelled,
                  self.detectionEpisodes[paneID] === episode else { return }
            if let abortEnd {
                self.finishSession(abortEnd, session: session)
                return
            }
            if let text {
                if purpose == .recap { episode.recapRead = true }
                self.apply(.detection(paneID: paneID, text: text, purpose: purpose))
            } else if purpose == .blocked {
                self.apply(.detection(paneID: paneID, text: "", purpose: .blocked))
            }
            self.publishIfChanged()
        }
    }

    // MARK: Reconcile and timers

    private func runReconcile(session: Int) async {
        var staleRetries = 0
        repeat {
            reconcilePending = false
            let requestSerial = eventSerial
            let structural = structuralSerial
            let snapshot: HerdrSnapshot
            do {
                snapshot = try await takeSnapshot()
            } catch let abort as SessionAbort {
                finishSession(abort.end, session: session)
                break
            } catch {
                break   // transient; G EOF or the ping notices a dead server
            }
            guard session == sessionID, phase == .online else { break }
            if structural != structuralSerial, staleRetries < 3 {
                // A lifecycle, focus or layout event was applied while the snapshot was in flight; the snapshot
                // may predate it. (Status events are handled per pane below instead.)
                staleRetries += 1
                reconcilePending = true
                continue
            }
            apply(.snapshot(keepingNewerStreamStatuses(snapshot, requestedAt: requestSerial)), fromSnapshot: true)
            lastStatusEvents = lastStatusEvents.filter { reducer.knownPaneIDs.contains($0.key) }
            publishIfChanged()
        } while reconcilePending && session == sessionID && phase == .online
        if session == sessionID { reconcileInFlight = false }
    }

    /// A pane whose stream reported a status after `serial` (the snapshot's request) keeps the stream's status:
    /// the snapshot's older view would revert working → idle into a false finished-while-away, or drop a
    /// question by reverting waiting → working. Other panes take the snapshot's status (#3124 repair).
    private func keepingNewerStreamStatuses(_ snapshot: HerdrSnapshot, requestedAt serial: Int) -> HerdrSnapshot {
        var newer: [String: HerdrAgentStatus] = [:]
        for (paneID, mark) in lastStatusEvents where mark.serial > serial {
            newer[paneID] = mark.status
        }
        guard !newer.isEmpty else { return snapshot }
        return HerdrFeed.snapshot(snapshot, replacingStatuses: newer)
    }

    private nonisolated static func snapshot(_ snapshot: HerdrSnapshot,
                                             replacingStatuses statuses: [String: HerdrAgentStatus]) -> HerdrSnapshot {
        let panes = snapshot.panes.map { pane -> HerdrPaneInfo in
            guard let status = statuses[pane.paneID], status != pane.agentStatus else { return pane }
            return HerdrPaneInfo(paneID: pane.paneID, workspaceID: pane.workspaceID, tabID: pane.tabID,
                                 focused: pane.focused, agentStatus: status, agent: pane.agent,
                                 terminalTitleStripped: pane.terminalTitleStripped, label: pane.label, cwd: pane.cwd,
                                 revision: pane.revision)
        }
        let agents = snapshot.agents.map { agent -> HerdrAgentInfo in
            guard let status = statuses[agent.paneID], status != agent.agentStatus else { return agent }
            return HerdrAgentInfo(paneID: agent.paneID, workspaceID: agent.workspaceID, tabID: agent.tabID,
                                  focused: agent.focused, agentStatus: status, agent: agent.agent,
                                  displayAgent: agent.displayAgent, name: agent.name,
                                  terminalTitleStripped: agent.terminalTitleStripped, cwd: agent.cwd,
                                  stateChangeSeq: agent.stateChangeSeq)
        }
        return HerdrSnapshot(version: snapshot.version, protocolVersion: snapshot.protocolVersion,
                             focusedWorkspaceID: snapshot.focusedWorkspaceID, focusedTabID: snapshot.focusedTabID,
                             focusedPaneID: snapshot.focusedPaneID, workspaces: snapshot.workspaces, tabs: snapshot.tabs,
                             panes: panes, agents: agents)
    }

    private func startTimers(session: Int) {
        let reconcileEvery = configuration.reconcileInterval
        let pingEvery = configuration.pingInterval
        timerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HerdrFeed.nanoseconds(reconcileEvery))
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.reconcileNow()
            }
        })
        timerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HerdrFeed.nanoseconds(pingEvery))
                guard !Task.isCancelled, let self, self.sessionID == session, self.phase == .online else { return }
                await self.pingOnce(session: session)
            }
        })
    }

    private func pingOnce(session: Int) async {
        do {
            let result = try await perform(.ping)
            guard session == sessionID else { return }
            if case .pong(_, let protocolVersion) = result, protocolVersion != HerdrCodec.supportedProtocol {
                finishSession(.disabled(reason: "protocol \(protocolVersion)"), session: session)
            }
        } catch let abort as SessionAbort {
            finishSession(abort.end, session: session)
        } catch {
            finishSession(.failed(cause: HerdrFeed.causeReason(error)), session: session)
        }
    }

    private func scheduleDeadline() {
        let now = clock.now()
        guard let deadline = reducer.nextDeadline(after: now), deadline != scheduledDeadline else { return }
        scheduledDeadline = deadline
        scheduler.schedule(after: max(0, deadline.timeIntervalSince(now))) { [weak self] in
            guard let self, self.isRunning else { return }
            if self.scheduledDeadline == deadline { self.scheduledDeadline = nil }
            self.tick()
        }
    }

    // MARK: Output

    private func report(_ health: FeedHealth) {
        guard health != lastHealth else { return }
        lastHealth = health
        reportHealth?(health)
    }

    /// A diagnostic is not a health change: NSLog (stderr.log under the LaunchAgent) plus the observer.
    private func diagnose(_ message: String) {
        NSLog("agent-island: herdr %@", message)
        reportDiagnostic?(message)
    }

    /// Publishes only while online (after a successful bootstrap), on every row change. While offline or
    /// disabled nothing is published, so StateStore keeps and dims the old rows; the next online publish
    /// carries whatever changed meanwhile.
    private func publishIfChanged() {
        guard phase == .online else { return }
        let rows = reducer.rows
        guard rows != lastPublished else { return }
        lastPublished = rows
        publishRows?(rows)
    }
}

import Foundation

/// What a detection read was fetched for.
public enum HerdrDetectionPurpose: String, Sendable {
    case blocked
    case recap
}

/// Every input that can change Herdr rows.
public enum HerdrInput: Equatable, Sendable {
    /// Bootstrap or reconcile snapshot. Authoritative for the pane set, statuses and labels.
    case snapshot(HerdrSnapshot)
    case event(HerdrEvent)
    case processInfo(HerdrProcessInfo)
    case detection(paneID: String, text: String, purpose: HerdrDetectionPurpose)
    case ghosttyFrontmost(Bool)
    /// Clears the finished-while-away overlay and an error tombstone.
    case rowClicked(paneID: String, acknowledgmentID: String?)
    /// Deadlines: exit grace, stale aging, tombstone retention.
    case tick
    /// Forget everything (re-bootstrap after the feed was disabled).
    case reset
    /// Herdr went away (EOF, failed ping, protocol disable). Exits still inside their grace period belong to
    /// the dead connection and are dropped, so they never mature into error rows after a reconnect; the dead
    /// streams' last statuses go too. Deadlines already due are processed first, as for every input.
    case connectionLost
}

/// Pure Herdr state machine. It never reads the clock; every rule uses the `now` passed to `apply`.
public struct HerdrReducer: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var hostname: String
        public var staleAfter: TimeInterval
        public var exitGrace: TimeInterval
        public var errorRetention: TimeInterval

        public init(hostname: String) {
            self.hostname = hostname
            self.staleAfter = IslandTiming.staleAfter
            self.exitGrace = IslandTiming.herdrExitGrace
            self.errorRetention = IslandTiming.seenExpiry
        }
    }

    private struct Pane: Sendable {
        var paneID: String
        var workspaceID: String
        var tabID: String
        var isAgent: Bool
        var agentName: String?
        var terminalTitle: String?
        var cwd: String?
        var status: HerdrAgentStatus
        var seq: UInt64?
        /// Last change of status or state_change_seq: the stale clock.
        var statusSince: Date
        var overlay = false
        var overlayAcknowledgmentID: String?
        var detail: Detail?
        var processIDs: [Int32] = []
        /// Last displayed state, used to decide when `since` moves.
        var shownState: DisplayState?
        var since: Date
    }

    private struct PendingExit: Sendable {
        var at: Date
        var released: Bool
        var status: HerdrAgentStatus
    }

    private struct Tombstone: Sendable {
        var row: AgentRow
        var at: Date
    }

    private let configuration: Configuration
    private var panes: [String: Pane] = [:]
    private var workspaceLabels: [String: String] = [:]
    private var tabLabels: [String: String] = [:]
    private var lastStreamStatus: [String: HerdrAgentStatus] = [:]
    private var reopenRequests: Set<String> = []
    private var pendingExits: [String: PendingExit] = [:]
    private var tombstones: [String: Tombstone] = [:]
    private var ghosttyFrontmost = false
    private var acknowledgmentSequence: UInt64 = 0

    public private(set) var rows: [AgentRow] = []
    public private(set) var focusedPaneID: String?
    public private(set) var knownPaneIDs: Set<String> = []

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func apply(_ input: HerdrInput, now: Date) -> [AgentRow] {
        if case .reset = input {
            let sequence = acknowledgmentSequence
            self = HerdrReducer(configuration: configuration)
            acknowledgmentSequence = sequence
            return rows
        }
        processDeadlines(now: now)
        switch input {
        case .snapshot(let snapshot):
            applySnapshot(snapshot, now: now)
        case .event(let event):
            applyEvent(event, now: now)
        case .processInfo(let info):
            panes[info.paneID]?.processIDs = info.foregroundPIDs
        case .detection(let paneID, let text, let purpose):
            applyDetection(paneID: paneID, text: text, purpose: purpose)
        case .ghosttyFrontmost(let frontmost):
            ghosttyFrontmost = frontmost
        case .rowClicked(let paneID, let token):
            // Deadlines above may have created a newer error since the row was clicked.
            if let token {
                if tombstones[paneID]?.row.acknowledgmentID == token { tombstones[paneID] = nil }
                if panes[paneID]?.overlayAcknowledgmentID == token {
                    panes[paneID]?.overlay = false
                    panes[paneID]?.overlayAcknowledgmentID = nil
                }
            }
        case .connectionLost:
            pendingExits = [:]
            lastStreamStatus = [:]
        case .tick, .reset:
            break
        }
        clearOverlayForLookedAtPane()
        rebuildRows(now: now)
        return rows
    }

    /// Panes whose snapshot status disagreed with the last status their stream reported (#3124).
    public mutating func takeReopenRequests() -> Set<String> {
        let requests = reopenRequests
        reopenRequests = []
        return requests
    }

    public func nextDeadline(after now: Date) -> Date? {
        var candidates: [Date] = []
        for pending in pendingExits.values {
            candidates.append(pending.at.addingTimeInterval(configuration.exitGrace))
        }
        for tombstone in tombstones.values {
            candidates.append(tombstone.at.addingTimeInterval(configuration.errorRetention))
        }
        for pane in panes.values where pane.isAgent && pane.status == .working && tombstones[pane.paneID] == nil {
            let staleAt = pane.statusSince.addingTimeInterval(configuration.staleAfter)
            if staleAt > now { candidates.append(staleAt) }
        }
        return candidates.min()
    }

    // MARK: Deadlines

    private mutating func processDeadlines(now: Date) {
        for (paneID, pending) in pendingExits where now >= pending.at.addingTimeInterval(configuration.exitGrace) {
            pendingExits[paneID] = nil
            guard var pane = panes[paneID] else { continue }
            let text: String
            if pending.released {
                text = "Agent released while working"
            } else if pending.status == .blocked {
                text = "Agent exited while waiting"
            } else {
                text = "Agent exited while working"
            }
            var row = makeRow(pane, state: .error, since: now, detail: Detail(question: text, kind: .error))
            row.acknowledgmentID = nextAcknowledgmentID()
            row.processIDs = []
            tombstones[paneID] = Tombstone(row: row, at: now)
            pane.isAgent = false
            pane.overlay = false
            pane.overlayAcknowledgmentID = nil
            pane.detail = nil
            pane.shownState = nil
            panes[paneID] = pane
        }
        for (paneID, tombstone) in tombstones where now >= tombstone.at.addingTimeInterval(configuration.errorRetention) {
            tombstones[paneID] = nil
        }
    }

    // MARK: Snapshot

    private mutating func applySnapshot(_ snapshot: HerdrSnapshot, now: Date) {
        workspaceLabels = [:]
        for workspace in snapshot.workspaces { workspaceLabels[workspace.workspaceID] = workspace.label }
        tabLabels = [:]
        for tab in snapshot.tabs { tabLabels[tab.tabID] = tab.label }
        focusedPaneID = snapshot.focusedPaneID

        var agentsByPane: [String: HerdrAgentInfo] = [:]
        for agent in snapshot.agents { agentsByPane[agent.paneID] = agent }

        var present = Set<String>()
        for info in snapshot.panes {
            present.insert(info.paneID)
            let agent = agentsByPane[info.paneID]
            upsertFromSnapshot(
                paneID: info.paneID, workspaceID: info.workspaceID, tabID: info.tabID,
                status: agent?.agentStatus ?? info.agentStatus, agent: agent,
                terminalTitle: agent?.terminalTitleStripped ?? info.terminalTitleStripped,
                cwd: agent?.cwd ?? info.cwd, now: now
            )
        }
        for agent in snapshot.agents where !present.contains(agent.paneID) {
            present.insert(agent.paneID)
            upsertFromSnapshot(
                paneID: agent.paneID, workspaceID: agent.workspaceID, tabID: agent.tabID,
                status: agent.agentStatus, agent: agent,
                terminalTitle: agent.terminalTitleStripped, cwd: agent.cwd, now: now
            )
        }
        for paneID in Array(panes.keys) where !present.contains(paneID) {
            removePane(paneID)
        }
        knownPaneIDs = present
    }

    private mutating func upsertFromSnapshot(
        paneID: String, workspaceID: String, tabID: String, status: HerdrAgentStatus,
        agent: HerdrAgentInfo?, terminalTitle: String?, cwd: String?, now: Date
    ) {
        if let last = lastStreamStatus[paneID], last != status {
            reopenRequests.insert(paneID)
        }
        lastStreamStatus[paneID] = status
        guard var pane = panes[paneID] else {
            if agent != nil { tombstones[paneID] = nil }   // a reused pane id with a new agent
            panes[paneID] = Pane(
                paneID: paneID, workspaceID: workspaceID, tabID: tabID, isAgent: agent != nil,
                agentName: agent?.displayAgent ?? agent?.agent, terminalTitle: terminalTitle, cwd: cwd,
                status: status, seq: agent?.stateChangeSeq, statusSince: now, since: now
            )
            return
        }
        pane.workspaceID = workspaceID
        pane.tabID = tabID
        pane.terminalTitle = terminalTitle
        pane.cwd = cwd
        if pendingExits[paneID] == nil {
            if !pane.isAgent, agent != nil { tombstones[paneID] = nil }   // a new agent replaces the error
            pane.isAgent = agent != nil
        }
        if let agent { pane.agentName = agent.displayAgent ?? agent.agent ?? pane.agentName }
        let statusChanged = pane.status != status
        setStatus(&pane, to: status, now: now)
        if let seq = agent?.stateChangeSeq {
            if !statusChanged, let previous = pane.seq, previous != seq { pane.statusSince = now }
            pane.seq = seq
        }
        panes[paneID] = pane
    }

    // MARK: Events

    private mutating func applyEvent(_ event: HerdrEvent, now: Date) {
        switch event {
        case .agentStatusChanged(let change):
            lastStreamStatus[change.paneID] = change.status
            guard var pane = panes[change.paneID] else { return }
            setStatus(&pane, to: change.status, now: now)
            panes[change.paneID] = pane
        case .paneCreated(let info):
            upsertFromEvent(info, now: now, setsAgent: true)
        case .paneUpdated(let info):
            upsertFromEvent(info, now: now, setsAgent: false)
        case .paneMoved(let previousPaneID, let info):
            movePane(from: previousPaneID, to: info, now: now)
        case .paneClosed(let paneID, _):
            removePane(paneID)
        case .paneExited(let paneID, _):
            registerExit(paneID: paneID, released: false, finalStatus: nil, now: now)
        case .agentDetected(let paneID, let agent, let released, let finalStatus):
            if released {
                registerExit(paneID: paneID, released: true, finalStatus: finalStatus, now: now)
                if pendingExits[paneID] == nil, var pane = panes[paneID] {
                    pane.isAgent = false
                    pane.overlay = false
                    pane.overlayAcknowledgmentID = nil
                    pane.detail = nil
                    panes[paneID] = pane
                }
            } else if var pane = panes[paneID] {
                tombstones[paneID] = nil   // detection after an exit or release is a new agent
                pane.isAgent = true
                pane.agentName = agent ?? pane.agentName
                pendingExits[paneID] = nil
                panes[paneID] = pane
            }
        case .paneFocused(let paneID, _):
            focusedPaneID = paneID
        case .tabFocused, .workspaceFocused, .layoutChanged, .unknown:
            break
        }
    }

    private mutating func upsertFromEvent(_ info: HerdrPaneInfo, now: Date, setsAgent: Bool) {
        knownPaneIDs.insert(info.paneID)
        guard var pane = panes[info.paneID] else {
            panes[info.paneID] = Pane(
                paneID: info.paneID, workspaceID: info.workspaceID, tabID: info.tabID, isAgent: info.agent != nil,
                agentName: info.agent, terminalTitle: info.terminalTitleStripped, cwd: info.cwd,
                status: info.agentStatus, seq: nil, statusSince: now, since: now
            )
            return
        }
        pane.workspaceID = info.workspaceID
        pane.tabID = info.tabID
        if let title = info.terminalTitleStripped { pane.terminalTitle = title }
        if let cwd = info.cwd { pane.cwd = cwd }
        if setsAgent, pendingExits[info.paneID] == nil { pane.isAgent = info.agent != nil }
        if pane.agentName == nil { pane.agentName = info.agent }
        panes[info.paneID] = pane
    }

    private mutating func movePane(from previousPaneID: String, to info: HerdrPaneInfo, now: Date) {
        guard previousPaneID != info.paneID else {
            upsertFromEvent(info, now: now, setsAgent: false)
            return
        }
        if var pane = panes.removeValue(forKey: previousPaneID) {
            pane.paneID = info.paneID
            pane.workspaceID = info.workspaceID
            pane.tabID = info.tabID
            if let title = info.terminalTitleStripped { pane.terminalTitle = title }
            if let cwd = info.cwd { pane.cwd = cwd }
            panes[info.paneID] = pane
        } else {
            upsertFromEvent(info, now: now, setsAgent: true)
        }
        if let pending = pendingExits.removeValue(forKey: previousPaneID) { pendingExits[info.paneID] = pending }
        if let last = lastStreamStatus.removeValue(forKey: previousPaneID) { lastStreamStatus[info.paneID] = last }
        reopenRequests.remove(previousPaneID)
        knownPaneIDs.remove(previousPaneID)
        knownPaneIDs.insert(info.paneID)
        if focusedPaneID == previousPaneID { focusedPaneID = info.paneID }
    }

    private mutating func removePane(_ paneID: String) {
        panes[paneID] = nil
        pendingExits[paneID] = nil
        lastStreamStatus[paneID] = nil
        reopenRequests.remove(paneID)
        knownPaneIDs.remove(paneID)
    }

    /// `finalStatus` is the release's own final status; the tracked status can be stale when the
    /// pane's stream went silent (#3124).
    private mutating func registerExit(paneID: String, released: Bool, finalStatus: HerdrAgentStatus?, now: Date) {
        guard pendingExits[paneID] == nil, tombstones[paneID] == nil,
              let pane = panes[paneID], pane.isAgent else { return }
        let status = finalStatus ?? pane.status
        let watched: Set<HerdrAgentStatus> = released ? [.working] : [.working, .blocked]
        guard watched.contains(status) else { return }
        if ghosttyFrontmost, focusedPaneID == paneID { return }   // Nathan closed it himself
        pendingExits[paneID] = PendingExit(at: now, released: released, status: status)
    }

    private mutating func setStatus(_ pane: inout Pane, to status: HerdrAgentStatus, now: Date) {
        guard pane.status != status else { return }
        if pane.status == .working, status == .idle, !ghosttyFrontmost {
            pane.overlay = true
            pane.overlayAcknowledgmentID = nextAcknowledgmentID()
        }
        if status == .working || status == .done {
            pane.overlay = false
            pane.overlayAcknowledgmentID = nil
        }
        pane.status = status
        pane.statusSince = now
        pane.detail = nil
    }

    // MARK: Detection and overlay

    private mutating func applyDetection(paneID: String, text: String, purpose: HerdrDetectionPurpose) {
        guard var pane = panes[paneID], pane.isAgent else { return }
        switch purpose {
        case .blocked:
            guard pane.status == .blocked else { return }
            if let prompt = DetectionTextParser.parseBlocked(text) {
                pane.detail = Detail(
                    question: prompt.question,
                    options: Array(prompt.options.prefix(DetectionTextParser.maxOptions)),
                    kind: .question
                )
            } else {
                pane.detail = Detail(question: "\(title(for: pane)) needs you", kind: .question)
            }
        case .recap:
            guard pane.status == .done || (pane.status == .idle && pane.overlay) else { return }
            guard let recap = DetectionTextParser.parseRecap(text) else { return }
            pane.detail = Detail(question: recap, kind: .recap)
        }
        panes[paneID] = pane
    }

    private mutating func clearOverlayForLookedAtPane() {
        guard ghosttyFrontmost, let focused = focusedPaneID, panes[focused]?.overlay == true else { return }
        panes[focused]?.overlay = false
        panes[focused]?.overlayAcknowledgmentID = nil
    }

    private mutating func nextAcknowledgmentID() -> String {
        acknowledgmentSequence += 1
        return "herdr:\(acknowledgmentSequence)"
    }

    // MARK: Rows

    private mutating func rebuildRows(now: Date) {
        var result: [AgentRow] = []
        for paneID in panes.keys.sorted() {
            guard var pane = panes[paneID] else { continue }
            guard pane.isAgent, tombstones[paneID] == nil else {
                if pane.shownState != nil {
                    pane.shownState = nil
                    panes[paneID] = pane
                }
                continue
            }
            let state = displayState(of: pane, now: now)
            if let shown = pane.shownState, Self.sharesSince(shown, state) {
                // unchanged state (working and stale share one clock): keep since
            } else {
                pane.since = now
            }
            pane.shownState = state
            panes[paneID] = pane
            result.append(makeRow(pane, state: state, since: pane.since, detail: visibleDetail(of: pane, in: state)))
        }
        for paneID in tombstones.keys.sorted() {
            if let tombstone = tombstones[paneID] { result.append(tombstone.row) }
        }
        rows = result
    }

    private static func sharesSince(_ lhs: DisplayState, _ rhs: DisplayState) -> Bool {
        if lhs == rhs { return true }
        let aging: Set<DisplayState> = [.working, .stale]
        return aging.contains(lhs) && aging.contains(rhs)
    }

    private func displayState(of pane: Pane, now: Date) -> DisplayState {
        switch pane.status {
        case .working:
            return now.timeIntervalSince(pane.statusSince) >= configuration.staleAfter ? .stale : .working
        case .blocked:
            return .waiting
        case .done:
            return .doneUnseen
        case .idle:
            return pane.overlay ? .doneUnseen : .idle
        case .unknown:
            return .starting
        }
    }

    private func visibleDetail(of pane: Pane, in state: DisplayState) -> Detail? {
        switch state {
        case .waiting:
            return pane.detail?.kind == .question ? pane.detail : nil
        case .doneUnseen:
            return pane.detail?.kind == .recap ? pane.detail : nil
        default:
            return nil
        }
    }

    private func makeRow(_ pane: Pane, state: DisplayState, since: Date, detail: Detail?) -> AgentRow {
        AgentRow(
            id: RowID(source: .herdr, key: pane.paneID),
            title: title(for: pane),
            subtitle: subtitle(for: pane),
            state: state,
            since: since,
            detail: detail,
            jump: .herdrPane(paneID: pane.paneID, windowTitlePrefix: windowTitlePrefix(for: pane)),
            cwd: pane.cwd,
            processIDs: pane.processIDs,
            sourceStatus: pane.status.rawValue,
            acknowledgmentID: state == .doneUnseen && pane.overlay ? pane.overlayAcknowledgmentID : nil
        )
    }

    private func title(for pane: Pane) -> String {
        SessionTitleFormatter.rowTitle(tabTitle: pane.terminalTitle, fallback: pane.agentName ?? pane.paneID)
    }

    private func subtitle(for pane: Pane) -> String {
        let workspace = workspaceLabels[pane.workspaceID] ?? pane.workspaceID
        let tab = tabLabels[pane.tabID] ?? pane.tabID
        return "\(workspace) › \(tab)"
    }

    /// Herdr's default Ghostty window title is "<host>: <workspace>".
    private func windowTitlePrefix(for pane: Pane) -> String? {
        guard let label = workspaceLabels[pane.workspaceID] else { return nil }
        return "\(configuration.hostname): \(label)"
    }
}

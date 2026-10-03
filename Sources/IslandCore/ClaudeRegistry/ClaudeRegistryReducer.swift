import Foundation

/// Pure mapping from live registry entries to rows. Owns the island's doneUnseen flag for registry sessions.
/// Cross-source deduplication against Herdr panes is RowMerger's job (it sees both sources); this reducer never
/// looks at Herdr.
public struct ClaudeRegistryReducer: Sendable {
    private struct Tracked: Sendable {
        var lastStatus: String?
        var doneAt: Date?
        var state: DisplayState
        var changedAt: Date
        var acknowledgmentID: String?
    }

    private let seenExpiry: TimeInterval
    private let staleAfter: TimeInterval
    private var tracked: [String: Tracked] = [:]
    private var acknowledgmentSequence: UInt64 = 0

    public init(seenExpiry: TimeInterval = IslandTiming.seenExpiry, staleAfter: TimeInterval = IslandTiming.staleAfter) {
        self.seenExpiry = seenExpiry
        self.staleAfter = staleAfter
    }

    /// `entries` are already liveness-filtered. Drops kind != "interactive" and "sdk-*" entrypoints, except an
    /// "sdk-cli" entry with a well-formed bridgeSessionId (a Remote Control session a person drives from Claude),
    /// maps status, and returns rows sorted by RowID key. State for entries that are no longer passed in is forgotten.
    ///
    /// Jump: "claude-desktop" opens the native session in Claude Desktop; a Remote Control session opens its
    /// conversation by bridge id; everything else, including a terminal session with Remote Control on, stays a
    /// terminal jump.
    ///
    /// Status mapping:
    /// - busy → working, or stale when statusUpdatedAt is older than `staleAfter`.
    /// - waiting → waiting with a Detail: kind .permission when waitingFor mentions "permission", else .question;
    ///   the text is waitingFor plus the session name.
    /// - idle right after busy → doneUnseen until markSeen, the next non-idle status, or `seenExpiry`.
    /// - idle, shell, a missing or unknown status → idle.
    ///
    /// `since` is statusUpdatedAt when present, else the time this reducer first saw the current DisplayState.
    public mutating func apply(_ entries: [RegistryEntry], now: Date) -> [AgentRow] {
        var next: [String: Tracked] = [:]
        var rows: [AgentRow] = []
        for entry in entries where Self.isIncluded(entry) {
            let key = entry.rowKey
            guard next[key] == nil else { continue }
            let previous = tracked[key]
            var doneAt: Date?
            var acknowledgmentID: String?
            if entry.status == "idle" {
                doneAt = previous?.lastStatus == "busy" ? now : previous?.doneAt
                if previous?.lastStatus == "busy" {
                    acknowledgmentSequence += 1
                    acknowledgmentID = "registry:\(acknowledgmentSequence)"
                } else {
                    acknowledgmentID = previous?.acknowledgmentID
                }
            }
            if let flaggedAt = doneAt, now.timeIntervalSince(flaggedAt) >= seenExpiry {
                doneAt = nil
            }
            if doneAt == nil { acknowledgmentID = nil }
            let sourceDate = entry.statusUpdatedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
            let state = Self.state(for: entry, doneUnseen: doneAt != nil, sourceDate: sourceDate,
                                   staleAfter: staleAfter, now: now)
            let changedAt = previous.map { $0.state == state ? $0.changedAt : now } ?? now
            next[key] = Tracked(lastStatus: entry.status, doneAt: doneAt, state: state, changedAt: changedAt,
                                acknowledgmentID: acknowledgmentID)
            var row = Self.row(for: entry, key: key, state: state, since: sourceDate ?? changedAt)
            row.acknowledgmentID = acknowledgmentID
            rows.append(row)
        }
        tracked = next
        return rows.sorted { $0.id.key < $1.id.key }
    }

    /// Click side effect: clears the doneUnseen flag. The caller re-applies its entries to publish the change.
    public mutating func markSeen(_ row: AgentRow) {
        guard row.source == .claudeRegistry, let token = row.acknowledgmentID,
              tracked[row.id.key]?.acknowledgmentID == token else { return }
        tracked[row.id.key]?.doneAt = nil
        tracked[row.id.key]?.acknowledgmentID = nil
    }

    private static func isIncluded(_ entry: RegistryEntry) -> Bool {
        guard entry.kind == "interactive" else { return false }
        if let entrypoint = entry.entrypoint, entrypoint.hasPrefix("sdk-") { return remoteControlBridgeID(entry) != nil }
        return true
    }

    /// The bridge id of a Remote Control session: an "sdk-cli" entry whose bridgeSessionId decoded (only a
    /// well-formed id does). nil for every other entry.
    private static func remoteControlBridgeID(_ entry: RegistryEntry) -> String? {
        entry.entrypoint == "sdk-cli" ? entry.bridgeSessionId : nil
    }

    private static func jumpTarget(for entry: RegistryEntry, tmux: String?) -> JumpTarget {
        if entry.entrypoint == "claude-desktop" {
            return .claudeDesktop(sessionID: entry.sessionId, tmuxTarget: tmux)
        }
        if let bridgeSessionID = remoteControlBridgeID(entry) {
            return .claudeRemoteControl(bridgeSessionID: bridgeSessionID)
        }
        return .terminal(tmuxTarget: tmux)
    }

    private static func state(for entry: RegistryEntry, doneUnseen: Bool, sourceDate: Date?,
                              staleAfter: TimeInterval, now: Date) -> DisplayState {
        switch entry.status {
        case "busy":
            if let sourceDate, now.timeIntervalSince(sourceDate) > staleAfter { return .stale }
            return .working
        case "waiting":
            return .waiting
        case "idle":
            return doneUnseen ? .doneUnseen : .idle
        default:
            return .idle
        }
    }

    private static func row(for entry: RegistryEntry, key: String, state: DisplayState, since: Date) -> AgentRow {
        let name = nonEmpty(entry.name)
        let folder = nonEmpty(entry.cwd).map { URL(fileURLWithPath: $0).lastPathComponent }
        let tmux = nonEmpty(entry.tmux)
        return AgentRow(
            id: RowID(source: .claudeRegistry, key: key),
            title: name ?? folder ?? "Claude session",
            subtitle: folder ?? "",
            state: state,
            since: since,
            detail: state == .waiting ? detail(for: entry, name: name) : nil,
            jump: jumpTarget(for: entry, tmux: tmux),
            cwd: entry.cwd,
            processIDs: [entry.pid],
            sourceStatus: entry.status
        )
    }

    private static func detail(for entry: RegistryEntry, name: String?) -> Detail {
        let reason = nonEmpty(entry.waitingFor) ?? "needs you"
        let kind: Detail.Kind = reason.lowercased().contains("permission") ? .permission : .question
        return Detail(question: name.map { "\(reason) — \($0)" } ?? reason, options: [], kind: kind)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

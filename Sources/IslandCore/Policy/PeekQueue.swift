import Foundation

/// Spec §7.3: the cards waiting to be shown. Pure value type; PeekCoordinator owns one.
///
/// - Order: error before waiting, then the newest event (`at` descending), then `rowID.description`.
///   `current` is always the head of that order when events arrive, so a new error takes the card
///   from a waiting one, and a newer waiting event takes it from an older waiting one. The displaced
///   event goes back into `pending`.
/// - One entry per row: enqueueing an event for a row replaces that row's older entry.
/// - `shownAt` restarts whenever `current` changes, so every card gets its full duration.
/// - `advance` retires `current` after `duration` (8 s) unless hovered, then promotes the head of
///   `pending`.
public struct PeekQueue: Equatable, Sendable {
    public private(set) var current: PeekEvent?
    public private(set) var pending: [PeekEvent]
    public private(set) var shownAt: Date?

    /// The "+N more" count on the card.
    public var moreCount: Int { pending.count }

    public init() {
        current = nil
        pending = []
        shownAt = nil
    }

    public mutating func enqueue(_ events: [PeekEvent], now: Date) {
        guard !events.isEmpty else { return }
        var all = pending
        if let current { all.insert(current, at: 0) }
        for event in events {
            all.removeAll { $0.rowID == event.rowID }
            all.append(event)
        }
        all.sort(by: Self.showsBefore)
        let head = all.removeFirst()
        if head != current { shownAt = now }
        current = head
        pending = all
    }

    /// Drops every event whose row is gone or no longer in the event's state
    /// (a waiting event needs a waiting row, an error event an error row).
    public mutating func prune(rows: [AgentRow]) {
        let states = Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        func keeps(_ event: PeekEvent) -> Bool {
            switch (event.kind, states[event.rowID]) {
            case (.waiting, .waiting?), (.error, .error?): true
            default: false
            }
        }
        pending.removeAll { !keeps($0) }
        if let current, !keeps(current) {
            self.current = nil
            shownAt = nil
        }
    }

    /// Retires an expired, unhovered `current` and promotes the next pending event.
    /// Returns true when `current` changed.
    @discardableResult
    public mutating func advance(now: Date, isHovered: Bool, duration: TimeInterval = IslandTiming.peekDuration) -> Bool {
        var changed = false
        if current != nil {
            guard let shown = shownAt else {
                shownAt = now
                return false
            }
            let elapsed = now.timeIntervalSince(shown)
            if elapsed < 0 {
                // The clock moved backwards: restart this card's duration instead of pinning it.
                shownAt = now
                return false
            }
            if isHovered || elapsed < duration { return false }
            current = nil
            shownAt = nil
            changed = true
        }
        if current == nil, !pending.isEmpty {
            current = pending.removeFirst()
            shownAt = now
            changed = true
        }
        return changed
    }

    /// Drops `current` without promoting anything (a card click). The next `advance` promotes.
    public mutating func dismissCurrent() {
        current = nil
        shownAt = nil
    }

    public func snapshot() -> PeekQueueSnapshot {
        PeekQueueSnapshot(current: current?.rowID, pending: pending.map(\.rowID), moreCount: moreCount)
    }

    static func showsBefore(_ lhs: PeekEvent, _ rhs: PeekEvent) -> Bool {
        let lhsRank = lhs.kind == .error ? 0 : 1
        let rhsRank = rhs.kind == .error ? 0 : 1
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.at != rhs.at { return lhs.at > rhs.at }
        return lhs.rowID.description < rhs.rowID.description
    }
}

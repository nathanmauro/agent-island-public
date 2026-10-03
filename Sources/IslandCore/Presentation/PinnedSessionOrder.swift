import Foundation

/// The row order an open session menu holds on to.
///
/// `StateStore` sorts by severity and then by `since`, and every state change
/// moves `since`, so a pair of busy agents reshuffles the list several times
/// a minute. That is the right behavior for a list nobody is pointing at,
/// and the wrong one for a list being used: the row you are reaching for
/// slides out from under the pointer, so the click lands on whatever took
/// its place. Hover itself recovers on its own — SwiftUI re-resolves it when
/// the layout moves beneath a still cursor — but aim does not.
///
/// So the menu pins the order it opened with. A row keeps its slot for as
/// long as it is on screen, newcomers land at the end where they displace
/// nothing, and the fresh sort arrives with the next opening.
public struct PinnedSessionOrder: Equatable, Sendable {
    private var rowIDs: [RowID] = []

    public init() {}

    /// Learns rows the pin has not seen yet, in the order given, and forgets
    /// the ones that have left the list. Deliberately additive: re-recording
    /// must never renumber a slot that is already pinned, or the pin would
    /// drift back toward the store's live ordering.
    public mutating func record(_ rows: [AgentRow]) {
        let liveRowIDs = Set(rows.map(\.id))
        rowIDs.removeAll { !liveRowIDs.contains($0) }
        var known = Set(rowIDs)
        for rowID in rows.map(\.id) where known.insert(rowID).inserted {
            rowIDs.append(rowID)
        }
    }

    /// `rows` in pinned order: pinned rows first, each in its recorded slot,
    /// then anything unrecorded in the order it arrived. An empty pin hands
    /// the store's own ordering back untouched, so the first render of a
    /// freshly opened menu is already correct.
    public func ordered(_ rows: [AgentRow]) -> [AgentRow] {
        guard !rowIDs.isEmpty else { return rows }
        let slotsByRowID = Dictionary(
            rowIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        // A stable partition rather than a sort: unpinned rows have no slot
        // to compare and must keep their relative arrival order.
        var pinned: [(slot: Int, row: AgentRow)] = []
        var unpinned: [AgentRow] = []
        for row in rows {
            if let slot = slotsByRowID[row.id] {
                pinned.append((slot, row))
            } else {
                unpinned.append(row)
            }
        }
        return pinned.sorted { $0.slot < $1.slot }.map(\.row) + unpinned
    }
}

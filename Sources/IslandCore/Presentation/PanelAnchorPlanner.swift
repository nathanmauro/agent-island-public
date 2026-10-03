import Foundation

/// What is on screen before a re-anchor: the displays hosting a pill panel,
/// the display showing the peek card (nil when no card is up), and whether
/// any board is expanded.
public struct PanelAnchorState: Equatable, Sendable {
    public var pillDisplayIDs: [UInt32]
    public var cardDisplayID: UInt32?
    public var boardExpanded: Bool

    public init(pillDisplayIDs: [UInt32], cardDisplayID: UInt32?, boardExpanded: Bool) {
        self.pillDisplayIDs = pillDisplayIDs
        self.cardDisplayID = cardDisplayID
        self.boardExpanded = boardExpanded
    }
}

/// What the panel controllers must do after a display change, a wake, or a
/// display-mode change. The controllers execute it; they decide nothing.
public struct PanelAnchorPlan: Equatable, Sendable {
    /// Every display that hosts a pill panel after the plan runs.
    public let pillDisplayIDs: [UInt32]
    /// Displays that need a new pill panel.
    public let createdPillDisplayIDs: [UInt32]
    /// Pill panels to tear down (their display is gone or no longer selected).
    public let removedPillDisplayIDs: [UInt32]
    /// Where the peek card goes; nil when no card is showing or no display exists.
    public let cardDisplayID: UInt32?
    /// Collapse every expanded board before re-laying out: the geometry under it may have moved.
    public let collapseBoard: Bool
    /// Recompute every kept panel's layout from its current screen.
    public let relayoutAll: Bool

    public init(
        pillDisplayIDs: [UInt32],
        createdPillDisplayIDs: [UInt32],
        removedPillDisplayIDs: [UInt32],
        cardDisplayID: UInt32?,
        collapseBoard: Bool,
        relayoutAll: Bool
    ) {
        self.pillDisplayIDs = pillDisplayIDs
        self.createdPillDisplayIDs = createdPillDisplayIDs
        self.removedPillDisplayIDs = removedPillDisplayIDs
        self.cardDisplayID = cardDisplayID
        self.collapseBoard = collapseBoard
        self.relayoutAll = relayoutAll
    }
}

/// Pure re-anchoring after the 0.35 s settle that follows a screen-parameter
/// change or a wake (and immediately on a display-mode change).
///
/// Rules:
/// - Pills go where `ScreenSelection.selectDisplayIDs` says: the current
///   primary, or every display.
/// - A card stays on its display while that display is connected (the
///   controller re-lays it out there). When its display is gone it moves to
///   the display under the pointer, or to the primary when the pointer is
///   off-screen.
/// - Any expanded board is collapsed, because a re-anchor only runs after the
///   geometry may have moved under it; the next hover re-opens it.
/// - With no displays at all the plan keeps nothing and lays out nothing.
public enum PanelAnchorPlanner {
    public static func plan(
        mode: ScreenSelectionMode,
        mainDisplayID: UInt32?,
        pointer: DisplayPoint?,
        displays: [DisplaySnapshot],
        current: PanelAnchorState
    ) -> PanelAnchorPlan {
        let pills = ScreenSelection.selectDisplayIDs(
            mode: mode,
            mainDisplayID: mainDisplayID,
            displays: displays
        )
        let currentPills = Set(current.pillDisplayIDs)
        let nextPills = Set(pills)
        let created = pills.filter { !currentPills.contains($0) }
        var removed: [UInt32] = []
        for displayID in current.pillDisplayIDs
        where !nextPills.contains(displayID) && !removed.contains(displayID) {
            removed.append(displayID)
        }

        let connected = Set(displays.map(\.id))
        let card: UInt32?
        if let cardDisplayID = current.cardDisplayID {
            card = connected.contains(cardDisplayID)
                ? cardDisplayID
                : ScreenSelection.pointerDisplay(
                    pointer: pointer,
                    mainDisplayID: mainDisplayID,
                    displays: displays
                )
        } else {
            card = nil
        }

        return PanelAnchorPlan(
            pillDisplayIDs: pills,
            createdPillDisplayIDs: created,
            removedPillDisplayIDs: removed,
            cardDisplayID: card,
            collapseBoard: current.boardExpanded,
            relayoutAll: !displays.isEmpty
        )
    }
}

/// Carries out a `PanelAnchorPlan` on live panels keyed by display ID. The
/// controller supplies the AppKit side through the closures; this owns the
/// order and guarantees that no panel outlives the plan.
///
/// Order: collapse every open board on the panels as they stand, tear down
/// the removed panels, re-lay out each kept panel (when `relayoutAll`) or
/// create the missing one, in plan order, then tear down any panel the plan
/// no longer names. It works on a copy and returns the new set, so a callback
/// that reads the controller's panels mid-way sees the old set, never a
/// half-applied one.
public enum PanelAnchorExecutor {
    @MainActor
    public static func apply<Panel>(
        _ plan: PanelAnchorPlan,
        to panels: [UInt32: Panel],
        collapseBoard: (Panel) -> Void,
        tearDown: (Panel) -> Void,
        relayout: (UInt32, Panel) -> Void,
        make: (UInt32) -> Panel?
    ) -> [UInt32: Panel] {
        var panels = panels
        if plan.collapseBoard {
            for displayID in panels.keys.sorted() {
                if let panel = panels[displayID] {
                    collapseBoard(panel)
                }
            }
        }
        for displayID in plan.removedPillDisplayIDs {
            if let panel = panels.removeValue(forKey: displayID) {
                tearDown(panel)
            }
        }
        for displayID in plan.pillDisplayIDs {
            if let panel = panels[displayID] {
                if plan.relayoutAll {
                    relayout(displayID, panel)
                }
            } else if let panel = make(displayID) {
                panels[displayID] = panel
            }
        }
        // Defensive: a panel the plan no longer names must not linger.
        let planned = Set(plan.pillDisplayIDs)
        for displayID in panels.keys.sorted() where !planned.contains(displayID) {
            if let panel = panels.removeValue(forKey: displayID) {
                tearDown(panel)
            }
        }
        return panels
    }
}

/// The 0.35 s display settle. The WindowServer reports docking, resolution
/// and lid changes in bursts, and a wake can land in the same burst, so each
/// request restarts the wait and the work runs once, `delay` after the last
/// request, on the final geometry. The pill controller and the card each own
/// one: PeekCardPanelModel runs its own settle on the same delay and
/// re-anchors the card itself; it does not share the pill controller's.
@MainActor
public final class DisplaySettle {
    private let scheduler: DeadlineScheduler
    private var generation: UInt64 = 0

    /// True from a request until its work runs.
    public private(set) var isPending = false

    public init(scheduler: DeadlineScheduler = .mainQueue) {
        self.scheduler = scheduler
    }

    /// Runs `work` once `delay` after this request, unless another request
    /// arrives first; the newer request then replaces it and restarts the wait.
    public func request(
        after delay: TimeInterval = IslandTiming.displaySettle,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        generation &+= 1
        let ticket = generation
        isPending = true
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, generation == ticket else { return }
            isPending = false
            work()
        }
    }
}

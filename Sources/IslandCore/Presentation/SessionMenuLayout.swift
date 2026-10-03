import Foundation

/// Shared expanded-menu spacing. Keeping these values outside the SwiftUI
/// tree makes the compact horizontal layout explicit and testable.
public enum SessionMenuLayout {
    public static let errorRowHeight: CGFloat = 25
    public static let contentHorizontalInset: CGFloat = 4
    /// Gap between the notch bar — whose wings now hold the header — and the
    /// first session row.
    public static let listTopPadding: CGFloat = 6
    /// Leading inset for the session rows' own content, shared with the
    /// header math below so both columns stay aligned.
    public static let sessionRowLeadingInset: CGFloat = 12
    /// Outer insets for header content living in the expanded bar wings,
    /// chosen so the header columns line up with the session rows below:
    /// leading matches the row's agent icon (8pt centering gutter + 4pt card
    /// inset + 12pt row leading), trailing matches the row's chevron button
    /// (8 + 4 + 12pt chevron trailing).
    public static let expandedHeaderLeadingInset: CGFloat = 24
    public static let expandedHeaderTrailingInset: CGFloat = 24
    public static let cardStackSpacing: CGFloat = 2
    public static let cardBottomPadding: CGFloat = 6
    public static let sessionListBottomPadding: CGFloat = 4
    /// Compact board rows (§7.2): one line per agent.
    public static let sessionRowHeight: CGFloat = IslandTiming.compactRowHeight
    /// The "Waiting" / "Error" / "Working" / "Done" / "N idle" label above
    /// each board group.
    public static let groupHeaderHeight: CGFloat = 20
    /// Legacy list budget, used when no board cap is passed (a layout built
    /// without a visible-frame height). The board passes its own maximum
    /// through `boardListHeight(rowCount:groupCount:hasExpandedActions:maximumHeight:)`.
    public static let maximumSessionListHeight: CGFloat = 300
    /// Three 32pt action rows (Rename, Copy Project Path, Reveal in Finder),
    /// their two hairline separators, and the area's 13pt vertical insets.
    /// The list reserves this whenever a row's actions are open; the rename
    /// sub-mode renders shorter content inside the same reservation rather
    /// than resizing the list.
    public static let expandedActionsHeight: CGFloat = 111

    /// The largest card the legacy panel must accommodate: a full list and
    /// every vertical inset rendered by `SessionMenuCard`. The header lives in
    /// the bar wings, so it adds no card height.
    public static func maximumCardHeight(hasError: Bool = false) -> CGFloat {
        listTopPadding
            + maximumSessionListHeight
            + sessionListBottomPadding
            + cardBottomPadding
            + (hasError ? errorRowHeight : 0)
    }

    /// The part of a board card that is not the scrolling list: top and
    /// bottom insets plus the reserved error row (41 pt).
    public static var boardCardChromeHeight: CGFloat {
        maximumCardHeight(hasError: true) - maximumSessionListHeight
    }

    /// The list's share of a board card budget (`NotchLayout.boardMaxHeight`).
    /// The legacy 341 pt budget gives back the legacy 300 pt list.
    public static func boardListMaximumHeight(boardMaxHeight: CGFloat) -> CGFloat {
        guard boardMaxHeight.isFinite else { return 0 }
        return max(0, boardMaxHeight - boardCardChromeHeight)
    }

    /// Metrics for the inline action list (Rename, Copy, Reveal).
    /// The hover resolver below depends on them, so they live here rather
    /// than as literals inside the SwiftUI tree.
    public static let actionRowHeight: CGFloat = 32
    public static let actionRowSpacing: CGFloat = 1

    /// Which action entry sits under a pointer at a list-local position.
    ///
    /// Per-row `.onHover` enter/exit pairs come from AppKit tracking areas
    /// that are replaced while the row's expansion spring animates, so the
    /// highlight could trail the pointer or skip an entry. Deriving the index
    /// from the pointer position on every continuous-hover sample makes the
    /// highlight exactly as current as the last mouse event. The hairline gap
    /// between entries counts toward the row above it, so the pointer never
    /// crosses a dead zone inside the list.
    public static func actionRowIndex(
        x: CGFloat,
        y: CGFloat,
        listWidth: CGFloat,
        rowCount: Int
    ) -> Int? {
        guard rowCount > 0, x >= 0, x < listWidth, y >= 0 else { return nil }
        let rowStride = actionRowHeight + actionRowSpacing
        let listHeight = CGFloat(rowCount) * rowStride - actionRowSpacing
        guard y < listHeight else { return nil }
        return min(Int(y / rowStride), rowCount - 1)
    }

    public static func sessionListHeight(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }

    /// A scroll affordance belongs only to a list whose expanded content
    /// cannot fit in its assigned viewport. Showing it for a fitting row
    /// makes the pointer target move unnecessarily while the row opens.
    public static func requiresScrolling(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> Bool {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return rowsHeight + actionsHeight > maximumSessionListHeight
    }

    /// Height of the grouped board list: one header per shown group, one
    /// compact row per visible row (a collapsed idle group contributes its
    /// header only), and the inline-actions reservation. Never more than
    /// `maximumHeight`; longer boards scroll inside it.
    public static func boardListHeight(
        rowCount: Int,
        groupCount: Int,
        hasExpandedActions: Bool,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let content = CGFloat(max(0, groupCount)) * groupHeaderHeight
            + CGFloat(max(0, rowCount)) * sessionRowHeight
            + (hasExpandedActions ? expandedActionsHeight : 0)
        let cap = maximumHeight.isFinite ? max(0, maximumHeight) : 0
        return min(content, cap)
    }
}

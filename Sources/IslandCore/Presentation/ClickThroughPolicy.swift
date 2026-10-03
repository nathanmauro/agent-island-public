import Foundation

/// How one panel treats the mouse right now. `ignoresMouseEvents` is always
/// `!isInside`: the panel only takes events over its visible surface.
public struct PointerRoute: Equatable, Sendable {
    public let ignoresMouseEvents: Bool
    public let isInside: Bool

    public init(isInside: Bool) {
        self.isInside = isInside
        ignoresMouseEvents = !isInside
    }
}

/// Decides click-through for a fixed-size panel. The panel always spans its
/// expanded height (800 x 898 pt on the Samsung, 800 x 612 pt on the built-in
/// since the Task 12 board cap), so without this about 870 pt (Samsung) of
/// transparent panel would sit over the title and tab bars of the window below. The app's always-on
/// pointer monitor asks this policy on every mouse move and sets
/// `NSWindow.ignoresMouseEvents` from the answer.
public enum ClickThroughPolicy {
    /// `pointer` and `panelFrame` are AppKit global coordinates (y grows
    /// upward). `region` is panel-local with a top-leading origin, exactly as
    /// `NotchHostingView.hitTest` tests it.
    ///
    /// The panel's top edge is included: a pointer pushed against the top of
    /// the screen reports y == the panel's maxY, and it is tested as the
    /// first half-point row of the panel so a hardware-notch bar stays
    /// clickable at the screen edge.
    public static func route(
        pointer: DisplayPoint,
        panelFrame: DisplayFrame,
        region: HangingNotchInteractionRegion
    ) -> PointerRoute {
        guard pointer.x.isFinite, pointer.y.isFinite,
              panelFrame.width > 0, panelFrame.height > 0 else {
            return PointerRoute(isInside: false)
        }
        let panelTop = panelFrame.minY + panelFrame.height
        guard pointer.x >= panelFrame.minX,
              pointer.x < panelFrame.minX + panelFrame.width,
              pointer.y >= panelFrame.minY,
              pointer.y <= panelTop else {
            return PointerRoute(isInside: false)
        }
        let local = DisplayPoint(
            x: pointer.x - panelFrame.minX,
            y: max(panelTop - pointer.y, 0.5)
        )
        return PointerRoute(isInside: region.contains(local))
    }
}

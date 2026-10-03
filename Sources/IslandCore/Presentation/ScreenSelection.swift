import Foundation

/// Where the pill panels live. The pill stays on the primary display (or is
/// mirrored on every display); only the peek card follows the pointer.
/// Pointer-follow and focused-window modes for the pill were removed.
public enum ScreenSelectionMode: String, CaseIterable, Sendable {
    case primary
    case allDisplays

    /// Reads the stored preference. Unknown and legacy values ("pointer",
    /// "focusedWindow", a missing key) all migrate to `.primary`.
    public init(storedValue: String?) {
        self = storedValue.flatMap { ScreenSelectionMode(rawValue: $0) } ?? .primary
    }
}

public struct DisplayPoint: Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

public struct DisplayFrame: Equatable, Sendable {
    public let minX: CGFloat
    public let minY: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public func contains(_ point: DisplayPoint) -> Bool {
        point.x >= minX && point.x < minX + width
            && point.y >= minY && point.y < minY + height
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let id: UInt32
    public let frame: DisplayFrame

    public init(id: UInt32, frame: DisplayFrame) {
        self.id = id
        self.frame = frame
    }
}

/// Pure display resolution. Frames and points use AppKit global coordinates
/// (origin at the bottom-left of the menu-bar display, y grows upward), as
/// `NSScreen.frame` and `NSEvent.mouseLocation` report them.
public enum ScreenSelection {
    /// The display that carries the menu bar: `CGMainDisplayID()` when that
    /// display is connected, else the display whose frame origin is (0,0),
    /// else the first display. Never `NSScreen.main`, which follows the key
    /// window rather than the menu bar.
    public static func primary(mainDisplayID: UInt32?, displays: [DisplaySnapshot]) -> UInt32? {
        if let mainDisplayID, displays.contains(where: { $0.id == mainDisplayID }) {
            return mainDisplayID
        }
        if let origin = displays.first(where: { $0.frame.minX == 0 && $0.frame.minY == 0 }) {
            return origin.id
        }
        return displays.first?.id
    }

    /// Every display that should host a pill panel: the primary alone, or
    /// every connected display in the order AppKit reports them.
    public static func selectDisplayIDs(
        mode: ScreenSelectionMode,
        mainDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> [UInt32] {
        guard !displays.isEmpty else { return [] }
        switch mode {
        case .allDisplays:
            return displays.map(\.id)
        case .primary:
            return primary(mainDisplayID: mainDisplayID, displays: displays).map { [$0] } ?? []
        }
    }

    /// The display under the pointer, where the peek card appears. The top
    /// pixel row of a display (y == maxY, where a pointer slammed against the
    /// screen edge lands) still counts as that display. A missing, non-finite
    /// or off-screen pointer resolves to the primary display.
    public static func pointerDisplay(
        pointer: DisplayPoint?,
        mainDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        if let pointer, pointer.x.isFinite, pointer.y.isFinite {
            if let hit = displays.first(where: { $0.frame.contains(pointer) }) {
                return hit.id
            }
            if let topEdge = displays.first(where: { display in
                let frame = display.frame
                return pointer.x >= frame.minX && pointer.x < frame.minX + frame.width
                    && pointer.y == frame.minY + frame.height
            }) {
                return topEdge.id
            }
        }
        return primary(mainDisplayID: mainDisplayID, displays: displays)
    }
}

// SyntheticMouse.swift: CGEvent pointer moves for step 4 (spec §12.3 step 3, §15 verify item 7).
// Posting needs Accessibility for the terminal that runs island-e2e; without it step 4 is skipped.
import ApplicationServices
import Foundation

enum SyntheticMouse {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Moves in small steps so the app's global mouse-moved monitor sees a path, not a jump.
    static func move(to target: CGPoint, steps: Int = 10) {
        let start = currentLocation()
        let count = max(1, steps)
        for index in 1...count {
            let fraction = CGFloat(index) / CGFloat(count)
            let point = CGPoint(x: start.x + (target.x - start.x) * fraction,
                                y: start.y + (target.y - start.y) * fraction)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
}

/// Probe points on the primary display, in CGEvent global coordinates (origin top-left, y down).
struct PillProbePoints: Equatable {
    /// Inside the collapsed pill on every presentation: the Samsung pill spans y 4...27, a notch bar y 0...~37.
    static let pillCenterDepth: CGFloat = 12
    /// At least 100 pt under the pill's bottom edge (≤ 38 pt) and still inside the 800 × 394 pt panel frame,
    /// i.e. in the dead zone that must stay click-through.
    static let belowPillDepth: CGFloat = 140
    /// Beyond half the 800 pt expanded panel width, so the pointer leaves the expanded board entirely.
    static let sideOffset: CGFloat = 520

    let pillCenter: CGPoint
    let outsidePanel: CGPoint
    let belowPill: CGPoint

    init(displayBounds bounds: CGRect) {
        pillCenter = CGPoint(x: bounds.midX, y: bounds.minY + Self.pillCenterDepth)
        belowPill = CGPoint(x: bounds.midX, y: bounds.minY + Self.belowPillDepth)
        outsidePanel = CGPoint(x: min(bounds.maxX - 5, bounds.midX + Self.sideOffset),
                               y: bounds.minY + Self.belowPillDepth)
    }
}

import Foundation

/// Geometry of the peek card inside its panel (spec §6, §7.3). The panel has the same width and
/// horizontal origin as the display's NotchLayout panel, with its top edge on the screen's top edge.
/// The card is a bubble centered in it, floating `gapBelowBar` below the menu-bar band (the pill or
/// the notch), so it never covers the pill and the pill never moves.
public enum PeekCardMetrics {
    public static let width: CGFloat = 480
    public static let gapBelowBar: CGFloat = 6
    public static let maximumHeight: CGFloat = 260

    /// Distance from the panel's top edge (the screen's top edge) to the card's top edge.
    public static func top(for layout: NotchLayout) -> CGFloat {
        layout.topGap + layout.height + gapBelowBar
    }

    public static func cardWidth(for layout: NotchLayout) -> CGFloat {
        min(width, layout.width)
    }

    public static func panelHeight(for layout: NotchLayout) -> CGFloat {
        top(for: layout) + maximumHeight
    }

    /// Panel frame in AppKit global coordinates: top edge on the screen's top edge.
    public static func panelFrame(for layout: NotchLayout) -> DisplayFrame {
        let height = panelHeight(for: layout)
        let screenTop = layout.originY + layout.height
        return DisplayFrame(minX: layout.originX, minY: screenTop - height, width: layout.width, height: height)
    }

    /// The card rect in panel-local top-leading coordinates. Before SwiftUI reports a measurement the
    /// whole maximum height is interactive, so the first click always lands.
    public static func cardFrame(for layout: NotchLayout, measuredHeight: CGFloat) -> DisplayFrame {
        let width = cardWidth(for: layout)
        let height = measuredHeight.isFinite && measuredHeight > 0
            ? min(measuredHeight, maximumHeight)
            : maximumHeight
        return DisplayFrame(minX: (layout.width - width) / 2, minY: top(for: layout), width: width, height: height)
    }

    /// The only part of the card panel that takes the mouse; everything else is click-through.
    public static func interactiveRegion(for layout: NotchLayout, measuredHeight: CGFloat) -> HangingNotchInteractionRegion {
        HangingNotchInteractionRegion(
            frame: cardFrame(for: layout, measuredHeight: measuredHeight),
            cornerStyle: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
    }
}

/// What the card panel model reads from the screens when it places the card: the connected
/// displays, each display's NotchLayout, the pointer, the menu-bar display and the pill mode.
/// PeekController reads them from NSScreen and NSEvent; tests pass fakes.
public struct PeekScreenFacts: Equatable, Sendable {
    public var displays: [DisplaySnapshot]
    public var layouts: [UInt32: NotchLayout]
    public var pointer: DisplayPoint?
    public var mainDisplayID: UInt32?
    public var mode: ScreenSelectionMode

    public init(
        displays: [DisplaySnapshot],
        layouts: [UInt32: NotchLayout],
        pointer: DisplayPoint?,
        mainDisplayID: UInt32?,
        mode: ScreenSelectionMode
    ) {
        self.displays = displays
        self.layouts = layouts
        self.pointer = pointer
        self.mainDisplayID = mainDisplayID
        self.mode = mode
    }
}

/// The peek card panel's state and decisions (spec §6, §7.3, §10; Review Focus 4). PeekController
/// owns one, conforms to CardPresenting through it, and applies its state to a NotchPanel after every
/// `onChange`: the panel frame, the interactive region, pointer routing and ordering. It decides
/// nothing itself, so everything here is testable without AppKit.
///
/// - A new event's card goes to the display under the pointer; an updated card stays where it is.
///   A card presented while no display exists stays hidden until a re-anchor gives it one.
/// - A screen-parameter change or wake waits the 0.35 s display settle (repeated notifications
///   restart it), then re-anchors: PanelAnchorPlanner plans with the pill state, and the coordinator
///   decides keep, move or dismiss (`onReanchor`, PeekCardPlacement).
/// - Only a visible card is interactive: the region is the card rect laid out for the card's display,
///   and pointer routing runs only while the card is visible. A hidden or dismissed card has an empty
///   region, no panel frame and no routing, so no panel is left behind on a display that is gone.
/// - While the pill's board is expanded the card is hidden (it would sit over the board's Waiting and
///   Error rows and take their clicks) and counts as hovered, so the queue holds it; collapsing the
///   board shows it again, and it expires normally from then on (final-review F3). A card that
///   arrives while the board is expanded is therefore not visible when presented, so it does not chime.
@MainActor
public final class PeekCardPanelModel: CardPresenting {
    public private(set) var card: PeekCard?
    public private(set) var cardDisplayID: UInt32?
    public private(set) var layout: NotchLayout?
    /// The card's measured height, kept across cards: the hosting view persists, and SwiftUI reports
    /// only changes.
    public private(set) var measuredCardHeight: CGFloat = 0
    /// True while the pill's board is expanded (PeekWiring reports it from NotchPanelController).
    public private(set) var isBoardExpanded = false
    /// The pointer monitor's raw fact: the pointer is inside the visible card's region. Cleared
    /// whenever the card is not visible.
    private var isPointerInside = false

    /// Set by PeekWiring to PeekCoordinator.cardClicked: returns the clicked row and dismisses.
    /// Until it is set a click does nothing; the coordinator owns every dismissal.
    public var onCardClick: (() -> RowID?)?
    /// Set by PeekWiring to PeekCoordinator.reanchorCard, which owns the keep/move/dismiss decision.
    /// Returns nil when the coordinator shows no card. Until it is set, re-anchoring does nothing.
    public var onReanchor: ((_ plan: PanelAnchorPlan, _ currentDisplayID: UInt32?, _ fallbackDisplayID: UInt32?) -> PeekCardPlacement?)?
    /// Set by PeekWiring from NotchPanelController, so PanelAnchorPlanner sees the pill state too.
    public var pillAnchorState: () -> (pillDisplayIDs: [UInt32], boardExpanded: Bool) = { ([], false) }
    /// Called after every change; PeekController applies the new state to its panel.
    public var onChange: (() -> Void)?

    private let screens: @MainActor () -> PeekScreenFacts
    private let settle: DisplaySettle

    /// `settle` defaults to a DisplaySettle on the main queue; tests pass one on a manual clock.
    public init(screens: @escaping @MainActor () -> PeekScreenFacts, settle: DisplaySettle? = nil) {
        self.screens = screens
        self.settle = settle ?? DisplaySettle()
    }

    /// A card is up, has a display to show on, and the expanded board does not cover it.
    public var isCardVisible: Bool { card != nil && cardDisplayID != nil && layout != nil && !isBoardExpanded }

    /// Hover holds the card open past its 8 s (PeekQueue.advance). The expanded board holds it too,
    /// so a card hidden under the board is not retired unseen.
    public var isCardHovered: Bool { card != nil && (isBoardExpanded || (isPointerInside && isCardVisible)) }

    /// The card panel is registered for pointer routing exactly while the card is visible.
    public var routesPointer: Bool { isCardVisible }

    /// The card rect for the card's display; empty whenever the card is not visible.
    public var interactiveRegion: HangingNotchInteractionRegion {
        guard isCardVisible, let layout else { return .empty }
        return PeekCardMetrics.interactiveRegion(for: layout, measuredHeight: measuredCardHeight)
    }

    /// Where the card panel sits (AppKit global coordinates); nil whenever the card is not visible.
    public var panelFrame: DisplayFrame? {
        guard isCardVisible, let layout else { return nil }
        return PeekCardMetrics.panelFrame(for: layout)
    }

    // MARK: CardPresenting

    public func present(_ card: PeekCard) {
        let isNewEvent = self.card?.event != card.event
        self.card = card
        if isNewEvent || cardDisplayID == nil || layout == nil {
            let facts = screens()
            place(on: ScreenSelection.pointerDisplay(
                pointer: facts.pointer,
                mainDisplayID: facts.mainDisplayID,
                displays: facts.displays
            ), facts: facts)
        }
        changed()
    }

    public func dismissCard() {
        card = nil
        cardDisplayID = nil
        layout = nil
        changed()
    }

    // MARK: Display changes

    /// A screen-parameter change or wake: re-anchor once the displays have settled.
    public func displaysChanged() {
        settle.request { [weak self] in
            self?.reanchor()
        }
    }

    /// Re-evaluates where a card belongs, immediately. PanelAnchorPlanner plans from the current
    /// screens; the coordinator decides through `onReanchor`.
    public func reanchor() {
        guard card != nil, let onReanchor else { return }
        let facts = screens()
        let pill = pillAnchorState()
        let current = cardDisplayID
        let plan = PanelAnchorPlanner.plan(
            mode: facts.mode,
            mainDisplayID: facts.mainDisplayID,
            pointer: facts.pointer,
            displays: facts.displays,
            current: PanelAnchorState(
                pillDisplayIDs: pill.pillDisplayIDs,
                cardDisplayID: current,
                boardExpanded: pill.boardExpanded
            )
        )
        let fallback = ScreenSelection.pointerDisplay(
            pointer: facts.pointer,
            mainDisplayID: facts.mainDisplayID,
            displays: facts.displays
        )
        switch onReanchor(plan, current, fallback) {
        case nil:
            // The coordinator shows no card, so the one still held here is stale.
            dismissCard()
        case .dismiss?:
            // The coordinator already retired it through dismissCard(), and may already have
            // presented the next card; there is nothing left to do here.
            break
        case .keep(displayID: let displayID)?, .move(toDisplayID: let displayID)?:
            // Re-read the layout even on keep: the display's geometry may have changed.
            place(on: displayID, facts: facts)
            changed()
        }
    }

    // MARK: Panel input

    /// From the pointer monitor: whether the pointer is inside the card's interactive region.
    public func pointerUpdated(isInside: Bool) {
        let inside = isInside && isCardVisible
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        onChange?()
    }

    /// From NotchPanelController (through PeekWiring): the board expanded or collapsed. Hides and
    /// holds the card while expanded; shows it again on collapse.
    public func boardExpansionChanged(_ expanded: Bool) {
        guard expanded != isBoardExpanded else { return }
        isBoardExpanded = expanded
        changed()
    }

    /// From the card view: its measured height.
    public func cardHeightMeasured(_ height: CGFloat) {
        guard height.isFinite, height != measuredCardHeight else { return }
        measuredCardHeight = height
        onChange?()
    }

    /// A click on the card: returns the row to jump to. The coordinator dismisses the card (and may
    /// promote the next one).
    public func clicked() -> RowID? {
        onCardClick?()
    }

    // MARK: Private

    private func place(on displayID: UInt32?, facts: PeekScreenFacts) {
        guard let displayID, let layout = facts.layouts[displayID] else {
            cardDisplayID = nil
            self.layout = nil
            return
        }
        cardDisplayID = displayID
        self.layout = layout
    }

    private func changed() {
        if !isCardVisible {
            isPointerInside = false
        }
        onChange?()
    }
}

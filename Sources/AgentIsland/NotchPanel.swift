import AppKit
import SwiftUI

import IslandCore

final class NotchPanel: NSPanel {
    /// The panel must never steal keyboard focus from the frontmost app —
    /// except while the user edits a session name inline, when the rename
    /// field needs key status to receive typing.
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts events inside the visible notch
/// silhouette. The panel itself always spans the expanded height — resizing
/// the window while SwiftUI animates the shape caused a visible glitch — so
/// the transparent strip below the visible surface must pass clicks through.
///
/// Two layers enforce that. `GlobalPointerMonitor` calls
/// `refreshPointerLocation()` on every mouse move, which sets the window's
/// `ignoresMouseEvents` from `ClickThroughPolicy` (the WindowServer then
/// routes clicks outside the surface straight to the window below) and
/// reports hover. `hitTest` still rejects points outside the region for the
/// moment between a move and the next refresh.
final class NotchHostingView<Content: View>: NSHostingView<Content>, PointerRoutingClient {
    /// The broad expanded panel reports its visible drop; the compact bar
    /// reports only its attached silhouette. An empty region passes through.
    var interactiveRegion = HangingNotchInteractionRegion.empty {
        didSet {
            guard interactiveRegion != oldValue else { return }
            scheduleContainmentRecheck()
        }
    }
    private var containmentRecheckIsScheduled = false
    /// Hover input: whether the pointer is inside the interactive region, and
    /// where it is in global coordinates. Driven by the pointer monitor; the
    /// tracking area below is a secondary source.
    var onPointerUpdate: ((Bool, DisplayPoint) -> Void)?
    /// Called with the new value whenever the window flips between
    /// click-through and interactive.
    var onMouseRoutingChange: ((Bool) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    /// The panel never becomes key, so every click arrives as a "first
    /// mouse" while another app is frontmost. Accepting it makes the first
    /// click act immediately instead of being swallowed as activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Unlike UIKit, AppKit supplies this point in the receiver's
        // superview coordinates. The interaction frame is hosting-local.
        let local = superview.map { convert(point, from: $0) } ?? point
        let localX = local.x - bounds.minX
        let distanceFromTop = isFlipped
            ? local.y - bounds.minY
            : bounds.maxY - local.y
        guard interactiveRegion.contains(
            DisplayPoint(x: localX, y: distanceFromTop)
        ) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshPointerLocation()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshPointerLocation()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshPointerLocation()
    }

    /// Re-tests containment once the current SwiftUI update has finished.
    ///
    /// The region arrives from that update: `onPreferenceChange` on a
    /// `GeometryReader` measuring the card, so it lands once per frame for as
    /// long as the open or close spring runs. Answering inline would publish
    /// pointer state from inside the very pass that is reading it, which
    /// SwiftUI does not allow. Hopping to the next turn of the run loop also
    /// coalesces the burst: the frames along the way are interpolation, and
    /// only the geometry the pointer actually ends up over decides anything.
    private func scheduleContainmentRecheck() {
        guard !containmentRecheckIsScheduled else { return }
        containmentRecheckIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            containmentRecheckIsScheduled = false
            refreshPointerLocation()
        }
    }

    /// The single routing entry point: the pointer monitor, the tracking
    /// area, region changes and layout changes all land here.
    func refreshPointerLocation() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let pointer = DisplayPoint(x: mouse.x, y: mouse.y)
        let frame = window.frame
        let route = ClickThroughPolicy.route(
            pointer: pointer,
            panelFrame: DisplayFrame(
                minX: frame.minX,
                minY: frame.minY,
                width: frame.width,
                height: frame.height
            ),
            region: interactiveRegion
        )
        if window.ignoresMouseEvents != route.ignoresMouseEvents {
            window.ignoresMouseEvents = route.ignoresMouseEvents
            onMouseRoutingChange?(route.ignoresMouseEvents)
        }
        onPointerUpdate?(route.isInside, pointer)
    }
}

/// One independent SwiftUI/AppKit surface for a display. Each surface owns
/// hover, expanded-menu, and keyboard-focus state, which lets all-displays
/// mode show the pill on every connected screen at once.
@MainActor
private final class NotchDisplayPanel {
    private let store: StateStore
    private let panel: NotchPanel
    private var layout: NotchLayout
    private var hostingView: NotchHostingView<NotchWidgetView>?
    private var pointerGate = PointerMovementGate()
    private let pointerTracker = NotchPointerTracker()
    private var hoverExpansionIntentSent = false
    private let onStateChange: () -> Void

    private(set) var menuIsVisible = false
    var ignoresMouseEvents: Bool { panel.ignoresMouseEvents }

    init(
        store: StateStore,
        layout: NotchLayout,
        onStateChange: @escaping () -> Void
    ) {
        self.store = store
        self.layout = layout
        self.onStateChange = onStateChange
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: layout.expandedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // The notch surface is always dark glass, so appearance-derived
        // colors (placeholder text, text selection) must resolve for dark
        // even when the system is in light mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Start click-through: until the first pointer refresh proves the
        // pointer is over the pill, nothing below the panel may be blocked.
        panel.ignoresMouseEvents = true
        applyLayout()
    }

    func show() {
        panel.orderFrontRegardless()
        if let hostingView {
            GlobalPointerMonitor.shared.register(hostingView)
            hostingView.refreshPointerLocation()
        }
    }

    /// Hides the panel and stops routing the pointer to it. Called before the
    /// controller drops a panel whose display is gone or no longer selected.
    func tearDown() {
        if let hostingView {
            GlobalPointerMonitor.shared.unregister(hostingView)
        }
        panel.orderOut(nil)
    }

    func update(layout: NotchLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        applyLayout()
    }

    func lockHoverExpansion(at point: DisplayPoint) {
        pointerGate.lock(at: point)
        hoverExpansionIntentSent = false
    }

    /// Closes an expanded board. The view owns `isExpanded`, so the request
    /// travels through the pointer tracker it already observes.
    func collapseBoard() {
        pointerTracker.requestCollapse()
    }

    private func applyLayout() {
        if let hostingView {
            hostingView.rootView = makeRootView()
        } else {
            let hostingView = NotchHostingView(rootView: makeRootView())
            hostingView.onPointerUpdate = { [weak self] isInside, location in
                self?.handlePointerUpdate(isInside: isInside, location: location)
            }
            hostingView.onMouseRoutingChange = { [weak self] _ in
                self?.onStateChange()
            }
            self.hostingView = hostingView
            panel.contentView = hostingView
        }
        panel.setFrame(
            NSRect(
                x: layout.originX,
                y: layout.originY + layout.height - layout.expandedHeight,
                width: layout.width,
                height: layout.expandedHeight
            ),
            display: true
        )
        // The frame moved under a possibly still pointer: re-route now
        // rather than waiting for the next mouse move.
        hostingView?.refreshPointerLocation()
    }

    private func handlePointerUpdate(isInside: Bool, location: DisplayPoint) {
        let location = pointerTracker.update(isInside: isInside, location: location)
        guard isInside else {
            hoverExpansionIntentSent = false
            return
        }
        guard !hoverExpansionIntentSent,
              pointerGate.update(pointerLocation: location) else { return }
        hoverExpansionIntentSent = true
        pointerTracker.requestHoverExpansion(at: location)
    }

    private func makeRootView() -> NotchWidgetView {
        NotchWidgetView(
            store: store,
            layout: layout,
            pointerTracker: pointerTracker,
            requestPointerRefresh: { [weak self] in
                self?.hostingView?.refreshPointerLocation()
            },
            onInteractiveRegionChange: { [weak self] region in
                self?.hostingView?.interactiveRegion = region
            },
            onKeyboardFocusChange: { [weak self] wantsKeyboard in
                self?.setKeyboardFocus(wantsKeyboard)
            },
            onMenuVisibilityChange: { [weak self] isVisible in
                guard let self, menuIsVisible != isVisible else { return }
                menuIsVisible = isVisible
                onStateChange()
            }
        )
    }

    private func setKeyboardFocus(_ wantsKeyboard: Bool) {
        panel.allowsKeyboardFocus = wantsKeyboard
        if wantsKeyboard {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }
}

/// Owns the pill panels: one on the primary display, or one per display in
/// all-displays mode. Placement is decided by `PanelAnchorPlanner`; this class
/// only gathers AppKit facts and executes the plan.
@MainActor
final class NotchPanelController {
    private let store: StateStore
    private var displayPanels: [UInt32: NotchDisplayPanel] = [:]
    private var selectionMode: ScreenSelectionMode
    private var panelsAreVisible = false
    private let settle = DisplaySettle()
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    /// Displays hosting a pill panel, in plan order.
    private(set) var pillDisplayIDs: [UInt32] = []
    /// Called after any change to pill placement, board expansion, or
    /// click-through state (UIStateReporter is fed by notifyUIStateChange;
    /// PeekWiring uses this hook to hide and hold the card while the board
    /// is expanded).
    var onStateChange: (() -> Void)?

    var isBoardExpanded: Bool {
        displayPanels.values.contains(where: \.menuIsVisible)
    }

    /// True while every pill panel is click-through (also true with no panels).
    var pillIgnoresMouseEvents: Bool {
        displayPanels.values.allSatisfy(\.ignoresMouseEvents)
    }

    init(store: StateStore) {
        self.store = store
        selectionMode = Self.configuredSelectionMode
        applyAnchorPlan()
        GlobalPointerMonitor.shared.start()
        // Docking, resolution switches and lid changes invalidate every notch
        // metric. The WindowServer reports them in bursts, so wait for the
        // settle delay and re-anchor once on the final geometry.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reanchor()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reanchor()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDefaultsChange()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func show() {
        panelsAreVisible = true
        displayPanels.values.forEach { $0.show() }
        notifyStateChange()
    }

    /// Waits `delay` (the 0.35 s display settle by default), then re-plans
    /// every panel from the current screens. Repeated calls restart the wait,
    /// so a burst of screen notifications, or a wake that also changes the
    /// screens, re-anchors once. `DisplaySettle` (IslandCore) owns the
    /// restart, which the display tests drive with a manual clock.
    func reanchor(after delay: TimeInterval = IslandTiming.displaySettle) {
        settle.request(after: delay) { [weak self] in
            self?.applyAnchorPlan()
        }
    }

    private func applyAnchorPlan() {
        var screensByID: [UInt32: NSScreen] = [:]
        var displays: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            screensByID[displayID] = screen
            displays.append(DisplaySnapshot(
                id: displayID,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            ))
        }
        let mouse = NSEvent.mouseLocation
        let pointer = DisplayPoint(x: mouse.x, y: mouse.y)
        let plan = PanelAnchorPlanner.plan(
            mode: selectionMode,
            mainDisplayID: CGMainDisplayID(),
            pointer: pointer,
            displays: displays,
            current: PanelAnchorState(
                pillDisplayIDs: pillDisplayIDs,
                cardDisplayID: nil,
                boardExpanded: isBoardExpanded
            )
        )

        // PanelAnchorExecutor (IslandCore) owns the order — collapse, tear
        // down, re-lay out or create, sweep — and the no-orphan guarantee;
        // this supplies the AppKit side.
        let isReanchor = !pillDisplayIDs.isEmpty
        displayPanels = PanelAnchorExecutor.apply(
            plan,
            to: displayPanels,
            collapseBoard: { $0.collapseBoard() },
            tearDown: { $0.tearDown() },
            relayout: { displayID, displayPanel in
                guard let screen = screensByID[displayID] else { return }
                displayPanel.update(layout: Self.layout(for: screen))
            },
            make: { displayID in
                guard let screen = screensByID[displayID] else { return nil }
                let displayPanel = NotchDisplayPanel(
                    store: store,
                    layout: Self.layout(for: screen),
                    onStateChange: { [weak self] in
                        self?.notifyStateChange()
                    }
                )
                if panelsAreVisible {
                    displayPanel.show()
                }
                // A pill that appears under a still pointer must not pop the
                // board open; only a deliberate move may.
                if isReanchor {
                    displayPanel.lockHoverExpansion(at: pointer)
                }
                return displayPanel
            }
        )
        pillDisplayIDs = plan.pillDisplayIDs
        notifyStateChange()
    }

    private func handleDefaultsChange() {
        let mode = Self.configuredSelectionMode
        guard mode != selectionMode else { return }
        selectionMode = mode
        applyAnchorPlan()
    }

    private func notifyStateChange() {
        notifyUIStateChange()
    }

    private static func layout(for screen: NSScreen?) -> NotchLayout {
        // frame minus visible frame isolates the menu bar strip: the Dock
        // can eat into the sides or bottom of a screen, never into the top
        // edge, so the difference is the real menu bar height.
        let menuBarHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX,
            menuBarHeight: menuBarHeight,
            visibleFrameHeight: screen?.visibleFrame.height
        )
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }

    private static var configuredSelectionMode: ScreenSelectionMode {
        ScreenSelectionMode(
            storedValue: UserDefaults.standard.string(forKey: PreferenceKeys.screenSelectionMode)
        )
    }
}

// MARK: - UI state reporting (Task 16)

extension NotchPanelController {
    /// Every pill/board state change goes through here: record it for the state dump,
    /// then run the external hook.
    func notifyUIStateChange() {
        reportUIState()
        onStateChange?()
    }

    func reportUIState() {
        let boardExpanded = isBoardExpanded
        let ignoresMouseEvents = pillIgnoresMouseEvents
        let displayIDs = pillDisplayIDs
        let primaryDisplayID = UInt32(CGMainDisplayID())
        UIStateReporter.shared.update { snapshot in
            snapshot.boardExpanded = boardExpanded
            snapshot.pillIgnoresMouseEvents = ignoresMouseEvents
            snapshot.pillDisplayIDs = displayIDs
            snapshot.primaryDisplayID = primaryDisplayID
        }
    }
}

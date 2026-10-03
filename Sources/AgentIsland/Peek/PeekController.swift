import AppKit
import SwiftUI

import IslandCore

/// The peek card surface (spec §6, §7.3): a second NotchPanel, separate from the pill panels, placed
/// on the display under the pointer when a new card appears.
///
/// Every decision lives in PeekCardPanelModel (IslandCore): where the card goes, when it re-anchors,
/// what is interactive, and whether it is visible. This class reads the AppKit facts the model asks
/// for (NSScreen, NSEvent) and applies the model's state to the panel after every change:
/// - Frame: the display's NotchLayout panel width and origin, top edge on the screen's top edge.
/// - Click-through: the hosting view is a NotchHostingView whose interactive region is only the card
///   rect. While the card is visible the view is registered with GlobalPointerMonitor, whose
///   always-on mouse-move monitor calls `refreshPointerLocation()`; that applies ClickThroughPolicy,
///   so everything outside the card passes clicks to the app below, and reports inside/outside,
///   which is hover (it holds the card open past 8 s).
/// - Hidden or dismissed: region `.empty`, unregistered, `ignoresMouseEvents`, ordered out.
/// - Click: the model asks PeekCoordinator for the row (which dismisses the card), then this runs
///   `store.focus` in a Task, the same path a board row click uses (it also marks the row seen).
/// - Re-anchor: screen-parameter changes and wake go to the model, which waits the 0.35 s settle.
@MainActor
final class PeekController: CardPresenting {
    private let store: StateStore
    private let model: PeekCardPanelModel
    private let jumpRecovery = PeekJumpRecovery()
    private let panel: NotchPanel
    private var hostingView: NotchHostingView<PeekCardView>?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // What was last applied to AppKit, so each sync touches only what moved.
    private var appliedFrame: DisplayFrame?
    private var appliedCard: PeekCard?
    private var appliedLayout: NotchLayout?
    private var isOrderedIn = false
    private var isRoutingPointer = false
    private var isSyncing = false
    private var needsSync = false

    var cardDisplayID: UInt32? { model.cardDisplayID }
    var isCardVisible: Bool { model.isCardVisible }
    var isCardHovered: Bool { model.isCardHovered }
    /// T16 hooks the UI snapshot here (card visibility and display).
    var onStateChange: (() -> Void)?
    /// Set by PeekWiring to PeekCoordinator.cardClicked: returns the clicked row and dismisses.
    var onCardClick: (() -> RowID?)? {
        get { model.onCardClick }
        set { model.onCardClick = newValue }
    }

    /// Set by PeekWiring from NotchPanelController, so PanelAnchorPlanner sees the pill state too.
    var pillAnchorState: () -> (pillDisplayIDs: [UInt32], boardExpanded: Bool) {
        get { model.pillAnchorState }
        set { model.pillAnchorState = newValue }
    }

    /// Set by PeekWiring to PeekCoordinator.reanchorCard, which owns the keep/move/dismiss decision.
    /// Returns nil when the coordinator shows no card.
    var onReanchor: ((_ plan: PanelAnchorPlan, _ currentDisplayID: UInt32?, _ fallbackDisplayID: UInt32?) -> PeekCardPlacement?)? {
        get { model.onReanchor }
        set { model.onReanchor = newValue }
    }

    init(store: StateStore) {
        self.store = store
        model = PeekCardPanelModel(screens: { PeekController.screenFacts() })
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: NotchLayout.expandedPanelWidth, height: PeekCardMetrics.maximumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true

        model.onChange = { [weak self] in
            self?.sync()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.displaysChanged()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.displaysChanged()
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
    }

    // MARK: CardPresenting

    func present(_ card: PeekCard) {
        model.present(card)
    }

    func dismissCard() {
        model.dismissCard()
    }

    /// Re-evaluates where a visible card belongs, immediately. The screen-change and wake observers
    /// reach it after the 0.35 s settle; the decision is PeekCardPlacement, applied by
    /// PeekCoordinator.reanchorCard through `onReanchor`.
    func reanchor() {
        model.reanchor()
    }

    /// The pill's board expanded or collapsed (PeekWiring forwards NotchPanelController's state).
    /// The model hides and holds the card while the board is expanded, so the card never covers the
    /// board's rows or takes their clicks; `sync` orders the panel out and back in.
    func boardExpansionChanged(_ expanded: Bool) {
        model.boardExpansionChanged(expanded)
    }

    // MARK: Applying the model

    /// Applies the model's state to the panel. A change raised while applying (a pointer refresh
    /// that changes hover, a height measurement) runs again after the current pass, never inside it.
    private func sync() {
        if isSyncing {
            needsSync = true
            return
        }
        isSyncing = true
        repeat {
            needsSync = false
            applyModelState()
        } while needsSync
        isSyncing = false
        notifyUIStateChange()
    }

    private func applyModelState() {
        guard model.isCardVisible, let card = model.card, let layout = model.layout, let frame = model.panelFrame else {
            hidePanel()
            return
        }
        var needsPointerRefresh = false
        if frame != appliedFrame {
            panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), display: true)
            appliedFrame = frame
            needsPointerRefresh = true
        }
        if card != appliedCard || layout != appliedLayout || hostingView == nil {
            let view = PeekCardView(
                card: card,
                title: store.displayName(for: card.row),
                layout: layout,
                onClick: { [weak self] in self?.handleClick() },
                onHeightChange: { [weak self] height in self?.model.cardHeightMeasured(height) }
            )
            if let hostingView {
                hostingView.rootView = view
            } else {
                let hostingView = NotchHostingView(rootView: view)
                hostingView.onPointerUpdate = { [weak self] isInside, _ in
                    self?.model.pointerUpdated(isInside: isInside)
                }
                self.hostingView = hostingView
                panel.contentView = hostingView
            }
            appliedCard = card
            appliedLayout = layout
        }
        hostingView?.interactiveRegion = model.interactiveRegion
        if !isOrderedIn {
            panel.orderFrontRegardless()
            isOrderedIn = true
            needsPointerRefresh = true
        }
        if !isRoutingPointer, let hostingView {
            GlobalPointerMonitor.shared.register(hostingView)
            isRoutingPointer = true
            needsPointerRefresh = true
        }
        if needsPointerRefresh {
            // The panel appeared or moved under a possibly still pointer: route it now rather than
            // waiting for the next mouse move.
            hostingView?.refreshPointerLocation()
        }
    }

    private func hidePanel() {
        hostingView?.interactiveRegion = .empty
        if isRoutingPointer, let hostingView {
            GlobalPointerMonitor.shared.unregister(hostingView)
            isRoutingPointer = false
        }
        panel.ignoresMouseEvents = true
        if isOrderedIn {
            panel.orderOut(nil)
            isOrderedIn = false
        }
    }

    private func handleClick() {
        var capturedRow: AgentRow?
        jumpRecovery.perform(clickedRow: {
            guard let id = model.clicked() else { return nil }
            capturedRow = store.row(id)
            return id
        }, focus: { [store] _ in
            guard let capturedRow else { throw JumpError.rowNotFound }
            try await store.focus(capturedRow)
        }, requestRetry: { _, error in
            NSLog("Agent Island could not jump from the peek card: %@", String(describing: error))
            let alert = NSAlert()
            alert.messageText = "Could not open this agent"
            let rowIsGone = (error as? JumpError) == .rowNotFound
            alert.informativeText = rowIsGone
                ? "This agent is no longer on the board."
                : "Check that the agent's app or terminal is available, then try again."
            if !rowIsGone { alert.addButton(withTitle: "Try Again") }
            alert.addButton(withTitle: "Close")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn && !rowIsGone
        })
    }

    // MARK: Screens

    /// The same derivation as NotchPanelController's private helpers (NotchPanel.swift belongs to
    /// Task 11, so they are repeated here), including Task 12's visible-frame height.
    private static func screenFacts() -> PeekScreenFacts {
        var displays: [DisplaySnapshot] = []
        var layouts: [UInt32: NotchLayout] = [:]
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            displays.append(DisplaySnapshot(
                id: displayID,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            ))
            layouts[displayID] = layout(for: screen)
        }
        let mouse = NSEvent.mouseLocation
        return PeekScreenFacts(
            displays: displays,
            layouts: layouts,
            pointer: DisplayPoint(x: mouse.x, y: mouse.y),
            mainDisplayID: CGMainDisplayID(),
            mode: ScreenSelectionMode(storedValue: UserDefaults.standard.string(forKey: PreferenceKeys.screenSelectionMode))
        )
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { $0.uint32Value }
    }

    /// Frame minus visible frame is the menu bar: the Dock never eats into the top edge.
    private static func layout(for screen: NSScreen) -> NotchLayout {
        NotchLayout(
            screenMinX: screen.frame.minX,
            screenWidth: screen.frame.width,
            screenMaxY: screen.frame.maxY,
            safeAreaTop: screen.safeAreaInsets.top,
            leftNotchEdgeX: screen.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen.auxiliaryTopRightArea?.minX,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            visibleFrameHeight: screen.visibleFrame.height
        )
    }
}

// MARK: - UI state reporting (Task 16)

extension PeekController {
    /// Every card state change goes through here: record it for the state dump, then
    /// run the external hook.
    func notifyUIStateChange() {
        reportUIState()
        onStateChange?()
    }

    func reportUIState() {
        let visible = isCardVisible
        let displayID = cardDisplayID
        UIStateReporter.shared.update { snapshot in
            snapshot.cardVisible = visible
            snapshot.cardDisplayID = displayID
        }
    }
}

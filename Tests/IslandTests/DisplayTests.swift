// Tests/IslandTests/DisplayTests.swift — Task 11 (`display:`)
import Foundation
import IslandCore

// Nathan's desk: the Samsung ultrawide is the main display at the origin and
// the built-in panel sits to its left (x < 0). AppKit global coordinates.
private let displayTestBuiltIn = DisplaySnapshot(
    id: 1,
    frame: DisplayFrame(minX: -1_512, minY: 0, width: 1_512, height: 982)
)
private let displayTestSamsung = DisplaySnapshot(
    id: 2,
    frame: DisplayFrame(minX: 0, minY: 0, width: 2_560, height: 1_440)
)
private let displayTestThird = DisplaySnapshot(
    id: 3,
    frame: DisplayFrame(minX: 2_560, minY: 0, width: 1_920, height: 1_080)
)
private let displayTestDesk = [displayTestBuiltIn, displayTestSamsung]
private let displayTestPointerOnBuiltIn = DisplayPoint(x: -700, y: 500)
private let displayTestPointerOnSamsung = DisplayPoint(x: 1_280, y: 700)
private let displayTestPointerOffScreen = DisplayPoint(x: -9_000, y: -9_000)

/// The Samsung measured by the launch-free layout probe: no notch, 31 pt menu bar.
private func displayTestSamsungLayout() -> NotchLayout {
    NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31
    )
}

// MARK: ScreenSelection

func testDisplayPrimaryIsTheMainDisplayWhereverThePointerIs() throws {
    try expect(
        ScreenSelection.primary(mainDisplayID: 2, displays: displayTestDesk),
        equals: 2,
        "the CG main display is the primary"
    )
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .primary, mainDisplayID: 2, displays: displayTestDesk),
        equals: [2],
        "primary mode hosts one pill, on the main display"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: displayTestPointerOnBuiltIn, mainDisplayID: 2, displays: displayTestDesk),
        equals: 1,
        "the card would follow the pointer to the built-in..."
    )
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .primary, mainDisplayID: 2, displays: displayTestDesk),
        equals: [2],
        "...while the pill stays on the primary"
    )
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .primary, mainDisplayID: 1, displays: displayTestDesk),
        equals: [1],
        "with the built-in as main display the pill hugs its notch"
    )
}

func testDisplayPrimaryFallsBackToTheOriginDisplay() throws {
    try expect(
        ScreenSelection.primary(mainDisplayID: 99, displays: displayTestDesk),
        equals: 2,
        "a main display ID that is not connected falls back to the display at (0,0)"
    )
    try expect(
        ScreenSelection.primary(mainDisplayID: nil, displays: displayTestDesk),
        equals: 2,
        "no main display ID also falls back to the display at (0,0)"
    )
    let noOrigin = [
        DisplaySnapshot(id: 7, frame: DisplayFrame(minX: 100, minY: 0, width: 800, height: 600)),
        DisplaySnapshot(id: 8, frame: DisplayFrame(minX: 900, minY: 0, width: 800, height: 600)),
    ]
    try expect(
        ScreenSelection.primary(mainDisplayID: nil, displays: noOrigin),
        equals: 7,
        "without a display at the origin the first display wins"
    )
    try expect(ScreenSelection.primary(mainDisplayID: 2, displays: []), equals: nil, "no displays, no primary")
}

func testDisplayPointerDisplayResolvesTheDisplayUnderThePointer() throws {
    try expect(
        ScreenSelection.pointerDisplay(pointer: displayTestPointerOnBuiltIn, mainDisplayID: 2, displays: displayTestDesk),
        equals: 1,
        "pointer on the built-in"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: displayTestPointerOnSamsung, mainDisplayID: 2, displays: displayTestDesk),
        equals: 2,
        "pointer on the Samsung"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: DisplayPoint(x: -700, y: 982), mainDisplayID: 2, displays: displayTestDesk),
        equals: 1,
        "the top pixel row of the built-in still belongs to the built-in"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: displayTestPointerOffScreen, mainDisplayID: 2, displays: displayTestDesk),
        equals: 2,
        "an off-screen pointer resolves to the primary"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: nil, mainDisplayID: 2, displays: displayTestDesk),
        equals: 2,
        "no pointer resolves to the primary"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: DisplayPoint(x: .nan, y: 10), mainDisplayID: 2, displays: displayTestDesk),
        equals: 2,
        "a non-finite pointer resolves to the primary"
    )
    try expect(
        ScreenSelection.pointerDisplay(pointer: displayTestPointerOnSamsung, mainDisplayID: 2, displays: []),
        equals: nil,
        "no displays, no card display"
    )
}

func testDisplayStoredModeMigratesLegacyValues() throws {
    try expect(ScreenSelectionMode(storedValue: "pointer"), equals: .primary, "legacy pointer mode")
    try expect(ScreenSelectionMode(storedValue: "focusedWindow"), equals: .primary, "legacy focused-window mode")
    try expect(ScreenSelectionMode(storedValue: nil), equals: .primary, "missing preference")
    try expect(ScreenSelectionMode(storedValue: ""), equals: .primary, "empty preference")
    try expect(ScreenSelectionMode(storedValue: "primary"), equals: .primary, "primary")
    try expect(ScreenSelectionMode(storedValue: "allDisplays"), equals: .allDisplays, "all displays")
    try expect(ScreenSelectionMode.allCases, equals: [.primary, .allDisplays], "only two modes remain")
    try expect(ScreenSelectionMode.primary.rawValue, equals: "primary", "stored spelling of primary")
}

func testDisplayAllDisplaysReturnsEveryID() throws {
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .allDisplays, mainDisplayID: 2, displays: displayTestDesk),
        equals: [1, 2],
        "every connected display, in AppKit order"
    )
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .allDisplays, mainDisplayID: 2, displays: []),
        equals: [],
        "no displays"
    )
    try expect(
        ScreenSelection.selectDisplayIDs(mode: .primary, mainDisplayID: 2, displays: []),
        equals: [],
        "no displays in primary mode"
    )
}

// MARK: Geometry

func testDisplaySamsungGeometryIsAPillInsideTheMenuBar() throws {
    let layout = displayTestSamsungLayout()
    try expect(layout.presentation, equals: .pill, "no notch means pill presentation")
    try expect(layout.cornerStyle, equals: .bubble, "the pill rounds every corner")
    try expect(layout.height, equals: 23, "31 pt menu bar - 4 pt gap - 4 pt bottom inset")
    try expect(layout.topGap, equals: 4, "the pill floats 4 pt below the screen edge")
    try expect(layout.topGap + layout.height + NotchLayout.pillBottomInset, equals: 31, "the pill stays inside the menu bar")
    try expect(layout.width, equals: 800, "the panel is the expanded width")
    try expect(layout.originX, equals: 880, "centered on x = 1280, left of the first status item at 1837")
    try expect(layout.originY, equals: 1_417, "the bar's bottom edge sits 23 pt below the top")
    try expect(layout.expandedHeight, equals: 394, "the fixed panel spans 800 x 394 pt")
}

func testDisplayNotchGeometryIsUnchanged() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 663.5,
        rightNotchEdgeX: 848.5,
        menuBarHeight: 38
    )
    try expect(layout.presentation, equals: .notch, "camera housing means notch presentation")
    try expect(layout.cornerStyle, equals: .hangingNotch, "the notch keeps its concave shoulders")
    try expect(layout.notchWidth, equals: 185, "the measured 185 pt notch")
    try expect(layout.height, equals: 38, "the bar is the safe-area height")
    try expect(layout.topGap, equals: 0, "the notch stays fused to the screen edge")
    try expect(layout.width, equals: 800, "expanded width")
    try expect(layout.originX, equals: 356, "the panel centers on the camera housing")
    try expect(layout.originY, equals: 944, "the bar hangs from the top edge")
    try expect(layout.expandedHeight, equals: 387, "38 + 341 + 8, as upstream")
}

let displaySelectionTests: [TestCase] = [
    ("display: primary is the main display wherever the pointer is", testDisplayPrimaryIsTheMainDisplayWhereverThePointerIs),
    ("display: primary falls back to the origin display", testDisplayPrimaryFallsBackToTheOriginDisplay),
    ("display: pointer display resolves the display under the pointer", testDisplayPointerDisplayResolvesTheDisplayUnderThePointer),
    ("display: stored mode migrates legacy values to primary", testDisplayStoredModeMigratesLegacyValues),
    ("display: all displays returns every display ID", testDisplayAllDisplaysReturnsEveryID),
    ("display: Samsung geometry is a 23 pt pill inside the 31 pt menu bar", testDisplaySamsungGeometryIsAPillInsideTheMenuBar),
    ("display: 185 pt notch geometry is unchanged from upstream", testDisplayNotchGeometryIsUnchanged),
]

/// The panel's AppKit frame, computed exactly as NotchDisplayPanel.applyLayout sets it.
private func displayTestPanelFrame(_ layout: NotchLayout) -> DisplayFrame {
    DisplayFrame(
        minX: layout.originX,
        minY: layout.originY + layout.height - layout.expandedHeight,
        width: layout.width,
        height: layout.expandedHeight
    )
}

/// Converts a panel-local top-leading point to AppKit global coordinates.
private func displayTestGlobal(_ localX: CGFloat, _ localY: CGFloat, in panel: DisplayFrame) -> DisplayPoint {
    DisplayPoint(x: panel.minX + localX, y: panel.minY + panel.height - localY)
}

private func displayTestRegion(_ frame: DisplayFrame, _ style: HangingNotchCornerStyle) -> HangingNotchInteractionRegion {
    HangingNotchInteractionRegion(
        frame: frame,
        cornerStyle: style,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )
}

private func expectRoute(
    _ route: PointerRoute,
    inside: Bool,
    _ message: String
) throws {
    try expect(route.isInside, equals: inside, "\(message) (isInside)")
    try expect(route.ignoresMouseEvents, equals: !inside, "\(message) (ignoresMouseEvents)")
}

// MARK: ClickThroughPolicy

func testDisplayClickThroughAtTheCollapsedPillEdges() throws {
    let layout = displayTestSamsungLayout()
    let panel = displayTestPanelFrame(layout)
    try expect(panel, equals: DisplayFrame(minX: 880, minY: 1_046, width: 800, height: 394), "panel frame")
    let barLeadingOffset = layout.barLeadingOffset(leftWidth: 100, rightWidth: 100)
    try expect(barLeadingOffset, equals: 300, "a 200 pt pill is centered in the 800 pt panel")
    let compact = DisplayFrame(minX: barLeadingOffset, minY: layout.topGap, width: 200, height: layout.height)
    let frame = HoverInteraction.interactiveFrame(
        compactFrame: compact,
        expandedPanelWidth: layout.width,
        expandedMaximumHeight: layout.expandedHeight,
        measuredContentHeight: 0,
        isExpanded: false,
        isHidden: false,
        expandedTopInset: layout.expandedTopGap
    )
    try expect(frame, equals: compact, "collapsed, the region is exactly the pill")
    let region = displayTestRegion(frame, layout.cornerStyle)
    let midY: CGFloat = 4 + 23 / 2
    func route(_ x: CGFloat, _ y: CGFloat) -> PointerRoute {
        ClickThroughPolicy.route(pointer: displayTestGlobal(x, y, in: panel), panelFrame: panel, region: region)
    }

    try expectRoute(route(400, 5), inside: true, "1 pt inside the top edge")
    try expectRoute(route(400, 26), inside: true, "1 pt inside the bottom edge")
    try expectRoute(route(301, midY), inside: true, "1 pt inside the left end")
    try expectRoute(route(499, midY), inside: true, "1 pt inside the right end")

    try expectRoute(route(400, 3), inside: false, "1 pt above the pill")
    try expectRoute(route(400, 28), inside: false, "1 pt below the pill")
    try expectRoute(route(299, midY), inside: false, "1 pt left of the pill")
    try expectRoute(route(501, midY), inside: false, "1 pt right of the pill")
    try expectRoute(route(301, 5), inside: false, "the transparent rounded corner passes through")

    try expectRoute(route(400, 200), inside: false, "the dead zone below the pill passes through")
    try expectRoute(route(40, 390), inside: false, "the bottom of the 363 pt dead zone passes through")
    try expectRoute(
        ClickThroughPolicy.route(pointer: DisplayPoint(x: 100, y: 1_430), panelFrame: panel, region: region),
        inside: false,
        "a point beside the panel is never inside"
    )
}

func testDisplayClickThroughForTheExpandedBoard() throws {
    let layout = displayTestSamsungLayout()
    let panel = displayTestPanelFrame(layout)
    let compact = DisplayFrame(minX: 300, minY: layout.topGap, width: 200, height: layout.height)
    let frame = HoverInteraction.interactiveFrame(
        compactFrame: compact,
        expandedPanelWidth: layout.width,
        expandedMaximumHeight: layout.expandedHeight,
        measuredContentHeight: 240,
        isExpanded: true,
        isHidden: false,
        expandedTopInset: layout.expandedTopGap
    )
    try expect(frame, equals: DisplayFrame(minX: 0, minY: 8, width: 800, height: 240), "expanded board frame")
    let region = displayTestRegion(frame, layout.cornerStyle)
    func route(_ x: CGFloat, _ y: CGFloat) -> PointerRoute {
        ClickThroughPolicy.route(pointer: displayTestGlobal(x, y, in: panel), panelFrame: panel, region: region)
    }

    try expectRoute(route(1, 128), inside: true, "1 pt inside the board's left side")
    try expectRoute(route(799, 128), inside: true, "1 pt inside the board's right side")
    try expectRoute(route(400, 9), inside: true, "1 pt inside the board's top")
    try expectRoute(route(400, 247), inside: true, "1 pt inside the board's bottom")

    try expectRoute(route(400, 7), inside: false, "the 8 pt gap above the open bubble")
    try expectRoute(route(400, 249), inside: false, "1 pt below the board")
    try expectRoute(route(1, 9), inside: false, "the board's transparent corner")
    try expectRoute(route(400, 330), inside: false, "the dead zone below the board")
}

func testDisplayClickThroughForTheCardFrame() throws {
    // A peek card on the built-in display, hanging from its notch: panel-local
    // card rect 800 x 160 inside an 800 x 387 panel whose top is the screen top.
    let panel = DisplayFrame(minX: -1_156, minY: 595, width: 800, height: 387)
    let region = displayTestRegion(DisplayFrame(minX: 0, minY: 0, width: 800, height: 160), .hangingNotch)
    func route(_ x: CGFloat, _ y: CGFloat) -> PointerRoute {
        ClickThroughPolicy.route(pointer: displayTestGlobal(x, y, in: panel), panelFrame: panel, region: region)
    }

    try expectRoute(route(400, 80), inside: true, "the middle of the card")
    try expectRoute(route(15, 80), inside: true, "1 pt inside the card's straight left side")
    try expectRoute(route(785, 80), inside: true, "1 pt inside the card's straight right side")
    try expectRoute(route(400, 159), inside: true, "1 pt inside the card's bottom")

    try expectRoute(route(13, 80), inside: false, "1 pt outside the left side, beside the shoulder")
    try expectRoute(route(787, 80), inside: false, "1 pt outside the right side")
    try expectRoute(route(400, 161), inside: false, "1 pt below the card")
    try expectRoute(route(15, 159), inside: false, "the card's transparent lower corner")
    try expectRoute(route(400, 300), inside: false, "the panel below the card passes through")

    try expectRoute(
        ClickThroughPolicy.route(pointer: DisplayPoint(x: -756, y: 982), panelFrame: panel, region: region),
        inside: true,
        "the screen's top pixel row over a hanging notch stays clickable"
    )
}

func testDisplayClickThroughRejectsDegenerateInput() throws {
    let layout = displayTestSamsungLayout()
    let panel = displayTestPanelFrame(layout)
    let pillCenter = displayTestGlobal(400, 15.5, in: panel)
    try expectRoute(
        ClickThroughPolicy.route(pointer: pillCenter, panelFrame: panel, region: .empty),
        inside: false,
        "an empty region (hidden pill) passes everything through"
    )
    try expectRoute(
        ClickThroughPolicy.route(
            pointer: DisplayPoint(x: .nan, y: pillCenter.y),
            panelFrame: panel,
            region: displayTestRegion(DisplayFrame(minX: 0, minY: 0, width: 800, height: 394), .bubble)
        ),
        inside: false,
        "a non-finite pointer passes through"
    )
    try expectRoute(
        ClickThroughPolicy.route(
            pointer: pillCenter,
            panelFrame: DisplayFrame(minX: 880, minY: 1_046, width: 0, height: 394),
            region: displayTestRegion(DisplayFrame(minX: 0, minY: 0, width: 800, height: 394), .bubble)
        ),
        inside: false,
        "a zero-width panel passes through"
    )
}

let displayClickThroughTests: [TestCase] = [
    ("display: click-through at the collapsed pill edges", testDisplayClickThroughAtTheCollapsedPillEdges),
    ("display: click-through for the expanded board", testDisplayClickThroughForTheExpandedBoard),
    ("display: click-through for the card frame", testDisplayClickThroughForTheCardFrame),
    ("display: click-through rejects degenerate input", testDisplayClickThroughRejectsDegenerateInput),
]

// MARK: PanelAnchorPlanner (hardening case 4: topology change while expanded or peeking)

func testDisplayAnchorKeepsThePillOnThePrimaryWhereverThePointerIs() throws {
    for pointer in [displayTestPointerOnBuiltIn, displayTestPointerOnSamsung, displayTestPointerOffScreen] {
        let plan = PanelAnchorPlanner.plan(
            mode: .primary,
            mainDisplayID: 2,
            pointer: pointer,
            displays: displayTestDesk,
            current: PanelAnchorState(pillDisplayIDs: [], cardDisplayID: nil, boardExpanded: false)
        )
        try expect(plan.pillDisplayIDs, equals: [2], "the pill ignores the pointer at \(pointer)")
        try expect(plan.createdPillDisplayIDs, equals: [2], "first plan creates the primary's panel")
    }
}

func testDisplayAnchorPrimarySwitchWhileTheBoardIsExpanded() throws {
    // The built-in (1) was primary with the board open; the Samsung (2) becomes the main display.
    let plan = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOnBuiltIn,
        displays: displayTestDesk,
        current: PanelAnchorState(pillDisplayIDs: [1], cardDisplayID: nil, boardExpanded: true)
    )
    try expect(plan.pillDisplayIDs, equals: [2], "the pill moves to the new primary")
    try expect(plan.createdPillDisplayIDs, equals: [2], "a pill panel is created on B")
    try expect(plan.removedPillDisplayIDs, equals: [1], "the pill panel on A is removed")
    try expect(plan.cardDisplayID, equals: nil, "no card was showing")
    try expect(plan.collapseBoard, equals: true, "the expanded board collapses")
    try expect(plan.relayoutAll, equals: true, "every kept panel is re-laid out")

    // Same switch, but A was unplugged rather than demoted.
    let unplugged = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: [displayTestSamsung],
        current: PanelAnchorState(pillDisplayIDs: [1], cardDisplayID: nil, boardExpanded: true)
    )
    try expect(unplugged.pillDisplayIDs, equals: [2], "the pill moves to the remaining display")
    try expect(unplugged.removedPillDisplayIDs, equals: [1], "the unplugged display's panel is removed")
    try expect(unplugged.collapseBoard, equals: true, "the board collapses")
}

func testDisplayAnchorCardLeavesAnUnpluggedDisplay() throws {
    // The card was on the built-in (1), which is now gone.
    let toPointer = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: DisplayPoint(x: 3_000, y: 500),
        displays: [displayTestSamsung, displayTestThird],
        current: PanelAnchorState(pillDisplayIDs: [2], cardDisplayID: 1, boardExpanded: false)
    )
    try expect(toPointer.cardDisplayID, equals: 3, "the card moves to the display under the pointer")
    try expect(toPointer.pillDisplayIDs, equals: [2], "the pill stays on the primary")
    try expect(toPointer.createdPillDisplayIDs, equals: [], "no pill panel is created")
    try expect(toPointer.removedPillDisplayIDs, equals: [], "no pill panel is removed")
    try expect(toPointer.collapseBoard, equals: false, "no board was open")

    let toPrimary = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOffScreen,
        displays: [displayTestSamsung, displayTestThird],
        current: PanelAnchorState(pillDisplayIDs: [2], cardDisplayID: 1, boardExpanded: false)
    )
    try expect(toPrimary.cardDisplayID, equals: 2, "an off-screen pointer sends the card to the primary")
}

func testDisplayAnchorCardOnThePrimaryWhileThePillMoves() throws {
    // The card is up on the old primary (1) when the Samsung (2) becomes primary.
    let demoted = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: displayTestDesk,
        current: PanelAnchorState(pillDisplayIDs: [1], cardDisplayID: 1, boardExpanded: false)
    )
    try expect(demoted.pillDisplayIDs, equals: [2], "the pill follows the new primary")
    try expect(demoted.cardDisplayID, equals: 1, "the card stays on its still-connected display")
    try expect(demoted.relayoutAll, equals: true, "and is re-laid out there")

    // The old primary is unplugged with the card on it: the card follows the plan
    // to the display under the pointer, which now also hosts the pill.
    let unplugged = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: [displayTestSamsung],
        current: PanelAnchorState(pillDisplayIDs: [1], cardDisplayID: 1, boardExpanded: false)
    )
    try expect(unplugged.pillDisplayIDs, equals: [2], "the pill moves")
    try expect(unplugged.cardDisplayID, equals: 2, "the card moves with it")
}

func testDisplayAnchorAllDisplaysAddsAndRemovesExactlyThatDisplay() throws {
    let added = PanelAnchorPlanner.plan(
        mode: .allDisplays,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: [displayTestBuiltIn, displayTestSamsung, displayTestThird],
        current: PanelAnchorState(pillDisplayIDs: [1, 2], cardDisplayID: nil, boardExpanded: false)
    )
    try expect(added.pillDisplayIDs, equals: [1, 2, 3], "a pill on every display")
    try expect(added.createdPillDisplayIDs, equals: [3], "only the new display gets a panel")
    try expect(added.removedPillDisplayIDs, equals: [], "nothing is removed")
    try expect(added.collapseBoard, equals: false, "no board was open")

    let removed = PanelAnchorPlanner.plan(
        mode: .allDisplays,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: [displayTestBuiltIn, displayTestThird],
        current: PanelAnchorState(pillDisplayIDs: [1, 2, 3], cardDisplayID: nil, boardExpanded: false)
    )
    try expect(removed.pillDisplayIDs, equals: [1, 3], "the remaining displays keep their pills")
    try expect(removed.createdPillDisplayIDs, equals: [], "nothing is created")
    try expect(removed.removedPillDisplayIDs, equals: [2], "only the unplugged display's panel goes")
}

func testDisplayAnchorWithNoDisplaysIsEmpty() throws {
    let fromNothing = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: nil,
        pointer: nil,
        displays: [],
        current: PanelAnchorState(pillDisplayIDs: [], cardDisplayID: nil, boardExpanded: false)
    )
    try expect(
        fromNothing,
        equals: PanelAnchorPlan(
            pillDisplayIDs: [],
            createdPillDisplayIDs: [],
            removedPillDisplayIDs: [],
            cardDisplayID: nil,
            collapseBoard: false,
            relayoutAll: false
        ),
        "an empty plan"
    )
    let allGone = PanelAnchorPlanner.plan(
        mode: .allDisplays,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: [],
        current: PanelAnchorState(pillDisplayIDs: [1, 2], cardDisplayID: 2, boardExpanded: true)
    )
    try expect(allGone.pillDisplayIDs, equals: [], "no pills without displays")
    try expect(allGone.createdPillDisplayIDs, equals: [], "nothing to create")
    try expect(allGone.removedPillDisplayIDs, equals: [1, 2], "every old panel is torn down")
    try expect(allGone.cardDisplayID, equals: nil, "the card has nowhere to go")
    try expect(allGone.relayoutAll, equals: false, "nothing to lay out")
}

func testDisplayAnchorUnchangedTopologyKeepsItsPanels() throws {
    let wakeWhileOpen = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: displayTestDesk,
        current: PanelAnchorState(pillDisplayIDs: [2], cardDisplayID: 2, boardExpanded: true)
    )
    try expect(wakeWhileOpen.pillDisplayIDs, equals: [2], "the pill stays")
    try expect(wakeWhileOpen.createdPillDisplayIDs, equals: [], "no panel churn")
    try expect(wakeWhileOpen.removedPillDisplayIDs, equals: [], "no panel churn")
    try expect(wakeWhileOpen.cardDisplayID, equals: 2, "the card stays")
    try expect(wakeWhileOpen.collapseBoard, equals: true, "an open board collapses after wake")
    try expect(wakeWhileOpen.relayoutAll, equals: true, "layouts are refreshed")

    let modeChange = PanelAnchorPlanner.plan(
        mode: .allDisplays,
        mainDisplayID: 2,
        pointer: displayTestPointerOnSamsung,
        displays: displayTestDesk,
        current: PanelAnchorState(pillDisplayIDs: [2], cardDisplayID: nil, boardExpanded: false)
    )
    try expect(modeChange.pillDisplayIDs, equals: [1, 2], "switching to all displays mirrors the pill")
    try expect(modeChange.createdPillDisplayIDs, equals: [1], "only the built-in needs a new panel")
    try expect(modeChange.removedPillDisplayIDs, equals: [], "the primary's panel is kept")
}

let displayAnchorTests: [TestCase] = [
    ("display: anchor keeps the pill on the primary wherever the pointer is", testDisplayAnchorKeepsThePillOnThePrimaryWhereverThePointerIs),
    ("display: anchor moves the pill when the primary switches while expanded", testDisplayAnchorPrimarySwitchWhileTheBoardIsExpanded),
    ("display: anchor moves the card off an unplugged display", testDisplayAnchorCardLeavesAnUnpluggedDisplay),
    ("display: anchor handles the card on the primary while the pill moves", testDisplayAnchorCardOnThePrimaryWhileThePillMoves),
    ("display: anchor adds and removes exactly one display in all-displays mode", testDisplayAnchorAllDisplaysAddsAndRemovesExactlyThatDisplay),
    ("display: anchor with no displays is an empty plan", testDisplayAnchorWithNoDisplaysIsEmpty),
    ("display: anchor keeps panels when the topology is unchanged", testDisplayAnchorUnchangedTopologyKeepsItsPanels),
]

// MARK: Settled re-anchor (Review Focus 4: topology change while the board is expanded)

/// A manual clock behind `DeadlineScheduler`. It records every settle the code
/// asks for and, when the test advances time, fires the work whose deadline has
/// passed. Time is kept in whole milliseconds so deadlines compare exactly.
private final class DisplayTestSettleClock: @unchecked Sendable {
    private var nowMilliseconds = 0
    private var pending: [(dueMilliseconds: Int, work: @MainActor @Sendable () -> Void)] = []
    private(set) var requestedDelays: [TimeInterval] = []

    var scheduler: DeadlineScheduler {
        DeadlineScheduler { [self] delay, work in
            requestedDelays.append(delay)
            pending.append((nowMilliseconds + Int((delay * 1_000).rounded()), work))
        }
    }

    @MainActor
    func advance(toMilliseconds time: Int) {
        nowMilliseconds = time
        let due = pending
            .filter { $0.dueMilliseconds <= time }
            .sorted { $0.dueMilliseconds < $1.dueMilliseconds }
        pending.removeAll { $0.dueMilliseconds <= time }
        for item in due {
            item.work()
        }
    }
}

/// The built-in is the only display with a camera housing; every other display
/// is a pill under a 31 pt menu bar. Mirrors NotchPanelController.layout(for:).
private func displayTestLayout(for display: DisplaySnapshot) -> NotchLayout {
    let frame = display.frame
    if display.id == displayTestBuiltIn.id {
        return NotchLayout(
            screenMinX: frame.minX,
            screenWidth: frame.width,
            screenMaxY: frame.minY + frame.height,
            safeAreaTop: 38,
            leftNotchEdgeX: frame.minX + 663.5,
            rightNotchEdgeX: frame.minX + 848.5,
            menuBarHeight: 38
        )
    }
    return NotchLayout(
        screenMinX: frame.minX,
        screenWidth: frame.width,
        screenMaxY: frame.minY + frame.height,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31
    )
}

/// Stands in for NotchDisplayPanel. Its region is derived the way
/// NotchWidgetView.publishInteractiveRegion derives it (a 200 pt pill; the open
/// board measures 240 pt) from the layout and expansion the panel has right
/// now, so a panel that missed a re-layout or a collapse routes the pointer
/// with stale geometry.
@MainActor
private final class DisplayTestPillPanel {
    let displayID: UInt32
    private(set) var layout: NotchLayout
    var isExpanded = false
    private(set) var isTornDown = false
    private(set) var relayoutCount = 0

    init(displayID: UInt32, layout: NotchLayout) {
        self.displayID = displayID
        self.layout = layout
    }

    func collapseBoard() { isExpanded = false }
    func tearDown() { isTornDown = true }

    func update(layout: NotchLayout) {
        self.layout = layout
        relayoutCount += 1
    }

    var panelFrame: DisplayFrame { displayTestPanelFrame(layout) }

    private var compactFrame: DisplayFrame {
        DisplayFrame(
            minX: layout.barLeadingOffset(leftWidth: 100, rightWidth: 100),
            minY: layout.topGap,
            width: 200,
            height: layout.height
        )
    }

    var region: HangingNotchInteractionRegion {
        guard !isTornDown else { return .empty }
        let frame = HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: layout.width,
            expandedMaximumHeight: layout.expandedHeight,
            measuredContentHeight: 240,
            isExpanded: isExpanded,
            isHidden: false,
            expandedTopInset: layout.expandedTopGap
        )
        return displayTestRegion(frame, layout.cornerStyle)
    }

    /// The middle of the compact pill, in AppKit global coordinates.
    var pillCenter: DisplayPoint {
        displayTestGlobal(compactFrame.minX + 100, compactFrame.minY + compactFrame.height / 2, in: panelFrame)
    }

    func route(_ pointer: DisplayPoint) -> PointerRoute {
        ClickThroughPolicy.route(pointer: pointer, panelFrame: panelFrame, region: region)
    }
}

/// Mirrors NotchPanelController: launch plans at once; screen and wake
/// notifications go through `DisplaySettle`; each re-anchor plans with
/// `PanelAnchorPlanner` and executes with `PanelAnchorExecutor`.
@MainActor
private final class DisplayTestPillController {
    var displays: [DisplaySnapshot]
    var mainDisplayID: UInt32?
    var pointer: DisplayPoint?
    let settle: DisplaySettle
    private(set) var panels: [UInt32: DisplayTestPillPanel] = [:]
    private(set) var pillDisplayIDs: [UInt32] = []
    private(set) var everCreated: [DisplayTestPillPanel] = []
    private(set) var planCount = 0

    init(displays: [DisplaySnapshot], mainDisplayID: UInt32?, scheduler: DeadlineScheduler) {
        self.displays = displays
        self.mainDisplayID = mainDisplayID
        settle = DisplaySettle(scheduler: scheduler)
        applyAnchorPlan()
    }

    var isBoardExpanded: Bool { panels.values.contains(where: \.isExpanded) }

    func reanchor() {
        settle.request { [weak self] in
            self?.applyAnchorPlan()
        }
    }

    private func applyAnchorPlan() {
        planCount += 1
        let plan = PanelAnchorPlanner.plan(
            mode: .primary,
            mainDisplayID: mainDisplayID,
            pointer: pointer,
            displays: displays,
            current: PanelAnchorState(
                pillDisplayIDs: pillDisplayIDs,
                cardDisplayID: nil,
                boardExpanded: isBoardExpanded
            )
        )
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        panels = PanelAnchorExecutor.apply(
            plan,
            to: panels,
            collapseBoard: { $0.collapseBoard() },
            tearDown: { $0.tearDown() },
            relayout: { displayID, panel in
                guard let display = displaysByID[displayID] else { return }
                panel.update(layout: displayTestLayout(for: display))
            },
            make: { displayID in
                guard let display = displaysByID[displayID] else { return nil }
                let panel = DisplayTestPillPanel(displayID: displayID, layout: displayTestLayout(for: display))
                everCreated.append(panel)
                return panel
            }
        )
        pillDisplayIDs = plan.pillDisplayIDs
    }
}

@MainActor
private func expectNoOrphanedPanel(_ controller: DisplayTestPillController, _ message: String) throws {
    try expect(
        controller.panels.keys.sorted(),
        equals: controller.pillDisplayIDs.sorted(),
        "\(message): one panel per planned display"
    )
    let live = controller.everCreated.filter { !$0.isTornDown }
    try expect(
        live.map(\.displayID).sorted(),
        equals: controller.pillDisplayIDs.sorted(),
        "\(message): every other panel ever created was torn down"
    )
    try expectTrue(
        live.allSatisfy { controller.panels[$0.displayID] === $0 },
        "\(message): the live panels are exactly the registered ones"
    )
}

@MainActor
func testDisplayTopologyChangeWhileExpandedReanchorsAfterTheSettle() throws {
    let clock = DisplayTestSettleClock()
    let builtInAlone = DisplaySnapshot(id: 1, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982))
    let controller = DisplayTestPillController(
        displays: [builtInAlone],
        mainDisplayID: 1,
        scheduler: clock.scheduler
    )
    try expect(controller.pillDisplayIDs, equals: [1], "launch plans at once: the pill hugs the built-in's notch")
    try expect(clock.requestedDelays, equals: [], "launch does not wait for a settle")
    guard let notchPanel = controller.panels[1] else {
        throw TestFailure.expectation("no panel on the built-in at launch")
    }
    notchPanel.isExpanded = true
    let notchBoardPoint = displayTestGlobal(400, 120, in: notchPanel.panelFrame)
    try expectRoute(notchPanel.route(notchBoardPoint), inside: true, "the open board takes the pointer")

    // Dock: the Samsung arrives and becomes the main display while the board is
    // open. The WindowServer reports it as a burst of screen-parameter changes.
    controller.displays = displayTestDesk
    controller.mainDisplayID = 2
    controller.pointer = displayTestPointerOnSamsung
    controller.reanchor()
    clock.advance(toMilliseconds: 100)
    controller.reanchor()
    clock.advance(toMilliseconds: 200)
    controller.reanchor()
    try expect(IslandTiming.displaySettle, equals: 0.35, "the settle is 0.35 s")
    try expect(
        clock.requestedDelays,
        equals: [IslandTiming.displaySettle, IslandTiming.displaySettle, IslandTiming.displaySettle],
        "every notification restarts the 0.35 s settle"
    )

    clock.advance(toMilliseconds: 549)
    try expect(controller.planCount, equals: 1, "nothing re-plans within 0.35 s of the last notification")
    try expectTrue(controller.settle.isPending, "the re-anchor is still settling")
    try expect(controller.pillDisplayIDs, equals: [1], "the pill has not moved yet")
    try expectTrue(notchPanel.isExpanded, "the board stays open until the re-anchor")

    clock.advance(toMilliseconds: 550)
    try expect(controller.planCount, equals: 2, "the burst re-anchors exactly once, 0.35 s after the last notification")
    try expectTrue(!controller.settle.isPending, "nothing is left pending")
    try expect(controller.pillDisplayIDs, equals: [2], "the pill moves to the new primary")
    try expectTrue(!notchPanel.isExpanded, "the open board was collapsed")
    try expectTrue(notchPanel.isTornDown, "the built-in's panel was torn down")
    try expectRoute(notchPanel.route(notchBoardPoint), inside: false, "the old board no longer takes clicks")
    try expectNoOrphanedPanel(controller, "after docking")
    guard let samsungPanel = controller.panels[2] else {
        throw TestFailure.expectation("no panel on the Samsung after docking")
    }
    try expect(samsungPanel.layout, equals: displayTestSamsungLayout(), "the new panel is laid out for the Samsung")
    try expect(samsungPanel.pillCenter, equals: DisplayPoint(x: 1_280, y: 1_424.5), "the pill sits in the Samsung's menu bar")
    try expectRoute(samsungPanel.route(samsungPanel.pillCenter), inside: true, "the recomputed region is the Samsung pill")
    try expectRoute(
        samsungPanel.route(displayTestGlobal(400, 120, in: samsungPanel.panelFrame)),
        inside: false,
        "the recomputed region is collapsed: the board area passes clicks through"
    )

    // The Samsung switches resolution with its board open, and a wake lands in
    // the same settle window: one re-anchor, the same panel, a new layout.
    samsungPanel.isExpanded = true
    let oldPillCenter = samsungPanel.pillCenter
    let scaledSamsung = DisplaySnapshot(id: 2, frame: DisplayFrame(minX: 0, minY: 0, width: 3_008, height: 1_692))
    controller.displays = [displayTestBuiltIn, scaledSamsung]
    controller.reanchor()
    controller.reanchor()
    clock.advance(toMilliseconds: 899)
    try expect(controller.planCount, equals: 2, "the resolution change is still settling")
    clock.advance(toMilliseconds: 900)
    try expect(controller.planCount, equals: 3, "screen change and wake re-anchor once")
    try expectTrue(controller.panels[2] === samsungPanel, "the Samsung keeps its panel")
    try expect(samsungPanel.relayoutCount, equals: 1, "the kept panel was re-laid out")
    try expectTrue(!samsungPanel.isExpanded, "the open board was collapsed")
    try expect(
        samsungPanel.panelFrame,
        equals: DisplayFrame(minX: 1_104, minY: 1_298, width: 800, height: 394),
        "the panel follows the new geometry"
    )
    try expectRoute(samsungPanel.route(samsungPanel.pillCenter), inside: true, "the region moved with the pill")
    try expectRoute(samsungPanel.route(oldPillCenter), inside: false, "the old pill position passes clicks through")
    try expectNoOrphanedPanel(controller, "after the resolution change")

    // Undock with the board open: the built-in is the main display again.
    samsungPanel.isExpanded = true
    controller.displays = [builtInAlone]
    controller.mainDisplayID = 1
    controller.pointer = DisplayPoint(x: 700, y: 500)
    controller.reanchor()
    clock.advance(toMilliseconds: 1_249)
    try expect(controller.pillDisplayIDs, equals: [2], "the undock is still settling")
    clock.advance(toMilliseconds: 1_250)
    try expect(controller.planCount, equals: 4, "the undock re-anchors once")
    try expect(controller.pillDisplayIDs, equals: [1], "the pill returns to the built-in")
    try expectTrue(!samsungPanel.isExpanded && samsungPanel.isTornDown, "the Samsung's open board collapsed and its panel went")
    guard let returnedPanel = controller.panels[1] else {
        throw TestFailure.expectation("no panel on the built-in after undocking")
    }
    try expectTrue(returnedPanel !== notchPanel, "the returning display gets a fresh panel")
    try expect(returnedPanel.layout.presentation, equals: .notch, "laid out for the notch again")
    try expectRoute(returnedPanel.route(returnedPanel.pillCenter), inside: true, "the recomputed region is the notch bar")
    try expectRoute(returnedPanel.route(notchBoardPoint), inside: false, "and it is collapsed")
    try expectNoOrphanedPanel(controller, "after undocking")
    try expect(controller.everCreated.count, equals: 3, "three panels over the whole sequence, never a duplicate")
}

let displayReanchorTests: [TestCase] = [
    (
        "display: topology change while the board is expanded re-anchors once after the settle, orphans nothing and recomputes regions",
        testDisplayTopologyChangeWhileExpandedReanchorsAfterTheSettle
    ),
]

let displayTests: [TestCase] = displaySelectionTests + displayClickThroughTests + displayAnchorTests + displayReanchorTests

// Tests/IslandTests/BoardTests.swift — Task 12 (`board:`)
import Foundation
import IslandCore
import IslandTestSupport

private let boardTestNow = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: Grouping

func testBoardGroupsFollowTheBoardOrder() throws {
    let rows = [
        AgentRow.fixture(key: "w1:p1", state: .waiting),
        AgentRow.fixture(key: "w1:p2", state: .error),
        AgentRow.fixture(key: "w1:p3", state: .working),
        AgentRow.fixture(key: "w1:p4", state: .stale),
        AgentRow.fixture(key: "w1:p5", state: .doneUnseen),
        AgentRow.fixture(key: "w1:p6", state: .idle),
        AgentRow.fixture(key: "w1:p7", state: .starting),
    ]
    let groups = BoardLayout.groups(rows)
    try expect(groups.map(\.kind), equals: [.waiting, .error, .working, .stale, .done, .idle], "board order")
    try expect(
        groups.first { $0.kind == .working }?.rows.map(\.id.key),
        equals: ["w1:p3"],
        "only confirmed working rows sit with working"
    )
    try expect(
        groups.first { $0.kind == .idle }?.rows.map(\.id.key),
        equals: ["w1:p6", "w1:p7"],
        "starting rows sit with idle"
    )
    try expect(groups.map(\.id), equals: groups.map(\.kind), "a group is identified by its kind")
}

func testBoardOmitsEmptyGroupsAndKeepsRowOrder() throws {
    let rows = [
        AgentRow.fixture(key: "b", state: .working),
        AgentRow.fixture(key: "a", state: .doneUnseen),
        AgentRow.fixture(key: "c", state: .working),
    ]
    let groups = BoardLayout.groups(rows)
    try expect(groups.map(\.kind), equals: [.working, .done], "only non-empty groups")
    try expect(groups[0].rows.map(\.id.key), equals: ["b", "c"], "rows keep the incoming (pinned) order")
    try expect(BoardLayout.groups([]), equals: [], "no rows, no groups")
}

func testBoardIdleGroupIsCollapsedByDefault() throws {
    let groups = BoardLayout.groups([
        AgentRow.fixture(key: "w1:p1", state: .waiting),
        AgentRow.fixture(key: "w1:p2", state: .idle),
        AgentRow.fixture(key: "w1:p3", state: .starting),
    ])
    guard let idle = groups.last else { throw TestFailure.expectation("missing idle group") }
    try expect(idle.kind, equals: .idle, "idle is last")
    try expect(idle.isCollapsedByDefault, equals: true, "idle starts collapsed")
    try expect(idle.title, equals: "2 idle", "the toggle names the idle count")
    try expect(groups[0].isCollapsedByDefault, equals: false, "other groups start open")
    try expect(
        [BoardGroup.Kind.waiting, .error, .working, .stale, .done].map { BoardGroup(kind: $0, rows: []).title },
        equals: ["Waiting", "Error", "Working", "Activity uncertain", "Done"],
        "group titles"
    )
}

// MARK: Text

func testBoardAgeTextExplainsStaleActivity() throws {
    let stale = AgentRow.fixture(key: "w1:p1", state: .stale, since: boardTestNow.addingTimeInterval(-52 * 60))
    try expect(BoardLayout.ageText(for: stale, now: boardTestNow), equals: "stale · 52m", "stale age text")
    let working = AgentRow.fixture(key: "w1:p2", state: .working, since: boardTestNow.addingTimeInterval(-72 * 60))
    try expect(BoardLayout.ageText(for: working, now: boardTestNow), equals: "1h 12m", "other rows use SessionDurationFormatter")
    let fresh = AgentRow.fixture(key: "w1:p3", state: .doneUnseen, since: boardTestNow.addingTimeInterval(-20))
    try expect(BoardLayout.ageText(for: fresh, now: boardTestNow), equals: "<1m", "under a minute")
}

func testBoardSummaryTextPutsErrorFirst() throws {
    var rows = [
        AgentRow.fixture(key: "w1:p1", state: .working),
        AgentRow.fixture(key: "w1:p2", state: .working),
        AgentRow.fixture(key: "w1:p3", state: .stale),
        AgentRow.fixture(key: "w1:p4", state: .waiting),
        AgentRow.fixture(key: "w1:p5", state: .doneUnseen),
        AgentRow.fixture(key: "w1:p6", state: .doneUnseen),
        AgentRow.fixture(key: "w1:p7", state: .idle),
    ]
    try expect(Summary(rows: rows).text, equals: "1 waiting · 2 working · 1 stale · 2 done", "pill text")
    rows.append(AgentRow.fixture(key: "w1:p8", state: .error))
    try expect(
        Summary(rows: rows).text,
        equals: "1 error · 1 waiting · 2 working · 1 stale · 2 done",
        "the error segment leads"
    )
    try expect(Summary(rows: rows).segments.first?.kind, equals: .error, "error is the first label, drawn red")
}

func testBoardDimsOnlyOfflineSources() throws {
    let working = AgentRow.fixture(key: "w1:p1", state: .working)
    let stale = AgentRow.fixture(key: "w1:p2", state: .stale)
    try expect(BoardLayout.dimsRow(working, health: .online), equals: false, "online working row")
    try expect(BoardLayout.dimsRow(working, health: nil), equals: false, "no health yet")
    try expect(BoardLayout.dimsRow(stale, health: .online), equals: false, "stale text stays readable")
    try expect(BoardLayout.dimsRow(working, health: .offline(reason: "socket missing")), equals: true, "offline feed")
    try expect(BoardLayout.dimsRow(working, health: .disabled(reason: "protocol 23")), equals: true, "disabled feed")
    try expect(BoardLayout.dimsRow(working, health: .inactive(reason: "no registry")), equals: false, "inactive feed")
}

// MARK: Height cap

func testBoardMaximumHeightIsSixtyPercentOfTheVisibleFrame() throws {
    try expect(BoardLayout.maximumBoardHeight(visibleFrameHeight: 1_409), equals: 845.4, "Samsung: 1440 - 31 pt menu bar")
    try expect(BoardLayout.maximumBoardHeight(visibleFrameHeight: 0), equals: 0, "no visible frame")
    try expect(BoardLayout.maximumBoardHeight(visibleFrameHeight: .nan), equals: 0, "non-finite height")
}

let boardGroupingTests: [TestCase] = [
    ("board: groups follow the board order", testBoardGroupsFollowTheBoardOrder),
    ("board: empty groups are omitted and row order is kept", testBoardOmitsEmptyGroupsAndKeepsRowOrder),
    ("board: the idle group is collapsed by default", testBoardIdleGroupIsCollapsedByDefault),
    ("board: age text explains stale activity", testBoardAgeTextExplainsStaleActivity),
    ("board: summary text puts the error segment first", testBoardSummaryTextPutsErrorFirst),
    ("board: only offline sources are dimmed", testBoardDimsOnlyOfflineSources),
    ("board: maximum height is 60 percent of the visible frame", testBoardMaximumHeightIsSixtyPercentOfTheVisibleFrame),
]

// MARK: Layout heights (NotchLayout board cap, SessionMenuLayout board list)

func testBoardNotchLayoutKeepsLegacyHeightsWithoutAVisibleFrame() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 663.5,
        rightNotchEdgeX: 848.5
    )
    try expect(notched.boardMaxHeight, equals: 341, "legacy card budget")
    try expect(notched.expandedHeight, equals: 387, "legacy notch panel")
    try expect(NotchLayout.menuMaxHeight, equals: 341, "legacy menu budget")
    try expect(SessionMenuLayout.maximumCardHeight(), equals: 316, "legacy card without error")
    try expect(SessionMenuLayout.maximumCardHeight(hasError: true), equals: 341, "legacy card with error")
    try expect(
        SessionMenuLayout.boardListMaximumHeight(boardMaxHeight: notched.boardMaxHeight),
        equals: SessionMenuLayout.maximumSessionListHeight,
        "the legacy budget leaves the legacy 300 pt list"
    )
}

func testBoardNotchLayoutCapsTheBoardAtTheVisibleFrame() throws {
    let samsung = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31,
        visibleFrameHeight: 1_409
    )
    try expect(samsung.boardMaxHeight, equals: 845.4, "60 % of the Samsung's visible height")
    try expect(samsung.expandedHeight, equals: 898.4, "23 bar + 845.4 board + 8 bottom + 8 gap + 14 header padding")
    try expect(samsung.height, equals: 23, "the pill itself is unchanged")
    try expect(samsung.originX, equals: 880, "the pill position is unchanged")
    try expect(
        SessionMenuLayout.boardListMaximumHeight(boardMaxHeight: samsung.boardMaxHeight),
        equals: 845.4 - 41,
        "the list gets the budget minus the 41 pt card chrome"
    )

    let builtIn = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 663.5,
        rightNotchEdgeX: 848.5,
        menuBarHeight: 38,
        visibleFrameHeight: 944
    )
    try expect(builtIn.boardMaxHeight, equals: 566.4, "60 % of the built-in's visible height")
    try expect(builtIn.expandedHeight, equals: 612.4, "38 bar + 566.4 board + 8 bottom")
    try expect(builtIn.notchWidth, equals: 185, "the notch geometry is unchanged")

    let small = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_280,
        screenMaxY: 500,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24,
        visibleFrameHeight: 476
    )
    try expect(small.boardMaxHeight, equals: 476 * 0.6, "a short screen shrinks the board below the legacy budget")
    try expect(small.expandedHeight < 387, equals: true, "and the panel with it")
}

func testBoardListHeightAccountsForGroupHeadersAndNeverExceedsTheCap() throws {
    try expect(SessionMenuLayout.sessionRowHeight, equals: 28, "compact rows")
    try expect(SessionMenuLayout.groupHeaderHeight, equals: 20, "group header")
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: 3, groupCount: 2, hasExpandedActions: false, maximumHeight: 800),
        equals: 2 * 20 + 3 * 28,
        "two headers and three rows"
    )
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: 3, groupCount: 2, hasExpandedActions: true, maximumHeight: 800),
        equals: 2 * 20 + 3 * 28 + 111,
        "open actions reserve 111 pt"
    )
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: 0, groupCount: 1, hasExpandedActions: false, maximumHeight: 800),
        equals: 20,
        "a collapsed idle group shows its header only"
    )
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: 40, groupCount: 5, hasExpandedActions: true, maximumHeight: 804.4),
        equals: 804.4,
        "forty agents scroll inside the cap"
    )
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: -1, groupCount: -1, hasExpandedActions: false, maximumHeight: 800),
        equals: 0,
        "negative counts clamp to zero"
    )
    try expect(
        SessionMenuLayout.boardListHeight(rowCount: 3, groupCount: 1, hasExpandedActions: false, maximumHeight: -5),
        equals: 0,
        "a negative cap clamps to zero"
    )
    for rows in 0...60 {
        for groups in 0...5 {
            let height = SessionMenuLayout.boardListHeight(
                rowCount: rows, groupCount: groups, hasExpandedActions: rows % 2 == 0, maximumHeight: 300
            )
            try expectTrue(height <= 300, "\(rows) rows in \(groups) groups stay within the cap")
        }
    }
}

let boardHeightTests: [TestCase] = [
    ("board: notch layout keeps legacy heights without a visible frame", testBoardNotchLayoutKeepsLegacyHeightsWithoutAVisibleFrame),
    ("board: notch layout caps the board at the visible frame", testBoardNotchLayoutCapsTheBoardAtTheVisibleFrame),
    ("board: list height counts group headers and never exceeds the cap", testBoardListHeightAccountsForGroupHeadersAndNeverExceedsTheCap),
]

// MARK: Frozen grouping (fix round 1: pinned order guards row slot, not group membership)

func testFrozenAssignmentKeepsAWorkingRowInWorkingAfterItFinishes() throws {
    // p1 was working when the pointer entered the board and has since
    // finished; frozen grouping must keep it under Working with its new
    // (done) state still visible on the row itself.
    let p1 = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    let groups = BoardLayout.groups([p1], frozenAssignment: [p1.id: .working])
    try expect(groups.map(\.kind), equals: [.working], "the row stays under its frozen group")
    try expect(groups.first?.rows.map(\.id.key), equals: ["w1:p1"], "and only that row is there")
    try expect(groups.first?.rows.first?.state, equals: .doneUnseen, "the row's own state is still live")
}

func testFrozenAssignmentAppendsANewRowToItsNaturalGroup() throws {
    // p1 was working when frozen but has since finished (its live state is
    // .doneUnseen); it must stay under Working, not jump to Done. p2 is new
    // (absent from the frozen map) and lands in its own natural group,
    // which happens to also be Working, appended after the frozen member.
    // p1's mismatched live/frozen state is what makes this fail under plain
    // grouping (see the fix-round-2 report for the RED demonstration).
    let p1 = AgentRow.fixture(key: "w1:p1", state: .doneUnseen)
    let p2 = AgentRow.fixture(key: "w1:p2", state: .working)
    let groups = BoardLayout.groups([p1, p2], frozenAssignment: [p1.id: .working])
    try expect(groups.map(\.kind), equals: [.working], "one group")
    try expect(groups.first?.rows.map(\.id.key), equals: ["w1:p1", "w1:p2"], "the new row appends after the frozen one")
}

func testFrozenAssignmentDropsDepartedRows() throws {
    // p1 was frozen into Done but has since left the row list entirely
    // (session ended); it must not reappear or leave a ghost entry, and its
    // departure must not leave a stray empty Done group either, since p2 —
    // the row that remains — is also frozen into Done. p2's frozen kind
    // deliberately differs from its natural one (Working, since its live
    // state is .working), so a silent fallback to plain grouping would
    // misplace it and expose the gap.
    let p2 = AgentRow.fixture(key: "w1:p2", state: .working)
    let groups = BoardLayout.groups(
        [p2],
        frozenAssignment: [RowID(source: .herdr, key: "w1:p1"): .done, p2.id: .done]
    )
    try expect(groups.map(\.kind), equals: [.done], "p2 keeps its frozen group, not its natural one")
    try expect(groups.first?.rows.map(\.id.key), equals: ["w1:p2"], "the departed row is gone, no duplicate")
}

func testFrozenAssignmentKeepsAnEmptyGroupsHeaderVisible() throws {
    // p1 was frozen into Waiting and has since departed, leaving Waiting
    // with no rows; the header must still render (in board order) so the
    // list above the pointer does not collapse and shift everything up.
    let p2 = AgentRow.fixture(key: "w1:p2", state: .working)
    let groups = BoardLayout.groups(
        [p2],
        frozenAssignment: [RowID(source: .herdr, key: "w1:p1"): .waiting, p2.id: .working]
    )
    try expect(groups.map(\.kind), equals: [.waiting, .working], "Waiting still appears, in board order")
    guard let waitingGroup = groups.first(where: { $0.kind == .waiting }) else {
        throw TestFailure.expectation("missing waiting group")
    }
    try expect(waitingGroup.rows, equals: [], "but it is empty")
}

func testNilFrozenAssignmentMatchesPlainGrouping() throws {
    let rows = [
        AgentRow.fixture(key: "w1:p1", state: .waiting),
        AgentRow.fixture(key: "w1:p2", state: .error),
        AgentRow.fixture(key: "w1:p3", state: .working),
        AgentRow.fixture(key: "w1:p4", state: .doneUnseen),
    ]
    try expect(
        BoardLayout.groups(rows, frozenAssignment: nil),
        equals: BoardLayout.groups(rows),
        "nil assignment is exactly today's grouping"
    )
}

let boardFrozenGroupingTests: [TestCase] = [
    ("board: a frozen row stays in its group after it finishes", testFrozenAssignmentKeepsAWorkingRowInWorkingAfterItFinishes),
    ("board: a new row appends to its natural group while frozen", testFrozenAssignmentAppendsANewRowToItsNaturalGroup),
    ("board: a departed row is dropped from a frozen grouping", testFrozenAssignmentDropsDepartedRows),
    ("board: an empty frozen group keeps its header", testFrozenAssignmentKeepsAnEmptyGroupsHeaderVisible),
    ("board: a nil frozen assignment matches plain grouping", testNilFrozenAssignmentMatchesPlainGrouping),
]

let boardTests: [TestCase] = boardGroupingTests + boardHeightTests + boardFrozenGroupingTests

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

// MARK: Row text (title context, source and feed health)

/// A synthetic row whose subtitle and jump the test chooses.
private func contextRow(
    source: SessionSource,
    title: String = "agent-island",
    subtitle: String,
    state: DisplayState = .working,
    ageMinutes: Double = 0,
    jump: JumpTarget? = nil,
    detail: Detail? = nil
) -> AgentRow {
    var row = AgentRow.fixture(
        source: source,
        key: "k1",
        state: state,
        since: boardTestNow.addingTimeInterval(-ageMinutes * 60),
        title: title,
        detail: detail,
        jump: jump
    )
    row.subtitle = subtitle
    return row
}

private func rowText(_ row: AgentRow, title: String? = nil, health: FeedHealth? = .online) -> BoardRowText {
    BoardLayout.rowText(for: row, title: title ?? row.title, health: health, now: boardTestNow)
}

func testBoardRowTextHidesASubtitleThatRepeatsTheTitle() throws {
    let unnamedClaude = contextRow(source: .claudeRegistry, subtitle: "  Agent-Island \n")
    try expect(rowText(unnamedClaude).secondary, equals: "", "case and surrounding whitespace do not make a new line")
    let spaced = contextRow(source: .codexDesktop, title: "My  Repo", subtitle: "my repo")
    try expect(rowText(spaced).secondary, equals: "", "inner whitespace runs compare as one space")
}

func testBoardRowTextKeepsADistinctSubtitle() throws {
    let herdr = contextRow(source: .herdr, title: "build", subtitle: "infra › shell")
    try expect(rowText(herdr).secondary, equals: "infra › shell", "a Herdr workspace and tab")
    let renamed = contextRow(source: .claudeRegistry, title: "agent-island", subtitle: "agent-island")
    try expect(
        rowText(renamed, title: "Fixer").secondary,
        equals: "agent-island",
        "a rename makes the folder informative again"
    )
}

func testBoardRowTextNamesTheSessionSurface() throws {
    let desktop = contextRow(
        source: .claudeRegistry, subtitle: "agent-island",
        jump: .claudeDesktop(sessionID: "s1", tmuxTarget: "work:1")
    )
    try expect(rowText(desktop).secondary, equals: "Claude Desktop", "Desktop replaces the repeated folder")
    let remote = contextRow(
        source: .claudeRegistry, subtitle: "agent-island",
        jump: .claudeRemoteControl(bridgeSessionID: "session_abc123")
    )
    try expect(rowText(remote).secondary, equals: "Remote Control", "Remote Control replaces the repeated folder")
    let tmux = contextRow(source: .claudeRegistry, subtitle: "agent-island", jump: .terminal(tmuxTarget: "work:2"))
    try expect(rowText(tmux).secondary, equals: "tmux work:2", "a tmux target replaces the repeated folder")
    let named = contextRow(
        source: .claudeRegistry, title: "Fix the board", subtitle: "agent-island",
        jump: .claudeDesktop(sessionID: "s1", tmuxTarget: nil)
    )
    try expect(rowText(named).secondary, equals: "agent-island · Claude Desktop", "a distinct folder keeps its place before the surface")
}

func testBoardRowTextShowsNoSurfaceWhenUnknown() throws {
    let terminal = contextRow(source: .claudeRegistry, subtitle: "agent-island", jump: .terminal(tmuxTarget: nil))
    try expect(rowText(terminal).secondary, equals: "", "no tmux target, no invented surface")
    try expect(rowText(terminal).help, equals: "agent-island", "the tooltip falls back to the full title")
    let codex = contextRow(source: .codexDesktop, subtitle: "agent-island")
    try expect(rowText(codex).secondary, equals: "", "Codex threads add no surface")
    let herdr = contextRow(source: .herdr, subtitle: "agent-island")
    try expect(rowText(herdr).secondary, equals: "", "Herdr panes add no surface")
}

func testBoardRowTextSanitizesUntrustedTmuxTargets() throws {
    for target in ["work\u{1B}[31m:1", "work 1", "-t:1", "work\n1", String(repeating: "w", count: 300)] {
        let row = contextRow(source: .claudeRegistry, subtitle: "agent-island", jump: .terminal(tmuxTarget: target))
        let text = rowText(row)
        try expect(text.secondary, equals: "", "an unusable tmux target \(target.debugDescription.prefix(24)) is not shown")
        try expectTrue(!text.accessibilityLabel.contains("tmux"), "nor spoken")
        try expect(row.jump, equals: .terminal(tmuxTarget: target), "navigation data is unchanged")
    }
    let long = String(repeating: "w", count: 200)
    let row = contextRow(source: .claudeRegistry, subtitle: "agent-island", jump: .terminal(tmuxTarget: long))
    let secondary = rowText(row).secondary
    try expectTrue(secondary.hasPrefix("tmux w"), "a long valid target is still named: \(secondary.prefix(12))")
    try expectTrue(secondary.hasSuffix("…"), "and truncated")
    try expectTrue(secondary.count <= 45, "to a compact length (\(secondary.count))")
}

func testBoardRowTextLabelNamesSourceStateAndAge() throws {
    let claude = contextRow(source: .claudeRegistry, subtitle: "agent-island", ageMinutes: 72)
    try expect(
        rowText(claude).accessibilityLabel,
        equals: "agent-island, Claude, working, 1h 12m",
        "title, source, state and age; no repeated folder"
    )
    let herdr = contextRow(source: .herdr, title: "build", subtitle: "infra › shell", state: .waiting, ageMinutes: 5)
    try expect(
        rowText(herdr).accessibilityLabel,
        equals: "build, Herdr, waiting for you, 5m, infra › shell",
        "the context line follows"
    )
    try expect(rowText(herdr).sourceHelp, equals: "Herdr pane", "the source glyph names its source")
    try expect(rowText(claude).sourceHelp, equals: "Claude Code session", "Claude source help")
    try expect(
        rowText(contextRow(source: .codexDesktop, subtitle: "x")).sourceHelp,
        equals: "Codex thread",
        "Codex source help"
    )
}

func testBoardRowTextStaleDoesNotRepeatStatus() throws {
    let stale = contextRow(source: .codexDesktop, title: "refactor", subtitle: "agent-island", state: .stale, ageMinutes: 52)
    let label = rowText(stale).accessibilityLabel
    try expect(label, equals: "refactor, Codex, stale, activity unconfirmed, 52m, agent-island", "stale label")
    try expect(label.components(separatedBy: "stale").count - 1, equals: 1, "stale is said once")
}

func testBoardRowTextNamesWarningFeedHealth() throws {
    let row = contextRow(source: .herdr, title: "build", subtitle: "infra › shell", ageMinutes: 5)
    let base = "build, Herdr, working, 5m, infra › shell"
    for health: FeedHealth? in [nil, .online, .inactive(reason: "no socket yet")] {
        let text = rowText(row, health: health)
        try expect(text.accessibilityLabel, equals: base, "\(String(describing: health)) adds no warning")
        try expect(text.help, equals: "infra › shell", "nor to the tooltip")
        try expect(text.sourceHelp, equals: "Herdr pane", "nor to the source tooltip")
    }
    let warnings: [(FeedHealth, String)] = [
        (.offline(reason: "socket missing"), "Herdr offline: socket missing"),
        (.disabled(reason: "protocol 23"), "Herdr disabled: protocol 23"),
        (.degraded(reason: "jumps unavailable"), "Herdr degraded: jumps unavailable"),
    ]
    for (health, warning) in warnings {
        let text = rowText(row, health: health)
        try expect(text.accessibilityLabel, equals: "\(base), \(warning)", "\(warning) is spoken")
        try expect(text.help, equals: "infra › shell\n\(warning)", "\(warning) is in the row tooltip")
        try expect(text.sourceHelp, equals: "Herdr pane\n\(warning)", "\(warning) is in the source tooltip")
    }
    let noisy = rowText(row, health: .offline(reason: "line one\nline\u{07} two " + String(repeating: "x", count: 300)))
    let warning = noisy.sourceHelp.components(separatedBy: "\n").dropFirst().joined()
    try expectTrue(warning.hasPrefix("Herdr offline: line one line two x"), "a noisy reason becomes one line: \(warning.prefix(40))")
    try expectTrue(warning.hasSuffix("…") && warning.count <= 100, "and is capped (\(warning.count))")
}

func testBoardRowTextHelpKeepsTheDetail() throws {
    let detail = Detail(question: "Proceed?", options: ["Yes", "No"], kind: .question)
    let row = contextRow(source: .herdr, title: "build", subtitle: "infra › shell", state: .waiting, detail: detail)
    try expect(rowText(row).help, equals: "Proceed?\n• Yes\n• No", "the question and its options")
    try expect(rowText(row).secondary, equals: "infra › shell", "the resting line stays the context; hover swaps in the question")
    try expect(
        rowText(row, health: .offline(reason: "socket missing")).help,
        equals: "Proceed?\n• Yes\n• No\nHerdr offline: socket missing",
        "a feed warning follows the detail"
    )
    let recap = Detail(question: "Done refactoring.", kind: .recap)
    let done = contextRow(source: .codexDesktop, title: "refactor", subtitle: "agent-island", state: .doneUnseen, detail: recap)
    try expect(rowText(done).help, equals: "Done refactoring.", "a recap without options")
}

func testBoardRowTextEmptyDetailFallsBack() throws {
    let empty = Detail(question: "", options: ["Yes"], kind: .question)
    let herdr = contextRow(source: .herdr, title: "build", subtitle: "infra › shell", detail: empty)
    try expect(rowText(herdr).help, equals: "infra › shell", "an empty question falls back to the context line")
    let claude = contextRow(source: .claudeRegistry, subtitle: "agent-island", detail: empty)
    try expect(rowText(claude).help, equals: "agent-island", "and with no context line, to the title")
}

let boardRowTextTests: [TestCase] = [
    ("board: row text hides a subtitle that repeats the title", testBoardRowTextHidesASubtitleThatRepeatsTheTitle),
    ("board: row text keeps a distinct subtitle", testBoardRowTextKeepsADistinctSubtitle),
    ("board: row text names the Desktop, Remote Control or tmux surface", testBoardRowTextNamesTheSessionSurface),
    ("board: row text shows no surface when it is unknown", testBoardRowTextShowsNoSurfaceWhenUnknown),
    ("board: row text drops unusable tmux targets and caps long ones", testBoardRowTextSanitizesUntrustedTmuxTargets),
    ("board: row label names title, source, state and age", testBoardRowTextLabelNamesSourceStateAndAge),
    ("board: a stale row label says stale once", testBoardRowTextStaleDoesNotRepeatStatus),
    ("board: warning feed health is spoken and shown in tooltips", testBoardRowTextNamesWarningFeedHealth),
    ("board: the row tooltip keeps the detail", testBoardRowTextHelpKeepsTheDetail),
    ("board: an empty detail falls back to context, then title", testBoardRowTextEmptyDetailFallsBack),
]

let boardTests: [TestCase] = boardGroupingTests + boardHeightTests + boardFrozenGroupingTests + boardRowTextTests

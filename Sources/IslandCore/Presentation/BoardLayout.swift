import Foundation

/// One section of the expanded board (§7.2).
public struct BoardGroup: Equatable, Sendable, Identifiable {
    /// Declaration order is the board order: Waiting, Error, Working, Activity uncertain, Done, idle.
    public enum Kind: String, CaseIterable, Sendable {
        case waiting, error, working, stale, done, idle
    }

    public let kind: Kind
    public let rows: [AgentRow]

    public init(kind: Kind, rows: [AgentRow]) {
        self.kind = kind
        self.rows = rows
    }

    public var id: Kind { kind }

    /// Only the idle group starts collapsed behind its "N idle" toggle.
    public var isCollapsedByDefault: Bool { kind == .idle }

    public var title: String {
        switch kind {
        case .waiting: "Waiting"
        case .error: "Error"
        case .working: "Working"
        case .stale: "Activity uncertain"
        case .done: "Done"
        case .idle: "\(rows.count) idle"
        }
    }
}

/// Pure board decisions: grouping, the height cap, the age text and dimming.
public enum BoardLayout {
    /// Stale activity has its own section; starting rows sit with idle.
    public static func kind(for state: DisplayState) -> BoardGroup.Kind {
        switch state {
        case .waiting: .waiting
        case .error: .error
        case .working: .working
        case .stale: .stale
        case .doneUnseen: .done
        case .idle, .starting: .idle
        }
    }

    /// Groups in board order; empty groups are omitted and every group keeps
    /// the incoming row order (the menu's pinned order).
    public static func groups(_ rows: [AgentRow]) -> [BoardGroup] {
        var rowsByKind: [BoardGroup.Kind: [AgentRow]] = [:]
        for row in rows {
            rowsByKind[kind(for: row.state), default: []].append(row)
        }
        return BoardGroup.Kind.allCases.compactMap { kind in
            rowsByKind[kind].map { BoardGroup(kind: kind, rows: $0) }
        }
    }

    /// Groups in board order, optionally freezing each row's group
    /// membership while the pointer is inside the board.
    ///
    /// `pinnedOrder` (see `PinnedSessionOrder`) keeps a row's *slot* stable
    /// so a click's aim survives a reorder, but a state change (working →
    /// done) still moves the row to a different *group*, and every row
    /// below it shifts. That is the same misclick the pin exists to
    /// prevent, one level up. Freezing the assignment closes that gap:
    ///
    /// - With `frozenAssignment == nil`, this is exactly `groups(_:)`.
    /// - A row present in the assignment stays under its frozen group
    ///   whatever its live state; the row itself (status light, age,
    ///   dimming) still reflects that live state — only its bucket is
    ///   frozen.
    /// - A row absent from the assignment (newly appeared since the freeze)
    ///   goes to its natural group, appended after that group's frozen
    ///   members (the caller passes rows in pinned order, so a new row is
    ///   always last in the incoming array; sequential appends land it
    ///   last in its bucket too).
    /// - A row absent from `rows` (departed) simply is not placed anywhere.
    /// - A kind that appears in the assignment's values but ends up with no
    ///   rows (every member departed) still returns an empty group, so its
    ///   header keeps rendering and nothing above the pointer collapses.
    public static func groups(
        _ rows: [AgentRow],
        frozenAssignment: [RowID: BoardGroup.Kind]?
    ) -> [BoardGroup] {
        guard let frozenAssignment else { return groups(rows) }
        var rowsByKind: [BoardGroup.Kind: [AgentRow]] = [:]
        for row in rows {
            let assignedKind = frozenAssignment[row.id] ?? kind(for: row.state)
            rowsByKind[assignedKind, default: []].append(row)
        }
        let frozenKinds = Set(frozenAssignment.values)
        return BoardGroup.Kind.allCases.compactMap { kind in
            if let rowsForKind = rowsByKind[kind] {
                return BoardGroup(kind: kind, rows: rowsForKind)
            }
            return frozenKinds.contains(kind) ? BoardGroup(kind: kind, rows: []) : nil
        }
    }

    /// A snapshot of `groups(_:)`'s current assignment, keyed by row id.
    /// Captured once when the pointer enters the board and handed back to
    /// `groups(_:frozenAssignment:)` for as long as it stays inside.
    public static func groupAssignment(_ rows: [AgentRow]) -> [RowID: BoardGroup.Kind] {
        Dictionary(rows.map { ($0.id, kind(for: $0.state)) }, uniquingKeysWith: { _, latest in latest })
    }

    /// The board card may use about 60 % of the screen's visible height.
    public static func maximumBoardHeight(visibleFrameHeight: CGFloat) -> CGFloat {
        guard visibleFrameHeight.isFinite, visibleFrameHeight > 0 else { return 0 }
        return visibleFrameHeight * IslandTiming.boardHeightFraction
    }

    /// Stale rows keep the status episode age without claiming ongoing work.
    /// Other rows show their compact age ("47m", "1h 12m").
    public static func ageText(for row: AgentRow, now: Date) -> String {
        let age = SessionDurationFormatter.string(from: row.since, to: now)
        return row.state == .stale ? "stale · \(age)" : age
    }

    /// Offline or disabled feeds are dimmed. Stale text stays readable in its own section.
    public static func dimsRow(_ row: AgentRow, health: FeedHealth?) -> Bool {
        health?.dimsRows == true
    }

    /// A tmux target is shown only when navigation would use it, and capped.
    static let maximumSurfaceTargetLength = 40
    /// A feed warning is one line, capped, whatever its reason carries.
    static let maximumWarningLength = 100

    /// What a row says beside its title, to VoiceOver and in its tooltips.
    /// `title` is the displayed name (a rename wins); `now` drives the age.
    public static func rowText(for row: AgentRow, title: String, health: FeedHealth?, now: Date) -> BoardRowText {
        var context: [String] = []
        if !row.subtitle.isEmpty, normalized(row.subtitle) != normalized(title) {
            context.append(row.subtitle)
        }
        if let surface = surfaceLabel(for: row.jump) {
            context.append(surface)
        }
        let secondary = context.joined(separator: " · ")
        let warning = health.flatMap { health in
            health.showsWarning
                ? singleLine("\(row.source.displayName) \(health.summary)", limit: maximumWarningLength)
                : nil
        }

        let age = SessionDurationFormatter.string(from: row.since, to: now)
        let spoken = [title, row.source.displayName, row.state.accessibilityName, age, secondary, warning ?? ""]
        let help = [detailText(row.detail) ?? (secondary.isEmpty ? title : secondary), warning ?? ""]
        let sourceHelp = [sourceDescription(row.source), warning ?? ""]
        return BoardRowText(
            secondary: secondary,
            accessibilityLabel: spoken.filter { !$0.isEmpty }.joined(separator: ", "),
            help: help.filter { !$0.isEmpty }.joined(separator: "\n"),
            sourceHelp: sourceHelp.filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    /// Where the session runs, when the jump knows it. This is context, not
    /// identity: several sessions can share Claude Desktop or Remote Control.
    /// A tmux target appears only if `JumpPlanner` would switch to it.
    private static func surfaceLabel(for jump: JumpTarget) -> String? {
        switch jump {
        case .claudeDesktop:
            return "Claude Desktop"
        case .claudeRemoteControl:
            return "Remote Control"
        case let .terminal(tmuxTarget):
            guard let tmuxTarget, JumpPlanner.isValidTmuxTarget(tmuxTarget) else { return nil }
            return "tmux \(SessionTitleFormatter.truncate(tmuxTarget, to: maximumSurfaceTargetLength))"
        case .herdrPane, .codexThread:
            return nil
        }
    }

    private static func sourceDescription(_ source: SessionSource) -> String {
        switch source {
        case .herdr: "Herdr pane"
        case .claudeRegistry: "Claude Code session"
        case .codexDesktop: "Codex thread"
        }
    }

    /// The question, error line or recap, with any options as bullets.
    private static func detailText(_ detail: Detail?) -> String? {
        guard let detail, !detail.question.isEmpty else { return nil }
        guard !detail.options.isEmpty else { return detail.question }
        return ([detail.question] + detail.options.map { "• \($0)" }).joined(separator: "\n")
    }

    /// Case-insensitive, with whitespace runs folded, for the repeat check.
    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Control characters and line breaks become spaces, runs fold to one.
    private static func singleLine(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        }
        let folded = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SessionTitleFormatter.truncate(folded, to: limit)
    }
}

/// A board row's context line, VoiceOver label and tooltips (`BoardLayout.rowText`).
public struct BoardRowText: Equatable, Sendable {
    /// Beside the title: a non-repeating subtitle and any known session surface.
    public let secondary: String
    /// Title, source, state, age, context line and any feed warning.
    public let accessibilityLabel: String
    /// The detail when there is one, else the context line (or the title), then any warning.
    public let help: String
    /// The source glyph's tooltip: what the source is, then any warning.
    public let sourceHelp: String
}

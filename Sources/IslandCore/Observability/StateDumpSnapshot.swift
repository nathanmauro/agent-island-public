import Foundation

/// What the pill, board and card look like right now. Written by the app's
/// UIStateReporter; read by the end-to-end driver from the state dump.
public struct UISnapshot: Codable, Equatable, Sendable {
    public var boardExpanded: Bool
    public var cardVisible: Bool
    public var cardDisplayID: UInt32?
    public var pillDisplayIDs: [UInt32]
    public var pillIgnoresMouseEvents: Bool
    public var primaryDisplayID: UInt32?

    public init(boardExpanded: Bool = false, cardVisible: Bool = false, cardDisplayID: UInt32? = nil,
                pillDisplayIDs: [UInt32] = [], pillIgnoresMouseEvents: Bool = false, primaryDisplayID: UInt32? = nil) {
        self.boardExpanded = boardExpanded
        self.cardVisible = cardVisible
        self.cardDisplayID = cardDisplayID
        self.pillDisplayIDs = pillDisplayIDs
        self.pillIgnoresMouseEvents = pillIgnoresMouseEvents
        self.primaryDisplayID = primaryDisplayID
    }
}

/// The JSON written to `$AGENT_ISLAND_STATE_DUMP` (spec §8 StateDump). Encoded with a
/// plain JSONEncoder (default date strategy), so a plain JSONDecoder reads it back.
public struct StateDumpSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var rows: [AgentRow]
    public var summaryText: String
    public var segments: [Summary.Segment]
    public var feedHealth: [String: FeedHealth]          // SessionSource.rawValue → health
    public var peekQueue: PeekQueueSnapshot
    public var chimePlayedCount: Int
    public var plannedJumps: [String: [JumpAction]]      // RowID.description → plan
    public var performedJumps: [[JumpAction]]
    /// I/O errors each feed swallowed rather than surfacing as a health change (controller
    /// ruling, Task 16), keyed by `SessionSource.rawValue`. A feed that does not opt into
    /// `FeedIOErrorCounting` (Herdr today) is omitted entirely: an absent key means "not
    /// tracked", never a false zero.
    public var feedErrorCounts: [String: Int]
    /// The most recent jump failure's `String(describing: error)` (controller ruling, Task
    /// 16), cleared once a later focus succeeds. NotchWidgetView itself still shows only a
    /// generic message; this is for the transition log / a trial run to diagnose from.
    public var lastErrorDescription: String?
    public var ui: UISnapshot

    public init(generatedAt: Date, rows: [AgentRow], summaryText: String, segments: [Summary.Segment],
                feedHealth: [String: FeedHealth], peekQueue: PeekQueueSnapshot, chimePlayedCount: Int,
                plannedJumps: [String: [JumpAction]], performedJumps: [[JumpAction]],
                feedErrorCounts: [String: Int] = [:], lastErrorDescription: String? = nil, ui: UISnapshot) {
        self.generatedAt = generatedAt
        self.rows = rows
        self.summaryText = summaryText
        self.segments = segments
        self.feedHealth = feedHealth
        self.peekQueue = peekQueue
        self.chimePlayedCount = chimePlayedCount
        self.plannedJumps = plannedJumps
        self.performedJumps = performedJumps
        self.feedErrorCounts = feedErrorCounts
        self.lastErrorDescription = lastErrorDescription
        self.ui = ui
    }

    /// Builds a snapshot from the store's typed values, keying health and error counts by
    /// source and planned jumps by row description.
    public init(generatedAt: Date, rows: [AgentRow], summary: Summary, feedHealth: [SessionSource: FeedHealth],
                peekQueue: PeekQueueSnapshot, chimePlayedCount: Int, plannedJumps: [RowID: [JumpAction]],
                performedJumps: [[JumpAction]], feedErrorCounts: [SessionSource: Int] = [:],
                lastErrorDescription: String? = nil, ui: UISnapshot) {
        self.init(
            generatedAt: generatedAt,
            rows: rows,
            summaryText: summary.text,
            segments: summary.segments,
            feedHealth: Dictionary(uniqueKeysWithValues: feedHealth.map { ($0.key.rawValue, $0.value) }),
            peekQueue: peekQueue,
            chimePlayedCount: chimePlayedCount,
            plannedJumps: Dictionary(uniqueKeysWithValues: plannedJumps.map { ($0.key.description, $0.value) }),
            performedJumps: performedJumps,
            feedErrorCounts: Dictionary(uniqueKeysWithValues: feedErrorCounts.map { ($0.key.rawValue, $0.value) }),
            lastErrorDescription: lastErrorDescription,
            ui: ui
        )
    }
}

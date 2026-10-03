import Foundation

/// Where a row comes from. Repurposes Moonglade's single-case `SessionSource`.
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case herdr
    case claudeRegistry
    case codexDesktop

    public var displayName: String {
        switch self {
        case .herdr: "Herdr"
        case .claudeRegistry: "Claude"
        case .codexDesktop: "Codex"
        }
    }
}

/// The island's own state vocabulary. Every feed maps its upstream status onto it.
public enum DisplayState: String, Codable, CaseIterable, Sendable {
    case waiting
    case error
    case working
    case stale
    case doneUnseen
    case idle
    case starting

    /// Waiting and error are the only states that may peek or chime.
    public var isInterrupting: Bool {
        self == .waiting || self == .error
    }

    /// The pill segment this state counts toward. Stale is counted separately;
    /// idle and starting are never counted.
    public var segmentKind: Summary.Segment.Kind? {
        switch self {
        case .error: .error
        case .waiting: .waiting
        case .working: .working
        case .stale: .stale
        case .doneUnseen: .done
        case .idle, .starting: nil
        }
    }

    /// Sort key: lower sorts first.
    public var severityRank: Int {
        switch self {
        case .error: 0
        case .waiting: 1
        case .working: 2
        case .stale: 3
        case .doneUnseen: 4
        case .starting: 5
        case .idle: 6
        }
    }

    /// Words VoiceOver reads for a row in this state.
    public var accessibilityName: String {
        switch self {
        case .waiting: "waiting for you"
        case .error: "error"
        case .working: "working"
        case .stale: "stale, activity unconfirmed"
        case .doneUnseen: "done"
        case .idle: "idle"
        case .starting: "starting"
        }
    }
}

/// Stable identity of a row: the source plus a source-specific key
/// (Herdr pane id, "<pid>@<procStart>" for the registry, Codex thread id).
public struct RowID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let source: SessionSource
    public let key: String

    public init(source: SessionSource, key: String) {
        self.source = source
        self.key = key
    }

    /// "herdr:w14:p9"
    public var description: String {
        "\(source.rawValue):\(key)"
    }

    /// "herdr|w14:p9", used for persisted name overrides and log lines.
    public var storageKey: String {
        "\(source.rawValue)|\(key)"
    }
}

/// The question, permission prompt, error line or recap shown under a row.
public struct Detail: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case question
        case permission
        case error
        case recap
    }

    private static let maximumOptionCount = 4

    public var question: String
    /// At most four option labels; `init` drops the rest.
    public var options: [String]
    public var kind: Kind

    public init(question: String, options: [String] = [], kind: Kind) {
        self.question = question
        self.options = Array(options.prefix(Self.maximumOptionCount))
        self.kind = kind
    }
}

/// What a click on the row should bring to the front.
public enum JumpTarget: Equatable, Codable, Sendable {
    /// `windowTitlePrefix` is "<short hostname>: <workspace label>".
    case herdrPane(paneID: String, windowTitlePrefix: String?)
    case codexThread(id: String)
    case claudeDesktop(sessionID: String, tmuxTarget: String?)
    /// A Claude Remote Control session, driven from Claude Desktop, claude.ai or the mobile app. Its conversation
    /// is addressed by the bridge id ("session_…"), not by the registry's native session id.
    case claudeRemoteControl(bridgeSessionID: String)
    case terminal(tmuxTarget: String?)

    private static let bridgeSessionIDPrefix = "session_"
    private static let maximumBridgeSessionIDSuffixBytes = 64
    private static let bridgeSessionIDSuffixBytes = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8
    )

    /// "session_" followed by 1 to 64 ASCII letters or digits. Shared by the registry decoder and JumpPlanner, so an
    /// id that reaches a URL can never carry a separator, a query or an escape.
    static func isValidBridgeSessionID(_ value: String) -> Bool {
        let prefix = bridgeSessionIDPrefix.utf8
        guard value.utf8.starts(with: prefix) else { return false }
        let suffix = value.utf8.dropFirst(prefix.count)
        guard (1...maximumBridgeSessionIDSuffixBytes).contains(suffix.count) else { return false }
        return suffix.allSatisfy { bridgeSessionIDSuffixBytes.contains($0) }
    }
}

/// One agent session as the island shows it.
public struct AgentRow: Equatable, Identifiable, Codable, Sendable {
    public let id: RowID
    /// Always equal to `id.source`.
    public let source: SessionSource
    public var title: String
    public var subtitle: String
    public var state: DisplayState
    /// Island-observed time of the last DisplayState change (or the source's own timestamp).
    public var since: Date
    public var detail: Detail?
    public var jump: JumpTarget
    /// Working directory, for the branch lookup, Copy Path and Reveal.
    public var cwd: String?
    /// Herdr foreground pids, or the registry pid. RowMerger deduplicates on these.
    public var processIDs: [Int32]
    /// The raw upstream status (Herdr agent_status, registry status, Codex last record).
    public var sourceStatus: String?
    /// Opaque source-issued identity of the result this row can acknowledge.
    /// A captured row must never acknowledge a newer result after an async jump.
    public var acknowledgmentID: String?

    public init(
        id: RowID,
        title: String,
        subtitle: String,
        state: DisplayState,
        since: Date,
        detail: Detail? = nil,
        jump: JumpTarget,
        cwd: String? = nil,
        processIDs: [Int32] = [],
        sourceStatus: String? = nil,
        acknowledgmentID: String? = nil
    ) {
        self.id = id
        self.source = id.source
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.since = since
        self.detail = detail
        self.jump = jump
        self.cwd = cwd
        self.processIDs = processIDs
        self.sourceStatus = sourceStatus
        self.acknowledgmentID = acknowledgmentID
    }
}

/// A feed's connection health. Offline and disabled feeds show a warning glyph
/// and dim their (kept) rows; inactive feeds are silent. A degraded feed is online and
/// its rows are live, but something it serves (today: Herdr jumps) does not work, so it
/// shows the warning glyph without dimming.
public enum FeedHealth: Equatable, Codable, Sendable {
    case online
    case inactive(reason: String)
    case offline(reason: String)
    case disabled(reason: String)
    case degraded(reason: String)

    public var showsWarning: Bool {
        switch self {
        case .offline, .disabled, .degraded: true
        case .online, .inactive: false
        }
    }

    public var dimsRows: Bool {
        switch self {
        case .offline, .disabled: true
        case .online, .inactive, .degraded: false
        }
    }

    public var isOnline: Bool {
        switch self {
        case .online, .degraded: true
        case .inactive, .offline, .disabled: false
        }
    }

    /// One line for the glyph tooltip and the transition log.
    public var summary: String {
        switch self {
        case .online: "online"
        case let .inactive(reason): "inactive: \(reason)"
        case let .offline(reason): "offline: \(reason)"
        case let .disabled(reason): "disabled: \(reason)"
        case let .degraded(reason): "degraded: \(reason)"
        }
    }
}

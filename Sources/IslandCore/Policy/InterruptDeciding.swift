import Foundation

/// A request to show one peek card for a row.
public struct PeekEvent: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case waiting
        case error
    }

    public let rowID: RowID
    public let kind: Kind
    public let question: String?
    public let at: Date

    public init(rowID: RowID, kind: Kind, question: String?, at: Date) {
        self.rowID = rowID
        self.kind = kind
        self.question = question
        self.at = at
    }
}

/// Why the policy did (or did not) interrupt. Raw values are the transition-log words.
public enum PolicyRule: String, Codable, Sendable {
    case peekWaiting = "peek.waiting"
    case peekError = "peek.error"
    case chime = "chime"
    case chimeGap = "suppressed.chime-gap"
    case holdPending = "hold.pending"
    case episodeRepeat = "suppressed.episode"
    case quietPeriod = "suppressed.quiet"
    case looking = "suppressed.looking"
}

public struct PolicyNote: Equatable, Codable, Sendable {
    public let rowID: RowID
    public let rule: PolicyRule
    public let at: Date

    public init(rowID: RowID, rule: PolicyRule, at: Date) {
        self.rowID = rowID
        self.rule = rule
        self.at = at
    }
}

/// The spec's (peeks, chime) pair, plus log notes and the next time the policy
/// wants to be asked again (for example when a 1 s blocked hold matures).
public struct PolicyDecision: Equatable, Sendable {
    public var peeks: [PeekEvent]
    public var chime: Bool
    public var notes: [PolicyNote]
    public var nextDeadline: Date?

    public init(peeks: [PeekEvent] = [], chime: Bool = false, notes: [PolicyNote] = [], nextDeadline: Date? = nil) {
        self.peeks = peeks
        self.chime = chime
        self.notes = notes
        self.nextDeadline = nextDeadline
    }

    public static let none = PolicyDecision()
}

/// Spec §7.4. Pure: every input, including the time, is passed in.
public protocol InterruptDeciding {
    mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision
    mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date)
}

/// The policy StateStore uses until the real InterruptPolicy is wired: never interrupts.
public struct NoInterrupts: InterruptDeciding, Sendable {
    public init() {}

    public mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision {
        .none
    }

    public mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date) {}
}

public struct PeekQueueSnapshot: Equatable, Codable, Sendable {
    public var current: RowID?
    public var pending: [RowID]
    public var moreCount: Int

    public init(current: RowID? = nil, pending: [RowID] = [], moreCount: Int = 0) {
        self.current = current
        self.pending = pending
        self.moreCount = moreCount
    }
}

/// Read by the state dump: what the peek layer is showing and how often it chimed.
@MainActor
public protocol PeekStatusProviding: AnyObject {
    var peekQueueSnapshot: PeekQueueSnapshot { get }
    var chimePlayedCount: Int { get }
}

import Foundation

public struct HealthChange: Equatable, Sendable {
    public let source: SessionSource
    public let from: FeedHealth?
    public let to: FeedHealth

    public init(source: SessionSource, from: FeedHealth?, to: FeedHealth) {
        self.source = source
        self.from = from
        self.to = to
    }
}

/// Everything one store update produced, handed to change observers
/// (peek coordinator, transition log, state dump) in registration order.
public struct StoreChange: Equatable, Sendable {
    public let at: Date
    public let previousRows: [AgentRow]
    public let rows: [AgentRow]
    public let decision: PolicyDecision
    /// Herdr RowID → the dropped registry row's sourceStatus (spec §5.2 soak diagnostic).
    public let registryShadow: [RowID: String]
    public let healthChanges: [HealthChange]

    public init(
        at: Date,
        previousRows: [AgentRow],
        rows: [AgentRow],
        decision: PolicyDecision,
        registryShadow: [RowID: String],
        healthChanges: [HealthChange]
    ) {
        self.at = at
        self.previousRows = previousRows
        self.rows = rows
        self.decision = decision
        self.registryShadow = registryShadow
        self.healthChanges = healthChanges
    }
}

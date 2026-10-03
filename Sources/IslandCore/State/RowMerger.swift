import Foundation

public struct MergeResult: Equatable, Sendable {
    public let rows: [AgentRow]
    public let registryShadow: [RowID: String]

    public init(rows: [AgentRow], registryShadow: [RowID: String]) {
        self.rows = rows
        self.registryShadow = registryShadow
    }
}

/// Cross-source deduplication and ordering (spec §5, §5.2).
public enum RowMerger {
    /// Drops claudeRegistry rows whose processIDs intersect any herdr row's processIDs
    /// (Herdr is authoritative for its panes), records their sourceStatus in
    /// registryShadow keyed by the matching herdr row, then sorts with `precedes`.
    public static func merge(_ rowsBySource: [SessionSource: [AgentRow]]) -> MergeResult {
        var herdrRowByProcessID: [Int32: RowID] = [:]
        for row in rowsBySource[.herdr] ?? [] {
            for processID in row.processIDs where herdrRowByProcessID[processID] == nil {
                herdrRowByProcessID[processID] = row.id
            }
        }

        var merged: [AgentRow] = []
        var shadow: [RowID: String] = [:]
        for source in SessionSource.allCases {
            for row in rowsBySource[source] ?? [] {
                if source == .claudeRegistry,
                   let herdrID = row.processIDs.lazy.compactMap({ herdrRowByProcessID[$0] }).first {
                    if let status = row.sourceStatus {
                        shadow[herdrID] = status
                    }
                    continue
                }
                merged.append(row)
            }
        }
        merged.sort(by: precedes)
        return MergeResult(rows: merged, registryShadow: shadow)
    }

    /// severityRank ascending, then since descending (newest first), then
    /// id.description ascending so equal rows still sort deterministically.
    public static func precedes(_ lhs: AgentRow, _ rhs: AgentRow) -> Bool {
        if lhs.state.severityRank != rhs.state.severityRank {
            return lhs.state.severityRank < rhs.state.severityRank
        }
        if lhs.since != rhs.since {
            return lhs.since > rhs.since
        }
        return lhs.id.description < rhs.id.description
    }
}

import Foundation

/// The pill's counts. Segments come in the fixed order error, waiting,
/// working, stale, done; zero counts are omitted; idle and
/// starting rows are never counted.
public struct Summary: Equatable, Codable, Sendable {
    public struct Segment: Equatable, Codable, Sendable, Identifiable {
        /// Declaration order is display order.
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case error
            case waiting
            case working
            case stale
            case done
        }

        public let kind: Kind
        public let count: Int

        public var id: Kind {
            kind
        }

        /// "2 working"
        public var label: String {
            "\(count) \(kind.rawValue)"
        }

        public init(kind: Kind, count: Int) {
            self.kind = kind
            self.count = count
        }
    }

    public let segments: [Segment]
    public let staleCount: Int
    /// Idle plus starting rows. They never appear in `segments`.
    public let idleCount: Int

    /// True when nothing is counted; idle and starting rows alone leave the summary empty.
    public var isEmpty: Bool {
        segments.isEmpty
    }

    /// Segment labels joined by " · "; "" when there is nothing to count.
    public var text: String {
        segments.map(\.label).joined(separator: " · ")
    }

    public init(rows: [AgentRow]) {
        var counts: [Segment.Kind: Int] = [:]
        var stale = 0
        var idle = 0
        for row in rows {
            switch row.state {
            case .stale: stale += 1
            case .idle, .starting: idle += 1
            default: break
            }
            if let kind = row.state.segmentKind {
                counts[kind, default: 0] += 1
            }
        }
        segments = Segment.Kind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return Segment(kind: kind, count: count)
        }
        staleCount = stale
        idleCount = idle
    }
}

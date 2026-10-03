import Foundation

/// One line of `transitions.jsonl` (spec §9). Built from a StoreChange only, so the
/// log answers "what made that sound?" and "why didn't I see X?" without guessing.
/// Nil fields are omitted from the JSON line.
public struct TransitionRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case state, peek, chime, suppressed, feed
        /// A jump the user triggered failed after the row was marked seen (controller
        /// ruling, Task 16). Never produced by `records(for:)`, because a jump failure is
        /// not part of a StoreChange; see `jumpFailure(rowID:description:at:)`.
        case jump
    }

    public let ts: Date
    public let kind: Kind
    public let source: String?
    public let rowID: String?
    public let from: String?
    public let to: String?
    public let rule: String?
    public let question: String?
    public let registryStatus: String?

    /// `to` value of a state record for a row that left the store.
    public static let removedState = "removed"

    public init(ts: Date, kind: Kind, source: String? = nil, rowID: String? = nil, from: String? = nil,
                to: String? = nil, rule: String? = nil, question: String? = nil, registryStatus: String? = nil) {
        self.ts = ts
        self.kind = kind
        self.source = source
        self.rowID = rowID
        self.from = from
        self.to = to
        self.rule = rule
        self.question = question
        self.registryStatus = registryStatus
    }

    /// Records for one store change, in this order: feed health changes; row state
    /// changes (new rows have `from` nil, removed rows have `to` "removed"); peeks;
    /// the chime; then suppression notes. Notes whose rule is a peek or the chime are
    /// skipped because the peek and chime records already carry them. A store change
    /// where nothing actually changed (the policy heartbeat) produces no records at all.
    public static func records(for change: StoreChange) -> [TransitionRecord] {
        let ts = change.at
        var records: [TransitionRecord] = []

        for health in change.healthChanges {
            records.append(TransitionRecord(ts: ts, kind: .feed, source: health.source.rawValue,
                                            from: health.from?.summary, to: health.to.summary))
        }

        let previousByID = Dictionary(change.previousRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentByID = Dictionary(change.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for row in change.rows {
            let before = previousByID[row.id]
            guard before?.state != row.state else { continue }
            let question = row.state.isInterrupting ? row.detail.map { truncateQuestion($0.question) } : nil
            records.append(TransitionRecord(ts: ts, kind: .state, source: row.source.rawValue,
                                            rowID: row.id.description, from: before?.state.rawValue,
                                            to: row.state.rawValue, question: question,
                                            registryStatus: change.registryShadow[row.id]))
        }
        for row in change.previousRows where currentByID[row.id] == nil {
            records.append(TransitionRecord(ts: ts, kind: .state, source: row.source.rawValue,
                                            rowID: row.id.description, from: row.state.rawValue,
                                            to: removedState))
        }

        for peek in change.decision.peeks {
            let rule: PolicyRule = peek.kind == .error ? .peekError : .peekWaiting
            records.append(TransitionRecord(ts: ts, kind: .peek, source: peek.rowID.source.rawValue,
                                            rowID: peek.rowID.description, rule: rule.rawValue,
                                            question: peek.question.map(truncateQuestion)))
        }

        // Controller ruling: every chime (not just every peek) carries its rule and a
        // truncated question, so the log alone answers "what made that sound?".
        if change.decision.chime {
            let first = change.decision.peeks.first
            records.append(TransitionRecord(ts: ts, kind: .chime, source: first?.rowID.source.rawValue,
                                            rowID: first?.rowID.description, rule: PolicyRule.chime.rawValue,
                                            question: first?.question.map(truncateQuestion)))
        }

        for note in change.decision.notes {
            switch note.rule {
            case .peekWaiting, .peekError, .chime:
                continue
            case .chimeGap, .holdPending, .episodeRepeat, .quietPeriod, .looking:
                let question = currentByID[note.rowID]?.detail.map { truncateQuestion($0.question) }
                records.append(TransitionRecord(ts: ts, kind: .suppressed, source: note.rowID.source.rawValue,
                                                rowID: note.rowID.description, rule: note.rule.rawValue,
                                                question: question))
            }
        }
        return records
    }

    /// The first `IslandTiming.questionLogLimit` (200) characters.
    public static func truncateQuestion(_ text: String) -> String {
        String(text.prefix(IslandTiming.questionLogLimit))
    }

    /// Encoder for log lines: one compact JSON object, sorted keys, ISO 8601 `ts` with milliseconds.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(logDateStyle))
        }
        return encoder
    }

    /// Decoder matching `makeEncoder()`.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return try logDateStyle.parse(try container.decode(String.self))
        }
        return decoder
    }

    private static let logDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

extension TransitionRecord {
    /// A jump the user triggered failed after the row was marked seen (controller ruling,
    /// Task 16): `String(describing: error)` from `jumpPerformer.perform`, truncated like a
    /// question so a verbose label can never blow out a log line. StateStore records this
    /// into `lastErrorDescription` and rethrows; ObservabilityWiring appends the record built
    /// here.
    public static func jumpFailure(rowID: RowID, description: String, at ts: Date) -> TransitionRecord {
        TransitionRecord(ts: ts, kind: .jump, source: rowID.source.rawValue, rowID: rowID.description,
                         to: truncateQuestion(description))
    }

    /// `rule` value of a `feed`-kind record built from a feed's own diagnostic message
    /// (controller ruling, Task 16), rather than a health change. Both a diagnostic and a
    /// feed's first health report have no `from`, so this is the only thing that tells them
    /// apart.
    public static let diagnosticRule = "diagnostic"

    /// A feed's own diagnostic (today only Herdr's pane-stream-cap notice) — not a health
    /// change, so it is discriminated from one by `rule: diagnosticRule`.
    public static func diagnostic(source: SessionSource, message: String, at ts: Date) -> TransitionRecord {
        TransitionRecord(ts: ts, kind: .feed, source: source.rawValue, to: message, rule: diagnosticRule)
    }
}

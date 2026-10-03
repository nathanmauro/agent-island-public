import Foundation

/// Spec §7.4: which rows peek, and whether the one chime plays.
///
/// Pure and deterministic. Every time value comes from the `now` argument, and the policy keeps its
/// own per-row memory, so a later call with the same rows (StateStore's `tick()` at a deadline)
/// completes a 1 s hold. `prev` is accepted for the protocol; the memory below is authoritative
/// because StateStore calls `decide` on every merge and every tick.
///
/// Rules:
/// - Only `waiting` and `error` interrupt. `doneUnseen`, `working`, `stale`, `idle` and `starting` never do.
/// - `waiting` must hold for `blockedHold` (1 s) before it peeks. The hold starts at the first `decide`
///   that sees the row waiting.
/// - One peek per waiting episode. A row that re-enters waiting within `episodeGap` (10 s) of leaving
///   it continues the same episode; an announced episode does not peek again (`suppressed.episode`).
///   A new episode needs 10 s out of waiting, or a question whose `questionKey` (its letters, lowercased)
///   was not yet announced in the current blocked stretch. The stretch is the run of waiting that
///   re-entries within 10 s continue; it ends after 10 s out of waiting or when the row is forgotten.
///   Counters, spinner glyphs, whitespace and punctuation never make a new question, and a question
///   flapping back to an announced one stays quiet. nil → text is not a change. A new episode must hold 1 s.
/// - While a hold is pending, a question change keeps the hold's start and only takes the latest text,
///   so a row whose text flaps faster than the hold still peeks once, at the original due time.
/// - `error` peeks immediately on every transition into error.
/// - Quiet period (launch, reconnect, wake): a waiting episode whose hold began before the quiet window
///   ended, evaluated at or after the window started, is suppressed (`suppressed.quiet`) and marked
///   announced, so it never peeks when the window ends. An error inside the window is suppressed too.
/// - Looking (FocusContext.isLooking): suppressed (`suppressed.looking`) and marked announced.
/// - Chime: at most one per decision, when it has at least one peek and at least `chimeGap` (3 s)
///   passed since the last chime; otherwise the peeks still show and a `suppressed.chime-gap` note is added.
/// - Clock moving backwards: a running hold restarts at `now`; negative gaps count as elapsed.
public struct InterruptPolicy: InterruptDeciding, Sendable {
    public struct Configuration: Equatable, Sendable {
        public var blockedHold: TimeInterval
        public var episodeGap: TimeInterval
        public var chimeGap: TimeInterval
        public var quietPeriod: TimeInterval

        public init(blockedHold: TimeInterval, episodeGap: TimeInterval, chimeGap: TimeInterval, quietPeriod: TimeInterval) {
            self.blockedHold = blockedHold
            self.episodeGap = episodeGap
            self.chimeGap = chimeGap
            self.quietPeriod = quietPeriod
        }

        /// 1 s hold, 10 s episode gap, 3 s chime gap, 10 s quiet period.
        public static let standard = Configuration(
            blockedHold: IslandTiming.blockedHold,
            episodeGap: IslandTiming.episodeGap,
            chimeGap: IslandTiming.chimeGap,
            quietPeriod: IslandTiming.quietPeriod
        )
    }

    private struct RowMemory: Equatable, Sendable {
        /// State seen by the last `decide`; nil once the row is absent from `next`.
        var state: DisplayState?
        /// Set while the row is waiting in an episode that is not announced yet.
        var holdStart: Date?
        /// The current (or last) waiting episode already peeked or was suppressed.
        var announced = false
        /// Latest question text of the current (or last) waiting episode; only texts with letters count.
        var question: String?
        /// When the row last left waiting (start of the episode gap).
        var leftWaitingAt: Date?
        /// Question keys seen during the current episode, including while its hold was pending.
        var episodeKeys: Set<String> = []
        /// Question keys already announced (peeked or suppressed) during the current blocked stretch.
        var announcedKeys: Set<String> = []

        /// Starts a waiting episode that must hold 1 s from `now`.
        mutating func startEpisode(_ text: String?, key: String?, at now: Date) {
            announced = false
            question = text
            episodeKeys = key.map { [$0] } ?? []
            holdStart = now
        }

        /// Takes `text` as the episode's latest question without starting a new episode.
        mutating func absorb(_ text: String?, key: String?) {
            guard let text, let key else { return }
            question = text
            episodeKeys.insert(key)
            if announced { announcedKeys.insert(key) }
        }

        /// True when `key` is a question this stretch has not announced yet. With no announced key
        /// (the episode peeked before any text arrived), the first text is adopted, not a change.
        func isNewQuestion(_ key: String?) -> Bool {
            guard announced, let key, !announcedKeys.isEmpty else { return false }
            return !announcedKeys.contains(key)
        }
    }

    private struct QuietWindow: Equatable, Sendable {
        var start: Date
        var end: Date
    }

    public let configuration: Configuration
    private var memory: [RowID: RowMemory] = [:]
    private var quietWindows: [SessionSource: QuietWindow] = [:]
    private var lastChimeAt: Date?

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision {
        var errorPeeks: [PeekEvent] = []
        var waitingPeeks: [PeekEvent] = []
        var notes: [PolicyNote] = []
        var nextDeadline: Date?

        // Rows that vanished leave waiting now; they keep their episode memory for the gap.
        let presentIDs = Set(next.map(\.id))
        let vanishedIDs = memory.keys.filter { !presentIDs.contains($0) && memory[$0]?.state != nil }
        for id in vanishedIDs {
            guard var entry = memory[id] else { continue }
            if entry.state == .waiting { entry.leftWaitingAt = now }
            entry.state = nil
            entry.holdStart = nil
            memory[id] = entry
        }

        for row in next {
            var entry = memory[row.id] ?? RowMemory()
            let previousState = entry.state
            switch row.state {
            case .waiting:
                // A text without letters (a bare counter or spinner) carries no question identity.
                let question = Self.waitingQuestion(of: row)
                let key = question.map(Self.questionKey).flatMap { $0.isEmpty ? nil : $0 }
                let text = key == nil ? nil : question
                if previousState != .waiting {
                    let withinGap = entry.leftWaitingAt.map { Self.isWithin(now, since: $0, gap: configuration.episodeGap) } ?? false
                    if !withinGap {
                        // A new blocked stretch: nothing has been announced in it yet.
                        entry.announcedKeys = []
                        entry.startEpisode(text, key: key, at: now)
                        notes.append(PolicyNote(rowID: row.id, rule: .holdPending, at: now))
                    } else if entry.isNewQuestion(key) {
                        // Back within 10 s with a question this stretch has not announced.
                        entry.startEpisode(text, key: key, at: now)
                        notes.append(PolicyNote(rowID: row.id, rule: .holdPending, at: now))
                    } else if entry.announced {
                        // The same episode continues, and it already announced.
                        entry.absorb(text, key: key)
                        entry.holdStart = nil
                        notes.append(PolicyNote(rowID: row.id, rule: .episodeRepeat, at: now))
                    } else {
                        // The same episode never announced (the 0.3 s flicker): its hold restarts.
                        entry.absorb(text, key: key)
                        entry.holdStart = now
                        notes.append(PolicyNote(rowID: row.id, rule: .holdPending, at: now))
                    }
                } else if entry.isNewQuestion(key) {
                    // Still waiting, a question this stretch has not announced: a new episode, which must hold again.
                    entry.startEpisode(text, key: key, at: now)
                    notes.append(PolicyNote(rowID: row.id, rule: .holdPending, at: now))
                } else {
                    // The same question, a counter or spinner change, text arriving late, or any change while
                    // the hold is pending: the hold keeps its start and the episode takes the latest text.
                    entry.absorb(text, key: key)
                }
                entry.state = .waiting

                if !entry.announced, var start = entry.holdStart {
                    if now < start {
                        start = now
                        entry.holdStart = now
                    }
                    let due = start.addingTimeInterval(configuration.blockedHold)
                    if now >= due {
                        entry.announced = true
                        entry.announcedKeys.formUnion(entry.episodeKeys)
                        entry.holdStart = nil
                        if let rule = suppression(for: row, episodeStart: start, focus: focus, now: now) {
                            notes.append(PolicyNote(rowID: row.id, rule: rule, at: now))
                        } else {
                            waitingPeeks.append(PeekEvent(rowID: row.id, kind: .waiting, question: entry.question, at: now))
                            notes.append(PolicyNote(rowID: row.id, rule: .peekWaiting, at: now))
                        }
                    } else if nextDeadline.map({ due < $0 }) ?? true {
                        nextDeadline = due
                    }
                }

            case .error:
                if previousState == .waiting {
                    entry.leftWaitingAt = now
                    entry.holdStart = nil
                }
                if previousState != .error {
                    if let rule = suppression(for: row, episodeStart: now, focus: focus, now: now) {
                        notes.append(PolicyNote(rowID: row.id, rule: rule, at: now))
                    } else {
                        errorPeeks.append(PeekEvent(rowID: row.id, kind: .error, question: Self.errorLine(of: row), at: now))
                        notes.append(PolicyNote(rowID: row.id, rule: .peekError, at: now))
                    }
                }
                entry.state = .error

            case .working, .stale, .doneUnseen, .idle, .starting:
                if previousState == .waiting {
                    entry.leftWaitingAt = now
                    entry.holdStart = nil
                }
                entry.state = row.state
            }
            memory[row.id] = entry
        }

        let peeks = errorPeeks + waitingPeeks
        var chime = false
        if let first = peeks.first {
            if let last = lastChimeAt, Self.isWithin(now, since: last, gap: configuration.chimeGap) {
                notes.append(PolicyNote(rowID: first.rowID, rule: .chimeGap, at: now))
            } else {
                chime = true
                lastChimeAt = now
                notes.append(PolicyNote(rowID: first.rowID, rule: .chime, at: now))
            }
        }

        forgetExpiredRows(now: now)
        return PolicyDecision(peeks: peeks, chime: chime, notes: notes, nextDeadline: nextDeadline)
    }

    public mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date) {
        let end = now.addingTimeInterval(configuration.quietPeriod)
        for source in sources {
            if let window = quietWindows[source], now >= window.start, now < window.end {
                quietWindows[source] = QuietWindow(start: window.start, end: max(window.end, end))
            } else {
                quietWindows[source] = QuietWindow(start: now, end: end)
            }
        }
    }

    // MARK: - Helpers

    private func suppression(for row: AgentRow, episodeStart: Date, focus: FocusContext, now: Date) -> PolicyRule? {
        if let window = quietWindows[row.source], now >= window.start, episodeStart < window.end {
            return .quietPeriod
        }
        if focus.isLooking(at: row) {
            return .looking
        }
        return nil
    }

    /// True while `now` is less than `gap` after `earlier`. A negative interval (clock moved
    /// backwards) counts as elapsed, so a clock change never silences the island.
    private static func isWithin(_ now: Date, since earlier: Date, gap: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(earlier)
        return elapsed >= 0 && elapsed < gap
    }

    /// Drops memory of absent rows once their episode gap has passed (bounded under pane churn).
    private mutating func forgetExpiredRows(now: Date) {
        let expired = memory.compactMap { id, entry -> RowID? in
            guard entry.state == nil else { return nil }
            guard let left = entry.leftWaitingAt else { return id }
            return Self.isWithin(now, since: left, gap: configuration.episodeGap) ? nil : id
        }
        for id in expired {
            memory.removeValue(forKey: id)
        }
    }

    static func waitingQuestion(of row: AgentRow) -> String? {
        guard let detail = row.detail, detail.kind == .question || detail.kind == .permission else { return nil }
        return nonEmpty(detail.question)
    }

    static func errorLine(of row: AgentRow) -> String? {
        guard let detail = row.detail else { return nil }
        return nonEmpty(detail.question)
    }

    /// A question's identity for episodes: only its Unicode letters (general category L*), lowercased.
    /// Digits, whitespace, punctuation, spinner glyphs and box drawing are dropped, so a counter or
    /// spinner frame changing is not a new question. Whole characters are kept, so a decomposed accent
    /// compares equal to the precomposed one.
    public static func questionKey(_ text: String) -> String {
        text.lowercased().filter { character in
            guard let scalar = character.unicodeScalars.first else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                return true
            default:
                return false
            }
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

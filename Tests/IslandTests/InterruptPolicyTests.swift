import Foundation
import IslandCore
import IslandTestSupport

// MARK: - Helpers

/// Drives one InterruptPolicy with a ManualWallClock. Every call moves the clock to t0 + offset
/// and passes `clock.now()` as `now`, the way StateStore does.
private final class PolicyDriver {
    let clock = ManualWallClock()
    let t0: Date
    var policy: InterruptPolicy
    var focus = FocusContext()
    private(set) var rows: [AgentRow] = []
    private(set) var peeks: [PeekEvent] = []
    private(set) var chimes = 0
    private(set) var notes: [PolicyNote] = []

    init(policy: InterruptPolicy = InterruptPolicy()) {
        self.policy = policy
        t0 = clock.now()
    }

    func time(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    /// A feed published `next` at t0 + offset.
    @discardableResult
    func publish(_ next: [AgentRow], at offset: TimeInterval) -> PolicyDecision {
        clock.set(time(offset))
        let decision = policy.decide(prev: rows, next: next, focus: focus, now: clock.now())
        rows = next
        peeks += decision.peeks
        if decision.chime { chimes += 1 }
        notes += decision.notes
        return decision
    }

    /// StateStore.tick at t0 + offset: the same rows again.
    @discardableResult
    func tick(at offset: TimeInterval) -> PolicyDecision {
        publish(rows, at: offset)
    }

    func quiet(_ sources: Set<SessionSource>, at offset: TimeInterval) {
        clock.set(time(offset))
        policy.beginQuietPeriod(for: sources, at: clock.now())
    }

    func notes(_ rule: PolicyRule) -> [PolicyNote] {
        notes.filter { $0.rule == rule }
    }
}

private let policyAllSources = Set(SessionSource.allCases)

private func policyHerdrRow(_ key: String, _ state: DisplayState, question: String? = nil,
                            options: [String] = [], kind: Detail.Kind = .question) -> AgentRow {
    AgentRow.fixture(
        source: .herdr, key: key, state: state,
        detail: question.map { Detail(question: $0, options: options, kind: kind) },
        jump: .herdrPane(paneID: key, windowTitlePrefix: nil)
    )
}

private func policyCodexRow(_ key: String, _ state: DisplayState, question: String? = nil) -> AgentRow {
    AgentRow.fixture(
        source: .codexDesktop, key: key, state: state,
        detail: question.map { Detail(question: $0, kind: .question) },
        jump: .codexThread(id: key)
    )
}

private func policyHerdrID(_ key: String) -> RowID { RowID(source: .herdr, key: key) }

// MARK: - Hold

func testPolicyWaitingUnderOneSecondNeverPeeks() throws {
    let d = PolicyDriver()
    let first = d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    try expect(first.peeks, equals: [], "no peek before the hold")
    try expect(first.nextDeadline, equals: d.time(1), "deadline at transition + 1 s")
    try expect(d.notes(.holdPending).count, equals: 1, "hold.pending noted once")
    let back = d.publish([policyHerdrRow("w1:p1", .working)], at: 0.9)
    try expect(back.nextDeadline, equals: nil, "no deadline once the row left waiting")
    d.tick(at: 1)
    d.tick(at: 2)
    try expect(d.peeks.count, equals: 0, "0.9 s of waiting never peeks")
    try expect(d.chimes, equals: 0, "and never chimes")
}

func testPolicyWaitingHeldOneSecondPeeksOnceWithChime() throws {
    let d = PolicyDriver()
    let row = policyHerdrRow("w1:p1", .waiting, question: "Allow the edit?", options: ["Yes", "No"], kind: .permission)
    let early = d.publish([row], at: 0)
    try expect(early.nextDeadline, equals: d.time(1), "decided early: deadline at transition + 1 s")
    let midway = d.tick(at: 0.5)
    try expect(midway.peeks, equals: [], "still holding at 0.5 s")
    try expect(midway.nextDeadline, equals: d.time(1), "deadline unchanged while holding")
    let due = d.tick(at: 1)
    try expect(due.peeks, equals: [PeekEvent(rowID: policyHerdrID("w1:p1"), kind: .waiting, question: "Allow the edit?", at: d.time(1))],
               "one waiting peek at the deadline")
    try expect(due.chime, equals: true, "with the chime")
    try expect(due.nextDeadline, equals: nil, "nothing left to wait for")
    d.tick(at: 2)
    d.tick(at: 30)
    try expect(d.peeks.count, equals: 1, "one peek per episode")
    try expect(d.chimes, equals: 1, "one chime per episode")
}

func testPolicyRecordedFlickerGivesOnePeekAndOneChime() throws {
    // Spec §7.4 / §12.1: the observed blocked → done → blocked flicker 0.3 s apart.
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    d.publish([policyHerdrRow("w1:p1", .doneUnseen)], at: 0.3)
    let back = d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0.6)
    try expect(back.nextDeadline, equals: d.time(1.6), "the hold restarts when waiting comes back")
    d.tick(at: 1.0)
    try expect(d.peeks.count, equals: 0, "the first hold never completed")
    d.tick(at: 1.6)
    d.tick(at: 3)
    d.tick(at: 15)
    try expect(d.peeks.count, equals: 1, "exactly one peek")
    try expect(d.chimes, equals: 1, "exactly one chime")
    try expect(d.peeks.first?.at, equals: d.time(1.6), "peek once the second waiting held 1 s")
}

// MARK: - Episodes

func testPolicySameQuestionWithinTenSecondsIsTheSameEpisode() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .working)], at: 2)
    let again = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 11.9)
    try expect(again.nextDeadline, equals: nil, "an announced episode does not hold again")
    try expect(again.notes.map(\.rule), equals: [.episodeRepeat], "suppressed.episode noted")
    d.tick(at: 13)
    d.tick(at: 25)
    try expect(d.peeks.count, equals: 1, "no second peek within the episode")
    try expect(d.chimes, equals: 1, "no second chime")
}

func testPolicyTenSecondsOutOfWaitingStartsANewEpisode() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .working)], at: 2)
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 12)
    try expect(d.peeks.count, equals: 1, "the new episode holds first")
    d.tick(at: 13)
    try expect(d.peeks.count, equals: 2, "a new peek after 10 s out of waiting")
    try expect(d.chimes, equals: 2, "and a new chime (12 s after the first)")
}

func testPolicyChangedQuestionStartsANewEpisode() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Question A")], at: 0)
    d.tick(at: 1)
    // Still waiting, the question text changes: a new episode that holds 1 s.
    let changed = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Question B")], at: 3)
    try expect(changed.nextDeadline, equals: d.time(4), "the new question holds 1 s")
    d.tick(at: 4)
    try expect(d.peeks.map(\.question), equals: ["Question A", "Question B"], "a peek per question")
    // Leaves and comes back within 10 s with yet another question: new episode again.
    d.publish([policyHerdrRow("w1:p1", .working)], at: 5)
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Question C")], at: 7)
    d.tick(at: 8)
    try expect(d.peeks.map(\.question), equals: ["Question A", "Question B", "Question C"], "re-entry with a new question peeks")
}

func testPolicyQuestionArrivingLaterIsNotAChange() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    d.tick(at: 1)
    try expect(d.peeks.first?.question, equals: nil, "peeked before the detection text arrived")
    let loaded = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Question A")], at: 2)
    try expect(loaded.notes, equals: [], "nil → text is not a new episode")
    d.tick(at: 3)
    try expect(d.peeks.count, equals: 1, "no second peek for the late text")
    // The late text became the episode's question, so a different text afterwards is a change.
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Question B")], at: 4)
    d.tick(at: 5)
    try expect(d.peeks.map(\.question), equals: [nil, "Question B"], "A → B starts a new episode")
}

// MARK: - Chime gap

func testPolicyTwoRowsTwoSecondsApartChimeOnce() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .waiting)], at: 2)
    let second = d.tick(at: 3)
    try expect(second.peeks.map(\.rowID), equals: [policyHerdrID("w1:p2")], "the second row still peeks")
    try expect(second.chime, equals: false, "no chime 2 s after the last one")
    try expect(second.notes.filter { $0.rule == .chimeGap }.map(\.rowID), equals: [policyHerdrID("w1:p2")], "suppressed.chime-gap noted")
    try expect(d.peeks.count, equals: 2, "2 peeks")
    try expect(d.chimes, equals: 1, "1 chime")
}

func testPolicyTwoRowsThreeSecondsApartChimeTwice() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .waiting)], at: 3)
    d.tick(at: 4)
    try expect(d.peeks.count, equals: 2, "2 peeks")
    try expect(d.chimes, equals: 2, "3 s apart: 2 chimes")
}

// MARK: - Quiet period

func testPolicyQuietPeriodSilencesRowsAlreadyWaiting() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p0", .waiting)], at: -0.5)   // waiting before the quiet period began
    d.quiet(policyAllSources, at: 0)
    d.publish([policyHerdrRow("w1:p0", .waiting), policyHerdrRow("w1:p1", .waiting), policyCodexRow("t1", .waiting)], at: 0)
    d.tick(at: 1)
    d.tick(at: 5)
    try expect(d.peeks.count, equals: 0, "no peek during the quiet period")
    try expect(d.chimes, equals: 0, "no chime during the quiet period")
    try expect(Set(d.notes(.quietPeriod).map(\.rowID)),
               equals: [policyHerdrID("w1:p0"), policyHerdrID("w1:p1"), RowID(source: .codexDesktop, key: "t1")],
               "each row noted as suppressed.quiet")
    d.tick(at: 10.5)
    d.tick(at: 30)
    try expect(d.peeks.count, equals: 0, "those episodes were announced: nothing when the period ends")
}

func testPolicyNewWaitingAfterQuietPeriodPeeks() throws {
    let d = PolicyDriver()
    d.quiet(policyAllSources, at: 0)
    d.publish([policyHerdrRow("w1:p1", .working)], at: 1)
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 10.2)
    d.tick(at: 11.2)
    try expect(d.peeks.map(\.rowID), equals: [policyHerdrID("w1:p1")], "a waiting that starts after the period peeks")
    try expect(d.chimes, equals: 1, "with a chime")
}

func testPolicyHerdrOnlyQuietStillLetsCodexPeek() throws {
    let d = PolicyDriver()
    d.quiet([.herdr], at: 0)
    d.publish([policyHerdrRow("w1:p1", .waiting), policyCodexRow("t1", .waiting)], at: 1)
    d.tick(at: 2)
    try expect(d.peeks.map(\.rowID), equals: [RowID(source: .codexDesktop, key: "t1")], "only codex peeks")
    try expect(d.notes(.quietPeriod).map(\.rowID), equals: [policyHerdrID("w1:p1")], "herdr is quiet")
    try expect(d.chimes, equals: 1, "one chime, for the codex card")
}

// MARK: - Looking

func testPolicyLookingSuppressesAndAnnouncesTheEpisode() throws {
    let d = PolicyDriver()
    d.focus = FocusContext(frontmostBundleID: KnownBundleIDs.ghostty, herdrFocusedPaneID: "w1:p1")
    d.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .waiting)], at: 0)
    d.tick(at: 1)
    try expect(d.peeks.map(\.rowID), equals: [policyHerdrID("w1:p2")], "only the pane Nathan is not looking at peeks")
    try expect(d.notes(.looking).map(\.rowID), equals: [policyHerdrID("w1:p1")], "suppressed.looking noted")
    d.focus = FocusContext(frontmostBundleID: "com.apple.finder")
    d.tick(at: 3)
    d.tick(at: 20)
    try expect(d.peeks.count, equals: 1, "looking away later does not re-announce the episode")

    let c = PolicyDriver()
    c.focus = FocusContext(frontmostBundleID: KnownBundleIDs.codex)
    c.publish([policyCodexRow("t1", .waiting)], at: 0)
    c.tick(at: 1)
    try expect(c.peeks.count, equals: 0, "Codex frontmost suppresses a codex row")
    try expect(c.notes(.looking).count, equals: 1, "noted as looking")
}

// MARK: - Never interrupting states

func testPolicyQuietStatesNeverPeekOrChime() throws {
    let d = PolicyDriver()
    let states: [DisplayState] = [.doneUnseen, .working, .stale, .idle, .starting]
    for step in 0..<20 {
        let rows = (0..<5).map { index in
            policyHerdrRow("w1:p\(index)", states[(index + step) % states.count])
        }
        let decision = d.publish(rows, at: TimeInterval(step) * 3)
        try expect(decision.nextDeadline, equals: nil, "no hold for step \(step)")
        d.tick(at: TimeInterval(step) * 3 + 1.5)
    }
    try expect(d.peeks.count, equals: 0, "never peek")
    try expect(d.chimes, equals: 0, "never chime")
}

// MARK: - Error

func testPolicyErrorPeeksImmediately() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .working), policyHerdrRow("w1:p2", .waiting)], at: 0)
    let failed = d.publish([policyHerdrRow("w1:p1", .error, question: "exited while working", kind: .error),
                            policyHerdrRow("w1:p2", .error, question: "exited while blocked", kind: .error)], at: 0.5)
    try expect(failed.peeks, equals: [
        PeekEvent(rowID: policyHerdrID("w1:p1"), kind: .error, question: "exited while working", at: d.time(0.5)),
        PeekEvent(rowID: policyHerdrID("w1:p2"), kind: .error, question: "exited while blocked", at: d.time(0.5)),
    ], "both errors peek at once, no hold")
    try expect(failed.chime, equals: true, "one chime for the decision")
    d.tick(at: 1)
    d.tick(at: 20)
    try expect(d.peeks.count, equals: 2, "an error row peeks once per transition; the cut-off waiting never peeks")

    let mixed = PolicyDriver()
    mixed.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .working)], at: 0)
    let both = mixed.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .error)], at: 1)
    try expect(both.peeks.map(\.kind), equals: [.error, .waiting], "errors come first in a decision")
}

func testPolicyHerdrReconnectKeepsRepublishedRowsQuiet() throws {
    // Review Focus 1: Herdr restarts; its rows vanish, then come back after the reconnect,
    // which StateStore answers with beginQuietPeriod([.herdr]).
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting), policyCodexRow("t1", .working)], at: 0)
    d.tick(at: 1)
    try expect(d.peeks.count, equals: 1, "the first episode peeked")
    d.publish([policyCodexRow("t1", .working)], at: 5)            // Herdr went away
    d.quiet([.herdr], at: 30)                              // reconnected
    d.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .waiting), policyCodexRow("t1", .waiting)], at: 30.2)
    d.tick(at: 31.5)
    d.tick(at: 45)
    try expect(d.peeks.map(\.rowID), equals: [policyHerdrID("w1:p1"), RowID(source: .codexDesktop, key: "t1")],
               "after the reconnect only the codex row peeks")
    try expect(Set(d.notes(.quietPeriod).map(\.rowID)), equals: [policyHerdrID("w1:p1"), policyHerdrID("w1:p2")],
               "both re-published herdr rows are quiet")
    try expect(d.chimes, equals: 2, "no chime storm: one per peek")
}

// MARK: - Hardening: sleep/wake after hours (Review Focus 5)

func testPolicyWakeAfterSixHoursQuietsTheBurst() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p0", .waiting)], at: 0)            // hold started; the machine slept before the tick
    let wake: TimeInterval = 6 * 3_600
    d.quiet(policyAllSources, at: wake)                           // NSWorkspace.didWake → StateStore.beginQuietPeriod(all)
    var burst = [policyHerdrRow("w1:p0", .waiting)]
    for (index, offset) in [0.0, 2, 4, 6, 9.5].enumerated() {
        burst.append(policyHerdrRow("w2:p\(index)", .waiting))
        d.publish(burst, at: wake + offset)
        d.tick(at: wake + offset + 1.1)
    }
    d.tick(at: wake + 15)
    d.tick(at: wake + 40)
    try expect(d.peeks.count, equals: 0, "0 peeks after the 6 h jump")
    try expect(d.chimes, equals: 0, "0 chimes after the 6 h jump")
    try expect(d.notes(.quietPeriod).count, equals: 6, "the stale hold and all 5 burst rows are quiet")
    d.publish(burst + [policyHerdrRow("w3:p1", .waiting)], at: wake + 50)
    d.tick(at: wake + 51)
    try expect(d.peeks.map(\.rowID), equals: [policyHerdrID("w3:p1")], "the policy still peeks for a genuinely new episode")
}

func testPolicyClockMovingBackwardsNeitherPinsNorSilences() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting)], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .waiting), policyHerdrRow("w1:p2", .waiting)], at: -3_600)
    d.tick(at: -3_599)
    try expect(d.peeks.count, equals: 2, "a hold after the clock went back still completes")
    try expect(d.chimes, equals: 2, "a negative chime gap counts as elapsed")

    let e = PolicyDriver()
    e.publish([policyHerdrRow("w1:p1", .waiting)], at: 100)
    let rewound = e.tick(at: 50)
    try expect(rewound.nextDeadline, equals: e.time(51), "the hold restarts at the earlier time")
    e.tick(at: 51)
    try expect(e.peeks.count, equals: 1, "and completes 1 s later")
}

// MARK: - PeekQueue

private func queueEvent(_ key: String, _ kind: PeekEvent.Kind, at offset: TimeInterval, question: String? = nil,
                        clock: ManualWallClock) -> PeekEvent {
    PeekEvent(rowID: policyHerdrID(key), kind: kind, question: question, at: clock.now().addingTimeInterval(offset))
}

func testPolicyQueueOrdersErrorsFirstThenNewest() throws {
    let clock = ManualWallClock()
    let t0 = clock.now()
    var queue = PeekQueue()
    let w1 = queueEvent("w1:p1", .waiting, at: 1, clock: clock)
    let w2 = queueEvent("w1:p2", .waiting, at: 2, clock: clock)
    let e1 = queueEvent("w1:p3", .error, at: 3, clock: clock)
    let w3 = queueEvent("w1:p4", .waiting, at: 4, clock: clock)
    clock.set(t0.addingTimeInterval(1))
    queue.enqueue([w1], now: clock.now())
    clock.set(t0.addingTimeInterval(2))
    queue.enqueue([w2], now: clock.now())
    try expect(queue.current, equals: w2, "the newer waiting takes the card")
    try expect(queue.pending, equals: [w1], "the older one waits")
    clock.set(t0.addingTimeInterval(3))
    queue.enqueue([e1], now: clock.now())
    try expect(queue.current, equals: e1, "an error outranks waiting")
    clock.set(t0.addingTimeInterval(4))
    queue.enqueue([w3], now: clock.now())
    try expect(queue.current, equals: e1, "a newer waiting does not displace an error")
    try expect(queue.pending, equals: [w3, w2, w1], "pending: newest first within waiting")
    try expect(queue.shownAt, equals: t0.addingTimeInterval(3), "the error card keeps its start time")
}

func testPolicyQueueOneEntryPerRowAndMoreCount() throws {
    let clock = ManualWallClock()
    let t0 = clock.now()
    var queue = PeekQueue()
    let a = queueEvent("w1:p1", .waiting, at: 1, question: "Question A", clock: clock)
    let b = queueEvent("w1:p2", .waiting, at: 2, clock: clock)
    let c = queueEvent("w1:p3", .waiting, at: 3, clock: clock)
    clock.set(t0.addingTimeInterval(3))
    queue.enqueue([a, b, c], now: clock.now())
    try expect(queue.moreCount, equals: 2, "moreCount equals pending.count")
    let a2 = queueEvent("w1:p1", .waiting, at: 5, question: "Question A2", clock: clock)
    clock.set(t0.addingTimeInterval(5))
    queue.enqueue([a2], now: clock.now())
    try expect(queue.current, equals: a2, "re-enqueue replaces the row's entry and, being newest, shows")
    try expect(queue.pending, equals: [c, b], "the old entry for that row is gone")
    try expect(queue.moreCount, equals: queue.pending.count, "moreCount still equals pending.count")
    try expect(queue.shownAt, equals: t0.addingTimeInterval(5), "a replaced card restarts its duration")
}

func testPolicyQueuePruneDropsRowsThatMovedOn() throws {
    let clock = ManualWallClock()
    let t0 = clock.now()
    var queue = PeekQueue()
    let a = queueEvent("w1:p1", .waiting, at: 1, clock: clock)
    let b = queueEvent("w1:p2", .waiting, at: 2, clock: clock)
    let e = queueEvent("w1:p3", .error, at: 3, clock: clock)
    clock.set(t0.addingTimeInterval(3))
    queue.enqueue([a, b, e], now: clock.now())
    queue.prune(rows: [policyHerdrRow("w1:p1", .working), policyHerdrRow("w1:p2", .waiting), policyHerdrRow("w1:p3", .idle)])
    try expect(queue.current, equals: nil, "the error row recovered: its card is dropped")
    try expect(queue.shownAt, equals: nil, "no card, no start time")
    try expect(queue.pending, equals: [b], "the row that left waiting is dropped")
    queue.prune(rows: [policyHerdrRow("w1:p2", .error)])
    try expect(queue.pending, equals: [], "a waiting event needs a waiting row")
}

func testPolicyQueueAdvanceExpiresAfterEightSecondsUnlessHovered() throws {
    let clock = ManualWallClock()
    let t0 = clock.now()
    var queue = PeekQueue()
    let a = queueEvent("w1:p1", .waiting, at: 0, clock: clock)
    let b = queueEvent("w1:p2", .waiting, at: 1, clock: clock)
    clock.set(t0.addingTimeInterval(1))
    queue.enqueue([a, b], now: clock.now())
    try expect(queue.current, equals: b, "newest first")
    clock.set(t0.addingTimeInterval(8.9))
    try expect(queue.advance(now: clock.now(), isHovered: false), equals: false, "7.9 s: still showing")
    clock.set(t0.addingTimeInterval(9))
    try expect(queue.advance(now: clock.now(), isHovered: true), equals: false, "hovered: stays open")
    try expect(queue.advance(now: clock.now(), isHovered: false), equals: true, "8 s and not hovered: expires")
    try expect(queue.current, equals: a, "the pending card is promoted")
    try expect(queue.shownAt, equals: t0.addingTimeInterval(9), "with a fresh start time")
    clock.set(t0.addingTimeInterval(17))
    try expect(queue.advance(now: clock.now(), isHovered: false), equals: true, "the second card expires too")
    try expect(queue.current, equals: nil, "queue empty")
    try expect(queue.advance(now: clock.now(), isHovered: false), equals: false, "nothing left to advance")
}

func testPolicyQueueSnapshotAndDismiss() throws {
    let clock = ManualWallClock()
    let t0 = clock.now()
    var queue = PeekQueue()
    let a = queueEvent("w1:p1", .waiting, at: 0, clock: clock)
    let b = queueEvent("w1:p2", .waiting, at: 1, clock: clock)
    clock.set(t0.addingTimeInterval(1))
    queue.enqueue([a, b], now: clock.now())
    try expect(queue.snapshot(), equals: PeekQueueSnapshot(current: policyHerdrID("w1:p2"), pending: [policyHerdrID("w1:p1")], moreCount: 1),
               "snapshot matches the queue")
    queue.dismissCurrent()
    try expect(queue.snapshot(), equals: PeekQueueSnapshot(current: nil, pending: [policyHerdrID("w1:p1")], moreCount: 1),
               "dismissCurrent drops only the current card")
    clock.set(t0.addingTimeInterval(2))
    try expect(queue.advance(now: clock.now(), isHovered: false), equals: true, "the next advance promotes")
    try expect(queue.current, equals: a, "the pending card shows")
}

// MARK: - Question flaps: the hold survives them, and episodes are keyed by the normalized question

/// Publishes one waiting row with `texts` in rotation every `interval` s from `start` through `end`.
/// Before each publish it ticks at every `nextDeadline` that has come due, the way StateStore does.
/// Returns the last pending deadline.
@discardableResult
private func policyFlap(_ d: PolicyDriver, key: String, texts: [String], every interval: TimeInterval,
                        from start: TimeInterval, through end: TimeInterval, deadline: Date?) -> Date? {
    var deadline = deadline
    var step = 0
    while start + Double(step) * interval <= end {
        let offset = start + Double(step) * interval
        while let due = deadline, due <= d.time(offset) {
            deadline = d.tick(at: due.timeIntervalSince(d.t0)).nextDeadline
        }
        deadline = d.publish([policyHerdrRow(key, .waiting, question: texts[step % texts.count])], at: offset).nextDeadline
        step += 1
    }
    return deadline
}

func testPolicyPendingHoldSurvivesQuestionFlaps() throws {
    for interval in [0.5, 0.9] {
        let d = PolicyDriver()
        let first = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Allow? a")], at: 0)
        policyFlap(d, key: "w1:p1", texts: ["Allow? b", "Allow? a"], every: interval, from: interval, through: 30,
                   deadline: first.nextDeadline)
        d.tick(at: 31)
        d.tick(at: 45)
        try expect(d.peeks.count, equals: 1, "text flapping every \(interval) s during the hold: exactly one peek")
        try expect(d.chimes, equals: 1, "text flapping every \(interval) s: exactly one chime")
        try expect(d.peeks.first?.at, equals: d.time(1), "\(interval) s: the peek comes at the original due time")
        try expect(d.peeks.first?.question, equals: "Allow? b", "\(interval) s: with the latest text")
        try expect(d.notes(.holdPending).count, equals: 1, "\(interval) s: the hold started once")
    }
}

func testPolicyFlappingAfterAnnounceGivesOnePeekPerQuestion() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Allow? a")], at: 0)
    d.tick(at: 1)
    try expect(d.peeks.count, equals: 1, "announced with the first text")
    policyFlap(d, key: "w1:p1", texts: ["Allow? b", "Allow? a"], every: 1.5, from: 1.5, through: 31, deadline: nil)
    d.tick(at: 32)
    d.tick(at: 45)
    try expect(d.peeks.map(\.question), equals: ["Allow? a", "Allow? b"], "a/b every 1.5 s for 30 s: one peek per question")
    try expectTrue(d.chimes <= 2, "at most 2 chimes (got \(d.chimes))")
}

func testPolicyCounterOrSpinnerChangesAreTheSameQuestion() throws {
    let cases: [[String]] = [
        ["Running… 3s", "Running… 4s", "Running… 5s"],
        ["⠋ Allow?", "⠙ Allow?", "⠹ Allow?"],
    ]
    for texts in cases {
        let d = PolicyDriver()
        d.publish([policyHerdrRow("w1:p1", .waiting, question: texts[0])], at: 0)
        d.tick(at: 1)
        policyFlap(d, key: "w1:p1", texts: Array(texts.dropFirst()) + [texts[0]], every: 1.5, from: 2, through: 20, deadline: nil)
        d.tick(at: 25)
        try expect(d.peeks.count, equals: 1, "\(texts[0]) …: a counter or spinner change is not a new question")
        try expect(d.chimes, equals: 1, "\(texts[0]) …: one chime")
    }
}

func testPolicyNewQuestionInTheSameStretchStillPeeks() throws {
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 0)
    d.tick(at: 1)
    let second = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Delete the branch?")], at: 2)
    try expect(second.nextDeadline, equals: d.time(3), "a question with different letters holds 1 s")
    let due = d.tick(at: 3)
    try expect(due.peeks.map(\.question), equals: ["Delete the branch?"], "and then peeks")
    try expect(due.chime, equals: false, "2 s after the last chime: the 3 s gap applies")
    try expect(due.notes.filter { $0.rule == .chimeGap }.count, equals: 1, "suppressed.chime-gap noted")
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Push to origin?")], at: 5)
    let third = d.tick(at: 6)
    try expect(third.chime, equals: true, "5 s after the last chime: chimes again")
    try expect(d.peeks.map(\.question), equals: ["Run the tests?", "Delete the branch?", "Push to origin?"], "a peek per new question")
}

func testPolicyAnnouncedQuestionsLastForTheStretch() throws {
    // A stretch is the run of waiting that re-entries within 10 s continue. An announced question stays
    // announced for the whole stretch, and the next stretch starts with no announced questions.
    let d = PolicyDriver()
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 0)
    d.tick(at: 1)
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Delete the branch?")], at: 2)
    d.tick(at: 3)
    d.publish([policyHerdrRow("w1:p1", .working)], at: 4)
    let back = d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 6)
    try expect(back.notes.map(\.rule), equals: [.episodeRepeat], "an earlier question returning within 10 s is the same stretch")
    d.tick(at: 7)
    try expect(d.peeks.map(\.question), equals: ["Run the tests?", "Delete the branch?"], "no peek for the returning question")
    d.publish([policyHerdrRow("w1:p1", .working)], at: 8)
    d.publish([policyHerdrRow("w1:p1", .waiting, question: "Run the tests?")], at: 18)
    d.tick(at: 19)
    try expect(d.peeks.map(\.question), equals: ["Run the tests?", "Delete the branch?", "Run the tests?"],
               "after 10 s out of waiting a new stretch starts, and the question peeks again")
}

func testPolicyQuestionKeyKeepsOnlyLowercasedLetters() throws {
    let key = InterruptPolicy.questionKey
    try expect(key("Running… 3s"), equals: "runnings", "digits, spaces and the ellipsis are dropped")
    try expect(key("Running… 4s"), equals: key("Running… 3s"), "a counter change keeps the key")
    try expect(key("⠋ Allow?"), equals: "allow", "a braille spinner glyph is dropped")
    try expect(key("⠙ Allow?"), equals: key("⠋ Allow?"), "a spinner frame change keeps the key")
    try expect(key("Allow? a"), equals: "allowa", "letters are kept, lowercased")
    try expect(key("Allow? b") == key("Allow? a"), equals: false, "different letters give a different key")
    try expect(key("│ Run the tests?  ─\n"), equals: "runthetests", "box drawing, whitespace and punctuation are dropped")
    try expect(key("RUN the Tests"), equals: key("run THE tests"), "case does not matter")
    try expect(key("12:34 … ⠿ ✔ ─"), equals: "", "a text without letters has an empty key")
    try expect(key("Café Ünïcödé 日本語"), equals: "caféünïcödé日本語", "letters beyond ASCII are kept")
    try expect(key("Cafe\u{301}"), equals: key("Caf\u{E9}"), "decomposed and precomposed accents give the same key")
}

let interruptPolicyTests: [TestCase] = [
    ("policy: waiting for 0.9 s then working never peeks", testPolicyWaitingUnderOneSecondNeverPeeks),
    ("policy: waiting held 1 s peeks once with a chime and a deadline at transition + 1 s", testPolicyWaitingHeldOneSecondPeeksOnceWithChime),
    ("policy: the recorded 0.3 s flicker gives exactly one peek and one chime", testPolicyRecordedFlickerGivesOnePeekAndOneChime),
    ("policy: re-entering waiting within 10 s with the same question does not peek", testPolicySameQuestionWithinTenSecondsIsTheSameEpisode),
    ("policy: 10 s out of waiting starts a new episode", testPolicyTenSecondsOutOfWaitingStartsANewEpisode),
    ("policy: a changed question starts a new episode", testPolicyChangedQuestionStartsANewEpisode),
    ("policy: a question arriving after the peek is not a change", testPolicyQuestionArrivingLaterIsNotAChange),
    ("policy: two rows peeking 2 s apart give 2 peeks and 1 chime", testPolicyTwoRowsTwoSecondsApartChimeOnce),
    ("policy: two rows peeking 3 s apart give 2 chimes", testPolicyTwoRowsThreeSecondsApartChimeTwice),
    ("policy: a quiet period silences rows already waiting, even after it ends", testPolicyQuietPeriodSilencesRowsAlreadyWaiting),
    ("policy: a new waiting after the quiet period peeks", testPolicyNewWaitingAfterQuietPeriodPeeks),
    ("policy: a herdr-only quiet period still lets a codex row peek", testPolicyHerdrOnlyQuietStillLetsCodexPeek),
    ("policy: looking suppresses and announces the episode", testPolicyLookingSuppressesAndAnnouncesTheEpisode),
    ("policy: done, working, stale, idle and starting never peek or chime", testPolicyQuietStatesNeverPeekOrChime),
    ("policy: a transition into error peeks immediately", testPolicyErrorPeeksImmediately),
    ("policy: hardening 1 - rows re-published after a Herdr reconnect stay quiet", testPolicyHerdrReconnectKeepsRepublishedRowsQuiet),
    ("policy: hardening 5 - a 6 h clock jump and the wake quiet period give 0 peeks for a burst", testPolicyWakeAfterSixHoursQuietsTheBurst),
    ("policy: a clock moving backwards neither pins a hold nor silences chimes", testPolicyClockMovingBackwardsNeitherPinsNorSilences),
    ("policy: queue orders errors first, then newest", testPolicyQueueOrdersErrorsFirstThenNewest),
    ("policy: queue keeps one entry per row and moreCount equals pending", testPolicyQueueOneEntryPerRowAndMoreCount),
    ("policy: queue prune drops rows that left waiting or error", testPolicyQueuePruneDropsRowsThatMovedOn),
    ("policy: queue advance expires after 8 s unless hovered", testPolicyQueueAdvanceExpiresAfterEightSecondsUnlessHovered),
    ("policy: queue snapshot matches and dismissCurrent drops only the card", testPolicyQueueSnapshotAndDismiss),
    ("policy: question text flapping during the hold gives one peek at the original due time", testPolicyPendingHoldSurvivesQuestionFlaps),
    ("policy: a/b flapping after the announce gives one peek per question", testPolicyFlappingAfterAnnounceGivesOnePeekPerQuestion),
    ("policy: a counter or spinner change is not a new question", testPolicyCounterOrSpinnerChangesAreTheSameQuestion),
    ("policy: a genuinely new question in the same stretch peeks, subject to the chime gap", testPolicyNewQuestionInTheSameStretchStillPeeks),
    ("policy: an announced question stays announced for the stretch", testPolicyAnnouncedQuestionsLastForTheStretch),
    ("policy: questionKey keeps only lowercased Unicode letters", testPolicyQuestionKeyKeepsOnlyLowercasedLetters),
]

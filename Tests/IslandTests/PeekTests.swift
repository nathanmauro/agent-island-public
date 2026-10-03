import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Fakes and helpers

@MainActor
private final class FakeCardPresenter: CardPresenting {
    enum Call: Equatable {
        case present(PeekCard)
        case dismiss
    }

    private(set) var presented: [PeekCard] = []
    private(set) var dismissCount = 0
    /// Every present and dismiss, in order (the chime audit reads it).
    private(set) var calls: [Call] = []
    /// The card on the panel right now, nil after a dismiss.
    private(set) var showing: PeekCard?
    var isCardHovered = false
    /// False models a present while no display exists: the panel stays hidden.
    var hasDisplay = true

    var isCardVisible: Bool { showing != nil && hasDisplay }

    func present(_ card: PeekCard) {
        presented.append(card)
        calls.append(.present(card))
        showing = card
    }

    func dismissCard() {
        dismissCount += 1
        calls.append(.dismiss)
        showing = nil
    }
}

@MainActor
private final class FakeChime: ChimePlaying {
    private(set) var playedCount = 0
    /// Runs inside play(), before it returns (the chime audit checks the presenter there).
    var onPlay: (() -> Void)?

    func play() {
        playedCount += 1
        onPlay?()
    }
}

@MainActor
private final class CoordinatorHarness {
    let clock = ManualWallClock()
    let presenter = FakeCardPresenter()
    let chime = FakeChime()
    var muted = false
    private(set) var coordinator: PeekCoordinator!

    init() {
        coordinator = PeekCoordinator(
            presenter: presenter,
            chime: chime,
            clock: clock,
            isMuted: { [unowned self] in self.muted },
            scheduler: .manual
        )
    }

    func time(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offset)
    }

    /// Delivers one StoreChange at t0 + offset (the clock moves there too).
    func change(_ rows: [AgentRow], peeks: [PeekEvent] = [], chime: Bool = false, at offset: TimeInterval) {
        clock.set(time(offset))
        coordinator.handle(StoreChange(
            at: clock.now(),
            previousRows: [],
            rows: rows,
            decision: PolicyDecision(peeks: peeks, chime: chime),
            registryShadow: [:],
            healthChanges: []
        ))
    }

    func tick(at offset: TimeInterval) {
        clock.set(time(offset))
        coordinator.tick()
    }

    func peek(_ row: AgentRow, _ kind: PeekEvent.Kind = .waiting, at offset: TimeInterval) -> PeekEvent {
        PeekEvent(rowID: row.id, kind: kind, question: row.detail?.question, at: time(offset))
    }
}

private func peekWaitingRow(_ key: String, question: String? = nil, options: [String] = []) -> AgentRow {
    AgentRow.fixture(source: .herdr, key: key, state: .waiting,
                     detail: question.map { Detail(question: $0, options: options, kind: .question) },
                     jump: .herdrPane(paneID: key, windowTitlePrefix: nil))
}

private func peekErrorRow(_ key: String, line: String? = nil) -> AgentRow {
    AgentRow.fixture(source: .herdr, key: key, state: .error,
                     detail: line.map { Detail(question: $0, kind: .error) },
                     jump: .herdrPane(paneID: key, windowTitlePrefix: nil))
}

private func peekWorkingRow(_ key: String) -> AgentRow {
    AgentRow.fixture(source: .herdr, key: key, state: .working,
                     jump: .herdrPane(paneID: key, windowTitlePrefix: nil))
}

// MARK: - Coordinator

@MainActor
func testPeekOnePeekWithChimePresentsOnceAndPlaysOnce() throws {
    let h = CoordinatorHarness()
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.count, equals: 1, "present called once")
    try expect(h.presenter.presented.first?.row, equals: row, "the card carries the row")
    try expect(h.presenter.presented.first?.moreCount, equals: 0, "nothing else pending")
    try expect(h.chime.playedCount, equals: 1, "chime played once")
    h.change([row], at: 0.5)
    try expect(h.presenter.presented.count, equals: 1, "an unchanged card is not presented again")
    try expect(h.chime.playedCount, equals: 1, "and does not chime again")
}

@MainActor
func testPeekMutedChimeStillPresents() throws {
    let h = CoordinatorHarness()
    h.muted = true
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.count, equals: 1, "muted still presents the card")
    try expect(h.chime.playedCount, equals: 0, "muted plays nothing")
    try expect(h.coordinator.chimePlayedCount, equals: 0, "chimePlayedCount unchanged")
}

@MainActor
func testPeekChimeGapDecisionPresentsWithoutChime() throws {
    let h = CoordinatorHarness()
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: false, at: 0)
    try expect(h.presenter.presented.count, equals: 1, "the peek still shows")
    try expect(h.chime.playedCount, equals: 0, "no chime inside the 3 s gap")
}

@MainActor
func testPeekDecisionWithoutPeeksNeverChimes() throws {
    let h = CoordinatorHarness()
    h.change([peekWaitingRow("w1:p1")], peeks: [], chime: true, at: 0)
    try expect(h.presenter.presented.count, equals: 0, "nothing to present")
    try expect(h.chime.playedCount, equals: 0, "a chime without a card never plays")
}

@MainActor
func testPeekTwoPeeksShowMostSevereWithMoreCount() throws {
    let h = CoordinatorHarness()
    let waiting = peekWaitingRow("w1:p1")
    let failed = peekErrorRow("w1:p2", line: "exited while working")
    h.change([failed, waiting], peeks: [h.peek(failed, .error, at: 0), h.peek(waiting, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.count, equals: 1, "one card")
    try expect(h.presenter.presented.last?.event.kind, equals: .error, "the most severe shows")
    try expect(h.presenter.presented.last?.moreCount, equals: 1, "+1 more")
    try expect(h.chime.playedCount, equals: 1, "one chime for the decision")
    try expect(h.coordinator.peekQueueSnapshot,
               equals: PeekQueueSnapshot(current: failed.id, pending: [waiting.id], moreCount: 1),
               "PeekStatusProviding snapshot")
}

@MainActor
func testPeekNewerWaitingTakesTheCardAndChimes() throws {
    let h = CoordinatorHarness()
    let first = peekWaitingRow("w1:p1")
    let second = peekWaitingRow("w1:p2")
    h.change([first], peeks: [h.peek(first, at: 0)], chime: true, at: 0)
    h.change([first, second], peeks: [h.peek(second, at: 4)], chime: true, at: 4)
    try expect(h.presenter.presented.map(\.row.id), equals: [first.id, second.id], "the newer waiting card shows")
    try expect(h.presenter.presented.last?.moreCount, equals: 1, "the first is still pending")
    try expect(h.chime.playedCount, equals: 2, "each presented new card chimed")
}

/// Final-review F4 (erratum to the T14 brief L221 / plan L29127): a new peek that queues behind the
/// shown card re-presents it with "+1 more", and that visible card is the card for the new event, so
/// the policy's chime plays. Before, it was swallowed while the policy still spent the 3 s gap and the
/// log wrote a chime.
@MainActor
func testPeekPlusMoreCardChimesForTheQueuedEvent() throws {
    let h = CoordinatorHarness()
    let failed = peekErrorRow("w1:p1")
    let waiting = peekWaitingRow("w1:p2")
    h.change([failed], peeks: [h.peek(failed, .error, at: 0)], chime: true, at: 0)
    h.change([failed, waiting], peeks: [h.peek(waiting, at: 4)], chime: true, at: 4)
    try expect(h.presenter.presented.count, equals: 2, "the error card is re-presented with +1 more")
    try expect(h.presenter.presented.last?.event.kind, equals: .error, "the error keeps the card")
    try expect(h.presenter.presented.last?.moreCount, equals: 1, "+1 more")
    try expect(h.chime.playedCount, equals: 2, "the +1 more card is the visible card for the new event")
    h.change([failed, waiting], at: 5)
    try expect(h.chime.playedCount, equals: 2, "an unchanged card does not chime again")
    h.presenter.hasDisplay = false
    let third = peekWaitingRow("w1:p3")
    h.change([failed, waiting, third], peeks: [h.peek(third, at: 6)], chime: true, at: 6)   // within the error card's 8 s
    try expect(h.presenter.presented.last?.moreCount, equals: 2, "+2 more")
    try expect(h.chime.playedCount, equals: 2, "still no sound without a visible card")
}

@MainActor
func testPeekRowLeavingWaitingPrunesAndAdvances() throws {
    let h = CoordinatorHarness()
    let first = peekWaitingRow("w1:p1")
    let second = peekWaitingRow("w1:p2")
    h.change([first, second], peeks: [h.peek(first, at: 0), h.peek(second, at: 1)], chime: true, at: 1)
    try expect(h.presenter.presented.last?.row.id, equals: second.id, "newest first")
    h.change([first, peekWorkingRow("w1:p2")], at: 2)
    try expect(h.presenter.presented.last?.row.id, equals: first.id, "the card advances to the remaining row")
    try expect(h.presenter.presented.last?.moreCount, equals: 0, "nothing more pending")
    try expect(h.presenter.dismissCount, equals: 0, "advanced, not dismissed")
    h.change([peekWorkingRow("w1:p1"), peekWorkingRow("w1:p2")], at: 3)
    try expect(h.presenter.dismissCount, equals: 1, "the last card is dismissed")
    try expect(h.coordinator.peekQueueSnapshot, equals: PeekQueueSnapshot(), "queue empty")
    try expect(h.chime.playedCount, equals: 1, "pruning never chimes")
}

@MainActor
func testPeekTickDismissesAfterEightSecondsUnlessHovered() throws {
    let h = CoordinatorHarness()
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    h.tick(at: 7.9)
    try expect(h.presenter.dismissCount, equals: 0, "still up at 7.9 s")
    h.presenter.isCardHovered = true
    h.tick(at: 8)
    h.tick(at: 12)
    try expect(h.presenter.dismissCount, equals: 0, "held open while hovered")
    h.presenter.isCardHovered = false
    h.tick(at: 12.5)
    try expect(h.presenter.dismissCount, equals: 1, "dismissed once unhovered past 8 s")
    try expect(h.coordinator.queue.current, equals: nil, "queue has no current card")
}

@MainActor
func testPeekCardClickedReturnsRowAndDismisses() throws {
    let h = CoordinatorHarness()
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    try expect(h.coordinator.cardClicked(), equals: row.id, "the clicked row is returned")
    try expect(h.presenter.dismissCount, equals: 1, "the card is dismissed")
    try expect(h.coordinator.peekQueueSnapshot.current, equals: nil, "no current card")
    try expect(h.coordinator.cardClicked(), equals: nil, "a second click has nothing to return")
}

@MainActor
func testPeekCardUpdatesInPlaceWhenTheQuestionArrives() throws {
    let h = CoordinatorHarness()
    let bare = peekWaitingRow("w1:p1")
    h.change([bare], peeks: [h.peek(bare, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.last?.bodyText, equals: "needs you", "fallback before detection text")
    let loaded = peekWaitingRow("w1:p1", question: "Run the migration?", options: ["Yes", "No"])
    h.change([loaded], at: 0.4)
    try expect(h.presenter.presented.count, equals: 2, "re-presented with the loaded row")
    try expect(h.presenter.presented.last?.bodyText, equals: "Run the migration?", "question shown")
    try expect(h.presenter.presented.last?.optionLabels, equals: ["Yes", "No"], "options shown")
    try expect(h.chime.playedCount, equals: 1, "an update never chimes")
}

func testPeekCardTextFallbacksAndLimits() throws {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let many = peekWaitingRow("w1:p1", question: "Pick one", options: ["A", "B", "C", "D", "E"])
    let manyCard = PeekCard(event: PeekEvent(rowID: many.id, kind: .waiting, question: "Pick one", at: at), row: many, moreCount: 0)
    try expect(manyCard.optionLabels, equals: ["A", "B", "C", "D"], "at most 4 options")
    let captured = PeekCard(event: PeekEvent(rowID: many.id, kind: .waiting, question: "Captured", at: at),
                            row: peekWaitingRow("w1:p1"), moreCount: 0)
    try expect(captured.bodyText, equals: "Captured", "the event's question when the row has none")
    let failed = peekErrorRow("w1:p2", line: "exited while working")
    let errorCard = PeekCard(event: PeekEvent(rowID: failed.id, kind: .error, question: nil, at: at), row: failed, moreCount: 2)
    try expect(errorCard.bodyText, equals: "exited while working", "the error line")
    try expect(errorCard.optionLabels, equals: [], "no options on an error card")
    let bareError = PeekCard(event: PeekEvent(rowID: failed.id, kind: .error, question: nil, at: at), row: peekErrorRow("w1:p2"), moreCount: 0)
    try expect(bareError.bodyText, equals: "stopped with an error", "error fallback")
}

// MARK: - Controller rulings 2 and 3 (Task 13 review): promotion, and no chime without a card

@MainActor
func testPeekClickPromotesThePendingCardAtOnceSilently() throws {
    let h = CoordinatorHarness()
    let waiting = peekWaitingRow("w1:p1")
    let failed = peekErrorRow("w1:p2", line: "exited while working")
    h.change([waiting, failed], peeks: [h.peek(failed, .error, at: 0), h.peek(waiting, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.last?.row.id, equals: failed.id, "the error card is up with +1 more")
    h.clock.set(h.time(2))
    try expect(h.coordinator.cardClicked(), equals: failed.id, "the click returns the error row")
    try expect(h.presenter.dismissCount, equals: 1, "the clicked card is dismissed")
    try expect(h.presenter.presented.map(\.row.id), equals: [failed.id, waiting.id],
               "the pending card shows at once, not at the next store change")
    try expect(h.presenter.presented.last?.moreCount, equals: 0, "nothing more pending")
    try expect(h.coordinator.queue.shownAt, equals: h.time(2), "the promoted card's 8 s start at the click")
    try expect(h.chime.playedCount, equals: 1, "promotion is silent")
    h.tick(at: 9.9)
    try expect(h.presenter.dismissCount, equals: 1, "still up 7.9 s after the click")
    h.tick(at: 10)
    try expect(h.presenter.dismissCount, equals: 2, "retired 8 s after the click")
}

@MainActor
func testPeekNoChimeWhenThePresentedCardHasNoDisplay() throws {
    let h = CoordinatorHarness()
    h.presenter.hasDisplay = false
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    try expect(h.presenter.presented.count, equals: 1, "the card is presented (hidden until a display exists)")
    try expect(h.chime.playedCount, equals: 0, "no sound without a visible card")
    h.presenter.hasDisplay = true
    let other = peekWaitingRow("w1:p2")
    h.change([row, other], peeks: [h.peek(other, at: 4)], chime: true, at: 4)
    try expect(h.chime.playedCount, equals: 1, "the next visible new card chimes")
}

/// SplitMix64: a fixed-seed generator, so the audit below is the same run every time.
private struct PeekRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }
}

/// Ruling 3: a chime plays only in the same step that presents a card, and only while that card is
/// visible (final-review F4 dropped the clause that the card's own event be one of the step's
/// `decision.peeks`: a "+N more" card is the visible card for the new event). Drives every coordinator entry point (store changes with random
/// rows, peeks and chime flags; ticks; clicks; re-anchors with and without displays; hover, mute
/// and display loss) and checks, from inside play(), what the presenter was just asked to show.
@MainActor
func testPeekNoPathChimesWithoutAPresentedVisibleCard() throws {
    var random = PeekRandom(seed: 0x00C0_FFEE)
    var violations: [String] = []
    var plays = 0
    var mutedOrHiddenSteps = 0
    let keys = ["w1:p1", "w1:p2", "w2:p1", "w3:p1"]
    for run in 0..<60 {
        let h = CoordinatorHarness()
        var offset: TimeInterval = 0
        var stepIsChange = false
        var stepDecision = PolicyDecision.none
        var stepCallStart = 0
        var playsThisStep = 0
        var step = 0
        h.chime.onPlay = { [unowned h] in
            plays += 1
            playsThisStep += 1
            let calls = h.presenter.calls
            guard stepIsChange, stepDecision.chime, !h.muted else {
                violations.append("run \(run) step \(step): chime outside a chiming, unmuted store change")
                return
            }
            guard calls.count > stepCallStart, case .present? = calls.last else {
                violations.append("run \(run) step \(step): chime without a present in the same step")
                return
            }
            if !h.presenter.isCardVisible {
                violations.append("run \(run) step \(step): chime while the card is not visible")
            }
        }
        for index in 0..<120 {
            step = index
            stepIsChange = false
            stepDecision = PolicyDecision.none
            stepCallStart = h.presenter.calls.count
            playsThisStep = 0
            switch random.below(10) {
            case 0...3:
                offset += Double(random.below(40)) / 10
                let rows: [AgentRow] = keys.compactMap { key in
                    switch random.below(4) {
                    case 0: nil
                    case 1: peekWorkingRow(key)
                    case 2: peekWaitingRow(key, question: random.chance(50) ? "Allow \(key)?" : nil)
                    default: peekErrorRow(key, line: random.chance(50) ? "\(key) exited" : nil)
                    }
                }
                let peeks = rows
                    .filter { ($0.state == .waiting || $0.state == .error) && random.chance(40) }
                    .map { row in
                        PeekEvent(rowID: row.id, kind: row.state == .error ? .error : .waiting,
                                  question: row.detail?.question, at: h.time(offset))
                    }
                stepIsChange = true
                stepDecision = PolicyDecision(peeks: peeks, chime: random.chance(60))
                if h.muted || !h.presenter.hasDisplay { mutedOrHiddenSteps += 1 }
                h.change(rows, peeks: stepDecision.peeks, chime: stepDecision.chime, at: offset)
            case 4:
                offset += Double(random.below(120)) / 10
                h.tick(at: offset)
            case 5:
                _ = h.coordinator.cardClicked()
            case 6:
                let displays = random.chance(70) ? [PeekDisplays.samsung, PeekDisplays.builtIn] : []
                _ = peekReanchor(h, mainDisplayID: displays.isEmpty ? nil : 2,
                                 pointer: random.chance(80) ? DisplayPoint(x: 100, y: 100) : nil,
                                 displays: displays, cardDisplayID: random.chance(50) ? 2 : nil)
            case 7:
                h.presenter.isCardHovered.toggle()
            case 8:
                h.muted.toggle()
            default:
                h.presenter.hasDisplay.toggle()
            }
            if playsThisStep > 1 {
                violations.append("run \(run) step \(step): \(playsThisStep) chimes in one step")
            }
            let queue = h.coordinator.queue
            if queue.current == nil, !queue.pending.isEmpty {
                violations.append("run \(run) step \(step): a pending card sits with no card shown")
            }
            if h.presenter.showing?.event != queue.current {
                violations.append("run \(run) step \(step): the presenter does not show the queue head")
            }
        }
    }
    try expect(Array(violations.prefix(5)), equals: [], "no chime without a presented, visible card")
    try expectTrue(plays > 50, "the audit exercised the chime (\(plays) plays)")
    try expectTrue(mutedOrHiddenSteps > 50, "the audit exercised mute and display loss (\(mutedOrHiddenSteps) steps)")
}

// MARK: - Store → policy → coordinator chain

@MainActor
private final class ChainHarness {
    let clock = ManualWallClock()
    let feed = FakeSessionFeed(source: .herdr)
    let presenter = FakeCardPresenter()
    let chime = FakeChime()
    let jumpPerformer = RecordingJumpPerformer()
    let store: StateStore
    let coordinator: PeekCoordinator
    private(set) var changes: [StoreChange] = []

    /// `policy` defaults to the bare InterruptPolicy; the wake-race tests pass the app's composition,
    /// WakeGuardedPolicy(InterruptPolicy()), exactly as PeekWiring.policy builds it.
    init(policy: any InterruptDeciding = InterruptPolicy()) {
        store = StateStore(
            feeds: [feed],
            clock: clock,
            focusProvider: FakeFocusContextProvider(FocusContext(frontmostBundleID: "com.apple.finder")),
            jumpPerformer: jumpPerformer,
            jumpContextProvider: StaticJumpContextProvider(JumpContext()),
            policy: policy,
            deadlineScheduler: .manual
        )
        coordinator = PeekCoordinator(presenter: presenter, chime: chime, clock: clock, isMuted: { false }, scheduler: .manual)
        store.addChangeObserver(coordinator.handle)
        store.addChangeObserver { [unowned self] change in
            self.changes.append(change)
        }
    }

    func publish(_ rows: [AgentRow]) throws {
        feed.publish(rows)
        try spinMainRunLoop(timeout: 2) { Set(store.rows.map(\.id)) == Set(rows.map(\.id)) }
    }

    func tick(after seconds: TimeInterval) {
        clock.advance(by: seconds)
        store.tick()
    }
}

@MainActor
func testPeekStoreChainHeldWaitingGivesOneCardAndOneChime() throws {
    let h = ChainHarness()
    h.store.start()                        // launch quiet period [t0, t0 + 10)
    h.clock.advance(by: 20)
    try h.publish([peekWaitingRow("w1:p1", question: "Allow the edit?")])
    try expect(h.presenter.presented.count, equals: 0, "held for 1 s first")
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.presenter.presented.first?.bodyText, equals: "Allow the edit?", "the card names the question")
    try expect(h.chime.playedCount, equals: 1, "exactly one chime with it")
    h.tick(after: 5)
    try expect(h.chime.playedCount, equals: 1, "still one chime")
}

/// Final-review F4 through the real chain (StateStore, WakeGuardedPolicy(InterruptPolicy()),
/// PeekCoordinator, TransitionRecord): a question that matures while an error card is up chimes with
/// the "+1 more" card, so every `chime` line in the log is a sound.
@MainActor
func testPeekStoreChainQuestionBehindAnErrorCardChimes() throws {
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    let failed = peekErrorRow("w1:p1", line: "exited while working")
    try h.publish([failed])
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.chime.playedCount, equals: 1, "the error card chimes")
    h.clock.advance(by: 3)
    try h.publish([failed, peekWaitingRow("w1:p2", question: "Allow the edit?")])
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 2 }
    try expect(h.presenter.presented.last?.event.kind, equals: .error, "the error keeps the card")
    try expect(h.presenter.presented.last?.moreCount, equals: 1, "with +1 more")
    try expect(h.chime.playedCount, equals: 2, "the matured question chimes with the +1 more card")
    let chimeLines = h.changes.flatMap(TransitionRecord.records(for:)).filter { $0.kind == .chime }.count
    try expect(chimeLines, equals: h.chime.playedCount, "every chime line in the log is a sound")
}

@MainActor
func testPeekStoreChainWakeQuietAbsorbsTheBurst() throws {
    // Review Focus 5 through the real chain: what PeekWiring's didWake handler calls
    // (StateStore.beginQuietPeriod for every source) after a 6 h sleep.
    let h = ChainHarness()
    h.store.start()
    h.clock.advance(by: 20)
    var rows = [peekWaitingRow("w1:p0")]
    try h.publish(rows)                    // hold starts; the machine sleeps before the tick
    h.clock.advance(by: 6 * 3_600)
    h.store.beginQuietPeriod(for: Set(SessionSource.allCases))
    h.tick(after: 0.1)
    for index in 0..<5 {
        rows.append(peekWaitingRow("w2:p\(index)"))
        try h.publish(rows)
        h.tick(after: 1.2)
        h.clock.advance(by: 0.6)
    }
    h.tick(after: 5)
    try expect(h.presenter.presented.count, equals: 0, "0 cards for the wake burst")
    try expect(h.chime.playedCount, equals: 0, "0 chimes for the wake burst")
    h.clock.advance(by: 10)
    rows.append(peekWaitingRow("w3:p1"))
    try h.publish(rows)
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.presenter.presented.first?.row.id, equals: RowID(source: .herdr, key: "w3:p1"), "a new episode after the guard peeks")
    try expect(h.chime.playedCount, equals: 1, "with one chime")
}

// MARK: - Controller ruling 1 (Task 13 review): the wake race

/// Records the order of calls into the wrapped policy.
private struct RecordingDecider: InterruptDeciding {
    final class Log {
        var calls: [String] = []
    }

    let log: Log
    let base: Date
    var nextDeadline: Date?

    mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision {
        log.calls.append("decide@\(now.timeIntervalSince(base))")
        return PolicyDecision(nextDeadline: nextDeadline)
    }

    mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date) {
        log.calls.append("quiet(\(sources.count))@\(now.timeIntervalSince(base))")
    }
}

func testPeekWakeGuardOpensTheQuietWindowBeforeADecideAfterAGap() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let log = RecordingDecider.Log()
    var policy = WakeGuardedPolicy(RecordingDecider(log: log, base: base))
    func decide(at offset: TimeInterval) {
        _ = policy.decide(prev: [], next: [], focus: FocusContext(), now: base.addingTimeInterval(offset))
    }
    decide(at: 0)
    decide(at: 30)
    try expect(log.calls, equals: ["decide@0.0", "decide@30.0"], "gaps up to 30 s are an awake island")
    decide(at: 60.5)
    try expect(Array(log.calls.suffix(2)), equals: ["quiet(3)@60.5", "decide@60.5"],
               "after a gap over 30 s the quiet window opens for every source, at now, before deciding")
    decide(at: 50)
    try expect(log.calls.last, equals: "decide@50.0", "a clock moving backwards is not a sleep")
    try expect(log.calls.count, equals: 5, "no quiet window for the backwards step")
    policy.beginQuietPeriod(for: [.herdr], at: base.addingTimeInterval(51))
    try expect(log.calls.last, equals: "quiet(1)@51.0", "explicit quiet periods (launch, reconnect, didWake) pass through")
}

func testPeekWakeGuardAsksToBeCalledAgainWithinTenSeconds() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var inner = RecordingDecider(log: RecordingDecider.Log(), base: base)
    var policy = WakeGuardedPolicy(inner)
    let idle = policy.decide(prev: [], next: [], focus: FocusContext(), now: base)
    try expect(idle.nextDeadline, equals: base.addingTimeInterval(10), "with nothing pending the heartbeat is 10 s away")
    inner.nextDeadline = base.addingTimeInterval(1.5)
    policy = WakeGuardedPolicy(inner)
    let holding = policy.decide(prev: [], next: [], focus: FocusContext(), now: base.addingTimeInterval(0.5))
    try expect(holding.nextDeadline, equals: base.addingTimeInterval(1.5), "an earlier hold deadline wins")
    inner.nextDeadline = base.addingTimeInterval(60)
    policy = WakeGuardedPolicy(inner)
    let far = policy.decide(prev: [], next: [], focus: FocusContext(), now: base)
    try expect(far.nextDeadline, equals: base.addingTimeInterval(10), "never later than the heartbeat")
}

@MainActor
func testPeekStoreChainWakeRaceOverdueTickBeforeDidWakeIsQuiet() throws {
    // Review Focus 5 with the ruling-1 guard, composed the way the app composes the policy. The
    // overdue hold deadline fires on wake before NSWorkspace.didWakeNotification is delivered.
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    var rows = [peekWaitingRow("w1:p0", question: "Allow the edit?"), peekWorkingRow("w1:p9")]
    try h.publish(rows)                    // the hold starts; the machine sleeps before its 1 s tick
    h.clock.advance(by: 6 * 3_600)
    h.store.tick()                         // wake: the overdue deadline runs first
    try expect(h.presenter.presented.count, equals: 0, "the hold from before the sleep does not peek")
    try expect(h.chime.playedCount, equals: 0, "and does not chime")
    // The feeds report what happened while asleep: an error and a burst of 5 waiting rows.
    rows[1] = peekErrorRow("w1:p9", line: "exited while asleep")
    try h.publish(rows)
    for index in 0..<5 {
        rows.append(peekWaitingRow("w2:p\(index)"))
        try h.publish(rows)
        h.tick(after: 1.2)
        h.clock.advance(by: 0.6)
    }
    h.store.beginQuietPeriod(for: Set(SessionSource.allCases))   // didWake, delivered late
    h.tick(after: 5)
    try expect(h.presenter.presented.count, equals: 0, "0 cards: the 10 s quiet guard covers the burst")
    try expect(h.chime.playedCount, equals: 0, "0 chimes: no chime burst")
    let quiet = h.changes.flatMap(\.decision.notes).filter { $0.rule == .quietPeriod }
    try expect(quiet.count, equals: 7, "the stale hold, the error and the 5 burst rows are suppressed.quiet")
    h.clock.advance(by: 10)
    rows.append(peekWaitingRow("w3:p1"))
    try h.publish(rows)
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.presenter.presented.first?.row.id, equals: RowID(source: .herdr, key: "w3:p1"), "a new episode after the guard peeks")
    try expect(h.chime.playedCount, equals: 1, "with one chime")
}

@MainActor
func testPeekStoreChainWakeRaceFeedPublishFirstWithoutDidWakeIsQuiet() throws {
    // The first thing after wake is a feed publish, and didWake never arrives at all.
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    var rows = [peekWaitingRow("w1:p0"), peekWorkingRow("w1:p9")]
    try h.publish(rows)
    h.clock.advance(by: 6 * 3_600)
    rows[1] = peekErrorRow("w1:p9")
    rows.append(peekWaitingRow("w2:p0", question: "Run the migration?"))
    try h.publish(rows)                    // wake: a feed publish decides first
    h.tick(after: 1.2)
    h.tick(after: 5)
    try expect(h.presenter.presented.count, equals: 0, "no card for the stale hold, the error or the new waiting row")
    try expect(h.chime.playedCount, equals: 0, "no chime")
    h.clock.advance(by: 10)
    rows.append(peekWaitingRow("w3:p1"))
    try h.publish(rows)
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.chime.playedCount, equals: 1, "a new episode after the window peeks with one chime")
}

@MainActor
func testPeekStoreChainAwakeLullStillPeeks() throws {
    // A quiet desk: nothing publishes for over a minute. The guard's heartbeat deadline keeps the
    // store deciding every 10 s, so the next real change is not mistaken for a wake.
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    try h.publish([peekWorkingRow("w1:p1")])
    for _ in 0..<6 {
        guard let deadline = h.changes.last?.decision.nextDeadline else {
            throw TestFailure.expectation("every decision asks to be called again")
        }
        try expectTrue(deadline <= h.clock.now().addingTimeInterval(10), "the heartbeat is at most 10 s away")
        h.clock.set(deadline)              // the store's deadline scheduler fires
        h.store.tick()
    }
    h.clock.advance(by: 9)
    try h.publish([peekWaitingRow("w1:p1", question: "Allow the edit?")])
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    try expect(h.chime.playedCount, equals: 1, "the first waiting after a 69 s lull peeks with one chime")
}

@MainActor
func testPeekStoreChainGapWithoutHeartbeatIsTreatedAsSleep() throws {
    // The contrast: 60 s with no decide at all (the heartbeat did not run) can only be a sleep or a
    // stall, so the next change opens the quiet window and its new waiting row stays quiet.
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    try h.publish([peekWorkingRow("w1:p1")])
    h.clock.advance(by: 60)
    try h.publish([peekWaitingRow("w1:p1", question: "Allow the edit?")])
    h.tick(after: 1.1)
    try expect(h.presenter.presented.count, equals: 0, "quiet after a gap with no heartbeat")
    try expect(h.chime.playedCount, equals: 0, "no chime")
}

@MainActor
func testPeekStoreChainCardClickJumpsThroughStoreFocus() throws {
    // Task 15: a card click reaches the jump through store.focus(rowID), like a board row click,
    // which also marks the row seen through its feed. PeekController runs exactly this.
    let h = ChainHarness(policy: WakeGuardedPolicy(InterruptPolicy()))
    h.store.start()
    h.clock.advance(by: 20)
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    try h.publish([row])
    h.tick(after: 1.1)
    try spinMainRunLoop(timeout: 2) { h.presenter.presented.count == 1 }
    guard let clicked = h.coordinator.cardClicked() else {
        throw TestFailure.expectation("the click returns the card's row")
    }
    let store = h.store
    Task { @MainActor in
        try? await store.focus(clicked)
    }
    try spinMainRunLoop(timeout: 2) { h.jumpPerformer.performedLog.count == 1 }
    try expect(h.feed.jumpedRows, equals: [row.id], "the feed marks the clicked row seen")
    try expect(h.jumpPerformer.performedLog.count, equals: 1, "one planned jump runs")
    try expect(h.presenter.dismissCount, equals: 1, "the card is gone")
}

// MARK: - Hardening: card re-anchor on display topology change (Review Focus 4)

/// The desk: the Samsung (id 2) is the primary at the origin; the built-in (id 1) sits to its left.
private enum PeekDisplays {
    static var samsung: DisplaySnapshot {
        DisplaySnapshot(id: 2, frame: DisplayFrame(minX: 0, minY: 0, width: 2_560, height: 1_440))
    }

    static var builtIn: DisplaySnapshot {
        DisplaySnapshot(id: 1, frame: DisplayFrame(minX: -1_512, minY: 0, width: 1_512, height: 982))
    }

    /// The built-in alone after the Samsung is unplugged: it becomes the primary at the origin.
    static var builtInAlone: DisplaySnapshot {
        DisplaySnapshot(id: 1, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982))
    }
}

/// Exactly what PeekController.reanchor() does, minus AppKit: plan with PanelAnchorPlanner, take the
/// pointer display for the same displays as the fallback, and let the coordinator decide.
@MainActor
private func peekReanchor(
    _ h: CoordinatorHarness,
    mainDisplayID: UInt32?,
    pointer: DisplayPoint?,
    displays: [DisplaySnapshot],
    cardDisplayID: UInt32?,
    boardExpanded: Bool = false
) -> (plan: PanelAnchorPlan, placement: PeekCardPlacement?) {
    let plan = PanelAnchorPlanner.plan(
        mode: .primary,
        mainDisplayID: mainDisplayID,
        pointer: pointer,
        displays: displays,
        current: PanelAnchorState(pillDisplayIDs: [2], cardDisplayID: cardDisplayID, boardExpanded: boardExpanded)
    )
    let fallback = ScreenSelection.pointerDisplay(pointer: pointer, mainDisplayID: mainDisplayID, displays: displays)
    let placement = h.coordinator.reanchorCard(plan: plan, currentDisplayID: cardDisplayID, fallbackDisplayID: fallback)
    return (plan, placement)
}

func testPeekCardPlacementKeepsMovesOrDismisses() throws {
    func plan(card: UInt32?) -> PanelAnchorPlan {
        PanelAnchorPlan(pillDisplayIDs: [2], createdPillDisplayIDs: [], removedPillDisplayIDs: [],
                        cardDisplayID: card, collapseBoard: false, relayoutAll: true)
    }
    try expect(PeekCardPlacement.decide(plan: plan(card: 2), currentDisplayID: 2, fallbackDisplayID: 2),
               equals: .keep(displayID: 2), "its display is still planned: keep")
    try expect(PeekCardPlacement.decide(plan: plan(card: 1), currentDisplayID: 2, fallbackDisplayID: 1),
               equals: .move(toDisplayID: 1), "the plan moved it: move")
    try expect(PeekCardPlacement.decide(plan: plan(card: nil), currentDisplayID: nil, fallbackDisplayID: 1),
               equals: .move(toDisplayID: 1), "a card presented while no display existed goes to the pointer display")
    try expect(PeekCardPlacement.decide(plan: plan(card: nil), currentDisplayID: 2, fallbackDisplayID: nil),
               equals: .dismiss, "cardDisplayID nil and no pointer display: dismiss")
}

@MainActor
func testPeekCardReanchorMovesTheCardWithoutPresentingOrChiming() throws {
    let h = CoordinatorHarness()
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)

    // Wake with the same topology: the card stays on the Samsung.
    let wake = peekReanchor(h, mainDisplayID: 2, pointer: DisplayPoint(x: 100, y: 100),
                            displays: [PeekDisplays.samsung, PeekDisplays.builtIn], cardDisplayID: 2)
    try expect(wake.placement, equals: .keep(displayID: 2), "same topology: the card stays")

    // The Samsung is unplugged while the board is open; the pointer is on the built-in.
    let unplugged = peekReanchor(h, mainDisplayID: 1, pointer: DisplayPoint(x: 700, y: 500),
                                 displays: [PeekDisplays.builtInAlone], cardDisplayID: 2, boardExpanded: true)
    try expect(unplugged.placement, equals: .move(toDisplayID: 1), "its display is gone: the card moves to the pointer display")
    try expect(unplugged.plan.collapseBoard, equals: true, "the same plan collapses the open board")

    // The Samsung comes back and the lid closes with the card on the built-in; the pointer is off-screen.
    let lidClosed = peekReanchor(h, mainDisplayID: 2, pointer: DisplayPoint(x: 99_999, y: 99_999),
                                 displays: [PeekDisplays.samsung], cardDisplayID: 1)
    try expect(lidClosed.placement, equals: .move(toDisplayID: 2), "pointer off-screen: the card goes to the primary")

    try expect(h.presenter.presented.count, equals: 1, "re-anchoring never presents the card again")
    try expect(h.presenter.dismissCount, equals: 0, "and never dismisses a card that still has a display")
    try expect(h.chime.playedCount, equals: 1, "and never chimes")
    try expect(h.coordinator.peekQueueSnapshot.current, equals: row.id, "the card keeps its place in the queue")
}

@MainActor
func testPeekCardIsDismissedWhenNoDisplayIsLeft() throws {
    let h = CoordinatorHarness()
    let first = peekWaitingRow("w1:p1")
    let second = peekWaitingRow("w1:p2")
    h.change([first, second], peeks: [h.peek(first, at: 0), h.peek(second, at: 1)], chime: true, at: 1)
    try expect(h.presenter.presented.last?.row.id, equals: second.id, "the newest card is up")

    // Every display goes away while the card is up and the board is open.
    let gone = peekReanchor(h, mainDisplayID: nil, pointer: nil, displays: [], cardDisplayID: 2, boardExpanded: true)
    try expect(gone.plan.cardDisplayID, equals: nil, "the plan's cardDisplayID becomes nil")
    try expect(gone.placement, equals: .dismiss, "the card is dismissed")
    try expect(h.presenter.dismissCount, equals: 1, "through CardPresenting.dismissCard")
    // Ruling 2: the pending card is promoted at once; it stays hidden until a display returns.
    try expect(h.coordinator.peekQueueSnapshot,
               equals: PeekQueueSnapshot(current: first.id, pending: [], moreCount: 0),
               "the shown event is retired; the pending one is promoted at once")
    try expect(h.presenter.presented.map(\.row.id), equals: [second.id, first.id],
               "the pending card is presented; the dismissed one does not come back")

    // The displays come back: the promoted card, which never had a display, goes to the pointer display.
    let back = peekReanchor(h, mainDisplayID: 2, pointer: DisplayPoint(x: 100, y: 100),
                            displays: [PeekDisplays.samsung, PeekDisplays.builtIn], cardDisplayID: nil)
    try expect(back.placement, equals: .move(toDisplayID: 2), "the promoted card lands on the pointer display")
    try expect(h.presenter.presented.count, equals: 2, "moving it presents nothing again")

    // Once the queue is empty there is nothing to re-anchor.
    _ = h.coordinator.cardClicked()
    let idle = peekReanchor(h, mainDisplayID: 2, pointer: nil, displays: [PeekDisplays.samsung], cardDisplayID: nil)
    try expect(idle.placement, equals: nil, "no card up: nothing to re-anchor")
    try expect(h.presenter.dismissCount, equals: 2, "the click dismissed; the idle re-anchor did not")
    try expect(h.chime.playedCount, equals: 1, "neither the dismissal nor the promotion chimes")
}

// MARK: - Hardening 4 through the card panel model (settle, no orphan, interactive region)

/// A manual clock behind DeadlineScheduler for DisplaySettle: records every settle requested and
/// fires the work whose deadline has passed when the test advances. Whole milliseconds, so
/// deadlines compare exactly.
private final class PeekSettleClock: @unchecked Sendable {
    private var nowMilliseconds = 0
    private var pending: [(dueMilliseconds: Int, work: @MainActor @Sendable () -> Void)] = []
    private(set) var requestedDelays: [TimeInterval] = []

    var scheduler: DeadlineScheduler {
        DeadlineScheduler { [self] delay, work in
            requestedDelays.append(delay)
            pending.append((nowMilliseconds + Int((delay * 1_000).rounded()), work))
        }
    }

    @MainActor
    func advance(toMilliseconds time: Int) {
        nowMilliseconds = time
        let due = pending
            .filter { $0.dueMilliseconds <= time }
            .sorted { $0.dueMilliseconds < $1.dueMilliseconds }
        pending.removeAll { $0.dueMilliseconds <= time }
        for item in due {
            item.work()
        }
    }
}

/// The built-in (id 1) has a camera housing under a 38 pt menu bar; every other display is a pill
/// under a 31 pt menu bar. Mirrors PeekController's (and NotchPanelController's) layout(for:).
private func peekLayout(for display: DisplaySnapshot) -> NotchLayout {
    let frame = display.frame
    if display.id == PeekDisplays.builtIn.id {
        return NotchLayout(
            screenMinX: frame.minX,
            screenWidth: frame.width,
            screenMaxY: frame.minY + frame.height,
            safeAreaTop: 38,
            leftNotchEdgeX: frame.minX + 663.5,
            rightNotchEdgeX: frame.minX + 848.5,
            menuBarHeight: 38,
            visibleFrameHeight: frame.height - 38
        )
    }
    return NotchLayout(
        screenMinX: frame.minX,
        screenWidth: frame.width,
        screenMaxY: frame.minY + frame.height,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31,
        visibleFrameHeight: frame.height - 31
    )
}

private func peekFacts(_ displays: [DisplaySnapshot], pointer: DisplayPoint?, mainDisplayID: UInt32?) -> PeekScreenFacts {
    PeekScreenFacts(
        displays: displays,
        layouts: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, peekLayout(for: $0)) }),
        pointer: pointer,
        mainDisplayID: mainDisplayID,
        mode: .primary
    )
}

@MainActor
private final class PeekScreenBox {
    var facts: PeekScreenFacts

    init(_ facts: PeekScreenFacts) {
        self.facts = facts
    }
}

/// Counts what the coordinator asks of the panel model, then forwards.
@MainActor
private final class CountingPresenter: CardPresenting {
    let model: PeekCardPanelModel
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    init(_ model: PeekCardPanelModel) {
        self.model = model
    }

    var isCardHovered: Bool { model.isCardHovered }
    var isCardVisible: Bool { model.isCardVisible }

    func present(_ card: PeekCard) {
        presentCount += 1
        model.present(card)
    }

    func dismissCard() {
        dismissCount += 1
        model.dismissCard()
    }
}

/// The card panel model (what PeekController executes on AppKit), wired to the real coordinator
/// the way PeekWiring wires them, with fake screens and a manual settle clock.
@MainActor
private final class PanelHarness {
    let clock: ManualWallClock
    let chime: FakeChime
    let settleClock: PeekSettleClock
    let screens: PeekScreenBox
    let model: PeekCardPanelModel
    let presenter: CountingPresenter
    let coordinator: PeekCoordinator

    init(_ facts: PeekScreenFacts) {
        let clock = ManualWallClock()
        let chime = FakeChime()
        let settleClock = PeekSettleClock()
        let screens = PeekScreenBox(facts)
        let model = PeekCardPanelModel(screens: { screens.facts }, settle: DisplaySettle(scheduler: settleClock.scheduler))
        let presenter = CountingPresenter(model)
        let coordinator = PeekCoordinator(presenter: presenter, chime: chime, clock: clock, isMuted: { false }, scheduler: .manual)
        model.onCardClick = { [weak coordinator] in coordinator?.cardClicked() }
        model.onReanchor = { [weak coordinator] plan, currentDisplayID, fallbackDisplayID in
            coordinator?.reanchorCard(plan: plan, currentDisplayID: currentDisplayID, fallbackDisplayID: fallbackDisplayID)
        }
        model.pillAnchorState = { ([2], false) }
        self.clock = clock
        self.chime = chime
        self.settleClock = settleClock
        self.screens = screens
        self.model = model
        self.presenter = presenter
        self.coordinator = coordinator
    }

    func time(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offset)
    }

    func change(_ rows: [AgentRow], peeks: [PeekEvent] = [], chime: Bool = false, at offset: TimeInterval) {
        clock.set(time(offset))
        coordinator.handle(StoreChange(
            at: clock.now(),
            previousRows: [],
            rows: rows,
            decision: PolicyDecision(peeks: peeks, chime: chime),
            registryShadow: [:],
            healthChanges: []
        ))
    }

    func tick(at offset: TimeInterval) {
        clock.set(time(offset))
        coordinator.tick()
    }

    func peek(_ row: AgentRow, at offset: TimeInterval) -> PeekEvent {
        PeekEvent(rowID: row.id, kind: row.state == .error ? .error : .waiting, question: row.detail?.question, at: time(offset))
    }

    /// A screen-parameter change or wake notification, `milliseconds` into the settle clock.
    func displaysChanged(at milliseconds: Int) {
        settleClock.advance(toMilliseconds: milliseconds)
        model.displaysChanged()
    }

    /// No orphan: a visible card's one panel hangs wholly on a connected display, from its top edge;
    /// a hidden card is routed nothing and has an empty region.
    func expectNoOrphan(_ label: String) throws {
        guard model.isCardVisible else {
            try expect(model.interactiveRegion, equals: HangingNotchInteractionRegion.empty, "\(label): a hidden card has an empty region")
            try expect(model.routesPointer, equals: false, "\(label): a hidden card is not routed the pointer")
            try expect(model.panelFrame, equals: nil, "\(label): a hidden card has no panel frame")
            return
        }
        guard let displayID = model.cardDisplayID,
              let display = screens.facts.displays.first(where: { $0.id == displayID }),
              let frame = model.panelFrame else {
            throw TestFailure.expectation("\(label): a visible card sits on a connected display")
        }
        try expectTrue(model.routesPointer, "\(label): a visible card is routed the pointer")
        try expectTrue(frame.minX >= display.frame.minX
                       && frame.minX + frame.width <= display.frame.minX + display.frame.width,
                       "\(label): the panel lies within its display horizontally")
        try expect(frame.minY + frame.height, equals: display.frame.minY + display.frame.height,
                   "\(label): the panel hangs from its display's top edge")
    }
}

func testPeekCardMetricsHangBelowTheMenuBarBand() throws {
    let samsung = peekLayout(for: PeekDisplays.samsung)
    try expect(PeekCardMetrics.top(for: samsung), equals: 33, "Samsung pill: 4 pt gap + 23 pt pill + 6 pt")
    try expectTrue(PeekCardMetrics.top(for: samsung) > 31, "the card starts below the 31 pt menu bar, so it never covers the pill")
    try expect(PeekCardMetrics.panelFrame(for: samsung),
               equals: DisplayFrame(minX: samsung.originX, minY: 1_440 - 293, width: samsung.width, height: 293),
               "the panel shares the pill panel's width and origin and spans top + 260 pt")
    try expect(PeekCardMetrics.cardFrame(for: samsung, measuredHeight: 0),
               equals: DisplayFrame(minX: 160, minY: 33, width: 480, height: 260),
               "before a measurement the whole 480 x 260 bubble takes clicks")
    try expect(PeekCardMetrics.cardFrame(for: samsung, measuredHeight: 96).height, equals: 96, "the measured height")
    try expect(PeekCardMetrics.cardFrame(for: samsung, measuredHeight: 900).height, equals: 260, "at most 260 pt")
    try expect(PeekCardMetrics.interactiveRegion(for: samsung, measuredHeight: 96).cornerStyle, equals: .bubble, "a bubble")
    let builtIn = peekLayout(for: PeekDisplays.builtInAlone)
    try expect(PeekCardMetrics.top(for: builtIn), equals: 44, "notch: 38 pt band + 6 pt")
    let narrow = NotchLayout(screenMinX: 0, screenWidth: 400, screenMaxY: 800, safeAreaTop: 0,
                             leftNotchEdgeX: nil, rightNotchEdgeX: nil, menuBarHeight: 24)
    try expect(PeekCardMetrics.cardWidth(for: narrow), equals: 400, "never wider than the panel")
}

@MainActor
func testPeekPanelNewCardFollowsThePointerAnUpdateStaysPut() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung, PeekDisplays.builtIn],
                                   pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    let bare = peekWaitingRow("w1:p1")
    h.change([bare], peeks: [h.peek(bare, at: 0)], chime: true, at: 0)
    try expect(h.model.cardDisplayID, equals: 2, "a new card appears on the display under the pointer")
    try expect(h.model.isCardVisible, equals: true, "and is visible")
    try expect(h.chime.playedCount, equals: 1, "with the chime")
    h.screens.facts.pointer = DisplayPoint(x: -700, y: 500)          // the pointer moves to the built-in
    let loaded = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([loaded], at: 0.4)
    try expect(h.presenter.presentCount, equals: 2, "the update is presented")
    try expect(h.model.cardDisplayID, equals: 2, "an updated card stays where it is")
    try expect(h.model.card?.bodyText, equals: "Allow the edit?", "with the new text")
    let other = peekWaitingRow("w1:p2")
    h.change([loaded, other], peeks: [h.peek(other, at: 4)], chime: true, at: 4)
    try expect(h.model.cardDisplayID, equals: 1, "a new event goes to the display now under the pointer")
    try expect(h.model.interactiveRegion,
               equals: PeekCardMetrics.interactiveRegion(for: peekLayout(for: PeekDisplays.builtIn), measuredHeight: 0),
               "the region is laid out for that display")
    try h.expectNoOrphan("after the move")
}

@MainActor
func testPeekPanelReanchorsAfterTheSettleWithNoOrphanAndANewRegion() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung, PeekDisplays.builtIn],
                                   pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    h.model.cardHeightMeasured(96)
    let samsungLayout = peekLayout(for: PeekDisplays.samsung)
    let samsungRegion = PeekCardMetrics.interactiveRegion(for: samsungLayout, measuredHeight: 96)
    try expect(h.model.interactiveRegion, equals: samsungRegion, "the region is the measured card on the Samsung")
    guard let samsungFrame = h.model.panelFrame else {
        throw TestFailure.expectation("a visible card has a panel frame")
    }
    let onCard = DisplayPoint(x: 1_280, y: 1_440 - 33 - 48)
    let belowCard = DisplayPoint(x: 1_280, y: 1_440 - 33 - 96 - 20)
    try expect(ClickThroughPolicy.route(pointer: onCard, panelFrame: samsungFrame, region: h.model.interactiveRegion).isInside,
               equals: true, "the card takes a click")
    try expect(ClickThroughPolicy.route(pointer: belowCard, panelFrame: samsungFrame, region: h.model.interactiveRegion).isInside,
               equals: false, "the panel below the card is click-through")
    try h.expectNoOrphan("on the Samsung")

    // The Samsung is unplugged; the WindowServer reports it in a burst.
    h.screens.facts = peekFacts([PeekDisplays.builtInAlone], pointer: DisplayPoint(x: 700, y: 500), mainDisplayID: 1)
    h.displaysChanged(at: 0)
    h.displaysChanged(at: 100)
    h.settleClock.advance(toMilliseconds: 440)
    try expect(h.model.cardDisplayID, equals: 2, "nothing moves before the 0.35 s settle")
    h.settleClock.advance(toMilliseconds: 450)
    try expect(h.settleClock.requestedDelays, equals: [0.35, 0.35], "each notification restarts the 0.35 s settle")
    let builtInLayout = peekLayout(for: PeekDisplays.builtInAlone)
    try expect(h.model.cardDisplayID, equals: 1, "after the settle the card moves to the pointer display")
    try expect(h.model.layout, equals: builtInLayout, "laid out for the built-in")
    try expect(h.model.interactiveRegion,
               equals: PeekCardMetrics.interactiveRegion(for: builtInLayout, measuredHeight: 96),
               "the interactive region is recomputed for the new display")
    try expectTrue(h.model.interactiveRegion != samsungRegion, "and differs from the Samsung's")
    try h.expectNoOrphan("after the unplug")
    guard let builtInFrame = h.model.panelFrame else {
        throw TestFailure.expectation("the moved card has a panel frame")
    }
    try expect(ClickThroughPolicy.route(pointer: onCard, panelFrame: builtInFrame, region: h.model.interactiveRegion).isInside,
               equals: false, "the card's old place no longer takes clicks")
    try expect(ClickThroughPolicy.route(pointer: DisplayPoint(x: builtInFrame.minX + 400, y: 982 - 44 - 48),
                                        panelFrame: builtInFrame, region: h.model.interactiveRegion).isInside,
               equals: true, "the moved card takes clicks")

    // The Samsung comes back and the lid closes; the pointer is off-screen.
    h.screens.facts = peekFacts([PeekDisplays.samsung], pointer: DisplayPoint(x: 99_999, y: 99_999), mainDisplayID: 2)
    h.displaysChanged(at: 1_000)
    h.settleClock.advance(toMilliseconds: 1_350)
    try expect(h.model.cardDisplayID, equals: 2, "pointer off-screen: the card goes to the primary")
    try expect(h.model.interactiveRegion, equals: samsungRegion, "with the Samsung's region again")
    try h.expectNoOrphan("after the lid closes")
    try expect(h.presenter.presentCount, equals: 1, "re-anchoring never presents again")
    try expect(h.chime.playedCount, equals: 1, "and never chimes")

    // Every display goes away: the card is retired and nothing is left on screen or routed.
    h.screens.facts = peekFacts([], pointer: nil, mainDisplayID: nil)
    h.displaysChanged(at: 2_000)
    h.settleClock.advance(toMilliseconds: 2_350)
    try expect(h.model.isCardVisible, equals: false, "no display: no card")
    try expect(h.presenter.dismissCount, equals: 1, "retired through dismissCard")
    try expect(h.coordinator.peekQueueSnapshot, equals: PeekQueueSnapshot(), "the queue is empty")
    try h.expectNoOrphan("with no display")
}

@MainActor
func testPeekPanelHiddenWithoutDisplaysLandsWhenOneReturnsSilently() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung, PeekDisplays.builtIn],
                                   pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    let first = peekWaitingRow("w1:p1")
    let second = peekWaitingRow("w1:p2")
    h.change([first, second], peeks: [h.peek(first, at: 0), h.peek(second, at: 1)], chime: true, at: 1)
    try expect(h.model.card?.row.id, equals: second.id, "the newest card is up")

    // Every display goes away.
    h.screens.facts = peekFacts([], pointer: nil, mainDisplayID: nil)
    h.displaysChanged(at: 0)
    h.settleClock.advance(toMilliseconds: 350)
    try expect(h.presenter.dismissCount, equals: 1, "the shown card is retired")
    try expect(h.model.card?.row.id, equals: first.id, "the pending card is promoted at once (ruling 2)")
    try expect(h.model.isCardVisible, equals: false, "but has no display to show on")
    try h.expectNoOrphan("with no display")

    // A new waiting row arrives while no display exists.
    let third = peekWaitingRow("w2:p1")
    h.change([first, second, third], peeks: [h.peek(third, at: 2)], chime: true, at: 2)
    try expect(h.model.card?.row.id, equals: third.id, "the newer card takes the panel")
    try expect(h.model.isCardVisible, equals: false, "still hidden")
    try expect(h.chime.playedCount, equals: 1, "no chime without a visible card (ruling 3)")
    try h.expectNoOrphan("new card, no display")

    // The built-in returns: the card lands on the pointer display, silently.
    h.screens.facts = peekFacts([PeekDisplays.builtInAlone], pointer: DisplayPoint(x: 700, y: 500), mainDisplayID: 1)
    h.displaysChanged(at: 1_000)
    h.settleClock.advance(toMilliseconds: 1_350)
    try expect(h.model.cardDisplayID, equals: 1, "the hidden card moves onto the returning display")
    try expect(h.model.interactiveRegion,
               equals: PeekCardMetrics.interactiveRegion(for: peekLayout(for: PeekDisplays.builtInAlone), measuredHeight: 0),
               "with a region for that display")
    try expect(h.model.card?.moreCount, equals: 1, "+1 more")
    try expect(h.chime.playedCount, equals: 1, "landing never chimes")
    try h.expectNoOrphan("after the display returns")
}

@MainActor
func testPeekPanelHoverHoldsTheCardAndAClickRetiresIt() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung], pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    h.model.pointerUpdated(isInside: true)
    try expect(h.model.isCardHovered, equals: true, "the pointer monitor's inside report is hover")
    h.tick(at: 9)
    try expect(h.model.isCardVisible, equals: true, "held open past 8 s while hovered")
    h.model.pointerUpdated(isInside: false)
    h.tick(at: 9.5)
    try expect(h.model.isCardVisible, equals: false, "retired once the pointer leaves")
    try h.expectNoOrphan("after expiry")

    let other = peekWaitingRow("w1:p2")
    h.change([row, other], peeks: [h.peek(other, at: 12)], chime: true, at: 12)
    try expect(h.model.clicked(), equals: other.id, "a click returns the row to jump to")
    try expect(h.model.isCardVisible, equals: false, "and retires the card")
    try expect(h.model.isCardHovered, equals: false, "a retired card is not hovered")
    try expect(h.coordinator.peekQueueSnapshot, equals: PeekQueueSnapshot(), "the queue is empty")
    try h.expectNoOrphan("after the click")
}

// MARK: - Final-review F3: the expanded board suppresses and holds the card

/// While the board is expanded the card would sit over its Waiting and Error rows and take their
/// clicks, so the model hides it (no region, no routing, no panel) and reports it hovered, which holds
/// it in the queue. Collapsing the board shows it again where it was.
@MainActor
func testPeekPanelExpandedBoardHidesAndHoldsTheCard() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung], pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    var changes = 0
    h.model.onChange = { changes += 1 }
    let row = peekWaitingRow("w1:p1", question: "Allow the edit?")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    h.model.cardHeightMeasured(96)
    let region = h.model.interactiveRegion
    let frame = h.model.panelFrame
    try expect(h.model.isCardVisible, equals: true, "the card is up before the board expands")
    try expect(h.model.isBoardExpanded, equals: false, "the board starts collapsed")
    try expect(h.model.isCardHovered, equals: false, "and the card is not hovered")

    changes = 0
    h.model.boardExpansionChanged(true)
    try expect(h.model.isBoardExpanded, equals: true, "the model records the expanded board")
    try expect(changes, equals: 1, "one change, so PeekController hides the panel")
    try expect(h.model.isCardVisible, equals: false, "the card is not visible over the expanded board")
    try expect(h.model.interactiveRegion, equals: HangingNotchInteractionRegion.empty, "it takes no clicks")
    try expect(h.model.routesPointer, equals: false, "it is not routed the pointer")
    try expect(h.model.panelFrame, equals: nil, "it has no panel frame")
    try expect(h.model.isCardHovered, equals: true, "it counts as hovered, so the queue holds it")
    try expect(h.model.card?.row.id, equals: row.id, "the card itself is kept, not dismissed")
    try h.expectNoOrphan("board expanded")
    h.model.boardExpansionChanged(true)
    try expect(changes, equals: 1, "a repeated report changes nothing")
    h.model.pointerUpdated(isInside: false)
    try expect(h.model.isCardHovered, equals: true, "a pointer report does not release a card the board covers")

    h.model.boardExpansionChanged(false)
    try expect(changes, equals: 2, "one change on collapse, so PeekController shows the panel again")
    try expect(h.model.isCardVisible, equals: true, "the card is visible again")
    try expect(h.model.interactiveRegion, equals: region, "with its region restored")
    try expect(h.model.panelFrame, equals: frame, "in the same place")
    try expect(h.model.routesPointer, equals: true, "and routed the pointer again")
    try expect(h.model.isCardHovered, equals: false, "no longer held once the board is gone")
    try h.expectNoOrphan("board collapsed")
}

/// With the real coordinator: a card held by the expanded board survives past its 8 s and is retired
/// on the first tick after the board collapses.
@MainActor
func testPeekPanelCardHeldByTheBoardExpiresAfterCollapse() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung], pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    h.model.boardExpansionChanged(true)
    h.tick(at: 8)
    h.tick(at: 20)
    try expect(h.presenter.dismissCount, equals: 0, "held past 8 s while the board is expanded")
    try expect(h.coordinator.peekQueueSnapshot.current, equals: row.id, "still the queue head")
    h.model.boardExpansionChanged(false)
    try expect(h.model.isCardVisible, equals: true, "shown again on collapse")
    h.tick(at: 21)
    try expect(h.presenter.dismissCount, equals: 1, "retired on the first tick after the board collapses")
    try expect(h.model.isCardVisible, equals: false, "and gone")
    try expect(h.coordinator.peekQueueSnapshot, equals: PeekQueueSnapshot(), "the queue is empty")
    try h.expectNoOrphan("after expiry")
}

/// Accepted consequence of F3: a question that arrives while the board is expanded appears on the board
/// with no chime (the visible-card gate sees no visible card); its card shows once the board collapses.
@MainActor
func testPeekPanelCardArrivingOverTheExpandedBoardIsSilentAndShowsOnCollapse() throws {
    let h = PanelHarness(peekFacts([PeekDisplays.samsung], pointer: DisplayPoint(x: 1_280, y: 700), mainDisplayID: 2))
    h.model.boardExpansionChanged(true)
    let row = peekWaitingRow("w1:p1")
    h.change([row], peeks: [h.peek(row, at: 0)], chime: true, at: 0)
    try expect(h.model.card?.row.id, equals: row.id, "the card is presented to the model")
    try expect(h.model.isCardVisible, equals: false, "but stays hidden while the board is expanded")
    try expect(h.chime.playedCount, equals: 0, "so no chime plays")
    try h.expectNoOrphan("arrived over the board")
    h.model.boardExpansionChanged(false)
    try expect(h.model.isCardVisible, equals: true, "it shows once the board collapses")
    try expect(h.model.cardDisplayID, equals: 2, "on the display under the pointer")
    try expect(h.chime.playedCount, equals: 0, "and showing it later never chimes")
}

// MARK: - Sound guard: one sound, from one place (spec §2)

/// Every Swift file under Sources/: its path relative to the repository root, and its text, sorted by path.
private func peekSourceFiles() throws -> [(path: String, text: String)] {
    let root = Fixtures.repositoryRoot.resolvingSymlinksInPath()
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
        return []
    }
    let base = root.path + "/"
    var files: [(path: String, text: String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let full = url.resolvingSymlinksInPath().path
        let path = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
        files.append((path: path, text: try String(contentsOf: url, encoding: .utf8)))
    }
    return files.sorted { $0.path < $1.path }
}

/// The sorted relative paths of the files whose text contains any of `needles`.
private func peekPaths(containing needles: [String], in files: [(path: String, text: String)]) -> [String] {
    files.filter { file in needles.contains { file.text.contains($0) } }.map { $0.path }
}

func testPeekSoundComesOnlyFromChimePlayer() throws {
    let files = try peekSourceFiles()
    try expectTrue(files.count > 20, "the guard sees the Sources tree (found \(files.count) Swift files)")
    try expect(
        peekPaths(containing: ["NSSound", "NSBeep", "AudioServicesPlay", "AVAudioPlayer"], in: files),
        equals: ["Sources/AgentIsland/Peek/ChimePlayer.swift"],
        "only ChimePlayer touches a sound API"
    )
    try expect(
        peekPaths(containing: [".play()"], in: files),
        equals: ["Sources/AgentIsland/Peek/ChimePlayer.swift", "Sources/IslandCore/Policy/PeekCoordinator.swift"],
        "only ChimePlayer plays, and only PeekCoordinator asks it to"
    )
    try expect(
        peekPaths(containing: ["ChimePlayer("], in: files),
        equals: ["Sources/AgentIsland/Composition/PeekWiring.swift"],
        "PeekWiring is the one place that constructs ChimePlayer"
    )
}

@MainActor
func testPeekJumpFailureOffersRetryForTheClickedRow() throws {
    let recovery = PeekJumpRecovery()
    let rowID = RowID(source: .herdr, key: "w1:p1")
    var clicks = 0
    var attempts: [RowID] = []
    var failures: [RowID] = []
    var finished = false
    Task { @MainActor in
        await recovery.perform(clickedRow: {
            clicks += 1
            return rowID
        }, focus: { id in
            attempts.append(id)
            if attempts.count == 1 { throw JumpError.actionFailed("synthetic failure") }
        }, requestRetry: { id, _ in
            failures.append(id)
            return true
        })?.value
        finished = true
    }
    try spinMainRunLoop(timeout: 2) { finished }
    try expect(failures, equals: [rowID], "a failed popup jump requests visible recovery")
    try expect(attempts, equals: [rowID, rowID], "Retry reopens the original agent")
    try expect(clicks, equals: 1, "retry never consumes the next queued popup")
    try expectTrue(!recovery.isRunning, "completion releases the click gate")
}

@MainActor
func testPeekJumpCancelAndSuccessDoNotRetry() throws {
    for fails in [true, false] {
        let recovery = PeekJumpRecovery()
        var attempts = 0
        var failures = 0
        var finished = false
        Task { @MainActor in
            await recovery.perform(clickedRow: { RowID(source: .herdr, key: "w1:p1") }, focus: { _ in
                attempts += 1
                if fails { throw JumpError.rowNotFound }
            }, requestRetry: { _, _ in
                failures += 1
                return false
            })?.value
            finished = true
        }
        try spinMainRunLoop(timeout: 2) { finished }
        try expect(attempts, equals: 1, "a successful jump or Cancel never retries")
        try expect(failures, equals: fails ? 1 : 0, "only failure asks for recovery, including a departed row")
    }
}

@MainActor
func testPeekJumpRecoveryDoesNotConsumeANewerCardWhileWaiting() throws {
    let recovery = PeekJumpRecovery()
    let original = RowID(source: .herdr, key: "w1:p1")
    var retryAnswer: CheckedContinuation<Bool, Never>?
    var clicks = 0
    var finished = false
    Task { @MainActor in
        await recovery.perform(clickedRow: { clicks += 1; return original }, focus: { _ in
            throw JumpError.actionFailed("synthetic failure")
        }, requestRetry: { _, _ in
            await withCheckedContinuation { retryAnswer = $0 }
        })?.value
        finished = true
    }
    try spinMainRunLoop(timeout: 2) { retryAnswer != nil }
    var duplicateFinished = false
    Task { @MainActor in
        await recovery.perform(clickedRow: { clicks += 1; return RowID(source: .herdr, key: "w1:p2") },
                               focus: { _ in }, requestRetry: { _, _ in false })?.value
        duplicateFinished = true
    }
    try spinMainRunLoop(timeout: 2) { duplicateFinished }
    let observedClicks = clicks
    retryAnswer?.resume(returning: false)
    try spinMainRunLoop(timeout: 2) { finished }
    try expect(observedClicks, equals: 1, "a newer popup remains queued while recovery is open")
}

@MainActor
func testPeekJumpCapturesTheCardBeforeTheAsyncTaskStarts() throws {
    let recovery = PeekJumpRecovery()
    let first = RowID(source: .herdr, key: "w1:p1")
    let second = RowID(source: .herdr, key: "w1:p2")
    var current = first
    var attempts: [RowID] = []
    recovery.perform(clickedRow: { current }, focus: { attempts.append($0) }, requestRetry: { _, _ in false })
    let reservedSynchronously = recovery.isRunning
    // A feed update promotes the next popup before the first Task can execute.
    current = second
    var consumedSecond = false
    recovery.perform(clickedRow: { consumedSecond = true; return current },
                     focus: { attempts.append($0) }, requestRetry: { _, _ in false })
    try spinMainRunLoop(timeout: 2) { !recovery.isRunning }
    try expectTrue(reservedSynchronously, "the input handler reserves recovery synchronously")
    try expectTrue(!consumedSecond, "a duplicate click does not consume the next popup")
    try expect(attempts, equals: [first], "the clicked card is captured before scheduling asynchronous work")
}

let peekTests: [TestCase] = [
    ("peek: jump failure offers retry for the clicked row", testPeekJumpFailureOffersRetryForTheClickedRow),
    ("peek: jump cancel and success never retry", testPeekJumpCancelAndSuccessDoNotRetry),
    ("peek: jump recovery does not consume a newer card while waiting", testPeekJumpRecoveryDoesNotConsumeANewerCardWhileWaiting),
    ("peek: jump captures the card before asynchronous work starts", testPeekJumpCapturesTheCardBeforeTheAsyncTaskStarts),
    ("peek: one peek with chime presents once and plays once", testPeekOnePeekWithChimePresentsOnceAndPlaysOnce),
    ("peek: a muted chime still presents and plays nothing", testPeekMutedChimeStillPresents),
    ("peek: a chime-gap decision presents without a chime", testPeekChimeGapDecisionPresentsWithoutChime),
    ("peek: a decision without peeks never chimes", testPeekDecisionWithoutPeeksNeverChimes),
    ("peek: two peeks show the most severe with +1 more", testPeekTwoPeeksShowMostSevereWithMoreCount),
    ("peek: a newer waiting takes the card and chimes", testPeekNewerWaitingTakesTheCardAndChimes),
    ("peek: the +1 more card is the visible card for a queued event and chimes", testPeekPlusMoreCardChimesForTheQueuedEvent),
    ("peek: a row leaving waiting is pruned and the card advances or dismisses", testPeekRowLeavingWaitingPrunesAndAdvances),
    ("peek: tick dismisses after 8 s unless hovered", testPeekTickDismissesAfterEightSecondsUnlessHovered),
    ("peek: cardClicked returns the row and dismisses", testPeekCardClickedReturnsRowAndDismisses),
    ("peek: the card updates in place when the question arrives", testPeekCardUpdatesInPlaceWhenTheQuestionArrives),
    ("peek: card text fallbacks and the 4-option limit", testPeekCardTextFallbacksAndLimits),
    ("peek: ruling 2 - a click promotes the pending card at once, silently", testPeekClickPromotesThePendingCardAtOnceSilently),
    ("peek: ruling 3 - no chime when the presented card has no display", testPeekNoChimeWhenThePresentedCardHasNoDisplay),
    ("peek: ruling 3 - no path chimes without a presented, visible card", testPeekNoPathChimesWithoutAPresentedVisibleCard),
    ("peek: store chain - a held waiting row gives one card and one chime", testPeekStoreChainHeldWaitingGivesOneCardAndOneChime),
    ("peek: store chain - a question behind an error card chimes; every chime line is a sound", testPeekStoreChainQuestionBehindAnErrorCardChimes),
    ("peek: hardening 5 - store chain wake quiet absorbs a burst after 6 h", testPeekStoreChainWakeQuietAbsorbsTheBurst),
    ("peek: ruling 1 - the wake guard opens the quiet window before a decide after a 30 s gap", testPeekWakeGuardOpensTheQuietWindowBeforeADecideAfterAGap),
    ("peek: ruling 1 - the wake guard asks to be called again within 10 s", testPeekWakeGuardAsksToBeCalledAgainWithinTenSeconds),
    ("peek: hardening 5 - wake race: an overdue hold tick before didWake gives no card or chime", testPeekStoreChainWakeRaceOverdueTickBeforeDidWakeIsQuiet),
    ("peek: hardening 5 - wake race: a feed publish first, with no didWake, is quiet", testPeekStoreChainWakeRaceFeedPublishFirstWithoutDidWakeIsQuiet),
    ("peek: ruling 1 - an awake lull of over a minute still peeks (heartbeat)", testPeekStoreChainAwakeLullStillPeeks),
    ("peek: ruling 1 - a 60 s gap with no heartbeat is treated as sleep", testPeekStoreChainGapWithoutHeartbeatIsTreatedAsSleep),
    ("peek: store chain - a card click jumps through store.focus and marks the row seen", testPeekStoreChainCardClickJumpsThroughStoreFocus),
    ("peek: hardening 4 - card placement keeps, moves or dismisses", testPeekCardPlacementKeepsMovesOrDismisses),
    ("peek: hardening 4 - re-anchoring moves the card without presenting or chiming again", testPeekCardReanchorMovesTheCardWithoutPresentingOrChiming),
    ("peek: hardening 4 - the card is dismissed when no display is left", testPeekCardIsDismissedWhenNoDisplayIsLeft),
    ("peek: card metrics - the card hangs below the menu-bar band, 480 pt wide, at most 260 pt", testPeekCardMetricsHangBelowTheMenuBarBand),
    ("peek: panel - a new card follows the pointer, an update stays put", testPeekPanelNewCardFollowsThePointerAnUpdateStaysPut),
    ("peek: hardening 4 - panel re-anchors after the 0.35 s settle with no orphan and a new region", testPeekPanelReanchorsAfterTheSettleWithNoOrphanAndANewRegion),
    ("peek: hardening 4 - panel hides without displays and lands silently when one returns", testPeekPanelHiddenWithoutDisplaysLandsWhenOneReturnsSilently),
    ("peek: panel - hover holds the card and a click retires it", testPeekPanelHoverHoldsTheCardAndAClickRetiresIt),
    ("peek: panel - the expanded board hides and holds the card; collapse restores it", testPeekPanelExpandedBoardHidesAndHoldsTheCard),
    ("peek: panel - a card held by the board expires on the first tick after collapse", testPeekPanelCardHeldByTheBoardExpiresAfterCollapse),
    ("peek: panel - a card arriving over the expanded board is silent and shows on collapse", testPeekPanelCardArrivingOverTheExpandedBoardIsSilentAndShowsOnCollapse),
    ("peek: sound comes only from ChimePlayer, constructed only in PeekWiring", testPeekSoundComesOnlyFromChimePlayer),
]

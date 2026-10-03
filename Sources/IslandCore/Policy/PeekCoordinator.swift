import Foundation

/// What the peek card shows: the event that raised it, the row as currently published, and "+N more".
public struct PeekCard: Equatable, Sendable {
    public let event: PeekEvent
    public let row: AgentRow
    public let moreCount: Int

    public init(event: PeekEvent, row: AgentRow, moreCount: Int) {
        self.event = event
        self.row = row
        self.moreCount = moreCount
    }

    /// The card's main line. Waiting: the row's current question, else the question captured with the
    /// event, else "needs you" (spec §5.1 parse-failure fallback). Error: the error line, else
    /// "stopped with an error".
    public var bodyText: String {
        switch event.kind {
        case .waiting:
            if let detail = row.detail, detail.kind == .question || detail.kind == .permission,
               let text = Self.nonEmpty(detail.question) {
                return text
            }
            return event.question.flatMap(Self.nonEmpty) ?? "needs you"
        case .error:
            if let detail = row.detail, detail.kind == .error, let text = Self.nonEmpty(detail.question) {
                return text
            }
            return event.question.flatMap(Self.nonEmpty) ?? "stopped with an error"
        }
    }

    /// Up to four option labels for a waiting card; none for an error card.
    public var optionLabels: [String] {
        guard event.kind == .waiting, let detail = row.detail,
              detail.kind == .question || detail.kind == .permission else { return [] }
        return Array(detail.options.compactMap(Self.nonEmpty).prefix(4))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The one sound. Implemented by the app's ChimePlayer; tests use a fake.
@MainActor
public protocol ChimePlaying: AnyObject {
    func play()
    var playedCount: Int { get }
}

/// The card surface. Implemented by the app's PeekController; tests use a fake.
@MainActor
public protocol CardPresenting: AnyObject {
    func present(_ card: PeekCard)
    func dismissCard()
    var isCardHovered: Bool { get }
    /// True while the presented card is actually on screen: a card is up and a display exists for it.
    /// The coordinator chimes only when this is true right after presenting, so no sound ever plays
    /// without a visible card (spec §2, success criterion 5). Deliberately has no default: every
    /// presenter must state its own visibility, or it would silently opt out of that gate.
    var isCardVisible: Bool { get }
}

/// Where a visible peek card goes after a display change or wake settles (spec §10, Review Focus 4).
/// PeekController gathers the inputs from AppKit; this is the whole decision.
public enum PeekCardPlacement: Equatable, Sendable {
    /// Its display is still the planned one: re-lay the card out there (the geometry may have changed).
    case keep(displayID: UInt32)
    /// Its display is gone, or it never had one: re-lay the card out on this display.
    case move(toDisplayID: UInt32)
    /// No display is left: retire the card.
    case dismiss

    /// `plan` is PanelAnchorPlanner's plan for a card on `currentDisplayID`. `fallbackDisplayID` is
    /// ScreenSelection.pointerDisplay for the same displays; it is used only when the plan has no card
    /// display (a card presented while no display existed has no current display to carry over).
    public static func decide(plan: PanelAnchorPlan, currentDisplayID: UInt32?, fallbackDisplayID: UInt32?) -> PeekCardPlacement {
        guard let target = plan.cardDisplayID ?? fallbackDisplayID else { return .dismiss }
        return target == currentDisplayID ? .keep(displayID: target) : .move(toDisplayID: target)
    }
}

/// Spec §2 "sound and card come from one place" and §7.3. Registered as a StateStore change observer.
///
/// - `handle` prunes the queue to the new rows, retires an expired card, enqueues the decision's
///   peeks, then presents the queue head (or dismisses). `present` is called only when the card
///   actually changes (new event, updated row, or a new "+N more").
/// - The chime plays only inside the `handle` call that presents a card, and only when
///   `decision.chime` is true, the card is visible and the user has not muted it. The presented card
///   need not show the new event itself: a peek that queues behind the shown card re-presents it with
///   "+N more", and that visible card is the card for the new event (final-review F4; spec §7.4 one
///   chime per episode). A decision with no peeks never chimes (the policy sets `chime` only with a
///   peek), and nothing else in the app calls `ChimePlaying.play()`.
/// - `tick` (scheduled at the card's 8 s deadline, or called by tests) retires an unhovered card.
///   While hovered past its deadline, the card is re-checked every second.
/// - Whenever the shown card is retired (expiry, prune, click, or a display change that leaves no
///   display), the next pending card is promoted in the same call, silently, so a queued card never
///   waits unseen for the next store change (controller ruling, Task 13 review).
/// - `reanchorCard` applies a display change to the shown card: keep or move leaves the queue alone;
///   dismiss (no display left) retires the card through `presenter.dismissCard()`.
@MainActor
public final class PeekCoordinator: PeekStatusProviding {
    public private(set) var queue = PeekQueue()

    private static let hoverRecheckInterval: TimeInterval = 1

    private let presenter: any CardPresenting
    private let chime: any ChimePlaying
    private let clock: any WallClock
    private let isMuted: @MainActor () -> Bool
    private let scheduler: DeadlineScheduler
    private var rowsByID: [RowID: AgentRow] = [:]
    private var shownCard: PeekCard?
    private var scheduledCheck: Date?

    public init(presenter: any CardPresenting, chime: any ChimePlaying, clock: any WallClock,
                isMuted: @escaping @MainActor () -> Bool, scheduler: DeadlineScheduler = .mainQueue) {
        self.presenter = presenter
        self.chime = chime
        self.clock = clock
        self.isMuted = isMuted
        self.scheduler = scheduler
    }

    public var peekQueueSnapshot: PeekQueueSnapshot { queue.snapshot() }
    public var chimePlayedCount: Int { chime.playedCount }

    public func handle(_ change: StoreChange) {
        rowsByID = Dictionary(change.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue.prune(rows: change.rows)
        // Retires an expired card first (so it cannot be re-queued) and promotes the next pending
        // card when prune dropped the shown one.
        queue.advance(now: change.at, isHovered: presenter.isCardHovered)
        queue.enqueue(change.decision.peeks, now: change.at)
        let presented = render(now: change.at)
        // The visibility gate reads the presenter's model state right after `present` returned. That
        // is sound only because PeekController applies it synchronously (PeekCardPanelModel.present
        // → onChange → PeekController.sync) and nothing inside applyModelState re-enters this
        // coordinator, so the card checked here is the card just presented. It may be the shown card
        // re-presented with "+N more" for a new event queued behind it: that is the visible card for
        // the new event, so it chimes (final-review F4).
        if presented != nil, change.decision.chime, presenter.isCardVisible, !isMuted() {
            chime.play()
        }
        scheduleExpiryCheck(now: change.at)
    }

    public func tick() {
        let now = clock.now()
        queue.advance(now: now, isHovered: presenter.isCardHovered)
        render(now: now)
        scheduleExpiryCheck(now: now)
    }

    /// The card was clicked: returns its row (the caller runs `StateStore.focus`) and dismisses it.
    /// The next pending card, if any, is promoted at once, silently.
    public func cardClicked() -> RowID? {
        guard let rowID = queue.current?.rowID else { return nil }
        retireShownCard(now: clock.now())
        return rowID
    }

    /// A display change or wake settled (Review Focus 4). Returns nil when no card is shown.
    /// `.keep` and `.move` leave the queue and the card as they are: the presenter re-lays the card
    /// out on that display, nothing is presented again and nothing chimes. `.dismiss` (no display
    /// left) retires the current event and calls `presenter.dismissCard()`; the row stays in the pill
    /// and board, and the next pending card is promoted at once, silently (it stays hidden until a
    /// display returns and the next re-anchor moves it).
    @discardableResult
    public func reanchorCard(plan: PanelAnchorPlan, currentDisplayID: UInt32?, fallbackDisplayID: UInt32?) -> PeekCardPlacement? {
        guard shownCard != nil else { return nil }
        let placement = PeekCardPlacement.decide(
            plan: plan,
            currentDisplayID: currentDisplayID,
            fallbackDisplayID: fallbackDisplayID
        )
        if placement == .dismiss {
            retireShownCard(now: clock.now())
        }
        return placement
    }

    /// Dismisses the shown card and promotes the next pending one in the same step. Never chimes.
    private func retireShownCard(now: Date) {
        queue.dismissCurrent()
        shownCard = nil
        presenter.dismissCard()
        queue.advance(now: now, isHovered: false)
        render(now: now)
        scheduleExpiryCheck(now: now)
    }

    /// Presents the queue head, or dismisses when the queue is empty. Returns the card presented
    /// by this call, or nil when nothing new was presented.
    @discardableResult
    private func render(now: Date) -> PeekCard? {
        var card: PeekCard?
        while let event = queue.current {
            if let row = rowsByID[event.rowID] {
                card = PeekCard(event: event, row: row, moreCount: queue.moreCount)
                break
            }
            // Defensive: prune normally drops an event whose row is gone before it gets here.
            queue.dismissCurrent()
            queue.advance(now: now, isHovered: false)
        }
        guard card != shownCard else { return nil }
        shownCard = card
        guard let card else {
            presenter.dismissCard()
            return nil
        }
        presenter.present(card)
        return card
    }

    private func scheduleExpiryCheck(now: Date) {
        guard queue.current != nil, let shownAt = queue.shownAt else { return }
        var due = shownAt.addingTimeInterval(IslandTiming.peekDuration)
        if due <= now {
            due = now.addingTimeInterval(Self.hoverRecheckInterval)
        }
        if let pending = scheduledCheck, pending > now, pending <= due { return }
        scheduledCheck = due
        scheduler.schedule(after: due.timeIntervalSince(now)) { [weak self] in
            guard let self else { return }
            self.scheduledCheck = nil
            self.tick()
        }
    }
}

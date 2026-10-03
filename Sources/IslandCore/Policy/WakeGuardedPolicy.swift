import Foundation

/// The wake guard (spec §10, Review Focus 5), independent of the order in which the sleep and wake
/// notifications arrive (controller ruling, Task 13 review).
///
/// Wraps the interrupt policy. A `decide` whose `now` is more than `sleepGap` (30 s) after the
/// previous `decide` means the island was not running in between: the machine slept, or the main
/// thread stalled. Before deciding, the wrapper opens the quiet period for every source at `now`,
/// the same 10 s guard `didWake` opens. So a hold that was pending before the sleep, and whatever the
/// feeds report on wake, cannot peek or chime, whichever runs first after wake: the overdue deadline
/// tick, a feed publish, or the wake notification.
///
/// An awake island must never look asleep, so the wrapper also asks to be decided again within
/// `heartbeat` (10 s): every decision's `nextDeadline` is at most `now + 10 s`, and StateStore ticks
/// then. Without it, a quiet desk (no publish for 30 s) would open a quiet window at the next real
/// change and swallow its peek. StateStore's deadline scheduler runs on uptime, which stops during
/// sleep, so the heartbeat never hides a sleep.
///
/// Pure: every time comes from `now`.
public struct WakeGuardedPolicy: InterruptDeciding {
    /// A longer gap between decisions than this is treated as a sleep.
    public static let sleepGap: TimeInterval = 30
    /// The longest an awake island goes without deciding.
    public static let heartbeat: TimeInterval = 10

    private var inner: any InterruptDeciding
    private var lastDecideAt: Date?

    public init(_ inner: any InterruptDeciding) {
        self.inner = inner
    }

    public mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision {
        if let lastDecideAt, now.timeIntervalSince(lastDecideAt) > Self.sleepGap {
            inner.beginQuietPeriod(for: Set(SessionSource.allCases), at: now)
        }
        lastDecideAt = now
        var decision = inner.decide(prev: prev, next: next, focus: focus, now: now)
        let heartbeatAt = now.addingTimeInterval(Self.heartbeat)
        decision.nextDeadline = min(decision.nextDeadline ?? heartbeatAt, heartbeatAt)
        return decision
    }

    public mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date) {
        inner.beginQuietPeriod(for: sources, at: now)
    }
}

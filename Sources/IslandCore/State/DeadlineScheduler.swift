import Foundation

/// Runs one piece of main-actor work after a delay. Production uses `.mainQueue`;
/// tests use `.manual` (never fires) and drive deadlines by calling `tick()` on the
/// owner after advancing a ManualWallClock.
public struct DeadlineScheduler: Sendable {
    private let scheduleWork: @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    public init(
        _ schedule: @escaping @Sendable (
            _ delay: TimeInterval,
            _ work: @escaping @MainActor @Sendable () -> Void
        ) -> Void
    ) {
        scheduleWork = schedule
    }

    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        scheduleWork(delay, work)
    }

    public static let mainQueue = DeadlineScheduler { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            MainActor.assumeIsolated {
                work()
            }
        }
    }

    public static let manual = DeadlineScheduler { _, _ in }
}

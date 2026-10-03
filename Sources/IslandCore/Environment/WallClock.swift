import Foundation

/// The only source of "now" for reducers, policy and feeds. Tests inject a manual clock.
public protocol WallClock: AnyObject, Sendable {
    func now() -> Date
}

/// The production clock. This file is the one place in IslandCore that reads the system time.
public final class SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

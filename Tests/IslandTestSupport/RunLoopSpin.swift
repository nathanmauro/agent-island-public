import Foundation

public struct SpinTimeout: Error, CustomStringConvertible {
    public let description: String
}

/// Runs the main run loop until `condition` is true, so main-queue blocks and
/// main-actor jobs drain while the test waits. Call it only on the main thread
/// (the runner already runs every test there). Throws SpinTimeout after `timeout`.
public func spinMainRunLoop(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.005,
    until condition: () -> Bool
) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw SpinTimeout(description: "condition not met within \(timeout) s")
        }
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: pollInterval))
    }
}

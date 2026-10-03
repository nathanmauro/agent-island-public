import Foundation
import IslandCore
import IslandIO

/// Raises the Ghostty window that shows a Herdr workspace (spec §7.5 step 2).
///
/// Nonisolated: every osascript call goes through OffMainActionRunner, so an Apple
/// Event that waits on the Automation prompt or a slow Ghostty never blocks the main
/// actor. Herdr retitles the window asynchronously after `agent.focus`, so the exact
/// prefix is tried `GhosttyScript.exactAttempts` times 150 ms apart, then the
/// host-only prefix once. If all fail, the last error is thrown and the planner's
/// fallback (activate Ghostty) runs.
final class GhosttyRaiser: Sendable {
    enum RaiseError: Error, Equatable {
        case noWindowTitlePrefix
    }

    init() {}

    func raise(windowTitlePrefix: String?) async throws {
        let prefixes = GhosttyScript.attemptPrefixes(for: windowTitlePrefix)
        guard !prefixes.isEmpty else { throw RaiseError.noWindowTitlePrefix }
        var lastError: Error = RaiseError.noWindowTitlePrefix
        for (attempt, prefix) in prefixes.enumerated() {
            if attempt > 0, attempt < GhosttyScript.exactAttempts {
                try await Task.sleep(nanoseconds: GhosttyScript.retryDelayNanoseconds)
            }
            do {
                try await OffMainActionRunner.run([.appleScript(GhosttyScript.focusTerminal(titlePrefix: prefix))])
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

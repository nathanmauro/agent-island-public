import Foundation
import IslandCore

/// Runs FocusActionRunner (synchronous, up to 10 s per action) on a detached task and
/// awaits it, so an osascript or tmux call never blocks the main actor. Error semantics
/// are FocusActionRunner's: every action runs, and the first failure is thrown.
public enum OffMainActionRunner {
    public static func run(_ actions: [FocusAction]) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FocusActionRunner.run(actions)
        }.value
    }
}

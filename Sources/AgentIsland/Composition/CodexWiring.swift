import Foundation
import IslandCore
import IslandIO

extension FeedWiring {
    /// Codex Desktop rollouts under FeedPaths.codexSessionsDirectory ($CODEX_SESSIONS_DIR or the default).
    static func codexDesktop(_ env: WiringEnvironment) -> (any SessionFeed)? {
        CodexDesktopFeed(
            sessionsDirectory: env.feedPaths.codexSessionsDirectory,
            sessionIndexURL: env.feedPaths.codexSessionIndex,
            seenStoreURL: env.paths.codexSeenFile,
            activity: env.activity,
            clock: env.clock,
            showExecThreads: { env.defaults.bool(forKey: PreferenceKeys.showExecThreads) }
        )
    }
}

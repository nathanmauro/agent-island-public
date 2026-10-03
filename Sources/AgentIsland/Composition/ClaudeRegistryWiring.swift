import Foundation
import IslandCore
import IslandIO

extension FeedWiring {
    /// Claude sessions outside Herdr (`CLAUDE_SESSIONS_DIR`, default ~/.claude/sessions).
    static func claudeRegistry(_ env: WiringEnvironment) -> (any SessionFeed)? {
        ClaudeRegistryFeed(
            directory: env.feedPaths.claudeSessionsDirectory,
            fileReader: LiveFileReader(),
            processProbe: LiveProcessProbe(),
            clock: env.clock
        )
    }
}

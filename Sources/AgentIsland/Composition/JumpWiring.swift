import Foundation
import IslandCore
import IslandIO

extension JumpWiring {
    /// AGENT_ISLAND_JUMP_DRY_RUN=1 records planned actions and never constructs the live
    /// performer, so no AppleScript, tmux, Herdr focus or URL open can run.
    static func make(_ env: WiringEnvironment) -> (performer: any JumpPerforming, context: any JumpContextProviding) {
        let context = LiveJumpContextProvider(activity: env.activity)
        if env.flags.jumpDryRun {
            let control = env.flags.jumpTestControl
                ? env.paths.supportDirectory.appendingPathComponent("jump-controls", isDirectory: true) : nil
            return (RecordingJumpPerformer(controlDirectory: control), context)
        }
        let performer = LiveJumpPerformer(
            herdrClient: HerdrClient(socketPath: env.feedPaths.herdrSocket.path),
            raiser: GhosttyRaiser()
        )
        return (performer, context)
    }
}

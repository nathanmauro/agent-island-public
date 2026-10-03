import Foundation
import IslandCore
import IslandIO

extension FeedWiring {
    /// The Herdr feed on $HERDR_SOCKET_PATH or ~/.config/herdr/herdr.sock, with the IslandTiming intervals.
    static func herdr(_ env: WiringEnvironment) -> (any SessionFeed)? {
        HerdrFeed(
            client: HerdrClient(socketPath: env.feedPaths.herdrSocket.path),
            clock: env.clock,
            activity: env.activity,
            configuration: .standard()
        )
    }
}

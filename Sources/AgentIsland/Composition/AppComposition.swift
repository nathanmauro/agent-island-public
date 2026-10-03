import Foundation

import IslandCore

/// Everything a wiring function may read. Built once by the composition root
/// in AgentIslandApp.swift from the process environment and home directory.
@MainActor
struct WiringEnvironment {
    let paths: AppPaths
    let feedPaths: FeedPaths
    let flags: DebugFlags
    let clock: any WallClock
    let activity: any AppActivityObserving
    let defaults: UserDefaults
}

/// One factory per source, each in its own file so the task that owns a feed
/// edits only that file: HerdrWiring.swift, ClaudeRegistryWiring.swift and
/// CodexWiring.swift. A factory returns nil when its feed is not built yet.
@MainActor
enum FeedWiring {}

/// JumpWiring.swift: the jump performer and its context provider.
@MainActor
enum JumpWiring {}

/// PeekWiring.swift: the interrupt policy and the peek card and chime.
@MainActor
enum PeekWiring {}

/// ObservabilityWiring.swift: the transition log, state dump and UI state.
@MainActor
enum ObservabilityWiring {}

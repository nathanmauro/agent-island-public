// swift-tools-version: 6.0
// agent-island — derived from Moonglade (MIT, ixjosemi/Moonglade be0c5b4) and
// Bantay-TUI's Herdr codec (MIT, 8-BitRhyon/bantay-tui e3e0517). See NOTICE.
//
// Target history (for implementers): Task 1 creates IslandCore, AgentIsland and
// IslandTests; Task 2 adds IslandIO and IslandTestSupport; Task 17 adds IslandE2E.
// No other task edits this file.
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "island-tests", targets: ["IslandTests"]),
        .executable(name: "island-e2e", targets: ["IslandE2E"]),
    ],
    targets: [
        // Pure logic: model, reducers, parsers, policy, planners, kept Moonglade
        // geometry/formatters/utilities. Must not import AppKit or SwiftUI.
        .target(
            name: "IslandCore",
            resources: [.copy("Resources")]
        ),
        // Foundation/Darwin/CoreServices I/O: Herdr socket client + feed, Claude
        // registry and Codex feeds, FSEvents, off-main action runner, transition
        // log, state dump. Must not import AppKit or SwiftUI.
        .target(
            name: "IslandIO",
            dependencies: ["IslandCore"]
        ),
        // The LSUIElement app: panels, SwiftUI views, NSWorkspace, AppleScript, NSSound.
        .executableTarget(
            name: "AgentIsland",
            dependencies: ["IslandCore", "IslandIO"]
        ),
        // Fakes and helpers shared by the unit runner and the end-to-end driver.
        .target(
            name: "IslandTestSupport",
            dependencies: ["IslandCore", "IslandIO"],
            path: "Tests/IslandTestSupport"
        ),
        // Custom executable test runner (not XCTest), as upstream: `swift run island-tests`.
        .executableTarget(
            name: "IslandTests",
            dependencies: ["IslandCore", "IslandIO", "IslandTestSupport"],
            path: "Tests/IslandTests"
        ),
        // Scripted end-to-end driver against the built app bundle: `scripts/e2e.sh`.
        .executableTarget(
            name: "IslandE2E",
            dependencies: ["IslandCore", "IslandIO", "IslandTestSupport"],
            path: "Tests/IslandE2E"
        ),
    ],
    swiftLanguageModes: [.v5]
)

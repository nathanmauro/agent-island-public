import AppKit
import IslandCore
import IslandIO

/// Executes planned jump actions for real. Every blocking step runs off the main actor:
/// Herdr requests are async socket I/O, osascript and tmux go through OffMainActionRunner,
/// and NSWorkspace opens URLs asynchronously. The pill never freezes during a jump.
@MainActor
final class LiveJumpPerformer: JumpPerforming {
    enum ExecutionError: Error, Equatable {
        case appNotRunning(String)
        case activationRefused(String)
        case invalidURL(String)
    }

    /// Bounds memory in a long-lived process; the state dump only needs recent jumps.
    private static let performedLogLimit = 100

    private let herdrClient: HerdrClient
    private let raiser: GhosttyRaiser
    private(set) var performedLog: [[JumpAction]] = []

    init(herdrClient: HerdrClient, raiser: GhosttyRaiser) {
        self.herdrClient = herdrClient
        self.raiser = raiser
    }

    func perform(_ actions: [JumpAction]) async throws {
        performedLog.append(actions)
        if performedLog.count > Self.performedLogLimit {
            performedLog.removeFirst(performedLog.count - Self.performedLogLimit)
        }
        var sequencer = JumpSequencer(actions)
        while let action = sequencer.next() {
            do {
                try await execute(action)
                sequencer.succeeded()
            } catch {
                sequencer.failed(error)
            }
        }
        if let failure = sequencer.failure {
            throw failure
        }
    }

    private func execute(_ action: JumpAction) async throws {
        switch action {
        case let .herdrFocus(paneID):
            _ = try await herdrClient.request(.focus(paneID: paneID))
        case let .raiseGhostty(windowTitlePrefix):
            try await raiser.raise(windowTitlePrefix: windowTitlePrefix)
        case let .activateApp(bundleID, _):
            try activate(bundleID: bundleID)
        case let .openURL(string, appPath, _):
            try await open(string, appPath: appPath)
        case let .tmuxSwitchClient(target):
            try await OffMainActionRunner.run([
                .run(executable: "tmux", arguments: ["switch-client", "-t", target]),
            ])
        }
    }

    private func activate(bundleID: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw ExecutionError.appNotRunning(bundleID)
        }
        // macOS 14 cooperative activation: hand activation over explicitly before asking for it.
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else {
            throw ExecutionError.activationRefused(bundleID)
        }
    }

    private func open(_ string: String, appPath: String?) async throws {
        guard let url = URL(string: string) else { throw ExecutionError.invalidURL(string) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let appPath {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: configuration
            )
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }
}

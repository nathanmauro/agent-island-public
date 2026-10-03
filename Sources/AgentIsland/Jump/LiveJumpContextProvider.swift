import AppKit
import IslandCore

/// Resolves the app bundles that deep links are opened with (spec §5.2, §5.3).
/// The installed-Codex lookup asks LaunchServices, so it is cached for 30 s.
@MainActor
final class LiveJumpContextProvider: JumpContextProviding {
    private static let installedLookupTTL: TimeInterval = 30

    private let activity: any AppActivityObserving
    private var cachedInstalledCodexPaths: [String] = []
    private var installedLookupUptime: TimeInterval?

    init(activity: any AppActivityObserving) {
        self.activity = activity
    }

    func currentJumpContext() -> JumpContext {
        JumpContext(
            codexAppPath: JumpAppResolver.codexAppPath(
                runningPath: activity.runningAppPath(bundleID: KnownBundleIDs.codex),
                installedPaths: installedCodexPaths()
            ),
            claudeAppPath: JumpAppResolver.claudeAppPath(
                runningPath: activity.runningAppPath(bundleID: KnownBundleIDs.claudeDesktop)
            )
        )
    }

    private func installedCodexPaths() -> [String] {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let installedLookupUptime, uptime - installedLookupUptime < Self.installedLookupTTL {
            return cachedInstalledCodexPaths
        }
        cachedInstalledCodexPaths = NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: KnownBundleIDs.codex)
            .map(\.path)
        installedLookupUptime = uptime
        return cachedInstalledCodexPaths
    }
}

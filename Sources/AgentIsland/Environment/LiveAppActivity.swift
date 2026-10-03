import AppKit

import IslandCore

/// NSWorkspace-backed app activity. With `frontmostOverride` set (the
/// AGENT_ISLAND_FRONTMOST_BUNDLE_ID test seam) the frontmost app is pinned to
/// that bundle id and real activations are not forwarded, so a scripted run
/// behaves the same whichever app launched it.
///
/// ChatGPT.app shares Codex.app's bundle id `com.openai.codex`. Every id this
/// class reports goes through `CodexAppIdentity.effectiveBundleID`, so while a
/// Codex.app is installed, ChatGPT.app is reported as
/// `CodexAppIdentity.chatGPTAppBundleID`: activating it marks no Codex thread
/// seen, having it frontmost suppresses no Codex peek, and having only it
/// running does not count as Codex running.
@MainActor
final class LiveAppActivity: AppActivityObserving {
    /// LaunchServices is asked whether a Codex.app is installed at most every 30 s.
    private static let installedLookupTTL: TimeInterval = 30

    private let frontmostOverride: String?
    private var observerTokens: [NSObjectProtocol] = []
    private var cachedCodexAppInstalled = false
    private var installedLookupUptime: TimeInterval?

    init(frontmostOverride: String?) {
        self.frontmostOverride = frontmostOverride
    }

    func frontmostBundleID() -> String? {
        if let frontmostOverride { return frontmostOverride }
        let application = NSWorkspace.shared.frontmostApplication
        return effectiveBundleID(
            bundleID: application?.bundleIdentifier,
            bundlePath: application?.bundleURL?.path
        )
    }

    func isRunning(bundleID: String) -> Bool {
        !runningApplications(bundleID: bundleID).isEmpty
    }

    func runningAppPath(bundleID: String) -> String? {
        runningApplications(bundleID: bundleID)
            .lazy
            .compactMap { $0.bundleURL?.path }
            .first
    }

    func addActivationObserver(_ handler: @escaping @MainActor (_ bundleID: String) -> Void) {
        guard frontmostOverride == nil else { return }
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let rawBundleID = application?.bundleIdentifier
            let bundlePath = application?.bundleURL?.path
            MainActor.assumeIsolated {
                guard let self,
                      let bundleID = self.effectiveBundleID(bundleID: rawBundleID, bundlePath: bundlePath)
                else { return }
                handler(bundleID)
            }
        }
        observerTokens.append(token)
    }

    /// Running applications whose effective id is `bundleID`
    /// (`CodexAppIdentity.chatGPTAppBundleID` finds ChatGPT.app under `com.openai.codex`).
    private func runningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: CodexAppIdentity.systemBundleID(for: bundleID))
            .filter { application in
                effectiveBundleID(
                    bundleID: application.bundleIdentifier,
                    bundlePath: application.bundleURL?.path
                ) == bundleID
            }
    }

    private func effectiveBundleID(bundleID: String?, bundlePath: String?) -> String? {
        CodexAppIdentity.effectiveBundleID(
            bundleID: bundleID,
            bundlePath: bundlePath,
            codexAppInstalled: { codexAppInstalled() }
        )
    }

    private func codexAppInstalled() -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let installedLookupUptime, uptime - installedLookupUptime < Self.installedLookupTTL {
            return cachedCodexAppInstalled
        }
        cachedCodexAppInstalled = NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: KnownBundleIDs.codex)
            .contains { CodexAppIdentity.isCodexAppBundle(path: $0.path) }
        installedLookupUptime = uptime
        return cachedCodexAppInstalled
    }
}

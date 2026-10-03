import AppKit
import SwiftUI

import IslandCore

@main
struct AgentIslandApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

/// The composition root. Every live object is built here, in one order, and
/// each later capability plugs in through its wiring file under Composition/.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private(set) var store: StateStore?
    private var instanceLock: SingleInstanceLock?
    private var activity: LiveAppActivity?
    private var peekStatus: (any PeekStatusProviding)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Paths and debug flags from the environment.
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = AppPaths.resolve(environment: environment, home: home)
        let feedPaths = FeedPaths.resolve(environment: environment, home: home)
        let flags = DebugFlags.resolve(environment: environment)
        guard acquireInstanceLock(paths: paths) else { return }

        // 2. Preference defaults. App code reads these keys only through
        // UserDefaults.bool(forKey:)/string(forKey:)/@AppStorage, so launch
        // arguments such as `-chimeMuted NO` override them.
        UserDefaults.standard.register(defaults: [
            PreferenceKeys.screenSelectionMode: ScreenSelectionMode.primary.rawValue,
            PreferenceKeys.chimeMuted: false,
            PreferenceKeys.showExecThreads: false,
        ])

        // 3. Live environment.
        let activity = LiveAppActivity(frontmostOverride: flags.frontmostBundleIDOverride)
        self.activity = activity
        let clock = SystemWallClock()
        let env = WiringEnvironment(
            paths: paths,
            feedPaths: feedPaths,
            flags: flags,
            clock: clock,
            activity: activity,
            defaults: .standard
        )

        // 4. Feeds that exist in this build.
        let feeds = [
            FeedWiring.herdr(env),
            FeedWiring.claudeRegistry(env),
            FeedWiring.codexDesktop(env),
        ].compactMap { $0 }

        // 5. Focus context. Without this cast the Herdr "looking at it" rule
        // would silently never suppress anything.
        let herdrFocus = feeds.lazy.compactMap { $0 as? any HerdrFocusReporting }.first
        let focusProvider = LiveFocusContextProvider(activity: activity, herdrFocus: herdrFocus)

        // 6. Jumps, policy and the store.
        let jump = JumpWiring.make(env)
        let policy = PeekWiring.policy(env)
        let store = StateStore(
            feeds: feeds,
            clock: clock,
            focusProvider: focusProvider,
            jumpPerformer: jump.performer,
            jumpContextProvider: jump.context,
            policy: policy,
            nameOverridesFileURL: paths.sessionNamesFile
        )
        self.store = store

        // 7. Panels, peek, observability, then start.
        let panelController = NotchPanelController(store: store)
        self.panelController = panelController
        peekStatus = PeekWiring.attach(store: store, env: env, panelController: panelController)
        ObservabilityWiring.attach(
            store: store,
            env: env,
            peekStatus: peekStatus,
            jumpPerformer: jump.performer,
            panelController: panelController
        )
        store.start()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// Two live instances would stack duplicate panels and double every
    /// chime. The file lock is atomic across bundled and `swift run` launches.
    private func acquireInstanceLock(paths: AppPaths) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: paths.supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let lock = try SingleInstanceLock.acquire(at: paths.lockFile) else {
                NSLog("Agent Island: another instance owns the application lock; exiting.")
                NSApp.terminate(nil)
                return false
            }
            instanceLock = lock
            return true
        } catch {
            NSLog("Agent Island failed to acquire its application lock: %@", String(describing: error))
            NSApp.terminate(nil)
            return false
        }
    }
}

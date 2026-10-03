import Foundation

/// Codex.app and ChatGPT.app both carry the bundle id `com.openai.codex`
/// (risk 40; both bundles report it). The island means Codex.app when it says
/// "Codex": "Codex is frontmost" suppresses Codex peeks, and
/// "Codex is running" keeps working threads from
/// going stale. `LiveAppActivity` therefore reports every `com.openai.codex`
/// bundle that is not named Codex.app under a separate id, unless no Codex.app
/// is installed, in which case the running bundle stands in for Codex. The
/// Task 15 jump resolver applies the same Codex.app-first rule to deep links.
public enum CodexAppIdentity {
    /// The id reported for a `com.openai.codex` bundle that is not Codex.app
    /// (today ChatGPT.app). It is synthetic: nothing in the island matches it,
    /// so that app never counts as Codex.
    public static let chatGPTAppBundleID = "com.openai.chatgpt"

    /// True when the bundle at `path` is named Codex.app, wherever it lives.
    public static func isCodexAppBundle(path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "Codex.app"
    }

    /// The bundle id the island uses for one running application.
    /// - Any id other than `KnownBundleIDs.codex` (and nil) passes through.
    /// - `com.openai.codex` at a bundle named Codex.app stays `KnownBundleIDs.codex`.
    /// - `com.openai.codex` with no bundle path stays `KnownBundleIDs.codex` (it cannot be told apart).
    /// - Any other `com.openai.codex` bundle becomes `chatGPTAppBundleID` while a Codex.app is
    ///   installed, and stays `KnownBundleIDs.codex` when none is.
    /// `codexAppInstalled` is a LaunchServices lookup in the app, so it is called only for that last case.
    public static func effectiveBundleID(
        bundleID: String?,
        bundlePath: String?,
        codexAppInstalled: () -> Bool
    ) -> String? {
        guard bundleID == KnownBundleIDs.codex,
              let bundlePath, !bundlePath.isEmpty,
              !isCodexAppBundle(path: bundlePath)
        else { return bundleID }
        return codexAppInstalled() ? chatGPTAppBundleID : bundleID
    }

    /// The real bundle id to ask the system for when the island asks about `bundleID`:
    /// `chatGPTAppBundleID` is looked up as `KnownBundleIDs.codex`; every other id is itself.
    public static func systemBundleID(for bundleID: String) -> String {
        bundleID == chatGPTAppBundleID ? KnownBundleIDs.codex : bundleID
    }
}

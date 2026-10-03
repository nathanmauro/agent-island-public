import Foundation

/// AppleScript text for raising the Ghostty window that shows a Herdr workspace.
///
/// Herdr titles the outer terminal `"<host>: <workspace>"` by default. The title
/// follows `agent.focus` asynchronously, so GhosttyRaiser retries the exact prefix
/// a few times and then falls back to the host-only prefix. Every value that
/// reaches the script passes through `AppleScriptText.escape`.
public enum GhosttyScript {
    /// How many times the exact window-title prefix is tried before the host-only prefix.
    public static let exactAttempts = 3
    /// Pause between two exact-prefix attempts (150 ms).
    public static let retryDelayNanoseconds: UInt64 = 150_000_000

    /// Focuses the first Ghostty terminal whose name starts with `titlePrefix`, then
    /// activates Ghostty. Fails (osascript exits non-zero) when Ghostty is not running
    /// or no terminal matches, so the caller can retry or fall back.
    public static func focusTerminal(titlePrefix: String) -> String {
        let prefix = AppleScriptText.escape(titlePrefix)
        return """
        if application id "\(KnownBundleIDs.ghostty)" is not running then error "Ghostty is not running"
        tell application id "\(KnownBundleIDs.ghostty)"
          set matches to every terminal whose name starts with "\(prefix)"
          if (count of matches) is 0 then error "no Ghostty terminal matches the window title prefix"
          focus item 1 of matches
          activate
        end tell
        """
    }

    /// `"fixture-host: api"` → `"fixture-host: "`. Nil when there is no `": "` separator, when
    /// the host part is empty, or when the result would equal the input.
    public static func hostOnlyPrefix(from windowTitlePrefix: String) -> String? {
        guard let separator = windowTitlePrefix.range(of: ": ") else { return nil }
        let host = windowTitlePrefix[..<separator.lowerBound]
        guard !host.isEmpty else { return nil }
        let hostOnly = String(host) + ": "
        return hostOnly == windowTitlePrefix ? nil : hostOnly
    }

    /// The prefixes GhosttyRaiser tries, in order: the exact prefix `exactAttempts`
    /// times, then the host-only prefix when there is one. Empty for a nil or empty prefix.
    public static func attemptPrefixes(for windowTitlePrefix: String?) -> [String] {
        guard let prefix = windowTitlePrefix, !prefix.isEmpty else { return [] }
        var prefixes = Array(repeating: prefix, count: exactAttempts)
        if let hostOnly = hostOnlyPrefix(from: prefix) {
            prefixes.append(hostOnly)
        }
        return prefixes
    }
}

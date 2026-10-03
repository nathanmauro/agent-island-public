import Foundation

/// UserDefaults keys. App code reads them only through `UserDefaults.bool(forKey:)`,
/// `string(forKey:)` or `@AppStorage`, so launch-argument overrides
/// (`-chimeMuted NO`, NSArgumentDomain) apply in the end-to-end run.
public enum PreferenceKeys {
    /// Bool, default false.
    public static let chimeMuted = "chimeMuted"
    /// "primary" | "allDisplays", default "primary".
    public static let screenSelectionMode = "screenSelectionMode"
    /// Bool, default false.
    public static let showExecThreads = "showExecThreads"
    /// Bool, default false (upstream key).
    public static let hideWhenEmpty = "hideWhenEmpty"
}

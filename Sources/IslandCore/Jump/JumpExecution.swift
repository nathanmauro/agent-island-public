import Foundation

/// The execution order every live `JumpPerforming` follows (pure; no I/O).
///
/// - Actions run in plan order.
/// - An action with `onlyIfPreviousFailed: true` is a fallback: it runs only when the
///   action immediately before it ran and failed. Otherwise it is skipped.
/// - A failure is recovered when a fallback right after it (or later in the same
///   fallback chain) succeeds. A recovered failure is not reported.
/// - Every non-fallback action runs even after an earlier failure, and the first
///   unrecovered failure is reported once the plan is exhausted, as a `JumpError`.
///
/// Usage: `while let action = sequencer.next() { run it; sequencer.succeeded() or failed(error) }`,
/// then throw `sequencer.failure` if it is non-nil.
public struct JumpSequencer: Sendable {
    private let actions: [JumpAction]
    private var index = 0
    private var inFlight: JumpAction?
    private var previousFailed = false
    private var pendingFailure: JumpError?
    private var firstUnrecoveredFailure: JumpError?
    /// Actions handed out by `next()`, in order.
    public private(set) var executed: [JumpAction] = []

    public init(_ actions: [JumpAction]) {
        self.actions = actions
    }

    /// The next action to run, or nil when the plan is exhausted.
    public mutating func next() -> JumpAction? {
        while index < actions.count {
            let action = actions[index]
            index += 1
            if Self.isFallback(action) {
                guard previousFailed else { continue }
            } else {
                commitPendingFailure()
            }
            inFlight = action
            executed.append(action)
            return action
        }
        commitPendingFailure()
        return nil
    }

    /// Records that the action last returned by `next()` succeeded.
    public mutating func succeeded() {
        guard inFlight != nil else { return }
        inFlight = nil
        previousFailed = false
        pendingFailure = nil
    }

    /// Records that the action last returned by `next()` failed with `error`.
    public mutating func failed(_ error: Error) {
        guard let action = inFlight else { return }
        inFlight = nil
        previousFailed = true
        if pendingFailure == nil {
            pendingFailure = Self.jumpError(error, action: action)
        }
    }

    /// The first failure no fallback recovered. Read it after `next()` returned nil.
    public var failure: JumpError? { firstUnrecoveredFailure }

    public static func isFallback(_ action: JumpAction) -> Bool {
        switch action {
        case let .activateApp(_, onlyIfPreviousFailed), let .openURL(_, _, onlyIfPreviousFailed):
            return onlyIfPreviousFailed
        case .herdrFocus, .raiseGhostty, .tmuxSwitchClient:
            return false
        }
    }

    /// A short name for logs and error text: "herdrFocus", "raiseGhostty", "activateApp", "openURL", "tmuxSwitchClient".
    public static func label(for action: JumpAction) -> String {
        switch action {
        case .herdrFocus: "herdrFocus"
        case .raiseGhostty: "raiseGhostty"
        case .activateApp: "activateApp"
        case .openURL: "openURL"
        case .tmuxSwitchClient: "tmuxSwitchClient"
        }
    }

    private static func jumpError(_ error: Error, action: JumpAction) -> JumpError {
        if let jumpError = error as? JumpError { return jumpError }
        return .actionFailed("\(label(for: action)): \(error)")
    }

    private mutating func commitPendingFailure() {
        if firstUnrecoveredFailure == nil, let pendingFailure {
            firstUnrecoveredFailure = pendingFailure
        }
        pendingFailure = nil
    }
}

/// Picks the app bundle a deep link must be opened with (pure; no I/O).
public enum JumpAppResolver {
    /// `com.openai.codex` is shared by Codex.app and ChatGPT.app, and both claim `codex:`.
    /// Order: the running bundle when it is Codex.app; else the first installed Codex.app;
    /// else whichever running bundle carries the id; else nil (the planner then plans nothing).
    public static func codexAppPath(runningPath: String?, installedPaths: [String]) -> String? {
        if let runningPath, isCodexApp(runningPath) { return runningPath }
        if let installed = installedPaths.first(where: isCodexApp) { return installed }
        if let runningPath, !runningPath.isEmpty { return runningPath }
        return nil
    }

    /// Claude.app only handles `claude://` when it is running (§5.2), so there is no installed fallback.
    public static func claudeAppPath(runningPath: String?) -> String? {
        guard let runningPath, !runningPath.isEmpty else { return nil }
        return runningPath
    }

    private static func isCodexApp(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "Codex.app"
    }
}

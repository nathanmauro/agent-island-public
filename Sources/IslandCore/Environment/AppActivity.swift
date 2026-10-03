import Foundation

public enum KnownBundleIDs {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let codex = "com.openai.codex"
    public static let claudeDesktop = "com.anthropic.claudefordesktop"
}

/// Frontmost/running application facts. The app implements it over NSWorkspace;
/// tests use FakeAppActivity.
@MainActor
public protocol AppActivityObserving: AnyObject {
    func frontmostBundleID() -> String?
    func isRunning(bundleID: String) -> Bool
    func runningAppPath(bundleID: String) -> String?
    func addActivationObserver(_ handler: @escaping @MainActor (_ bundleID: String) -> Void)
}

/// What the user is looking at right now, for the policy's "suppressed while looking" rule.
public struct FocusContext: Equatable, Sendable {
    public var frontmostBundleID: String?
    /// From the latest Herdr snapshot or pane.focused event.
    public var herdrFocusedPaneID: String?

    public init(frontmostBundleID: String? = nil, herdrFocusedPaneID: String? = nil) {
        self.frontmostBundleID = frontmostBundleID
        self.herdrFocusedPaneID = herdrFocusedPaneID
    }

    /// herdrPane: Ghostty is frontmost and Herdr's focused pane is this pane.
    /// codexThread: Codex is frontmost. claudeDesktop and claudeRemoteControl: Claude is frontmost. terminal: never.
    public func isLooking(at row: AgentRow) -> Bool {
        switch row.jump {
        case let .herdrPane(paneID, _):
            frontmostBundleID == KnownBundleIDs.ghostty && herdrFocusedPaneID == paneID
        case .codexThread:
            frontmostBundleID == KnownBundleIDs.codex
        case .claudeDesktop, .claudeRemoteControl:
            frontmostBundleID == KnownBundleIDs.claudeDesktop
        case .terminal:
            false
        }
    }
}

@MainActor
public protocol FocusContextProviding: AnyObject {
    func currentFocus() -> FocusContext
}

/// Implemented by the Herdr feed; the composition root casts feeds to find it.
@MainActor
public protocol HerdrFocusReporting: AnyObject {
    var focusedPaneID: String? { get }
}

import Foundation

/// One OS-level step of a jump. Executed in order by a JumpPerforming.
public enum JumpAction: Equatable, Codable, Sendable {
    /// Herdr agent.focus {target}.
    case herdrFocus(paneID: String)
    /// AppleScript focus of the Ghostty window whose title starts with the prefix, then activate.
    case raiseGhostty(windowTitlePrefix: String?)
    case activateApp(bundleID: String, onlyIfPreviousFailed: Bool)
    case openURL(String, appPath: String?, onlyIfPreviousFailed: Bool)
    case tmuxSwitchClient(target: String)
}

public struct JumpContext: Equatable, Sendable {
    /// Running com.openai.codex bundle path, else the installed Codex.app, else nil.
    public var codexAppPath: String?
    /// Running com.anthropic.claudefordesktop bundle path, else nil.
    public var claudeAppPath: String?

    public init(codexAppPath: String? = nil, claudeAppPath: String? = nil) {
        self.codexAppPath = codexAppPath
        self.claudeAppPath = claudeAppPath
    }
}

public enum JumpError: Error, Equatable, Sendable {
    case rowNotFound
    case noActions
    case actionFailed(String)
}

/// Spec §7.5 and §5.2: turns a row's JumpTarget into ordered actions. Pure.
public enum JumpPlanner {
    private static let maximumTmuxTargetBytes = 256

    public static func plan(_ target: JumpTarget, context: JumpContext) -> [JumpAction] {
        switch target {
        case let .herdrPane(paneID, windowTitlePrefix):
            return [
                .herdrFocus(paneID: paneID),
                .raiseGhostty(windowTitlePrefix: windowTitlePrefix),
                .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: true),
            ]
        case let .codexThread(id):
            guard let appPath = context.codexAppPath else { return [] }
            return [.openURL("codex://threads/\(id)", appPath: appPath, onlyIfPreviousFailed: false)]
        case let .claudeDesktop(sessionID, tmuxTarget):
            guard let appPath = context.claudeAppPath else {
                return plan(.terminal(tmuxTarget: tmuxTarget), context: context)
            }
            let session = sessionID.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? sessionID
            return [
                .openURL("claude://code/continue?session=\(session)", appPath: appPath, onlyIfPreviousFailed: false),
                .openURL("claude://code/needs-input", appPath: appPath, onlyIfPreviousFailed: true),
            ]
        case let .claudeRemoteControl(bridgeSessionID):
            // Claude Desktop opens claude://claude.ai/<path> in its hosted claude.ai view, where /epitaxy/<bridge id>
            // is that exact conversation. It needs the running app; the session has no terminal to fall back to, so
            // an empty plan (a visible "could not jump") is the fallback.
            guard let appPath = context.claudeAppPath, JumpTarget.isValidBridgeSessionID(bridgeSessionID) else {
                return []
            }
            return [
                .openURL("claude://claude.ai/epitaxy/\(bridgeSessionID)", appPath: appPath, onlyIfPreviousFailed: false),
            ]
        case let .terminal(tmuxTarget):
            let activate = JumpAction.activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false)
            guard let tmuxTarget, isValidTmuxTarget(tmuxTarget) else { return [activate] }
            return [activate, .tmuxSwitchClient(target: tmuxTarget)]
        }
    }

    /// Non-empty, at most 256 UTF-8 bytes, no leading "-" (never an option to tmux),
    /// and no whitespace or control characters.
    public static func isValidTmuxTarget(_ value: String?) -> Bool {
        guard let value, !value.isEmpty,
              value.utf8.count <= maximumTmuxTargetBytes,
              !value.hasPrefix("-") else { return false }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// RFC 3986 unreserved characters; everything else in a query value is percent-encoded.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// Executes planned jump actions.
@MainActor
public protocol JumpPerforming: AnyObject {
    /// In order; onlyIfPreviousFailed honored; throws the first failure. MUST NOT block the
    /// main thread: any subprocess/AppleScript work runs off the main actor and is awaited.
    func perform(_ actions: [JumpAction]) async throws
    var performedLog: [[JumpAction]] { get }
}

@MainActor
public protocol JumpContextProviding: AnyObject {
    func currentJumpContext() -> JumpContext
}

/// A fixed context, for tests and for the dry-run wiring.
@MainActor
public final class StaticJumpContextProvider: JumpContextProviding {
    private let context: JumpContext

    public init(_ context: JumpContext) {
        self.context = context
    }

    public func currentJumpContext() -> JumpContext {
        context
    }
}

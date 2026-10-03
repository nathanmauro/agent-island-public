import Foundation

/// `session_meta.payload.source`. Codex writes either a plain string ("vscode", "exec")
/// or an object such as {"subagent": …}, so it needs its own decoder.
public enum CodexSource: Equatable, Sendable, Decodable {
    case named(String)
    case subagent
    case object(keys: [String])
    case missing

    /// Never throws: an unexpected shape must not discard the whole session_meta line.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() {
                self = .missing
                return
            }
            if let name = try? single.decode(String.self) {
                self = .named(name)
                return
            }
        }
        if let object = try? decoder.container(keyedBy: CodexAnyCodingKey.self) {
            let keys = object.allKeys.map(\.stringValue).sorted()
            self = keys.contains("subagent") ? .subagent : .object(keys: keys)
            return
        }
        self = .object(keys: [])
    }
}

struct CodexAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct CodexSessionMeta: Equatable, Sendable {
    public let id: String
    public let cwd: String?
    public let originator: String?
    public let threadSource: String?
    public let source: CodexSource
    public let startedAt: Date?
}

public struct CodexQuestion: Equatable, Codable, Sendable {
    public let question: String
    public let options: [String]
}

public enum CodexRolloutRecord: Equatable, Sendable {
    case sessionMeta(CodexSessionMeta)
    case taskStarted(turnID: String, at: Date?)
    case taskComplete(turnID: String, lastAgentMessage: String?, at: Date?)
    /// A task_complete carrying a non-null `error` (real shape: {codex_error_info, message}).
    /// Fix round 1, Finding 2: additive — .taskComplete's signature is unchanged (Tasks 10 and 17
    /// depend on it exactly as pinned).
    case taskFailed(turnID: String, at: Date?, message: String)
    case turnAborted(turnID: String?, reason: String?, at: Date?)
    case functionCall(name: String, callID: String, arguments: String, at: Date?)
    case functionCallOutput(callID: String, at: Date?)
    case error(message: String, at: Date?)
}

public struct CodexRolloutFile: Hashable, Sendable {
    public let path: String
    /// The UUID at the end of `rollout-<date>-<uuid>.jsonl`, or nil when the name has another shape.
    public let threadIDFromFileName: String?

    public init(path: String) {
        self.path = path
        threadIDFromFileName = Self.threadID(fromFileName: URL(fileURLWithPath: path).lastPathComponent)
    }

    static func threadID(fromFileName name: String) -> String? {
        let suffix = ".jsonl"
        guard name.hasPrefix("rollout-"), name.hasSuffix(suffix) else { return nil }
        let stem = name.dropLast(suffix.count)
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        guard UUID(uuidString: candidate) != nil else { return nil }
        return candidate
    }
}

public struct ThreadState: Equatable, Sendable {
    public let threadID: String
    public var meta: CodexSessionMeta? = nil
    public var openTurnID: String? = nil
    public var lastCompletedTurnID: String? = nil
    public var lastCompletedAt: Date? = nil
    public var lastAgentMessage: String? = nil
    /// call_id → question for open `request_user_input` calls (exact waiting).
    public var openUserInputCalls: [String: CodexQuestion] = [:]
    /// Set by a `request_user_input_async` call in the current or last completed turn; cleared by the next
    /// task_started or turn_aborted. `CodexReducer.rows` honors it only once that turn has completed.
    public var asyncQuestionInLastCompletedTurn: CodexQuestion? = nil
    public var lastError: String? = nil
    public var lastErrorAt: Date? = nil
    /// The turn id `lastError` belongs to, or nil for a standalone event_msg error/stream_error
    /// (never observed in real data) that is not tied to any turn. Only `.taskFailed` sets this;
    /// `.taskStarted` and a standalone `.error` clear it. `CodexReducer.rows` uses it (not
    /// `openTurnID`) to tell a closed failed turn (seen-gated) from a standalone error (shown
    /// until the next task_started, regardless of seen).
    public var lastErrorTurnID: String? = nil
    public var lastEventAt: Date? = nil
}

public enum CodexThreadFilter {
    static let hiddenThreadSources: Set<String> = ["guardian_review", "subagent"]

    /// Hidden: meta nil; source object with "subagent"; threadSource ∈ {guardian_review, subagent};
    /// originator containing "chrome"; exec (originator codex_exec or source "exec") unless showExec.
    public static func isVisible(_ meta: CodexSessionMeta?, showExec: Bool) -> Bool {
        guard let meta else { return false }
        switch meta.source {
        case .subagent:
            return false
        case .object(let keys) where keys.contains("subagent"):
            return false
        default:
            break
        }
        if let threadSource = meta.threadSource, hiddenThreadSources.contains(threadSource) {
            return false
        }
        let originator = meta.originator?.lowercased() ?? ""
        if originator.contains("chrome") {
            return false
        }
        let isExec = originator == "codex_exec" || meta.source == .named("exec")
        if isExec && !showExec {
            return false
        }
        return true
    }
}

import Darwin
import Foundation

/// Re-derived from Moonglade's CodexRolloutParser: the same envelope decoding
/// ({"timestamp","type","payload"}), with a byte prefilter so only lines that can carry a
/// record the island uses are JSON-decoded.
public struct CodexRolloutParser: Sendable {
    static let userInputToolName = "request_user_input"
    static let asyncUserInputToolName = "request_user_input_async"

    static let prefilterTokens: [[UInt8]] = [
        "session_meta", "task_started", "task_complete", "turn_aborted",
        "function_call", "\"error\"", "stream_error",
    ].map { Array($0.utf8) }

    private static let decoder = JSONDecoder()
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDateFormatter = ISO8601DateFormatter()

    /// nil for malformed or unknown lines. Only the two question tools produce `.functionCall`.
    public static func parse(line: Data) -> CodexRolloutRecord? {
        guard mayContainRecord(line),
              let envelope = try? decoder.decode(Envelope.self, from: line),
              let payload = envelope.payload
        else { return nil }
        let at = envelope.timestamp.flatMap(parseDate)
        switch (envelope.type, payload.type) {
        case ("session_meta", _):
            guard let id = payload.id, !id.isEmpty else { return nil }
            return .sessionMeta(CodexSessionMeta(
                id: id,
                cwd: payload.cwd,
                originator: payload.originator,
                threadSource: payload.threadSource,
                source: payload.source ?? .missing,
                startedAt: payload.timestamp.flatMap(parseDate) ?? at
            ))
        case ("event_msg", "task_started"?):
            guard let turnID = payload.turnID else { return nil }
            return .taskStarted(turnID: turnID, at: at)
        case ("event_msg", "task_complete"?):
            guard let turnID = payload.turnID else { return nil }
            if let error = payload.error {
                let trimmed = error.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message: String
                if let trimmed, !trimmed.isEmpty {
                    message = trimmed
                } else if let info = error.codexErrorInfo, !info.isEmpty {
                    message = "Codex turn failed: \(info)"
                } else {
                    message = "Codex turn failed"
                }
                return .taskFailed(turnID: turnID, at: at, message: message)
            }
            return .taskComplete(turnID: turnID, lastAgentMessage: payload.lastAgentMessage, at: at)
        case ("event_msg", "turn_aborted"?):
            return .turnAborted(turnID: payload.turnID, reason: payload.reason, at: at)
        // event_msg "error"/"stream_error" are the spec's inferred names for a standalone failure
        // event; neither was observed in any real ~/.codex rollout (fix round 1, Finding 2 audit).
        // Real task failures instead arrive as a task_complete with a non-null `error`, handled
        // above as `.taskFailed`. This mapping is kept because it is harmless and may exist on
        // some Codex version or channel not covered by the audited sample.
        case ("event_msg", "error"?), ("event_msg", "stream_error"?):
            let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .error(message: message.isEmpty ? "Codex reported an error" : message, at: at)
        case ("response_item", "function_call"?):
            guard let name = payload.name,
                  name == userInputToolName || name == asyncUserInputToolName,
                  let callID = payload.callID
            else { return nil }
            return .functionCall(name: name, callID: callID, arguments: payload.arguments ?? "", at: at)
        case ("response_item", "function_call_output"?):
            guard let callID = payload.callID else { return nil }
            return .functionCallOutput(callID: callID, at: at)
        default:
            return nil
        }
    }

    /// questions[0].question (falling back to questions[0].title — the real request_user_input_async
    /// shape uses `title`, not `question`) and at most 4 option labels. Options are accepted either
    /// as `[{label}]` objects (the exact tool's shape) or as a plain `[String]` (the real async shape).
    public static func question(fromArguments arguments: String) -> CodexQuestion? {
        guard let data = arguments.data(using: .utf8),
              let decoded = try? decoder.decode(QuestionArguments.self, from: data),
              let first = decoded.questions?.first,
              let text = (first.question ?? first.title)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        let labels = (first.options ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return CodexQuestion(question: text, options: Array(labels.prefix(4)))
    }

    static func mayContainRecord(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            for token in prefilterTokens {
                let found = token.withUnsafeBytes { needle -> Bool in
                    memmem(base, raw.count, needle.baseAddress, needle.count) != nil
                }
                if found { return true }
            }
            return false
        }
    }

    static func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? plainDateFormatter.date(from: value)
    }

    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload?

        private enum Key: String, CodingKey { case timestamp, type, payload }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            type = try container.decode(String.self, forKey: .type)
            timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
            payload = try? container.decodeIfPresent(Payload.self, forKey: .payload)
        }
    }

    /// Every field is decoded leniently: a field of an unexpected type becomes nil instead of
    /// failing the line.
    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let cwd: String?
        let timestamp: String?
        let originator: String?
        let source: CodexSource?
        let threadSource: String?
        let turnID: String?
        let lastAgentMessage: String?
        let reason: String?
        let name: String?
        let callID: String?
        let arguments: String?
        let message: String?
        let error: TaskCompleteError?

        private enum Key: String, CodingKey {
            case type, id, cwd, timestamp, originator, source, reason, name, arguments, message, error
            case threadSource = "thread_source"
            case turnID = "turn_id"
            case lastAgentMessage = "last_agent_message"
            case callID = "call_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func text(_ key: Key) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
            type = text(.type)
            id = text(.id)
            cwd = text(.cwd)
            timestamp = text(.timestamp)
            originator = text(.originator)
            source = try? container.decodeIfPresent(CodexSource.self, forKey: .source)
            threadSource = text(.threadSource)
            turnID = text(.turnID)
            lastAgentMessage = text(.lastAgentMessage)
            reason = text(.reason)
            name = text(.name)
            callID = text(.callID)
            arguments = text(.arguments)
            message = text(.message)
            error = try? container.decodeIfPresent(TaskCompleteError.self, forKey: .error)
        }
    }

    /// `task_complete.payload.error`: the real failure shape (`codex_error_info`, `message`),
    /// decoded leniently. Not observed alongside the spec's inferred `error`/`stream_error` names.
    private struct TaskCompleteError: Decodable {
        let message: String?
        let codexErrorInfo: String?

        private enum Key: String, CodingKey {
            case message
            case codexErrorInfo = "codex_error_info"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            codexErrorInfo = try? container.decodeIfPresent(String.self, forKey: .codexErrorInfo)
        }
    }

    private struct QuestionArguments: Decodable {
        let questions: [Item]?

        struct Item: Decodable {
            let question: String?
            let title: String?
            let options: [String]?

            private enum Key: String, CodingKey { case question, title, options }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                question = try? container.decodeIfPresent(String.self, forKey: .question)
                title = try? container.decodeIfPresent(String.self, forKey: .title)
                // Accept either a plain array of strings (the real async shape) or an array of
                // {label} objects (the exact tool's shape).
                if let stringOptions = try? container.decodeIfPresent([String].self, forKey: .options) {
                    options = stringOptions
                } else if let objectOptions = try? container.decodeIfPresent([Option].self, forKey: .options) {
                    options = objectOptions.compactMap(\.label)
                } else {
                    options = nil
                }
            }
        }

        private struct Option: Decodable {
            let label: String?
        }
    }
}

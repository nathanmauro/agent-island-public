import Foundation

/// Synthetic Codex rollout lines with the observed key shapes (no real content).
/// Each function returns one JSON line without the trailing newline.
public enum RolloutLine {
    public static func sessionMeta(id: String, cwd: String = "/tmp/fixture-project", originator: String = "Codex Desktop",
                                   sourceJSON: String = #""vscode""#, threadSource: String? = "user",
                                   forkedFromID: String? = nil, at: Date) -> String {
        var fields = [
            "\"session_id\":\(quote(id))",
            "\"id\":\(quote(id))",
            "\"timestamp\":\(quote(timestamp(at)))",
            "\"cwd\":\(quote(cwd))",
            "\"originator\":\(quote(originator))",
            "\"cli_version\":\"0.0.0-fixture\"",
            "\"source\":\(sourceJSON)",
        ]
        if let threadSource {
            fields.append("\"thread_source\":\(quote(threadSource))")
        }
        if let forkedFromID {
            fields.append("\"forked_from_id\":\(quote(forkedFromID))")
        }
        fields.append("\"model_provider\":\"fixture\"")
        return envelope("session_meta", at: at, fields)
    }

    public static func taskStarted(turnID: String, at: Date) -> String {
        envelope("event_msg", at: at, [
            "\"type\":\"task_started\"",
            "\"turn_id\":\(quote(turnID))",
            "\"started_at\":\(Int(at.timeIntervalSince1970))",
        ])
    }

    public static func taskComplete(turnID: String, message: String?, at: Date) -> String {
        envelope("event_msg", at: at, [
            "\"type\":\"task_complete\"",
            "\"turn_id\":\(quote(turnID))",
            "\"last_agent_message\":\(message.map(quote) ?? "null")",
            "\"completed_at\":\(Int(at.timeIntervalSince1970))",
        ])
    }

    public static func turnAborted(turnID: String, at: Date) -> String {
        envelope("event_msg", at: at, [
            "\"type\":\"turn_aborted\"",
            "\"turn_id\":\(quote(turnID))",
            "\"reason\":\"interrupted\"",
        ])
    }

    public static func functionCall(name: String, callID: String, question: String, options: [String], at: Date) -> String {
        let optionObjects = options
            .map { "{\"label\":\(quote($0)),\"description\":\"Fixture option\"}" }
            .joined(separator: ",")
        let arguments = "{\"questions\":[{\"header\":\"Fixture\",\"id\":\"fixture_question\",\"question\":\(quote(question)),\"options\":[\(optionObjects)]}]}"
        return envelope("response_item", at: at, [
            "\"type\":\"function_call\"",
            "\"name\":\(quote(name))",
            "\"arguments\":\(quote(arguments))",
            "\"call_id\":\(quote(callID))",
        ])
    }

    /// The real `request_user_input_async` shape observed in ~/.codex rollouts: `title` instead of
    /// `question`, and `options` as a plain array of strings (or absent), not `[{label}]` objects.
    public static func functionCallAsync(callID: String, title: String, options: [String] = [], at: Date) -> String {
        let optionValues = options.map(quote).joined(separator: ",")
        let arguments = "{\"questions\":[{\"title\":\(quote(title)),\"options\":[\(optionValues)]}]}"
        return envelope("response_item", at: at, [
            "\"type\":\"function_call\"",
            "\"name\":\"request_user_input_async\"",
            "\"arguments\":\(quote(arguments))",
            "\"call_id\":\(quote(callID))",
        ])
    }

    /// A task_complete carrying a real failure shape: `error: {codex_error_info, message}` and
    /// `last_agent_message: null`. Pass `message: nil` to test the codex_error_info fallback.
    public static func taskCompleteFailed(turnID: String, codexErrorInfo: String, message: String?, at: Date) -> String {
        envelope("event_msg", at: at, [
            "\"type\":\"task_complete\"",
            "\"turn_id\":\(quote(turnID))",
            "\"last_agent_message\":null",
            "\"completed_at\":\(Int(at.timeIntervalSince1970))",
            "\"error\":{\"codex_error_info\":\(quote(codexErrorInfo)),\"message\":\(message.map(quote) ?? "null")}",
        ])
    }

    public static func functionCallOutput(callID: String, at: Date) -> String {
        envelope("response_item", at: at, [
            "\"type\":\"function_call_output\"",
            "\"call_id\":\(quote(callID))",
            "\"output\":\"fixture output\"",
        ])
    }

    public static func errorEvent(type: String = "error", message: String, at: Date) -> String {
        envelope("event_msg", at: at, [
            "\"type\":\(quote(type))",
            "\"message\":\(quote(message))",
        ])
    }

    /// One item_completed line of about `approximateBytes` bytes. It contains none of the parser's
    /// prefilter tokens, so it is never JSON-decoded.
    public static func filler(approximateBytes: Int, at: Date) -> String {
        let head = "{\"timestamp\":\(quote(timestamp(at))),\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"fixture\",\"text\":\""
        let tail = "\"}}}"
        let padding = max(0, approximateBytes - head.utf8.count - tail.utf8.count)
        return head + String(repeating: "x", count: padding) + tail
    }

    /// rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl (UTC).
    public static func fileName(threadID: String, at: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "rollout-\(formatter.string(from: at))-\(threadID).jsonl"
    }

    /// ISO 8601 with milliseconds, UTC, as Codex writes it.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A JSON string literal (quotes included).
    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func envelope(_ type: String, at: Date, _ fields: [String]) -> String {
        "{\"timestamp\":\(quote(timestamp(at))),\"type\":\(quote(type)),\"payload\":{\(fields.joined(separator: ","))}}"
    }
}

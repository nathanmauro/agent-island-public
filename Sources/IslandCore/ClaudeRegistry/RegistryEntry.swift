import Foundation

/// One `~/.claude/sessions/<pid>.json` record. Only the fields the island uses are decoded; every other key is
/// ignored. `pid` and `sessionId` are required. Every other field is optional and tolerant: a missing key, a JSON
/// null or a value of an unexpected type decodes as nil instead of failing the whole entry. `bridgeSessionId` also
/// decodes as nil unless it has the Remote Control id shape (`JumpTarget.isValidBridgeSessionID`).
public struct RegistryEntry: Equatable, Sendable, Decodable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let procStart: String?
    public let kind: String?
    public let entrypoint: String?
    public let name: String?
    public let status: String?
    public let waitingFor: String?
    /// Epoch milliseconds.
    public let statusUpdatedAt: Int64?
    public let tmux: String?
    /// Claude Remote Control's id for the session's conversation ("session_…"); nil when absent or malformed.
    public let bridgeSessionId: String?

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, procStart, kind, entrypoint, name, status, waitingFor, statusUpdatedAt, tmux
        case bridgeSessionId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = Self.optionalString(container, .cwd)
        procStart = Self.optionalString(container, .procStart)
        kind = Self.optionalString(container, .kind)
        entrypoint = Self.optionalString(container, .entrypoint)
        name = Self.optionalString(container, .name)
        status = Self.optionalString(container, .status)
        waitingFor = Self.optionalString(container, .waitingFor)
        statusUpdatedAt = Self.optionalMilliseconds(container, .statusUpdatedAt)
        tmux = Self.optionalString(container, .tmux)
        bridgeSessionId = Self.optionalString(container, .bridgeSessionId).flatMap {
            JumpTarget.isValidBridgeSessionID($0) ? $0 : nil
        }
    }

    /// nil for malformed JSON, a non-object, or a missing/invalid `pid` or `sessionId`.
    public static func decode(_ data: Data) -> RegistryEntry? {
        try? JSONDecoder().decode(RegistryEntry.self, from: data)
    }

    /// "<pid>@<procStart with whitespace runs collapsed to one space>", or "<pid>@?" without a procStart.
    /// A reused pid gets a different key because its start time differs.
    public var rowKey: String {
        let collapsed = procStart.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
        return "\(pid)@\(collapsed.isEmpty ? "?" : collapsed)"
    }

    private static func optionalString(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    private static func optionalMilliseconds(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
        if let integer = (try? container.decodeIfPresent(Int64.self, forKey: key)) ?? nil {
            return integer
        }
        if let double = (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil,
           double.isFinite, abs(double) < 9.0e18 {
            return Int64(double)
        }
        return nil
    }
}

/// The only file names the registry feed may open: one or more ASCII digits followed by ".json".
/// Everything else in the directory, in particular the `*.key` messaging-socket secrets, is never read.
public enum RegistryPathFilter {
    public static func accepts(fileName: String) -> Bool {
        let suffix = ".json"
        guard fileName.hasSuffix(suffix) else { return false }
        let stem = fileName.utf8.dropLast(suffix.utf8.count)
        return !stem.isEmpty && stem.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}

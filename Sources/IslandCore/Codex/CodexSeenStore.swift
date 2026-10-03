import Foundation

/// `codex-seen.json`: {threadId: lastSeenTurnId}. A missing file means first launch (baseline).
public struct CodexSeenStore: Equatable, Sendable, Codable {
    static let maximumFileBytes = 16 * 1_048_576

    public private(set) var lastSeenTurnByThread: [String: String]

    public init() {
        lastSeenTurnByThread = [:]
    }

    public init(from decoder: Decoder) throws {
        lastSeenTurnByThread = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(lastSeenTurnByThread)
    }

    /// nil when the file is missing (first-run baseline). An unreadable or corrupt file also
    /// returns nil, so the caller re-baselines instead of flooding the board.
    public static func load(from url: URL) -> CodexSeenStore? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? SecureFileReader.read(at: url, maximumSize: maximumFileBytes),
              let store = try? JSONDecoder().decode(CodexSeenStore.self, from: data)
        else { return nil }
        return store
    }

    /// Atomic write, mode 0600. Creates the parent directory (0700) when needed.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileWriter.writeAtomically(try encoder.encode(self), to: url, permissions: 0o600)
    }

    public mutating func markSeen(threadID: String, turnID: String) {
        lastSeenTurnByThread[threadID] = turnID
    }

    public func isSeen(threadID: String, turnID: String) -> Bool {
        lastSeenTurnByThread[threadID] == turnID
    }

    /// False when there is no completed turn, when it was marked seen, or when `expiry` has
    /// passed since it completed (measured on the injected wall clock, no replay needed).
    public func isUnseen(threadID: String, turnID: String?, completedAt: Date?, now: Date,
                         expiry: TimeInterval = IslandTiming.seenExpiry) -> Bool {
        guard let turnID, !isSeen(threadID: threadID, turnID: turnID) else { return false }
        if let completedAt, now.timeIntervalSince(completedAt) >= expiry {
            return false
        }
        return true
    }
}

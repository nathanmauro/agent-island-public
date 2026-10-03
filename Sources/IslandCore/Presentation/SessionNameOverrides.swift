import Foundation

/// User-chosen display names for rows, keyed by `RowID.storageKey`
/// ("source|key") so a name survives state churn but never outlives its
/// row. Purely a presentation overlay: feeds rebuild rows from their sources
/// on every event, so a name stored on a row would be lost on the next one.
public struct SessionNameOverrides: Equatable, Sendable, Codable {
    private var namesBySessionKey: [String: String] = [:]

    public init() {}

    /// A blank or empty name clears the override, so the row falls back to
    /// its own title — renaming to nothing is the undo gesture.
    public mutating func rename(_ id: RowID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            namesBySessionKey[id.storageKey] = nil
        } else {
            namesBySessionKey[id.storageKey] = trimmedName
        }
    }

    public func displayName(for id: RowID) -> String? {
        namesBySessionKey[id.storageKey]
    }

    /// Drops names whose row no longer exists so the set cannot grow across
    /// weeks of agent churn. Only entries whose source is in `sources` are
    /// considered: the store passes the sources that are online and have
    /// published, so a silent or disconnected feed keeps its names.
    public mutating func prune(keeping ids: Set<RowID>, sources: Set<SessionSource>) {
        let liveKeys = Set(ids.map(\.storageKey))
        namesBySessionKey = namesBySessionKey.filter { key, _ in
            guard let separator = key.firstIndex(of: "|"),
                  let source = SessionSource(rawValue: String(key[..<separator])),
                  sources.contains(source) else { return true }
            return liveKeys.contains(key)
        }
    }
}

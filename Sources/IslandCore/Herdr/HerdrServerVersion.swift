import Foundation

/// Herdr servers before 0.9.1 apply `agent.focus` to server state only: every attached client
/// keeps its own view, so a jump marks the pane seen but never moves what is on screen. Herdr
/// 0.9.1 made `agent focus` move attached clients (#3760, #4153, #4171). The feed reports such a
/// server as degraded rather than online, so the pill shows why a click does nothing. Pure.
public enum HerdrServerVersion {
    /// The first release whose `agent.focus` moves attached clients.
    public static let minimumForJumps = [0, 9, 1]

    /// Degraded for a server older than 0.9.1; online otherwise, including when the version
    /// cannot be parsed (an unknown build is never blamed).
    public static func health(forServerVersion version: String) -> FeedHealth {
        guard let components = numericComponents(version), isOlder(components, than: minimumForJumps) else {
            return .online
        }
        return .degraded(reason: "server \(version) predates 0.9.1, so a click cannot move the Herdr view; run herdr update --handoff")
    }

    /// "0.9.1-fake" → [0, 9, 1]; "0.9" → [0, 9]. Nil unless the version starts with a digit.
    static func numericComponents(_ version: String) -> [Int]? {
        let core = version.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            components.append(value)
        }
        return components
    }

    /// Lexicographic on numeric components; a missing component counts as zero.
    static func isOlder(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

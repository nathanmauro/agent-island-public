import Foundation

/// `session_index.jsonl`: one {"id","thread_name","updated_at"} object per line.
public enum CodexSessionIndex {
    /// id → thread_name. A later line for the same id wins. Malformed lines and blank names are skipped.
    public static func parse(_ data: Data) -> [String: String] {
        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let id = entry.id, !id.isEmpty,
                  let name = entry.threadName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { continue }
            titles[id] = name
        }
        return titles
    }

    private struct Entry: Decodable {
        let id: String?
        let threadName: String?

        private enum Key: String, CodingKey {
            case id
            case threadName = "thread_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            threadName = try? container.decodeIfPresent(String.self, forKey: .threadName)
        }
    }
}

import Foundation
import IslandCore

/// Writes `StateDumpSnapshot` JSON to `$AGENT_ISLAND_STATE_DUMP` (spec §8). Each write
/// goes to a temporary file in the same directory and is renamed over the target, so a
/// reader never sees a partial file. The caller debounces (50 ms).
public final class StateDump {
    public let url: URL
    private let encoder: JSONEncoder
    private var reportedFailure = false

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func write(_ snapshot: StateDumpSnapshot) {
        do {
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try SecureFileWriter.writeAtomically(data, to: url, permissions: 0o600)
        } catch {
            guard !reportedFailure else { return }
            reportedFailure = true
            NSLog("Agent Island could not write the state dump: %@", String(describing: error))
        }
    }
}

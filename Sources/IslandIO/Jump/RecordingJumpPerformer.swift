import Foundation
import IslandCore

/// Records jump plans instead of running them. Used when AGENT_ISLAND_JUMP_DRY_RUN=1
/// and by tests.
@MainActor
public final class RecordingJumpPerformer: JumpPerforming {
    public private(set) var performedLog: [[JumpAction]] = []
    private let controlDirectory: URL?
    private let controlTimeout: Duration

    public enum ControlError: Error, Equatable, CustomStringConvertible {
        case failed, invalidOutcome, timedOut
        public var description: String {
            switch self {
            case .failed: "Scripted jump failure"
            case .invalidOutcome: "Invalid scripted jump outcome"
            case .timedOut: "Scripted jump timed out"
            }
        }
    }

    public init(controlDirectory: URL? = nil, controlTimeout: Duration = .seconds(60)) {
        self.controlDirectory = controlDirectory
        self.controlTimeout = controlTimeout
    }

    /// Records only by default. Fixture control waits for <attempt>.result (success/failure)
    /// without performing any OS actions. Missing outcomes time out; cancellation propagates.
    public func perform(_ actions: [JumpAction]) async throws {
        performedLog.append(actions)
        guard let controlDirectory else { return }
        let outcome = controlDirectory.appendingPathComponent("\(performedLog.count).result")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: controlTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let data = try SecureFileReader.read(at: outcome, maximumSize: 32,
                                                     requiredPermissions: 0o600, followSymlinks: false)
                switch String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "success": return
                case "failure": throw ControlError.failed
                default: throw ControlError.invalidOutcome
                }
            } catch let error as POSIXError where error.code == .ENOENT {
                // A missing outcome means this fixture jump is still pending.
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ControlError.timedOut
    }
}

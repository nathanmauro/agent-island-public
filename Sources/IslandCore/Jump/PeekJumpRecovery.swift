import Foundation

/// Runs one popup click at a time, keeping recovery attached to the clicked row even if
/// the peek queue promotes a different card while the asynchronous jump completes.
@MainActor
public final class PeekJumpRecovery {
    public private(set) var isRunning = false

    public init() {}

    /// Capture the click before scheduling any work: a feed update may promote the next card
    /// as soon as this input handler returns. The returned task can be cancelled by its owner.
    @discardableResult
    public func perform(
        clickedRow: () -> RowID?,
        focus: @escaping (RowID) async throws -> Void,
        requestRetry: @escaping (RowID, Error) async -> Bool
    ) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        guard let rowID = clickedRow() else {
            isRunning = false
            return nil
        }
        return Task { @MainActor in
            defer { isRunning = false }
            while !Task.isCancelled {
                do {
                    try await focus(rowID)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, await requestRetry(rowID, error) else { return }
                }
            }
        }
    }
}

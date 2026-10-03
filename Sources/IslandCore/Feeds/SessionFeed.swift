import Foundation

/// One source of rows (Herdr, the Claude registry, Codex Desktop).
@MainActor
public protocol SessionFeed: AnyObject {
    var source: SessionSource { get }

    /// Publishes the full row set on every change (idempotent). Rows are kept by
    /// StateStore while the feed is offline.
    func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void)

    func stop()

    /// Click side effects owned by this feed ONLY: island seen-state (Herdr overlay/error
    /// tombstone, Codex seen store, registry seen flag). Called after successful navigation;
    /// validate the captured row's acknowledgmentID against the current episode first.
    /// OS-level actions are planned by JumpPlanner and run by StateStore via JumpPerforming.
    func jump(_ row: AgentRow) async throws

    /// Called once before start(_:). Feeds report health transitions
    /// (online/offline/disabled/inactive).
    func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void)

    /// Lazy detail on hover (Herdr done recap). Default: no-op. Never marks a row seen.
    func loadDetail(for row: AgentRow)
}

extension SessionFeed {
    public func loadDetail(for row: AgentRow) {}
}

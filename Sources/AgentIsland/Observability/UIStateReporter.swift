import IslandCore

/// The one place the app records what the pill, board and card look like, for the
/// state dump. NotchPanelController and PeekController update it on every state
/// change; ObservabilityWiring listens through `onChange` (dump mode only).
@MainActor
final class UIStateReporter {
    static let shared = UIStateReporter()

    var snapshot = UISnapshot()
    /// Runs after `update` changed the snapshot. Never runs for a no-op update.
    var onChange: (() -> Void)?

    func update(_ mutate: (inout UISnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }
}

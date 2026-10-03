import IslandCore

/// What the user is looking at right now, for the interrupt policy's
/// "suppressed while looking" rule: the frontmost app, plus the Herdr pane
/// the latest snapshot or pane.focused event reported (nil without a Herdr
/// feed, so Herdr rows are then never treated as looked at).
@MainActor
final class LiveFocusContextProvider: FocusContextProviding {
    private let activity: any AppActivityObserving
    private let herdrFocus: (any HerdrFocusReporting)?

    init(activity: any AppActivityObserving, herdrFocus: (any HerdrFocusReporting)?) {
        self.activity = activity
        self.herdrFocus = herdrFocus
    }

    func currentFocus() -> FocusContext {
        FocusContext(
            frontmostBundleID: activity.frontmostBundleID(),
            herdrFocusedPaneID: herdrFocus?.focusedPaneID
        )
    }
}

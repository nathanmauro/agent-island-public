import AppKit

import IslandCore

extension PeekWiring {
    /// The real §7.4 policy, replacing the Task 3 stub, behind the wake guard: a decide more than
    /// 30 s after the previous one opens the quiet period first, whatever order the wake reaches the
    /// app in, and a 10 s heartbeat keeps an awake island from ever looking asleep.
    static func policy(_ env: WiringEnvironment) -> any InterruptDeciding {
        WakeGuardedPolicy(InterruptPolicy())
    }

    /// Builds the peek path: PeekController (card panel), ChimePlayer (the only sound) and the
    /// PeekCoordinator that drives both from StoreChange. Also installs the wake guard.
    static func attach(store: StateStore, env: WiringEnvironment, panelController: NotchPanelController) -> (any PeekStatusProviding)? {
        let controller = PeekController(store: store)
        let chime = ChimePlayer()
        let defaults = env.defaults
        let coordinator = PeekCoordinator(
            presenter: controller,
            chime: chime,
            clock: env.clock,
            isMuted: { defaults.bool(forKey: PreferenceKeys.chimeMuted) }
        )
        controller.onCardClick = { [weak coordinator] in
            coordinator?.cardClicked()
        }
        controller.pillAnchorState = { [weak panelController] in
            (panelController?.pillDisplayIDs ?? [], panelController?.isBoardExpanded ?? false)
        }
        // Final-review F3: the card is hidden and held while the board is expanded, so it never sits
        // over the board's rows. NotchPanelController calls onStateChange on every expand and collapse;
        // seed the current value once here.
        panelController.onStateChange = { [weak controller, weak panelController] in
            controller?.boardExpansionChanged(panelController?.isBoardExpanded ?? false)
        }
        controller.boardExpansionChanged(panelController.isBoardExpanded)
        controller.onReanchor = { [weak coordinator] plan, currentDisplayID, fallbackDisplayID in
            coordinator?.reanchorCard(plan: plan, currentDisplayID: currentDisplayID, fallbackDisplayID: fallbackDisplayID)
        }
        store.addChangeObserver(coordinator.handle)

        // Spec §10 / Review Focus 5: after sleep, the same 10 s quiet guard as launch and reconnect,
        // then re-anchor the pill (it settles 0.35 s itself). PeekController re-anchors the card on
        // its own wake observer. WakeGuardedPolicy has usually opened the window already, at the
        // first decide after wake; this extends it from the moment the wake is delivered.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak store, weak panelController] _ in
            MainActor.assumeIsolated {
                store?.beginQuietPeriod(for: Set(SessionSource.allCases))
                panelController?.reanchor()
            }
        }
        return coordinator
    }

    /// Kept for the app's lifetime; the block observer is never removed.
    private static var wakeObserver: NSObjectProtocol?
}

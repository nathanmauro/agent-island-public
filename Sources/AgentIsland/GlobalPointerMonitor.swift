import AppKit

import IslandCore

/// A panel surface that re-derives click-through and hover from the current
/// pointer location. `NotchHostingView` conforms; Task 14's card panel reuses
/// the same hosting view.
@MainActor
protocol PointerRoutingClient: AnyObject {
    func refreshPointerLocation()
}

/// The always-on pointer source for every island panel.
///
/// An `NSTrackingArea` stops delivering events while its window has
/// `ignoresMouseEvents == true`, which is exactly the state a click-through
/// panel sits in whenever the pointer is outside its visible surface. So the
/// panels cannot learn from their own tracking areas that the pointer has come
/// back. This monitor watches every mouse move instead: the global monitor sees
/// moves delivered to other apps (the panel is click-through), the local one
/// sees moves delivered to this app (the panel is interactive). Each move asks
/// every registered panel to re-route itself. Mouse-move monitors need no
/// Accessibility permission, and an idle pointer produces no events at all.
@MainActor
final class GlobalPointerMonitor {
    static let shared = GlobalPointerMonitor()

    private struct WeakClient {
        weak var client: (any PointerRoutingClient)?
    }

    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
    ]

    private var clients: [ObjectIdentifier: WeakClient] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func register(_ client: any PointerRoutingClient) {
        clients[ObjectIdentifier(client)] = WeakClient(client: client)
    }

    func unregister(_ client: any PointerRoutingClient) {
        clients.removeValue(forKey: ObjectIdentifier(client))
    }

    /// Idempotent. The monitors stay installed for the life of the app,
    /// whatever the display count or selection mode.
    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dispatch()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dispatch()
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func dispatch() {
        // Copy first: a refresh can collapse a board or tear a panel down,
        // which unregisters clients while this loop runs.
        let live = clients.values.compactMap(\.client)
        if live.count != clients.count {
            clients = clients.filter { $0.value.client != nil }
        }
        for client in live {
            client.refreshPointerLocation()
        }
    }
}

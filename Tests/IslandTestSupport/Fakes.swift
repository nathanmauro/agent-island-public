import Foundation
import IslandCore

extension AgentRow {
    /// A row with predictable defaults: title "row <key>", subtitle "fixture", and a jump
    /// target that matches the source (herdr → herdrPane(key), codexDesktop → codexThread(key),
    /// claudeRegistry → terminal(nil)). Set `sourceStatus` on the returned value when needed.
    public static func fixture(
        source: SessionSource = .herdr,
        key: String,
        state: DisplayState = .working,
        since: Date = Date(timeIntervalSince1970: 1_800_000_000),
        title: String? = nil,
        detail: Detail? = nil,
        processIDs: [Int32] = [],
        jump: JumpTarget? = nil,
        cwd: String? = nil
    ) -> AgentRow {
        let defaultJump: JumpTarget = switch source {
        case .herdr: .herdrPane(paneID: key, windowTitlePrefix: nil)
        case .codexDesktop: .codexThread(id: key)
        case .claudeRegistry: .terminal(tmuxTarget: nil)
        }
        return AgentRow(
            id: RowID(source: source, key: key),
            title: title ?? "row \(key)",
            subtitle: "fixture",
            state: state,
            since: since,
            detail: detail,
            jump: jump ?? defaultJump,
            cwd: cwd,
            processIDs: processIDs
        )
    }
}

/// A feed the test drives by hand. `publish` and `report` call the store's callbacks
/// synchronously, whether or not the feed is started (so a test can simulate a late
/// publish after stop).
@MainActor
public final class FakeSessionFeed: SessionFeed {
    public let source: SessionSource
    public private(set) var isStarted = false
    public private(set) var stopCount = 0
    public private(set) var jumpedRows: [RowID] = []
    public private(set) var jumpedSnapshots: [AgentRow] = []
    public private(set) var detailRequests: [RowID] = []

    private var publishHandler: (@MainActor ([AgentRow]) -> Void)?
    private var healthHandler: (@MainActor (FeedHealth) -> Void)?

    public init(source: SessionSource) {
        self.source = source
    }

    public func start(_ publish: @escaping @MainActor ([AgentRow]) -> Void) {
        publishHandler = publish
        isStarted = true
    }

    public func stop() {
        isStarted = false
        stopCount += 1
    }

    public func jump(_ row: AgentRow) async throws {
        jumpedRows.append(row.id)
        jumpedSnapshots.append(row)
    }

    public func observeHealth(_ report: @escaping @MainActor (FeedHealth) -> Void) {
        healthHandler = report
    }

    public func loadDetail(for row: AgentRow) {
        detailRequests.append(row.id)
    }

    public func publish(_ rows: [AgentRow]) {
        publishHandler?(rows)
    }

    public func report(_ health: FeedHealth) {
        healthHandler?(health)
    }
}

@MainActor
public final class FakeFocusContextProvider: FocusContextProviding {
    public var focus: FocusContext

    public init(_ focus: FocusContext = FocusContext()) {
        self.focus = focus
    }

    public func currentFocus() -> FocusContext {
        focus
    }
}

/// `runningAppPath` returns `appPaths[id]` only while `running` contains the id.
/// `activate` sets `frontmost` and fires every activation observer in registration
/// order; it does not change `running`.
@MainActor
public final class FakeAppActivity: AppActivityObserving {
    public var frontmost: String?
    public var running: Set<String>
    public var appPaths: [String: String]

    private var activationObservers: [@MainActor (String) -> Void] = []

    public init() {
        frontmost = nil
        running = []
        appPaths = [:]
    }

    public func frontmostBundleID() -> String? {
        frontmost
    }

    public func isRunning(bundleID: String) -> Bool {
        running.contains(bundleID)
    }

    public func runningAppPath(bundleID: String) -> String? {
        running.contains(bundleID) ? appPaths[bundleID] : nil
    }

    public func addActivationObserver(_ handler: @escaping @MainActor (_ bundleID: String) -> Void) {
        activationObservers.append(handler)
    }

    public func activate(_ bundleID: String) {
        frontmost = bundleID
        for observer in activationObservers {
            observer(bundleID)
        }
    }
}

/// Records calls into a shared Log (a class, so the record survives the struct being
/// copied into a store) and returns `scripted` decisions in order, then `.none`.
public struct SpyInterruptDecider: InterruptDeciding {
    public final class Log: @unchecked Sendable {
        public var decideCalls = 0
        public var lastFocus: FocusContext?
        public var quietPeriods: [(sources: Set<SessionSource>, at: Date)] = []

        public init() {}
    }

    public let log: Log
    public var scripted: [PolicyDecision]

    public init(log: Log = Log(), scripted: [PolicyDecision] = []) {
        self.log = log
        self.scripted = scripted
    }

    public mutating func decide(prev: [AgentRow], next: [AgentRow], focus: FocusContext, now: Date) -> PolicyDecision {
        log.decideCalls += 1
        log.lastFocus = focus
        guard !scripted.isEmpty else { return .none }
        return scripted.removeFirst()
    }

    public mutating func beginQuietPeriod(for sources: Set<SessionSource>, at now: Date) {
        log.quietPeriods.append((sources: sources, at: now))
    }
}

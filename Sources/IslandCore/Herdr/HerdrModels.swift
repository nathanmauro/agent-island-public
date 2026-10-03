import Foundation

// Herdr socket API model, protocol 22. Shapes follow the server's published JSON schema
// (success_response, event, subscription_event, error_response). Pure values: no I/O, no clock.

/// A bare JSON value. Codable is hand-written over a single-value container so a value encodes as
/// plain JSON ("a", 1, true, null, [..], {..}); synthesized Codable would wrap each case in an object.
public enum HerdrJSON: Equatable, Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([HerdrJSON])
    case object([String: HerdrJSON])
    case null

    /// Decode order: null, bool, int, double, string, array, object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HerdrJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HerdrJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum HerdrAgentStatus: String, Codable, Sendable {
    case idle, working, blocked, done, unknown

    /// Any value the island does not recognize (including a missing one) is `.unknown`.
    public init(wire: String?) {
        self = wire.flatMap(HerdrAgentStatus.init(rawValue:)) ?? .unknown
    }
}

public struct HerdrPaneInfo: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let focused: Bool
    public let agentStatus: HerdrAgentStatus
    public let agent: String?
    public let terminalTitleStripped: String?
    public let label: String?
    public let cwd: String?
    public let revision: UInt64

    public init(paneID: String, workspaceID: String, tabID: String, focused: Bool = false,
                agentStatus: HerdrAgentStatus, agent: String? = nil, terminalTitleStripped: String? = nil,
                label: String? = nil, cwd: String? = nil, revision: UInt64 = 0) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.focused = focused
        self.agentStatus = agentStatus
        self.agent = agent
        self.terminalTitleStripped = terminalTitleStripped
        self.label = label
        self.cwd = cwd
        self.revision = revision
    }
}

public struct HerdrAgentInfo: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let focused: Bool
    public let agentStatus: HerdrAgentStatus
    public let agent: String?
    public let displayAgent: String?
    public let name: String?
    public let terminalTitleStripped: String?
    public let cwd: String?
    public let stateChangeSeq: UInt64

    public init(paneID: String, workspaceID: String, tabID: String, focused: Bool = false,
                agentStatus: HerdrAgentStatus, agent: String? = nil, displayAgent: String? = nil, name: String? = nil,
                terminalTitleStripped: String? = nil, cwd: String? = nil, stateChangeSeq: UInt64 = 0) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.focused = focused
        self.agentStatus = agentStatus
        self.agent = agent
        self.displayAgent = displayAgent
        self.name = name
        self.terminalTitleStripped = terminalTitleStripped
        self.cwd = cwd
        self.stateChangeSeq = stateChangeSeq
    }
}

public struct HerdrWorkspaceInfo: Equatable, Sendable {
    public let workspaceID: String
    public let label: String
    public let focused: Bool
    public let activeTabID: String?

    public init(workspaceID: String, label: String, focused: Bool = false, activeTabID: String? = nil) {
        self.workspaceID = workspaceID
        self.label = label
        self.focused = focused
        self.activeTabID = activeTabID
    }
}

public struct HerdrTabInfo: Equatable, Sendable {
    public let tabID: String
    public let workspaceID: String
    public let label: String
    public let focused: Bool

    public init(tabID: String, workspaceID: String, label: String, focused: Bool = false) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.label = label
        self.focused = focused
    }
}

public struct HerdrSnapshot: Equatable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [HerdrWorkspaceInfo]
    public let tabs: [HerdrTabInfo]
    public let panes: [HerdrPaneInfo]
    public let agents: [HerdrAgentInfo]

    public init(version: String, protocolVersion: Int, focusedWorkspaceID: String? = nil, focusedTabID: String? = nil,
                focusedPaneID: String? = nil, workspaces: [HerdrWorkspaceInfo] = [], tabs: [HerdrTabInfo] = [],
                panes: [HerdrPaneInfo] = [], agents: [HerdrAgentInfo] = []) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.focusedWorkspaceID = focusedWorkspaceID
        self.focusedTabID = focusedTabID
        self.focusedPaneID = focusedPaneID
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
    }
}

public struct HerdrProcessInfo: Equatable, Sendable {
    public let paneID: String
    public let shellPID: Int32?
    public let foregroundPIDs: [Int32]

    public init(paneID: String, shellPID: Int32? = nil, foregroundPIDs: [Int32] = []) {
        self.paneID = paneID
        self.shellPID = shellPID
        self.foregroundPIDs = foregroundPIDs
    }
}

public struct HerdrRead: Equatable, Sendable {
    public let paneID: String
    public let text: String
    public let truncated: Bool
    public let revision: UInt64

    public init(paneID: String, text: String, truncated: Bool = false, revision: UInt64 = 0) {
        self.paneID = paneID
        self.text = text
        self.truncated = truncated
        self.revision = revision
    }
}

public struct HerdrStatusChange: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let status: HerdrAgentStatus
    public let agent: String?
    public let title: String?

    public init(paneID: String, workspaceID: String, status: HerdrAgentStatus, agent: String? = nil, title: String? = nil) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.status = status
        self.agent = agent
        self.title = title
    }
}

/// Stream events. Names are normalized "." → "_" before matching (status events arrive dotted,
/// lifecycle events arrive underscored).
public enum HerdrEvent: Equatable, Sendable {
    case agentStatusChanged(HerdrStatusChange)                                                 // pane_agent_status_changed
    case paneCreated(HerdrPaneInfo)                                                            // pane_created
    case paneClosed(paneID: String, workspaceID: String)                                       // pane_closed
    case paneExited(paneID: String, workspaceID: String)                                       // pane_exited
    case agentDetected(paneID: String, agent: String?, released: Bool, finalStatus: HerdrAgentStatus?) // pane_agent_detected
    case paneUpdated(HerdrPaneInfo)                                                            // pane_updated
    case paneMoved(previousPaneID: String, pane: HerdrPaneInfo)                                // pane_moved
    case paneFocused(paneID: String, workspaceID: String)                                      // pane_focused
    case tabFocused(tabID: String, workspaceID: String)                                        // tab_focused
    case workspaceFocused(workspaceID: String)                                                 // workspace_focused
    /// workspace_created/closed/renamed, tab_created/closed/renamed. The payload (labels) is ignored:
    /// the feed answers every layout change with a snapshot reconcile.
    case layoutChanged(name: String)
    case unknown(name: String)
}

public struct HerdrError: Error, Equatable, Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// The server rejects a method it does not implement at parse level: invalid_request "unknown variant …".
    public var isUnsupportedMethod: Bool { code == "invalid_request" && message.contains("unknown variant") }
    public var isPaneNotFound: Bool { code == "pane_not_found" }
}

public enum HerdrResult: Equatable, Sendable {
    case pong(version: String, protocolVersion: Int)
    case snapshot(HerdrSnapshot)
    case processInfo(HerdrProcessInfo)
    case read(HerdrRead)
    case subscriptionStarted
    /// Any other success type (for example the reply to agent.focus).
    case ok(type: String)
}

public enum HerdrResponse: Equatable, Sendable {
    case success(id: String, result: HerdrResult)
    /// Parse-level errors arrive with id "".
    case failure(id: String, error: HerdrError)
}

public enum HerdrStreamLine: Equatable, Sendable {
    case ack(id: String)
    case rejected(HerdrError)
    case event(HerdrEvent)
}

/// One entry of an events.subscribe request. (The spec calls this "Subscription"; renamed because
/// Combine exports a protocol with that name.)
public enum HerdrSubscription: Equatable, Sendable {
    /// A global lifecycle or focus type, for example "pane.created".
    case event(String)
    /// {"type":"pane.agent_status_changed","pane_id":P}
    case paneStatus(paneID: String)

    /// The global stream G: lifecycle, focus and layout-change types (15 entries).
    public static let globalStream: [HerdrSubscription] = [
        "pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "pane.updated", "pane.moved",
        "pane.focused", "tab.focused", "workspace.focused", "workspace.created", "workspace.closed",
        "workspace.renamed", "tab.created", "tab.closed", "tab.renamed",
    ].map { HerdrSubscription.event($0) }

    var wireValue: HerdrJSON {
        switch self {
        case let .event(type):
            return .object(["type": .string(type)])
        case let .paneStatus(paneID):
            return .object(["type": .string("pane.agent_status_changed"), "pane_id": .string(paneID)])
        }
    }
}

/// Every request the island sends. Only these methods exist in the island; there is no generic
/// "call any method" path except `.raw`, which only the opt-in contract test uses.
public enum HerdrRequest: Equatable, Sendable {
    case ping
    case snapshot
    case processInfo(paneID: String)
    case readDetection(paneID: String)
    case focus(paneID: String)
    case subscribe([HerdrSubscription])
    case raw(method: String, params: [String: HerdrJSON])

    public var method: String {
        switch self {
        case .ping: return "ping"
        case .snapshot: return "session.snapshot"
        case .processInfo: return "pane.process_info"
        case .readDetection: return "agent.read"
        case .focus: return "agent.focus"
        case .subscribe: return "events.subscribe"
        case let .raw(method, _): return method
        }
    }

    public var params: [String: HerdrJSON] {
        switch self {
        case .ping, .snapshot:
            return [:]
        case let .processInfo(paneID):
            // The schema's PaneProcessInfoParams takes pane_id; only agent.* methods take target.
            return ["pane_id": .string(paneID)]
        case let .readDetection(paneID):
            return ["target": .string(paneID), "source": .string("detection"), "strip_ansi": .bool(true)]
        case let .focus(paneID):
            return ["target": .string(paneID)]
        case let .subscribe(subscriptions):
            return ["subscriptions": .array(subscriptions.map(\.wireValue))]
        case let .raw(_, params):
            return params
        }
    }
}

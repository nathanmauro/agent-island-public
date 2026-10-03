import Foundation

// NDJSON codec for the Herdr socket API, protocol 22.
// Ported from Bantay-TUI (MIT, commit e3e0517) Sources/BantayTUI/HerdrSocketClient.swift
// `HerdrSocketProtocol` (requestLine / parseResponseLine / extractLines); see NOTICE and
// LICENSES/Bantay-TUI.txt. Changes from the original:
// - requests are built from typed HerdrRequest values; agent.* methods send `target` (the original sent
//   pane_id), pane.process_info sends `pane_id` as the schema requires;
// - responses decode into typed results instead of a re-serialized result string;
// - error replies with id "" (parse-level errors) decode instead of being dropped;
// - line splitting keeps a partial trailing line in the buffer instead of splitting a single 64 KB read;
// - event envelopes (dotted status events, underscored lifecycle events) decode into HerdrEvent.
public enum HerdrCodec {
    public static let supportedProtocol = 22

    /// One request line, terminated by "\n".
    public static func encodeRequest(_ request: HerdrRequest, id: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let envelope = RequestEnvelope(id: id, method: request.method, params: request.params)
        var line = (try? encoder.encode(envelope))
            ?? (try? encoder.encode(RequestEnvelope(id: id, method: request.method, params: [:])))
            ?? Data()
        line.append(0x0A)
        return line
    }

    /// Decodes a one-shot reply line. Returns nil for anything that is not a reply.
    public static func decodeResponse(_ line: Data) -> HerdrResponse? {
        guard let envelope = decodeEnvelope(line), let id = envelope.id else { return nil }
        if let error = envelope.error {
            return .failure(id: id, error: error.model)
        }
        guard let result = envelope.result, let type = result.type else { return nil }
        switch type {
        case "pong":
            guard let protocolVersion = result.protocolVersion else { return nil }
            return .success(id: id, result: .pong(version: result.version ?? "", protocolVersion: protocolVersion))
        case "session_snapshot":
            guard let snapshot = result.snapshot?.model else { return nil }
            return .success(id: id, result: .snapshot(snapshot))
        case "pane_process_info":
            guard let info = result.processInfo?.model else { return nil }
            return .success(id: id, result: .processInfo(info))
        case "pane_read":
            guard let read = result.read?.model else { return nil }
            return .success(id: id, result: .read(read))
        case "subscription_started":
            return .success(id: id, result: .subscriptionStarted)
        default:
            return .success(id: id, result: .ok(type: type))
        }
    }

    /// Decodes one line of a subscription connection: the ack, a rejection, or an event.
    public static func decodeStreamLine(_ line: Data) -> HerdrStreamLine? {
        guard let envelope = decodeEnvelope(line) else { return nil }
        if let name = envelope.event {
            return .event(event(named: name, data: envelope.data))
        }
        if let error = envelope.error {
            return .rejected(error.model)
        }
        if let id = envelope.id, envelope.result?.type == "subscription_started" {
            return .ack(id: id)
        }
        return nil
    }

    public static func normalizeEventName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    /// Removes every complete "\n"-terminated line from `buffer` and returns them (without the newline,
    /// a trailing "\r" also dropped, empty lines skipped). A partial trailing line stays in `buffer`.
    public static func takeLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        return lines
    }

    // MARK: - Events

    private static func event(named rawName: String, data: WireEventData?) -> HerdrEvent {
        let name = normalizeEventName(rawName)
        guard let data else { return .unknown(name: name) }
        switch name {
        case "pane_agent_status_changed":
            guard let paneID = data.paneID, let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .agentStatusChanged(HerdrStatusChange(
                paneID: paneID, workspaceID: workspaceID, status: HerdrAgentStatus(wire: data.agentStatus),
                agent: data.agent, title: data.title))
        case "pane_created":
            guard let pane = data.pane?.paneInfo else { return .unknown(name: name) }
            return .paneCreated(pane)
        case "pane_updated":
            guard let pane = data.pane?.paneInfo else { return .unknown(name: name) }
            return .paneUpdated(pane)
        case "pane_moved":
            guard let previous = data.previousPaneID, let pane = data.pane?.paneInfo else { return .unknown(name: name) }
            return .paneMoved(previousPaneID: previous, pane: pane)
        case "pane_closed":
            guard let paneID = data.paneID, let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .paneClosed(paneID: paneID, workspaceID: workspaceID)
        case "pane_exited":
            guard let paneID = data.paneID, let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .paneExited(paneID: paneID, workspaceID: workspaceID)
        case "pane_agent_detected":
            guard let paneID = data.paneID else { return .unknown(name: name) }
            return .agentDetected(paneID: paneID, agent: data.agent, released: data.released ?? false,
                                  finalStatus: data.finalStatus.map { HerdrAgentStatus(wire: $0) })
        case "pane_focused":
            guard let paneID = data.paneID, let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .paneFocused(paneID: paneID, workspaceID: workspaceID)
        case "tab_focused":
            guard let tabID = data.tabID, let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .tabFocused(tabID: tabID, workspaceID: workspaceID)
        case "workspace_focused":
            guard let workspaceID = data.workspaceID else { return .unknown(name: name) }
            return .workspaceFocused(workspaceID: workspaceID)
        case "workspace_created", "workspace_closed", "workspace_renamed", "tab_created", "tab_closed", "tab_renamed":
            return .layoutChanged(name: name)
        default:
            return .unknown(name: name)
        }
    }

    // MARK: - Wire shapes (private; every field optional and type-tolerant, unknown fields ignored)

    private struct RequestEnvelope: Encodable {
        let id: String
        let method: String
        let params: [String: HerdrJSON]
    }

    private static func decodeEnvelope(_ line: Data) -> WireEnvelope? {
        try? JSONDecoder().decode(WireEnvelope.self, from: line)
    }

    private struct WireEnvelope: Decodable {
        let id: String?
        let result: WireResult?
        let error: WireError?
        let event: String?
        let data: WireEventData?

        enum CodingKeys: String, CodingKey { case id, result, error, event, data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.herdrLenient(String.self, .id)
            result = container.herdrLenient(WireResult.self, .result)
            error = container.herdrLenient(WireError.self, .error)
            event = container.herdrLenient(String.self, .event)
            data = container.herdrLenient(WireEventData.self, .data)
        }
    }

    private struct WireError: Decodable {
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey { case code, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = container.herdrLenient(String.self, .code)
            message = container.herdrLenient(String.self, .message)
        }

        var model: HerdrError { HerdrError(code: code ?? "unknown", message: message ?? "") }
    }

    private struct WireResult: Decodable {
        let type: String?
        let version: String?
        let protocolVersion: Int?
        let snapshot: WireSnapshot?
        let processInfo: WireProcessInfo?
        let read: WireRead?

        enum CodingKeys: String, CodingKey {
            case type, version, snapshot, read
            case protocolVersion = "protocol"
            case processInfo = "process_info"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = container.herdrLenient(String.self, .type)
            version = container.herdrLenient(String.self, .version)
            protocolVersion = container.herdrLenient(Int.self, .protocolVersion)
            snapshot = container.herdrLenient(WireSnapshot.self, .snapshot)
            processInfo = container.herdrLenient(WireProcessInfo.self, .processInfo)
            read = container.herdrLenient(WireRead.self, .read)
        }
    }

    private struct WireSnapshot: Decodable {
        let version: String?
        let protocolVersion: Int?
        let focusedWorkspaceID: String?
        let focusedTabID: String?
        let focusedPaneID: String?
        let workspaces: [WireWorkspace]
        let tabs: [WireTab]
        let panes: [WirePane]
        let agents: [WirePane]

        enum CodingKeys: String, CodingKey {
            case version, workspaces, tabs, panes, agents
            case protocolVersion = "protocol"
            case focusedWorkspaceID = "focused_workspace_id"
            case focusedTabID = "focused_tab_id"
            case focusedPaneID = "focused_pane_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = container.herdrLenient(String.self, .version)
            protocolVersion = container.herdrLenient(Int.self, .protocolVersion)
            focusedWorkspaceID = container.herdrLenient(String.self, .focusedWorkspaceID)
            focusedTabID = container.herdrLenient(String.self, .focusedTabID)
            focusedPaneID = container.herdrLenient(String.self, .focusedPaneID)
            workspaces = container.herdrLenient([WireWorkspace].self, .workspaces) ?? []
            tabs = container.herdrLenient([WireTab].self, .tabs) ?? []
            panes = container.herdrLenient([WirePane].self, .panes) ?? []
            agents = container.herdrLenient([WirePane].self, .agents) ?? []
        }

        var model: HerdrSnapshot? {
            guard let protocolVersion else { return nil }
            return HerdrSnapshot(
                version: version ?? "", protocolVersion: protocolVersion,
                focusedWorkspaceID: focusedWorkspaceID, focusedTabID: focusedTabID, focusedPaneID: focusedPaneID,
                workspaces: workspaces.compactMap(\.model), tabs: tabs.compactMap(\.model),
                panes: panes.compactMap(\.paneInfo), agents: agents.compactMap(\.agentInfo))
        }
    }

    private struct WireWorkspace: Decodable {
        let workspaceID: String?
        let label: String?
        let focused: Bool?
        let activeTabID: String?

        enum CodingKeys: String, CodingKey {
            case label, focused
            case workspaceID = "workspace_id"
            case activeTabID = "active_tab_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspaceID = container.herdrLenient(String.self, .workspaceID)
            label = container.herdrLenient(String.self, .label)
            focused = container.herdrLenient(Bool.self, .focused)
            activeTabID = container.herdrLenient(String.self, .activeTabID)
        }

        var model: HerdrWorkspaceInfo? {
            guard let workspaceID else { return nil }
            return HerdrWorkspaceInfo(workspaceID: workspaceID, label: label ?? workspaceID,
                                      focused: focused ?? false, activeTabID: activeTabID)
        }
    }

    private struct WireTab: Decodable {
        let tabID: String?
        let workspaceID: String?
        let label: String?
        let focused: Bool?

        enum CodingKeys: String, CodingKey {
            case label, focused
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tabID = container.herdrLenient(String.self, .tabID)
            workspaceID = container.herdrLenient(String.self, .workspaceID)
            label = container.herdrLenient(String.self, .label)
            focused = container.herdrLenient(Bool.self, .focused)
        }

        var model: HerdrTabInfo? {
            guard let tabID, let workspaceID else { return nil }
            return HerdrTabInfo(tabID: tabID, workspaceID: workspaceID, label: label ?? tabID, focused: focused ?? false)
        }
    }

    /// PaneInfo and AgentInfo share their fields; AgentInfo adds display_agent, name and state_change_seq.
    private struct WirePane: Decodable {
        let paneID: String?
        let workspaceID: String?
        let tabID: String?
        let focused: Bool?
        let agentStatus: String?
        let agent: String?
        let displayAgent: String?
        let name: String?
        let terminalTitleStripped: String?
        let label: String?
        let cwd: String?
        let revision: UInt64?
        let stateChangeSeq: UInt64?

        enum CodingKeys: String, CodingKey {
            case focused, agent, name, label, cwd, revision
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agentStatus = "agent_status"
            case displayAgent = "display_agent"
            case terminalTitleStripped = "terminal_title_stripped"
            case stateChangeSeq = "state_change_seq"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = container.herdrLenient(String.self, .paneID)
            workspaceID = container.herdrLenient(String.self, .workspaceID)
            tabID = container.herdrLenient(String.self, .tabID)
            focused = container.herdrLenient(Bool.self, .focused)
            agentStatus = container.herdrLenient(String.self, .agentStatus)
            agent = container.herdrLenient(String.self, .agent)
            displayAgent = container.herdrLenient(String.self, .displayAgent)
            name = container.herdrLenient(String.self, .name)
            terminalTitleStripped = container.herdrLenient(String.self, .terminalTitleStripped)
            label = container.herdrLenient(String.self, .label)
            cwd = container.herdrLenient(String.self, .cwd)
            revision = container.herdrLenient(UInt64.self, .revision)
            stateChangeSeq = container.herdrLenient(UInt64.self, .stateChangeSeq)
        }

        var paneInfo: HerdrPaneInfo? {
            guard let paneID, let workspaceID, let tabID else { return nil }
            return HerdrPaneInfo(
                paneID: paneID, workspaceID: workspaceID, tabID: tabID, focused: focused ?? false,
                agentStatus: HerdrAgentStatus(wire: agentStatus), agent: agent,
                terminalTitleStripped: terminalTitleStripped, label: label, cwd: cwd, revision: revision ?? 0)
        }

        var agentInfo: HerdrAgentInfo? {
            guard let paneID, let workspaceID, let tabID else { return nil }
            return HerdrAgentInfo(
                paneID: paneID, workspaceID: workspaceID, tabID: tabID, focused: focused ?? false,
                agentStatus: HerdrAgentStatus(wire: agentStatus), agent: agent, displayAgent: displayAgent,
                name: name, terminalTitleStripped: terminalTitleStripped, cwd: cwd, stateChangeSeq: stateChangeSeq ?? 0)
        }
    }

    private struct WireProcessInfo: Decodable {
        let paneID: String?
        let shellPID: Int64?
        let foregroundProcesses: [WireProcess]

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case shellPID = "shell_pid"
            case foregroundProcesses = "foreground_processes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = container.herdrLenient(String.self, .paneID)
            shellPID = container.herdrLenient(Int64.self, .shellPID)
            foregroundProcesses = container.herdrLenient([WireProcess].self, .foregroundProcesses) ?? []
        }

        var model: HerdrProcessInfo? {
            guard let paneID else { return nil }
            return HerdrProcessInfo(
                paneID: paneID, shellPID: shellPID.flatMap { Int32(exactly: $0) },
                foregroundPIDs: foregroundProcesses.compactMap { $0.pid.flatMap { Int32(exactly: $0) } })
        }
    }

    private struct WireProcess: Decodable {
        let pid: Int64?

        enum CodingKeys: String, CodingKey { case pid }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = container.herdrLenient(Int64.self, .pid)
        }
    }

    private struct WireRead: Decodable {
        let paneID: String?
        let text: String?
        let truncated: Bool?
        let revision: UInt64?

        enum CodingKeys: String, CodingKey {
            case text, truncated, revision
            case paneID = "pane_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = container.herdrLenient(String.self, .paneID)
            text = container.herdrLenient(String.self, .text)
            truncated = container.herdrLenient(Bool.self, .truncated)
            revision = container.herdrLenient(UInt64.self, .revision)
        }

        var model: HerdrRead? {
            guard let paneID, let text else { return nil }
            return HerdrRead(paneID: paneID, text: text, truncated: truncated ?? false, revision: revision ?? 0)
        }
    }

    private struct WireEventData: Decodable {
        let type: String?
        let paneID: String?
        let workspaceID: String?
        let tabID: String?
        let agentStatus: String?
        let agent: String?
        let title: String?
        let released: Bool?
        let finalStatus: String?
        let previousPaneID: String?
        let pane: WirePane?

        enum CodingKeys: String, CodingKey {
            case type, agent, title, released, pane
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agentStatus = "agent_status"
            case finalStatus = "final_status"
            case previousPaneID = "previous_pane_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = container.herdrLenient(String.self, .type)
            paneID = container.herdrLenient(String.self, .paneID)
            workspaceID = container.herdrLenient(String.self, .workspaceID)
            tabID = container.herdrLenient(String.self, .tabID)
            agentStatus = container.herdrLenient(String.self, .agentStatus)
            agent = container.herdrLenient(String.self, .agent)
            title = container.herdrLenient(String.self, .title)
            released = container.herdrLenient(Bool.self, .released)
            finalStatus = container.herdrLenient(String.self, .finalStatus)
            previousPaneID = container.herdrLenient(String.self, .previousPaneID)
            pane = container.herdrLenient(WirePane.self, .pane)
        }
    }
}

private extension KeyedDecodingContainer {
    /// Missing key, null, or a value of the wrong type all read as nil.
    func herdrLenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

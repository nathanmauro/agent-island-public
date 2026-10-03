import Darwin
import Foundation
import IslandCore

/// One pane in the fake server's state. `agent == nil` makes it a plain shell (absent from `agents`).
public struct FakeHerdrPane: Equatable, Sendable {
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var agent: String?
    public var status: String
    public var title: String?
    public var cwd: String?
    public var focused: Bool
    public var stateChangeSeq: UInt64

    public init(paneID: String, workspaceID: String, tabID: String? = nil, agent: String? = "claude", status: String = "idle",
                title: String? = nil, cwd: String? = nil, focused: Bool = false, stateChangeSeq: UInt64 = 1) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID ?? "\(workspaceID):t1"
        self.agent = agent
        self.status = status
        self.title = title
        self.cwd = cwd
        self.focused = focused
        self.stateChangeSeq = stateChangeSeq
    }
}

public struct FakeHerdrState: Equatable, Sendable {
    public var panes: [FakeHerdrPane]
    public var workspaceLabels: [String: String]
    public var tabLabels: [String: String]
    public var focusedPaneID: String?

    public init(panes: [FakeHerdrPane] = [], workspaceLabels: [String: String] = [:], tabLabels: [String: String] = [:],
                focusedPaneID: String? = nil) {
        self.panes = panes
        self.workspaceLabels = workspaceLabels
        self.tabLabels = tabLabels
        self.focusedPaneID = focusedPaneID
    }
}

public struct FakeHerdrRequestRecord: Equatable, Sendable {
    public let method: String
    /// The request's params re-serialized with sorted keys (compare parsed, not as text).
    public let paramsJSON: String

    public init(method: String, paramsJSON: String) {
        self.method = method
        self.paramsJSON = paramsJSON
    }
}

public struct FakeHerdrServerError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32
    public var description: String { "FakeHerdrServer \(operation) failed: errno \(code) (\(String(cString: strerror(code))))" }
}

/// In-process Herdr socket server (protocol 22 wire shapes) for tests and the end-to-end driver.
///
/// Behavior, mirroring the real server where it matters to the island:
/// - One-shot requests are answered with one line and the server closes the connection.
/// - `events.subscribe` answers `{"type":"subscription_started"}` and keeps the connection; any byte the
///   client writes afterwards is counted in `bytesReceivedAfterSubscribe` and closes the connection.
/// - A subscription naming an unknown pane is rejected atomically with pane_not_found; the server then
///   waits for the client to close (so tests can prove the client closes its descriptor).
/// - Unknown methods get the parse-level reply `{"id":"","error":{"code":"invalid_request","message":"unknown variant …"}}`.
/// - agent.focus records the target, focuses the pane, and like Herdr marks it seen: a `done` pane
///   becomes `idle` and its status subscribers get that change; global subscribers get pane_focused.
/// - Status events use the dotted envelope (`pane.agent_status_changed`, no data.type); lifecycle
///   events use the underscored envelope with data.type.
/// All state lives on one private serial queue; public members may be called from any thread.
public final class FakeHerdrServer: @unchecked Sendable {
    public let socketPath: String

    private let queue = DispatchQueue(label: "agent-island.fake-herdr")
    private var serverVersion: String
    private var currentProtocol: Int
    private var listenerSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 0
    private var openDescriptors = 0
    private var state = FakeHerdrState()
    private var detectionTexts: [String: String] = [:]
    private var heldDetectionPanes: Set<String> = []
    private var heldDetectionReplies: [(paneID: String, reply: [String: Any], connection: Connection)] = []
    private var processIDs: [String: [Int32]] = [:]
    private var rejections: [String: (code: String, message: String)] = [:]
    private var requests: [FakeHerdrRequestRecord] = []
    private var focusTargets: [String] = []
    private var bytesAfterSubscribe = 0
    private var isStopped = false

    private static let pathLock = NSLock()
    private static var pathCounter = 0

    private final class Connection {
        let id: Int
        let descriptor: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var isSubscribed = false
        var isClosed = false
        var globalTypes: Set<String> = []
        var statusPaneIDs: Set<String> = []
        var silencedPaneIDs: Set<String> = []

        init(id: Int, descriptor: Int32) {
            self.id = id
            self.descriptor = descriptor
        }
    }

    /// Default path /tmp/hf-<pid>-<n>.sock stays far below the 104-byte sun_path limit.
    public init(socketPath: String? = nil, protocolVersion: Int = 22, version: String = "0.9.1-fake") throws {
        if let socketPath {
            self.socketPath = socketPath
        } else {
            FakeHerdrServer.pathLock.lock()
            FakeHerdrServer.pathCounter += 1
            let counter = FakeHerdrServer.pathCounter
            FakeHerdrServer.pathLock.unlock()
            self.socketPath = "/tmp/hf-\(getpid())-\(counter).sock"
        }
        self.currentProtocol = protocolVersion
        self.serverVersion = version
        try queue.sync { try self.startListening() }
    }

    /// Never `queue.sync` here: the last release can happen on `queue` itself (a handler's temporary
    /// strong reference), and a sync onto the current queue traps. Handlers hold `self` weakly, so by
    /// the time deinit runs nothing else can reach this state and it is safe to tear down directly.
    deinit {
        guard !isStopped else { return }
        isStopped = true
        closeEverything()
    }

    // MARK: - Configuration

    public var protocolVersion: Int {
        get { queue.sync { currentProtocol } }
        set { queue.sync { currentProtocol = newValue } }
    }

    public func setState(_ state: FakeHerdrState) {
        queue.sync { self.state = state }
    }

    public func updateState(_ mutate: (inout FakeHerdrState) -> Void) {
        queue.sync { mutate(&state) }
    }

    public func setDetectionText(paneID: String, _ text: String) {
        queue.sync { detectionTexts[paneID] = text }
    }

    /// Captures detection replies at request time but leaves the rest of the socket traffic flowing.
    public func holdDetectionReads(paneID: String) {
        queue.sync { _ = heldDetectionPanes.insert(paneID) }
    }

    /// Releases the oldest captured reply, including one whose client has since cancelled its request.
    public func releaseNextDetectionRead(paneID: String) {
        queue.sync {
            guard let index = heldDetectionReplies.firstIndex(where: { $0.paneID == paneID }) else { return }
            let held = heldDetectionReplies.remove(at: index)
            reply(held.reply, to: held.connection, thenClose: true)
        }
    }

    public func setProcessInfo(paneID: String, foregroundPIDs: [Int32]) {
        queue.sync { processIDs[paneID] = foregroundPIDs }
    }

    /// Every later request for `method` gets {"id":…,"error":{"code":code,"message":message}}. The default
    /// message is Herdr's parse-level "unknown variant" text, so isUnsupportedMethod is true (and, like a
    /// parse-level error, the reply id is "").
    public func rejectMethod(_ method: String, code: String = "invalid_request", message: String? = nil) {
        let text = message ?? "unknown variant `\(method)`, expected one of `ping`, `session.snapshot`, `events.subscribe`"
        queue.sync { rejections[method] = (code, text) }
    }

    public func clearRejections() {
        queue.sync { rejections.removeAll() }
    }

    // MARK: - Events

    /// Writes a raw event line ({"event":…,"data":…}) to every connection holding a global subscription.
    public func emitGlobal(_ eventJSON: String) {
        queue.sync {
            let line = Data((eventJSON.hasSuffix("\n") ? eventJSON : eventJSON + "\n").utf8)
            for connection in liveConnections where !connection.globalTypes.isEmpty {
                write(line, to: connection)
            }
        }
    }

    public func emitPaneCreated(_ pane: FakeHerdrPane) {
        queue.sync {
            if let index = state.panes.firstIndex(where: { $0.paneID == pane.paneID }) {
                state.panes[index] = pane
            } else {
                state.panes.append(pane)
            }
            broadcastGlobal(["event": "pane_created", "data": ["type": "pane_created", "pane": paneJSON(pane)]])
        }
    }

    public func emitPaneClosed(paneID: String) {
        queue.sync {
            let workspaceID = workspaceID(of: paneID)
            state.panes.removeAll { $0.paneID == paneID }
            if state.focusedPaneID == paneID { state.focusedPaneID = nil }
            broadcastGlobal(["event": "pane_closed",
                             "data": ["type": "pane_closed", "pane_id": paneID, "workspace_id": workspaceID]])
        }
    }

    public func emitPaneExited(paneID: String) {
        queue.sync {
            broadcastGlobal(["event": "pane_exited",
                             "data": ["type": "pane_exited", "pane_id": paneID, "workspace_id": workspaceID(of: paneID)]])
        }
    }

    /// released == false: an agent was detected (agent defaults to "claude"). released == true: the agent
    /// left the pane; the event carries its last status as final_status and the pane becomes a shell.
    public func emitAgentDetected(paneID: String, released: Bool) {
        queue.sync {
            let workspaceID = workspaceID(of: paneID)
            var agent: Any = NSNull()
            var finalStatus: Any = NSNull()
            if let index = state.panes.firstIndex(where: { $0.paneID == paneID }) {
                if released {
                    finalStatus = state.panes[index].status
                    state.panes[index].agent = nil
                    state.panes[index].status = "unknown"
                } else {
                    let name = state.panes[index].agent ?? "claude"
                    state.panes[index].agent = name
                    agent = name
                }
            } else if !released {
                agent = "claude"
            }
            broadcastGlobal(["event": "pane_agent_detected",
                             "data": ["type": "pane_agent_detected", "pane_id": paneID, "workspace_id": workspaceID,
                                      "agent": agent, "released": released, "final_status": finalStatus]])
        }
    }

    /// Updates the pane's status (bumping state_change_seq) and sends the dotted status event to that
    /// pane's status subscribers (except silenced ones).
    public func emitStatus(paneID: String, status: String) {
        queue.sync { emitStatusLocked(paneID: paneID, status: status) }
    }

    /// Herdr #3124: the acknowledged connection stays open but receives nothing more. A new subscription
    /// for the same pane is not affected.
    public func silenceStatusStream(paneID: String) {
        queue.sync {
            for connection in liveConnections where connection.statusPaneIDs.contains(paneID) {
                connection.silencedPaneIDs.insert(paneID)
            }
        }
    }

    // MARK: - Connections

    /// Closes every accepted connection (clients read EOF). The listener stays up.
    public func dropAllConnections() {
        queue.sync {
            for connection in liveConnections { closeConnection(connection) }
        }
    }

    /// Closes everything, unlinks the path and binds a new listener at the same path (a new inode).
    /// `version` replaces the reported server version, as a live handoff to a newer Herdr would.
    public func restart(protocolVersion: Int? = nil, version: String? = nil) throws {
        try queue.sync {
            closeEverything()
            if let protocolVersion { currentProtocol = protocolVersion }
            if let version { serverVersion = version }
            isStopped = false
            try startListening()
        }
    }

    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            closeEverything()
        }
    }

    // MARK: - Inspection

    public var requestLog: [FakeHerdrRequestRecord] { queue.sync { requests } }

    public func subscriberCount(paneID: String) -> Int {
        queue.sync { liveConnections.filter { $0.statusPaneIDs.contains(paneID) }.count }
    }

    public var globalSubscriberCount: Int {
        queue.sync { liveConnections.filter { !$0.globalTypes.isEmpty }.count }
    }

    /// Descriptors the server holds right now: the listener plus accepted connections not yet closed.
    public var liveDescriptorCount: Int { queue.sync { openDescriptors } }

    public var bytesReceivedAfterSubscribe: Int { queue.sync { bytesAfterSubscribe } }

    public var focusRequests: [String] { queue.sync { focusTargets } }

    // MARK: - Listener (queue-confined from here on)

    private var liveConnections: [Connection] {
        connections.values.filter { !$0.isClosed }.sorted { $0.id < $1.id }
    }

    private func startListening() throws {
        let pathBytes = Array(socketPath.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw FakeHerdrServerError(operation: "path length", code: ENAMETOOLONG)
        }
        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FakeHerdrServerError(operation: "socket", code: errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // Accepted sockets inherit SO_NOSIGPIPE from the listener. The per-accept setsockopt below
        // fails with EINVAL when the client has already gone, and a reply would then raise SIGPIPE.
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 128) == 0 else {
            let code = errno
            close(descriptor)
            throw FakeHerdrServerError(operation: "bind/listen", code: code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        openDescriptors += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: descriptor) }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.openDescriptors -= 1
        }
        listenerSource = source
        source.resume()
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            var enabled: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            openDescriptors += 1
            nextConnectionID += 1
            let connection = Connection(id: nextConnectionID, descriptor: descriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.readAvailable(from: connection)
            }
            source.setCancelHandler { [weak self] in
                close(descriptor)
                self?.openDescriptors -= 1
            }
            connection.source = source
            connections[connection.id] = connection
            source.resume()
        }
    }

    private func readAvailable(from connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !connection.isClosed {
            let count = chunk.withUnsafeMutableBytes { read(connection.descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                receive(Data(chunk[0..<count]), on: connection)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                closeConnection(connection)   // EOF or error
                return
            }
        }
    }

    private func receive(_ chunk: Data, on connection: Connection) {
        if connection.isSubscribed {
            bytesAfterSubscribe += chunk.count
            closeConnection(connection)
            return
        }
        connection.buffer.append(chunk)
        for line in HerdrCodec.takeLines(from: &connection.buffer) {
            guard !connection.isClosed else { return }
            if connection.isSubscribed {
                bytesAfterSubscribe += line.count + 1
                closeConnection(connection)
                return
            }
            handleRequest(line, on: connection)
        }
        if connection.isSubscribed && !connection.buffer.isEmpty {
            bytesAfterSubscribe += connection.buffer.count
            connection.buffer = Data()
            closeConnection(connection)
        }
    }

    private func closeConnection(_ connection: Connection) {
        guard !connection.isClosed else { return }
        connection.isClosed = true
        connections[connection.id] = nil
        connection.source?.cancel()   // the cancel handler closes the descriptor
        connection.source = nil
    }

    private func closeEverything() {
        for connection in liveConnections { closeConnection(connection) }
        heldDetectionReplies = []
        listenerSource?.cancel()
        listenerSource = nil
        unlink(socketPath)
    }

    // MARK: - Requests

    private func handleRequest(_ line: Data, on connection: Connection) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            reply(["id": "", "error": ["code": "invalid_request", "message": "expected value at line 1 column 1"]],
                  to: connection, thenClose: true)
            return
        }
        let id = object["id"] as? String ?? ""
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        requests.append(FakeHerdrRequestRecord(method: method, paramsJSON: FakeHerdrServer.canonicalJSON(params)))

        if let rejection = rejections[method] {
            let replyID = rejection.message.contains("unknown variant") ? "" : id
            reply(["id": replyID, "error": ["code": rejection.code, "message": rejection.message]],
                  to: connection, thenClose: method != "events.subscribe")
            return
        }

        switch method {
        case "ping":
            reply(["id": id, "result": ["type": "pong", "version": serverVersion, "protocol": currentProtocol,
                                        "capabilities": ["live_handoff": false]]],
                  to: connection, thenClose: true)
        case "session.snapshot":
            reply(["id": id, "result": ["type": "session_snapshot", "snapshot": snapshotJSON()]], to: connection, thenClose: true)
        case "agent.read":
            handleRead(id: id, params: params, connection: connection)
        case "agent.focus":
            handleFocus(id: id, params: params, connection: connection)
        case "pane.process_info":
            handleProcessInfo(id: id, params: params, connection: connection)
        case "events.subscribe":
            handleSubscribe(id: id, params: params, connection: connection)
        default:
            reply(["id": "", "error": ["code": "invalid_request",
                                       "message": "unknown variant `\(method)`, expected one of `ping`, `session.snapshot`"]],
                  to: connection, thenClose: true)
        }
    }

    private func handleRead(id: String, params: [String: Any], connection: Connection) {
        guard let paneID = params["target"] as? String, let pane = state.panes.first(where: { $0.paneID == paneID }) else {
            replyPaneNotFound(id: id, params: params, key: "target", connection: connection, thenClose: true)
            return
        }
        guard params["source"] as? String == "detection" else {
            reply(["id": id, "error": ["code": "invalid_params", "message": "fake server serves detection reads only"]],
                  to: connection, thenClose: true)
            return
        }
        let read: [String: Any] = [
            "pane_id": paneID, "workspace_id": pane.workspaceID, "tab_id": pane.tabID, "source": "detection",
            "format": "text", "text": detectionTexts[paneID] ?? "", "revision": 1, "truncated": false,
        ]
        let response: [String: Any] = ["id": id, "result": ["type": "pane_read", "read": read]]
        if heldDetectionPanes.contains(paneID) {
            heldDetectionReplies.append((paneID, response, connection))
        } else {
            reply(response, to: connection, thenClose: true)
        }
    }

    private func handleFocus(id: String, params: [String: Any], connection: Connection) {
        let target = params["target"] as? String ?? ""
        focusTargets.append(target)
        guard let pane = state.panes.first(where: { $0.paneID == target }) else {
            replyPaneNotFound(id: id, params: params, key: "target", connection: connection, thenClose: true)
            return
        }
        let changed = state.focusedPaneID != target
        state.focusedPaneID = target
        for index in state.panes.indices { state.panes[index].focused = (state.panes[index].paneID == target) }
        reply(["id": id, "result": ["type": "ok"]], to: connection, thenClose: true)
        if changed {
            broadcastGlobal(["event": "pane_focused",
                             "data": ["type": "pane_focused", "pane_id": target, "workspace_id": pane.workspaceID]])
        }
        if pane.status == "done" {
            emitStatusLocked(paneID: target, status: "idle")
        }
    }

    private func handleProcessInfo(id: String, params: [String: Any], connection: Connection) {
        guard let paneID = params["pane_id"] as? String, state.panes.contains(where: { $0.paneID == paneID }) else {
            replyPaneNotFound(id: id, params: params, key: "pane_id", connection: connection, thenClose: true)
            return
        }
        let processes = (processIDs[paneID] ?? []).map { ["pid": Int($0), "name": "claude"] as [String: Any] }
        let info: [String: Any] = ["pane_id": paneID, "shell_pid": NSNull(), "foreground_processes": processes]
        reply(["id": id, "result": ["type": "pane_process_info", "process_info": info]], to: connection, thenClose: true)
    }

    private func handleSubscribe(id: String, params: [String: Any], connection: Connection) {
        guard let list = params["subscriptions"] as? [[String: Any]], !list.isEmpty else {
            reply(["id": id, "error": ["code": "invalid_params", "message": "subscriptions must be a non-empty array"]],
                  to: connection, thenClose: true)
            return
        }
        var globalTypes = Set<String>()
        var paneIDs = Set<String>()
        for item in list {
            guard let type = item["type"] as? String else {
                reply(["id": id, "error": ["code": "invalid_params", "message": "subscription without type"]],
                      to: connection, thenClose: true)
                return
            }
            if type == "pane.agent_status_changed" {
                guard let paneID = item["pane_id"] as? String, state.panes.contains(where: { $0.paneID == paneID }) else {
                    // Atomic: one unknown pane rejects the whole request. Wait for the client to close.
                    replyPaneNotFound(id: id, params: item, key: "pane_id", connection: connection, thenClose: false)
                    return
                }
                paneIDs.insert(paneID)
            } else {
                globalTypes.insert(type)
            }
        }
        connection.isSubscribed = true
        connection.globalTypes = globalTypes
        connection.statusPaneIDs = paneIDs
        reply(["id": id, "result": ["type": "subscription_started"]], to: connection, thenClose: false)
    }

    private func replyPaneNotFound(id: String, params: [String: Any], key: String, connection: Connection, thenClose: Bool) {
        let paneID = params[key] as? String ?? ""
        reply(["id": id, "error": ["code": "pane_not_found", "message": "pane \(paneID) not found"]],
              to: connection, thenClose: thenClose)
    }

    // MARK: - Events and writing

    private func emitStatusLocked(paneID: String, status: String) {
        guard let index = state.panes.firstIndex(where: { $0.paneID == paneID }) else { return }
        state.panes[index].status = status
        state.panes[index].stateChangeSeq += 1
        let pane = state.panes[index]
        let event: [String: Any] = [
            "event": "pane.agent_status_changed",
            "data": ["pane_id": paneID, "workspace_id": pane.workspaceID, "agent_status": status,
                     "agent": pane.agent ?? NSNull(), "title": pane.title ?? NSNull()] as [String: Any],
        ]
        guard let line = FakeHerdrServer.line(event) else { return }
        for connection in liveConnections
        where connection.statusPaneIDs.contains(paneID) && !connection.silencedPaneIDs.contains(paneID) {
            write(line, to: connection)
        }
    }

    private func broadcastGlobal(_ event: [String: Any]) {
        guard let line = FakeHerdrServer.line(event) else { return }
        for connection in liveConnections where !connection.globalTypes.isEmpty {
            write(line, to: connection)
        }
    }

    private func reply(_ object: [String: Any], to connection: Connection, thenClose: Bool) {
        if let line = FakeHerdrServer.line(object) { write(line, to: connection) }
        if thenClose { closeConnection(connection) }
    }

    /// Writes the whole line; waits (poll, up to about 2 s) when the socket buffer is full.
    private func write(_ line: Data, to connection: Connection) {
        guard !connection.isClosed else { return }
        let failed: Bool = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            var waits = 0
            while offset < raw.count {
                let written = Darwin.write(connection.descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && waits < 200 {
                    waits += 1
                    var descriptor = pollfd(fd: connection.descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                } else {
                    return true
                }
            }
            return false
        }
        if failed { closeConnection(connection) }
    }

    private static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Snapshot

    private func workspaceID(of paneID: String) -> String {
        if let pane = state.panes.first(where: { $0.paneID == paneID }) { return pane.workspaceID }
        return String(paneID.split(separator: ":").first ?? Substring(paneID))
    }

    private var focusedPaneID: String? {
        state.focusedPaneID ?? state.panes.first(where: \.focused)?.paneID
    }

    private func paneJSON(_ pane: FakeHerdrPane) -> [String: Any] {
        [
            "pane_id": pane.paneID, "terminal_id": "term-\(pane.paneID)", "workspace_id": pane.workspaceID,
            "tab_id": pane.tabID, "focused": pane.paneID == focusedPaneID, "agent_status": pane.status,
            "agent": pane.agent ?? NSNull(), "terminal_title_stripped": pane.title ?? NSNull(),
            "cwd": pane.cwd ?? NSNull(), "label": NSNull(), "revision": 1,
        ]
    }

    private func snapshotJSON() -> [String: Any] {
        let focusedID = focusedPaneID
        let focusedPane = state.panes.first { $0.paneID == focusedID }
        var workspaceOrder: [String] = []
        var tabOrder: [(tabID: String, workspaceID: String)] = []
        for pane in state.panes {
            if !workspaceOrder.contains(pane.workspaceID) { workspaceOrder.append(pane.workspaceID) }
            if !tabOrder.contains(where: { $0.tabID == pane.tabID }) { tabOrder.append((pane.tabID, pane.workspaceID)) }
        }
        let workspaces: [[String: Any]] = workspaceOrder.enumerated().map { index, workspaceID in
            let tabs = tabOrder.filter { $0.workspaceID == workspaceID }
            return [
                "workspace_id": workspaceID, "number": index + 1,
                "label": state.workspaceLabels[workspaceID] ?? workspaceID,
                "focused": workspaceID == focusedPane?.workspaceID,
                "pane_count": state.panes.filter { $0.workspaceID == workspaceID }.count,
                "tab_count": tabs.count, "active_tab_id": tabs.first?.tabID ?? "\(workspaceID):t1", "agent_status": "idle",
            ]
        }
        let tabs: [[String: Any]] = tabOrder.map { tab in
            let siblings = tabOrder.filter { $0.workspaceID == tab.workspaceID }
            return [
                "tab_id": tab.tabID, "workspace_id": tab.workspaceID,
                "number": (siblings.firstIndex { $0.tabID == tab.tabID } ?? 0) + 1,
                "label": state.tabLabels[tab.tabID] ?? tab.tabID, "focused": tab.tabID == focusedPane?.tabID,
                "pane_count": state.panes.filter { $0.tabID == tab.tabID }.count, "agent_status": "idle",
            ]
        }
        let agents: [[String: Any]] = state.panes.filter { $0.agent != nil }.map { pane in
            var agent = paneJSON(pane)
            agent["display_agent"] = pane.agent ?? NSNull()
            agent["name"] = NSNull()
            agent["terminal_title"] = pane.title ?? NSNull()
            agent["state_change_seq"] = pane.stateChangeSeq
            return agent
        }
        return [
            "version": serverVersion, "protocol": currentProtocol,
            "focused_workspace_id": focusedPane?.workspaceID ?? NSNull(),
            "focused_tab_id": focusedPane?.tabID ?? NSNull(),
            "focused_pane_id": focusedID ?? NSNull(),
            "workspaces": workspaces, "tabs": tabs, "panes": state.panes.map(paneJSON), "layouts": [], "agents": agents,
        ]
    }
}

import Darwin
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

// MARK: - Fake server self-test (raw sockets, no HerdrClient)

private func herdrClientServer(panes: [FakeHerdrPane] = [FakeHerdrPane(paneID: "w1:p1", workspaceID: "w1"),
                                                         FakeHerdrPane(paneID: "w1:p2", workspaceID: "w1")]) throws -> FakeHerdrServer {
    let server = try FakeHerdrServer()
    server.setState(FakeHerdrState(panes: panes, workspaceLabels: ["w1": "api"]))
    return server
}

private func herdrFakeSubscribeLine(paneID: String) -> String {
    #"{"id":"s1","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":"\#(paneID)"}]}}"#
}

/// A minimal blocking NDJSON client on a raw AF_UNIX socket. It checks the fake before HerdrClient exists and
/// shares no code with it. Each read blocks for at most 2 s (SO_RCVTIMEO); the descriptor is closed at most once.
private final class HerdrFakeRawConnection {
    private var descriptor: Int32 = -1
    private var buffer = Data()

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure.expectation("raw socket failed: errno \(errno)") }
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            closeDescriptor()
            throw TestFailure.expectation("raw connect to \(path) failed: errno \(code)")
        }
    }

    func sendLine(_ line: String) throws {
        let bytes = Array((line + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw TestFailure.expectation("raw write wrote \(written) of \(bytes.count) bytes") }
    }

    /// The next complete line as a JSON object, or nil at EOF (the server closed its end).
    func readObject() throws -> [String: Any]? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw TestFailure.expectation("raw reply is not a JSON object")
                }
                return object
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return nil
            } else if errno != EINTR {
                throw TestFailure.expectation("raw read failed: errno \(errno) (35 means no line within 2 s)")
            }
        }
    }

    /// Closes the descriptor at most once, so a later call can never close a number the process has reused.
    func closeDescriptor() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { closeDescriptor() }
}

func testHerdrFakeAnswersPingAndSnapshotOnRawSockets() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let ping = try HerdrFakeRawConnection(path: server.socketPath)
    defer { ping.closeDescriptor() }
    try ping.sendLine(#"{"id":"1","method":"ping","params":{}}"#)
    let pong = try ping.readObject()
    try expect(pong?["id"] as? String, equals: "1", "ping reply id")
    let pongResult = pong?["result"] as? [String: Any]
    try expect(pongResult?["type"] as? String, equals: "pong", "pong type")
    try expect(pongResult?["protocol"] as? Int, equals: 22, "protocol")
    try expect(pongResult?["version"] as? String, equals: "0.9.1-fake", "version")
    try expectTrue(try ping.readObject() == nil, "one-shot reply: the server closes after one line")

    let snapshotConnection = try HerdrFakeRawConnection(path: server.socketPath)
    defer { snapshotConnection.closeDescriptor() }
    try snapshotConnection.sendLine(#"{"id":"2","method":"session.snapshot","params":{}}"#)
    let reply = try snapshotConnection.readObject()
    try expect(reply?["id"] as? String, equals: "2", "snapshot reply id")
    let result = reply?["result"] as? [String: Any]
    try expect(result?["type"] as? String, equals: "session_snapshot", "snapshot type")
    let snapshot = result?["snapshot"] as? [String: Any]
    try expect(snapshot?["protocol"] as? Int, equals: 22, "snapshot protocol")
    let paneIDs = (snapshot?["panes"] as? [[String: Any]])?.compactMap { $0["pane_id"] as? String }
    try expect(paneIDs, equals: ["w1:p1", "w1:p2"], "snapshot panes")
    let labels = (snapshot?["workspaces"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
    try expect(labels, equals: ["api"], "workspace label")
    try expect(server.requestLog.map(\.method), equals: ["ping", "session.snapshot"], "request log")
}

func testHerdrFakeHoldsOneStatusSubscriber() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let subscriber = try HerdrFakeRawConnection(path: server.socketPath)
    defer { subscriber.closeDescriptor() }
    try subscriber.sendLine(herdrFakeSubscribeLine(paneID: "w1:p1"))
    let ack = try subscriber.readObject()
    try expect(ack?["id"] as? String, equals: "s1", "ack id")
    try expect((ack?["result"] as? [String: Any])?["type"] as? String, equals: "subscription_started", "ack type")
    try expect(server.subscriberCount(paneID: "w1:p1"), equals: 1, "one status subscriber")
    try expect(server.subscriberCount(paneID: "w1:p2"), equals: 0, "no subscriber for the other pane")
    server.emitStatus(paneID: "w1:p2", status: "working")   // another pane: never sent on this connection
    server.emitStatus(paneID: "w1:p1", status: "blocked")
    let event = try subscriber.readObject()
    try expect(event?["event"] as? String, equals: "pane.agent_status_changed", "dotted status envelope")
    let data = event?["data"] as? [String: Any]
    try expect(data?["pane_id"] as? String, equals: "w1:p1", "only the subscribed pane's event arrives")
    try expect(data?["agent_status"] as? String, equals: "blocked", "status")
    try expectTrue(data?["type"] == nil, "status events carry no data.type")
    subscriber.closeDescriptor()
    try spinMainRunLoop(timeout: 1) { server.subscriberCount(paneID: "w1:p1") == 0 }
    try expect(server.bytesReceivedAfterSubscribe, equals: 0, "nothing was written after the request line")
}

func testHerdrFakeLiveDescriptorCountTracksConnections() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    try expect(server.liveDescriptorCount, equals: 1, "the listener")
    let ping = try HerdrFakeRawConnection(path: server.socketPath)
    try ping.sendLine(#"{"id":"1","method":"ping","params":{}}"#)
    _ = try ping.readObject()
    ping.closeDescriptor()
    try spinMainRunLoop(timeout: 1) { server.liveDescriptorCount == 1 }
    let baseline = openFileDescriptorCount() - server.liveDescriptorCount
    let subscriber = try HerdrFakeRawConnection(path: server.socketPath)
    defer { subscriber.closeDescriptor() }
    try subscriber.sendLine(herdrFakeSubscribeLine(paneID: "w1:p1"))
    _ = try subscriber.readObject()
    try expect(server.liveDescriptorCount, equals: 2, "the listener plus the accepted subscription")
    try expect(openFileDescriptorCount() - baseline - server.liveDescriptorCount, equals: 1,
               "only the raw client's descriptor is not the server's")
    subscriber.closeDescriptor()
    try spinMainRunLoop(timeout: 1) { server.liveDescriptorCount == 1 }
    try expect(openFileDescriptorCount() - baseline - server.liveDescriptorCount, equals: 0, "back to the baseline")
    server.stop()
    try spinMainRunLoop(timeout: 1) { server.liveDescriptorCount == 0 }
    try expect(openFileDescriptorCount() - baseline, equals: 0, "stop closes the listener")
}

// MARK: - Helpers (file-private)

/// Collects what a consuming task sees on a subscription stream.
private final class HerdrClientEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [HerdrEvent] = []
    private var ending: Error?
    private var finished = false

    var events: [HerdrEvent] { lock.lock(); defer { lock.unlock() }; return collected }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var endError: Error? { lock.lock(); defer { lock.unlock() }; return ending }

    func append(_ event: HerdrEvent) { lock.lock(); collected.append(event); lock.unlock() }
    func finish(_ error: Error?) { lock.lock(); ending = error; finished = true; lock.unlock() }
}

private func herdrClientConsume(_ stream: AsyncThrowingStream<HerdrEvent, Error>,
                                into collector: HerdrClientEventCollector) -> Task<Void, Never> {
    Task.detached {
        do {
            for try await event in stream { collector.append(event) }
            collector.finish(nil)
        } catch {
            collector.finish(error)
        }
    }
}

/// One request and one subscription against a throwaway server, so descriptors the runtime creates
/// lazily (the libdispatch kqueue, cooperative-pool wakeups) exist before a test takes its baseline.
private func herdrClientWarmUp() throws {
    let server = try herdrClientServer()
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 1)
    _ = try waitForAsync(timeout: 5) { try await client.request(.ping) }
    let stream = try waitForAsync(timeout: 5) { try await client.subscribe([.paneStatus(paneID: "w1:p1")]) }
    let collector = HerdrClientEventCollector()
    herdrClientConsume(stream, into: collector).cancel()
    try spinMainRunLoop(timeout: 2) { server.subscriberCount(paneID: "w1:p1") == 0 }
    server.stop()
    try spinMainRunLoop(timeout: 2) { server.liveDescriptorCount == 0 }
}

/// Descriptors this process holds beyond `baseline` that the fake server does not account for.
private func herdrClientLeak(_ baseline: Int, _ server: FakeHerdrServer) -> Int {
    openFileDescriptorCount() - baseline - server.liveDescriptorCount
}

private func herdrClientError(_ operation: @escaping @Sendable () async throws -> Void) throws -> Error {
    do {
        try waitForAsync(timeout: 10, operation)
    } catch let error as HerdrClientError {
        return error
    } catch let error as TestFailure {
        throw error
    } catch {
        return error
    }
    throw TestFailure.expectation("expected an error, the call succeeded")
}

/// A listening socket that never accepts: connects succeed (backlog) and nothing is ever answered.
private final class HerdrClientHungListener {
    let path = "/tmp/hf-hung-\(getpid()).sock"
    private var descriptor: Int32 = -1

    init() throws {
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let code = errno
            closeListener()   // deinit still runs after this throw; the -1 keeps it from closing again
            throw TestFailure.expectation("hung listener bind/listen failed: errno \(code)")
        }
    }

    /// Closes the listener but leaves the socket file: later connects fail with ECONNREFUSED.
    func closeLeavingStaleFile() { closeListener() }

    /// Closes the listening descriptor at most once. A second close() could hit a descriptor number the process
    /// has reused since (a client or fake-server socket of a later test) and make that test fail intermittently.
    private func closeListener() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        closeListener()
        unlink(path)
    }
}

// MARK: - Tests

func testHerdrClientPingReturnsPong() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let result = try waitForAsync { try await client.request(.ping) }
    try expect(result, equals: .pong(version: "0.9.1-fake", protocolVersion: 22), "pong")
    try expect(server.requestLog.map(\.method), equals: ["ping"], "one ping request")
}

func testHerdrClientSnapshotRoundTripsThroughTheFakeServer() throws {
    let server = try herdrClientServer(panes: [
        FakeHerdrPane(paneID: "w1:p1", workspaceID: "w1", status: "working", title: "fixture title 1", cwd: "/tmp/fixture-project",
                      stateChangeSeq: 5),
        FakeHerdrPane(paneID: "w1:p2", workspaceID: "w1", agent: nil, status: "unknown"),
    ])
    defer { server.stop() }
    server.updateState { $0.focusedPaneID = "w1:p1" }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let result = try waitForAsync { try await client.request(.snapshot) }
    guard case let .snapshot(snapshot) = result else { throw TestFailure.expectation("expected a snapshot, got \(result)") }
    try expect(snapshot.focusedPaneID, equals: "w1:p1", "focused pane")
    try expect(snapshot.workspaces.map(\.label), equals: ["api"], "workspace label")
    try expect(snapshot.panes.map(\.paneID), equals: ["w1:p1", "w1:p2"], "all panes")
    try expect(snapshot.agents.map(\.paneID), equals: ["w1:p1"], "agent panes only")
    try expect(snapshot.agents.first?.stateChangeSeq, equals: 5, "state_change_seq")
    try expect(snapshot.agents.first?.terminalTitleStripped, equals: "fixture title 1", "title")
}

func testHerdrClientReadsLargeDetectionTextInFull() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let text = String(repeating: "0123456789 fixture detection line\n", count: 9_000)   // about 306 KB
    server.setDetectionText(paneID: "w1:p1", text)
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let result = try waitForAsync { try await client.request(.readDetection(paneID: "w1:p1")) }
    guard case let .read(read) = result else { throw TestFailure.expectation("expected a read result, got \(result)") }
    try expect(read.text.utf8.count, equals: text.utf8.count, "byte count")
    try expect(read.text, equals: text, "full text")
    let params = try JSONSerialization.jsonObject(with: Data(server.requestLog.last!.paramsJSON.utf8)) as? NSDictionary
    try expect(params, equals: ["target": "w1:p1", "source": "detection", "strip_ansi": true] as NSDictionary, "wire params")
}

func testHerdrClientMissingSocketLeaksNothing() throws {
    try herdrClientWarmUp()
    let path = "/tmp/hf-missing-\(getpid()).sock"
    unlink(path)
    let baseline = openFileDescriptorCount()
    let client = HerdrClient(socketPath: path, requestTimeout: 1)
    let error = try herdrClientError { _ = try await client.request(.ping) }
    try expect(error as? HerdrClientError, equals: .socketMissing, "missing socket")
    try expect(openFileDescriptorCount(), equals: baseline, "no descriptor increase")
}

func testHerdrClientStaleSocketFileIsConnectionRefused() throws {
    let listener = try HerdrClientHungListener()
    try withExtendedLifetime(listener) {
        listener.closeLeavingStaleFile()
        let client = HerdrClient(socketPath: listener.path, requestTimeout: 1)
        let error = try herdrClientError { _ = try await client.request(.ping) }
        try expect(error as? HerdrClientError, equals: .connectFailed(errno: ECONNREFUSED), "stale socket file")
    }
}

func testHerdrClientHungServerTimesOutAndCloses() throws {
    try herdrClientWarmUp()
    let listener = try HerdrClientHungListener()
    try withExtendedLifetime(listener) {
        let baseline = openFileDescriptorCount()
        let client = HerdrClient(socketPath: listener.path, requestTimeout: 0.3)
        let started = Date()
        let error = try herdrClientError { _ = try await client.request(.snapshot) }
        let elapsed = Date().timeIntervalSince(started)
        try expect(error as? HerdrClientError, equals: .timedOut, "hung server")
        try expectTrue(elapsed < 0.3 + 0.5, "timed out after \(elapsed) s, limit 0.8 s")
        try spinMainRunLoop(timeout: 1) { openFileDescriptorCount() == baseline }
    }
}

func testHerdrClientSubscribeDeliversStatusEvents() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let stream = try waitForAsync { try await client.subscribe([.paneStatus(paneID: "w1:p1")]) }
    try expect(server.subscriberCount(paneID: "w1:p1"), equals: 1, "subscribe returned after the server registered it")
    let collector = HerdrClientEventCollector()
    let consumer = herdrClientConsume(stream, into: collector)
    server.emitStatus(paneID: "w1:p1", status: "blocked")
    server.emitStatus(paneID: "w1:p2", status: "working")   // another pane: not delivered
    server.emitStatus(paneID: "w1:p1", status: "done")
    try spinMainRunLoop(timeout: 2) { collector.events.count == 2 }
    try expect(collector.events, equals: [
        .agentStatusChanged(HerdrStatusChange(paneID: "w1:p1", workspaceID: "w1", status: .blocked, agent: "claude")),
        .agentStatusChanged(HerdrStatusChange(paneID: "w1:p1", workspaceID: "w1", status: .done, agent: "claude")),
    ], "status events for the subscribed pane, in order")
    try expect(server.bytesReceivedAfterSubscribe, equals: 0, "client never writes after the request line")
    consumer.cancel()
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 && server.subscriberCount(paneID: "w1:p1") == 0 }
}

func testHerdrClientGlobalStreamDeliversLifecycleEvents() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let stream = try waitForAsync { try await client.subscribe(HerdrSubscription.globalStream) }
    try expect(server.globalSubscriberCount, equals: 1, "one global subscriber")
    let collector = HerdrClientEventCollector()
    let consumer = herdrClientConsume(stream, into: collector)
    server.emitPaneCreated(FakeHerdrPane(paneID: "w1:p3", workspaceID: "w1", agent: nil, status: "unknown"))
    server.emitAgentDetected(paneID: "w1:p3", released: false)
    server.emitPaneExited(paneID: "w1:p2")
    server.emitPaneClosed(paneID: "w1:p2")
    server.emitGlobal(#"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"w1","label":"x"}}"#)
    try spinMainRunLoop(timeout: 2) { collector.events.count == 5 }
    try expect(collector.events, equals: [
        .paneCreated(HerdrPaneInfo(paneID: "w1:p3", workspaceID: "w1", tabID: "w1:t1", agentStatus: .unknown, revision: 1)),
        .agentDetected(paneID: "w1:p3", agent: "claude", released: false, finalStatus: nil),
        .paneExited(paneID: "w1:p2", workspaceID: "w1"),
        .paneClosed(paneID: "w1:p2", workspaceID: "w1"),
        .layoutChanged(name: "workspace_renamed"),
    ], "lifecycle events in order")
    consumer.cancel()
}

func testHerdrClientPaneNotFoundRejectionClosesFirst() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let error = try herdrClientError { _ = try await client.subscribe([.paneStatus(paneID: "w9:p404")]) }
    guard case let .server(serverError)? = error as? HerdrClientError else {
        throw TestFailure.expectation("expected .server, got \(error)")
    }
    try expectTrue(serverError.isPaneNotFound, "pane_not_found")
    // The fake keeps a rejected subscription open until the client closes: the server sees EOF.
    try spinMainRunLoop(timeout: 1) { server.liveDescriptorCount == 1 }
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 }
}

func testHerdrClientUnsupportedMethodAndRecovery() throws {
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    server.rejectMethod("session.snapshot")
    let error = try herdrClientError { _ = try await client.request(.snapshot) }
    guard case let .server(serverError)? = error as? HerdrClientError else {
        throw TestFailure.expectation("expected .server, got \(error)")
    }
    try expectTrue(serverError.isUnsupportedMethod, "unknown variant maps to unsupported method")
    server.clearRejections()
    let recovered = try waitForAsync { try await client.request(.snapshot) }
    guard case .snapshot = recovered else { throw TestFailure.expectation("snapshot works again after clearRejections") }
    let unknown = try herdrClientError { _ = try await client.request(.raw(method: "island.fake_unknown", params: [:])) }
    guard case let .server(unknownError)? = unknown as? HerdrClientError else {
        throw TestFailure.expectation("expected .server for an unknown method, got \(unknown)")
    }
    try expectTrue(unknownError.isUnsupportedMethod, "the fake answers unknown methods like Herdr")
}

/// `.raw` exists only for island.* contract probes. Any other method is refused before a socket is
/// opened, so a computed method name cannot reach Herdr (the static guard only sees literals).
func testHerdrClientRawRequestsAreLimitedToIslandProbes() throws {
    try herdrClientWarmUp()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let baseline = openFileDescriptorCount() - server.liveDescriptorCount
    let refused = try herdrClientError {
        _ = try await client.request(.raw(method: "send_keys", params: ["pane_id": .string("w1:p1"), "text": .string("x")]))
    }
    try expect(refused as? HerdrClientError,
               equals: .server(HerdrError(code: "invalid_request", message: "raw requests are limited to island.* probes")),
               "non-island raw method refused")
    try expect(herdrClientLeak(baseline, server), equals: 0, "the refusal left no descriptor open")
    try expect(server.liveDescriptorCount, equals: 1, "the server accepted no connection")
    try expect(server.requestLog.map(\.method), equals: [], "nothing reached the server")

    let probe = try herdrClientError { _ = try await client.request(.raw(method: "island.fake_unknown", params: [:])) }
    guard case let .server(probeError)? = probe as? HerdrClientError else {
        throw TestFailure.expectation("expected .server for the island.* probe, got \(probe)")
    }
    try expectTrue(probeError.isUnsupportedMethod, "an island.* probe still reaches the server and is answered as before")
    try expect(server.requestLog.map(\.method), equals: ["island.fake_unknown"], "only the island.* probe was sent")
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 }
}

func testHerdrClientCancellingConsumerClosesDescriptor() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let stream = try waitForAsync { try await client.subscribe([.paneStatus(paneID: "w1:p1")]) }
    let collector = HerdrClientEventCollector()
    let consumer = herdrClientConsume(stream, into: collector)
    server.emitStatus(paneID: "w1:p1", status: "working")
    try spinMainRunLoop(timeout: 2) { collector.events.count == 1 }
    try expect(herdrClientLeak(baseline, server), equals: 1, "the subscription holds one descriptor")
    consumer.cancel()
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 && server.subscriberCount(paneID: "w1:p1") == 0 }
    try spinMainRunLoop(timeout: 1) { collector.isFinished }
    try expect(server.bytesReceivedAfterSubscribe, equals: 0, "no bytes after subscribe")
}

func testHerdrClientDroppedStreamClosesDescriptor() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    do {
        let stream = try waitForAsync { try await client.subscribe([.paneStatus(paneID: "w1:p1")]) }
        try expect(server.subscriberCount(paneID: "w1:p1"), equals: 1, "subscribed")
        _ = stream   // never iterated; released at the end of this scope
    }
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 && server.subscriberCount(paneID: "w1:p1") == 0 }
}

func testHerdrClientHundredSubscribeCancelCyclesReturnToBaseline() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    for cycle in 0..<100 {
        let stream = try waitForAsync { try await client.subscribe([.paneStatus(paneID: cycle.isMultiple(of: 2) ? "w1:p1" : "w1:p2")]) }
        let collector = HerdrClientEventCollector()
        herdrClientConsume(stream, into: collector).cancel()
    }
    try spinMainRunLoop(timeout: 3) {
        herdrClientLeak(baseline, server) == 0
            && server.subscriberCount(paneID: "w1:p1") == 0 && server.subscriberCount(paneID: "w1:p2") == 0
    }
    try expect(server.bytesReceivedAfterSubscribe, equals: 0, "no bytes after subscribe in 100 cycles")
}

func testHerdrClientDropAllConnectionsEndsStream() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    let stream = try waitForAsync { try await client.subscribe(HerdrSubscription.globalStream) }
    let collector = HerdrClientEventCollector()
    _ = herdrClientConsume(stream, into: collector)
    server.dropAllConnections()
    try spinMainRunLoop(timeout: 2) { collector.isFinished }
    try expect(collector.endError as? HerdrClientError, equals: .streamEnded, "EOF finishes with .streamEnded")
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 }
}

func testHerdrClientServerRestartEndsStreamsAndServesNewProtocol() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let server = try herdrClientServer()
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    var before = stat()
    try expect(stat(server.socketPath, &before), equals: 0, "socket file exists")
    let stream = try waitForAsync { try await client.subscribe(HerdrSubscription.globalStream) }
    let collector = HerdrClientEventCollector()
    _ = herdrClientConsume(stream, into: collector)
    try server.restart(protocolVersion: 23)
    try spinMainRunLoop(timeout: 2) { collector.isFinished }
    try expect(collector.endError as? HerdrClientError, equals: .streamEnded, "restart ends open streams")
    var after = stat()
    try expect(stat(server.socketPath, &after), equals: 0, "socket file exists after restart")
    try expectTrue(before.st_ino != after.st_ino, "restart binds a new inode at the same path")
    let result = try waitForAsync { try await client.request(.ping) }
    try expect(result, equals: .pong(version: "0.9.1-fake", protocolVersion: 23), "new protocol after restart")
    try spinMainRunLoop(timeout: 1) { herdrClientLeak(baseline, server) == 0 }
}

func testHerdrClientFortyFivePaneStreamsStayIndependent() throws {
    try herdrClientWarmUp()
    let baseline = openFileDescriptorCount()
    let paneIDs = (1...45).map { "w1:p\($0)" }
    let server = try herdrClientServer(panes: paneIDs.map { FakeHerdrPane(paneID: $0, workspaceID: "w1") })
    defer { server.stop() }
    let client = HerdrClient(socketPath: server.socketPath, requestTimeout: 2)
    var consumers: [Task<Void, Never>] = []
    var collectors: [String: HerdrClientEventCollector] = [:]
    for paneID in paneIDs {
        let stream = try waitForAsync { try await client.subscribe([.paneStatus(paneID: paneID)]) }
        let collector = HerdrClientEventCollector()
        collectors[paneID] = collector
        consumers.append(herdrClientConsume(stream, into: collector))
    }
    try expect(herdrClientLeak(baseline, server), equals: 45, "one descriptor per pane stream")
    for paneID in paneIDs { server.emitStatus(paneID: paneID, status: "working") }
    try spinMainRunLoop(timeout: 3) { collectors.values.allSatisfy { $0.events.count == 1 } }
    for (paneID, collector) in collectors {
        try expect(collector.events, equals: [.agentStatusChanged(HerdrStatusChange(
            paneID: paneID, workspaceID: "w1", status: .working, agent: "claude"))], "\(paneID) sees only its own event")
    }
    consumers.forEach { $0.cancel() }
    try spinMainRunLoop(timeout: 3) {
        herdrClientLeak(baseline, server) == 0 && paneIDs.allSatisfy { server.subscriberCount(paneID: $0) == 0 }
    }
}

let herdrClientTests: [TestCase] = [
    ("herdrClient: fake server answers ping and snapshot on raw sockets", testHerdrFakeAnswersPingAndSnapshotOnRawSockets),
    ("herdrClient: fake server holds one status subscriber", testHerdrFakeHoldsOneStatusSubscriber),
    ("herdrClient: fake server liveDescriptorCount tracks its descriptors", testHerdrFakeLiveDescriptorCountTracksConnections),
    ("herdrClient: ping returns pong with protocol 22", testHerdrClientPingReturnsPong),
    ("herdrClient: snapshot round-trips through the fake server", testHerdrClientSnapshotRoundTripsThroughTheFakeServer),
    ("herdrClient: reads a 300 KB detection text in full", testHerdrClientReadsLargeDetectionTextInFull),
    ("herdrClient: missing socket throws socketMissing without a descriptor", testHerdrClientMissingSocketLeaksNothing),
    ("herdrClient: stale socket file is connection refused", testHerdrClientStaleSocketFileIsConnectionRefused),
    ("herdrClient: hung server times out and closes", testHerdrClientHungServerTimesOutAndCloses),
    ("herdrClient: subscribe returns after the ack and delivers status events", testHerdrClientSubscribeDeliversStatusEvents),
    ("herdrClient: global stream delivers lifecycle events", testHerdrClientGlobalStreamDeliversLifecycleEvents),
    ("herdrClient: pane_not_found rejection closes before throwing", testHerdrClientPaneNotFoundRejectionClosesFirst),
    ("herdrClient: unsupported method is reported and clears", testHerdrClientUnsupportedMethodAndRecovery),
    ("herdrClient: raw requests are limited to island.* probes", testHerdrClientRawRequestsAreLimitedToIslandProbes),
    ("herdrClient: cancelling the consumer closes the descriptor", testHerdrClientCancellingConsumerClosesDescriptor),
    ("herdrClient: dropping an unread stream closes the descriptor", testHerdrClientDroppedStreamClosesDescriptor),
    ("herdrClient: 100 subscribe and cancel cycles return to the baseline", testHerdrClientHundredSubscribeCancelCyclesReturnToBaseline),
    ("herdrClient: dropAllConnections ends the stream with streamEnded", testHerdrClientDropAllConnectionsEndsStream),
    ("herdrClient: server restart ends streams and serves the new protocol", testHerdrClientServerRestartEndsStreamsAndServesNewProtocol),
    ("herdrClient: 45 pane streams stay independent and close to baseline", testHerdrClientFortyFivePaneStreamsStayIndependent),
]

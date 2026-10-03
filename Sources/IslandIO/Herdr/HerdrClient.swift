import Foundation
import IslandCore

public enum HerdrClientError: Error, Equatable, Sendable {
    case socketMissing
    case connectFailed(errno: Int32)
    case timedOut
    case closedBeforeReply
    case malformedReply
    case server(HerdrError)
    case streamEnded
}

/// Herdr socket client. Every call opens its own connection (the server closes one-shot connections
/// after replying, and a subscription connection must never be written to after its request line).
/// Every path closes the descriptor: success, server error, timeout, EOF, task cancellation, and
/// dropping a subscription stream without iterating it.
public final class HerdrClient: @unchecked Sendable {
    public let socketPath: String
    private let requestTimeout: TimeInterval
    private let ids = HerdrRequestIDs()

    /// A reply line longer than this is treated as malformed.
    static let maximumLineBytes = 32 * 1_048_576

    public init(socketPath: String, requestTimeout: TimeInterval = IslandTiming.herdrRequestTimeout) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
    }

    /// One connection per request; reads until the first "\n"; closes the descriptor on every path.
    /// Server errors throw .server(HerdrError) (check isUnsupportedMethod / isPaneNotFound). Cancelling the
    /// calling task closes the connection and throws CancellationError.
    /// `.raw` is limited to `island.*` contract probes: any other method is refused before a socket
    /// is opened, so a computed method name can never reach Herdr through this path.
    public func request(_ request: HerdrRequest) async throws -> HerdrResult {
        if case let .raw(method, _) = request, !method.hasPrefix("island.") {
            throw HerdrClientError.server(HerdrError(code: "invalid_request", message: "raw requests are limited to island.* probes"))
        }
        let id = ids.next()
        let exchange = HerdrOneShotExchange(path: socketPath, timeout: requestTimeout)
        let reply = try await exchange.run(HerdrCodec.encodeRequest(request, id: id))
        guard let response = HerdrCodec.decodeResponse(reply) else { throw HerdrClientError.malformedReply }
        switch response {
        case let .success(replyID, result):
            guard replyID == id else { throw HerdrClientError.malformedReply }
            return result
        case let .failure(_, error):
            throw HerdrClientError.server(error)
        }
    }

    /// One connection per call. Returns after the subscription_started ack; throws .server(e) on
    /// rejection (descriptor closed first). Never writes after the request line. Cancelling the consuming
    /// task or dropping the stream closes the descriptor; EOF finishes the stream with .streamEnded.
    /// Buffering: unbounded when any global type is subscribed, newest 16 events for pane-status streams.
    public func subscribe(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, Error> {
        let id = ids.next()
        let hasGlobalType = subscriptions.contains { subscription in
            if case .event = subscription { return true }
            return false
        }
        let channel = HerdrSubscriptionChannel(path: socketPath, timeout: requestTimeout, bufferLimit: hasGlobalType ? nil : 16)
        try await channel.open(HerdrCodec.encodeRequest(.subscribe(subscriptions), id: id))
        return AsyncThrowingStream<HerdrEvent, Error>(unfolding: { try await channel.next() })
    }
}

private final class HerdrRequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "island-\(counter)"
    }
}

/// Connect, write one line, read one reply line, close.
private final class HerdrOneShotExchange: @unchecked Sendable {
    private let path: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "agent-island.herdr.request")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var outcome: Result<Data, Error>?
    private var socket: UnixSocket?
    private var buffer = Data()   // touched only on `queue`

    init(path: String, timeout: TimeInterval) {
        self.path = path
        self.timeout = timeout
    }

    func run(_ line: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                queue.async { self.start(line) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(_ line: Data) {
        do {
            let socket = try UnixSocket.connect(path: path, queue: queue)
            lock.lock()
            if outcome != nil {
                lock.unlock()
                socket.close()
                return
            }
            self.socket = socket
            lock.unlock()
            try socket.writeAll(line)
            socket.startReading { [weak self] chunk in self?.receive(chunk) }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(HerdrClientError.timedOut))
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func receive(_ chunk: Data?) {
        guard let chunk else {
            finish(.failure(HerdrClientError.closedBeforeReply))
            return
        }
        let searchStart = buffer.endIndex
        buffer.append(chunk)
        if let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            finish(.success(Data(buffer[buffer.startIndex..<newline])))
        } else if buffer.count > HerdrClient.maximumLineBytes {
            finish(.failure(HerdrClientError.malformedReply))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        let socket = self.socket
        self.socket = nil
        lock.unlock()
        socket?.close()
        continuation?.resume(with: result)
    }
}

/// A subscription connection: waits for the ack, then turns lines into events for one consumer.
private final class HerdrSubscriptionChannel: @unchecked Sendable {
    private let path: String
    private let timeout: TimeInterval
    private let bufferLimit: Int?
    private let queue = DispatchQueue(label: "agent-island.herdr.subscription")
    private let lock = NSLock()
    private var socket: UnixSocket?
    private var buffer = Data()                                   // touched only on `queue`
    private var ackContinuation: CheckedContinuation<Void, Error>?
    private var ackOutcome: Result<Void, Error>?
    private var pending: [HerdrEvent] = []
    private var waiter: CheckedContinuation<HerdrEvent?, Error>?
    private var ended = false
    private var endError: Error?

    init(path: String, timeout: TimeInterval, bufferLimit: Int?) {
        self.path = path
        self.timeout = timeout
        self.bufferLimit = bufferLimit
    }

    /// Dropping the stream releases the channel; the socket goes with it.
    deinit { socket?.close() }

    func open(_ line: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let ackOutcome {
                    lock.unlock()
                    continuation.resume(with: ackOutcome)
                    return
                }
                ackContinuation = continuation
                lock.unlock()
                queue.async { self.start(line) }
            }
        } onCancel: {
            self.failAck(CancellationError())
        }
    }

    func next() async throws -> HerdrEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HerdrEvent?, Error>) in
                lock.lock()
                if !pending.isEmpty {
                    let event = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: event)
                } else if ended {
                    let error = endError
                    endError = nil
                    lock.unlock()
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                } else if waiter != nil {
                    lock.unlock()
                    continuation.resume(throwing: HerdrClientError.malformedReply)   // one consumer only
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ line: Data) {
        do {
            let socket = try UnixSocket.connect(path: path, queue: queue)
            lock.lock()
            if ackOutcome != nil {
                lock.unlock()
                socket.close()
                return
            }
            self.socket = socket
            lock.unlock()
            try socket.writeAll(line)
            socket.startReading { [weak self] chunk in self?.receive(chunk) }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failAck(HerdrClientError.timedOut)
            }
        } catch {
            failAck(error)
        }
    }

    private func receive(_ chunk: Data?) {
        guard let chunk else {
            lock.lock()
            let acknowledged = (ackOutcome != nil)
            lock.unlock()
            if acknowledged {
                end(throwing: HerdrClientError.streamEnded)
            } else {
                failAck(HerdrClientError.closedBeforeReply)
            }
            return
        }
        buffer.append(chunk)
        for line in HerdrCodec.takeLines(from: &buffer) {
            handle(line)
        }
        if buffer.count > HerdrClient.maximumLineBytes {
            buffer = Data()
            end(throwing: HerdrClientError.malformedReply)
        }
    }

    private func handle(_ line: Data) {
        let decoded = HerdrCodec.decodeStreamLine(line)
        lock.lock()
        let acknowledged = (ackOutcome != nil)
        lock.unlock()
        guard acknowledged else {
            switch decoded {
            case .ack?: succeedAck()
            case let .rejected(error)?: failAck(HerdrClientError.server(error))
            default: failAck(HerdrClientError.malformedReply)
            }
            return
        }
        switch decoded {
        case let .event(event)?: deliver(event)
        case let .rejected(error)?: end(throwing: HerdrClientError.server(error))
        case .ack?, nil: break
        }
    }

    private func succeedAck() {
        lock.lock()
        guard ackOutcome == nil else {
            lock.unlock()
            return
        }
        ackOutcome = .success(())
        let continuation = ackContinuation
        ackContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    /// Before the ack: close first, then fail the subscribe call. After the ack: no effect.
    private func failAck(_ error: Error) {
        lock.lock()
        guard ackOutcome == nil else {
            lock.unlock()
            return
        }
        ackOutcome = .failure(error)
        ended = true
        let continuation = ackContinuation
        ackContinuation = nil
        let socket = self.socket
        self.socket = nil
        lock.unlock()
        socket?.close()
        continuation?.resume(throwing: error)
    }

    private func deliver(_ event: HerdrEvent) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
            return
        }
        pending.append(event)
        if let bufferLimit, pending.count > bufferLimit {
            pending.removeFirst(pending.count - bufferLimit)
        }
        lock.unlock()
    }

    /// EOF, read error or a late rejection: close, then deliver the error once after pending events.
    private func end(throwing error: Error) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        let socket = self.socket
        self.socket = nil
        let waiter = self.waiter
        self.waiter = nil
        if waiter == nil { endError = error }
        lock.unlock()
        socket?.close()
        waiter?.resume(throwing: error)
    }

    /// The consumer went away: close and finish quietly.
    private func cancel() {
        lock.lock()
        ended = true
        endError = nil
        pending.removeAll()
        let socket = self.socket
        self.socket = nil
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        socket?.close()
        waiter?.resume(returning: nil)
    }
}

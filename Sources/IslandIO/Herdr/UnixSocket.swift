import Darwin
import Foundation

/// One AF_UNIX stream connection that owns its descriptor and closes it exactly once.
///
/// - The descriptor is created with FD_CLOEXEC and SO_NOSIGPIPE (a peer that went away yields EPIPE,
///   never SIGPIPE).
/// - `connect` and `writeAll` are blocking and run on the caller's queue; request lines are small.
/// - `startReading` switches to O_NONBLOCK and delivers chunks from a DispatchSourceRead on `queue`.
/// - `close` is idempotent and may be called from any thread. With a read source the descriptor is
///   closed by the source's cancel handler (libdispatch requires that order). During a `writeAll` it
///   only shuts the socket down (waking a blocked write) and `writeAll` closes the descriptor when the
///   write returns. Otherwise it is closed immediately.
/// - Ordering invariant: `isClosed`, `isWriting` and `readSource` change only under `lock`, and each use
///   of the descriptor number is ordered before its close:
///   - `writeAll` checks `isClosed` and sets `isWriting` under the lock before it writes, and re-takes
///     the lock (clearing `isWriting`) before it closes the descriptor itself.
///   - `close` calls `shutdown` while still holding the lock, so a `writeAll` that returns meanwhile
///     closes only after that shutdown.
///   - `startReading` checks `isClosed` and installs the read source under the lock; the source's
///     reads end before its cancel handler closes the descriptor (libdispatch orders them).
///   So no call writes to, shuts down or reads a descriptor number after it was closed, and a racing
///   cancellation can never touch a descriptor the process has reused.
/// - `writeAll` and `startReading` are called from one thread, write first.
/// - After changing any of this, rerun `scripts/check-unix-socket-interleaving.sh`. It forces
///   close-before-write, close during a blocked write, and a write that returns while `close` is at its
///   `shutdown` call.
final class UnixSocket: @unchecked Sendable {
    let descriptor: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false
    private var isWriting = false
    private var readSource: DispatchSourceRead?

    private init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
    }

    deinit { close() }

    /// Connects to `path`. Throws HerdrClientError.socketMissing when nothing exists at the path (no
    /// descriptor is left open) and .connectFailed(errno:) for every other failure (ECONNREFUSED for a
    /// stale socket file, ENAMETOOLONG for a path that does not fit sun_path).
    static func connect(path: String, queue: DispatchQueue) throws -> UnixSocket {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty, pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrClientError.connectFailed(errno: ENAMETOOLONG)
        }
        if access(path, F_OK) != 0 && errno == ENOENT {
            throw HerdrClientError.socketMissing
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HerdrClientError.connectFailed(errno: errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == ENOENT { throw HerdrClientError.socketMissing }
            throw HerdrClientError.connectFailed(errno: code)
        }
        return UnixSocket(descriptor: descriptor, queue: queue)
    }

    /// Blocking write of the whole buffer. Throws .closedBeforeReply if the peer is gone or `close`
    /// ran before or during the write (the descriptor is then never written to after it was closed).
    func writeAll(_ data: Data) throws {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw HerdrClientError.closedBeforeReply
        }
        isWriting = true
        lock.unlock()
        let completed: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        lock.lock()
        isWriting = false
        let closedDuringWrite = isClosed   // close() left the descriptor to this call
        lock.unlock()
        if closedDuringWrite { Darwin.close(descriptor) }
        guard completed, !closedDuringWrite else { throw HerdrClientError.closedBeforeReply }
    }

    /// Delivers each received chunk on `queue`. `nil` means end of stream (EOF or a read error) and is
    /// delivered at most once. Call at most once, before `close`.
    func startReading(_ handler: @escaping (Data?) -> Void) {
        lock.lock()
        guard !isClosed, readSource == nil else {
            lock.unlock()
            return
        }
        let descriptor = self.descriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let state = UnixSocketReadState()
        source.setEventHandler {
            guard !state.ended else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    handler(Data(chunk[0..<count]))
                    if count < chunk.count { return }
                } else if count == 0 {
                    state.ended = true
                    handler(nil)
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    state.ended = true
                    handler(nil)
                    return
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        readSource = source
        lock.unlock()
        source.resume()   // a close() that raced in already cancelled it; the cancel handler still runs
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let source = readSource
        readSource = nil
        if source == nil && isWriting {
            // Still under the lock: writeAll re-takes the lock before it closes the descriptor, so its
            // close is ordered after this shutdown and the number cannot have been reused yet.
            _ = shutdown(descriptor, SHUT_RDWR)   // wakes a blocked write; writeAll closes the descriptor
            lock.unlock()
            return
        }
        lock.unlock()
        if let source {
            source.cancel()
        } else {
            Darwin.close(descriptor)
        }
    }
}

/// End-of-stream flag for one read source; only its (serial) event handler touches it.
private final class UnixSocketReadState: @unchecked Sendable {
    var ended = false
}

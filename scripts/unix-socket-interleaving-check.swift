// Manual interleaving check for Sources/IslandIO/Herdr/UnixSocket.swift. Not part of the package
// (SwiftPM never builds scripts/) and not part of island-tests: run it with
// scripts/check-unix-socket-interleaving.sh, which compiles this file (as main.swift) together with
// UnixSocket.swift into one throwaway module.
//
// UnixSocket's races are between close() on a cancelling thread and writeAll() on the connection's
// queue. They are too narrow to hit reliably through HerdrClient, so this check forces each
// interleaving deterministically:
//   1. close() before writeAll(): writeAll must not write into a descriptor that reused the number.
//   2. close() during a blocked writeAll(): the writer wakes and the descriptor is closed exactly once.
//   3. writeAll() returns while close() is about to shut the socket down: close() must not shut down an
//      unrelated socket that reused the number. The module-level shutdown() below shadows Darwin's
//      for the unqualified call in UnixSocket.swift, and pauses close() at that call.
import Darwin
import Foundation

/// Stub of the one IslandIO type UnixSocket.swift references.
enum HerdrClientError: Error {
    case socketMissing, connectFailed(errno: Int32), timedOut, closedBeforeReply, malformedReply, streamEnded
}

private let hookLock = NSLock()
private var shutdownHook: (() -> Void)?

/// Interposed shutdown(2): runs the installed hook once, then the real call.
func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
    hookLock.lock()
    let hook = shutdownHook
    shutdownHook = nil
    hookLock.unlock()
    hook?()
    return Darwin.shutdown(descriptor, how)
}

private func installShutdownHook(_ hook: @escaping () -> Void) {
    hookLock.lock()
    shutdownHook = hook
    hookLock.unlock()
}

private func isOpen(_ descriptor: Int32) -> Bool { fcntl(descriptor, F_GETFD) != -1 }

/// Runs `body` on a new thread; the returned semaphore is signalled when it finishes.
private func onThread(_ body: @escaping () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread {
        body()
        done.signal()
    }.start()
    return done
}

/// A connected, bidirectional pair standing in for an unrelated socket (say, a Herdr subscription)
/// that takes whichever descriptor number was freed last.
private func unrelatedSocketPair() -> [Int32] {
    var pair: [Int32] = [-1, -1]
    _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
    for descriptor in pair { _ = fcntl(descriptor, F_SETFL, O_NONBLOCK) }
    return pair
}

/// Bytes waiting on either end of the pair (anything there was written by someone else).
private func strayBytes(in pair: [Int32]) -> Int {
    var total = 0
    for descriptor in pair {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 { total += count }
    }
    return total
}

/// True when the pair still carries data both ways (neither end was shut down).
private func pairIsIntact(_ pair: [Int32]) -> Bool {
    for (from, to) in [(pair[1], pair[0]), (pair[0], pair[1])] {
        let sent = write(from, "ok", 2)
        var buffer = [UInt8](repeating: 0, count: 8)
        usleep(10_000)
        let received = read(to, &buffer, buffer.count)
        if sent != 2 || received != 2 { return false }
    }
    return true
}

signal(SIGPIPE, SIG_IGN)   // a shut-down victim must fail visibly, not kill the check

let path = "/tmp/hf-ilc-\(getpid()).sock"
unlink(path)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0, listen(listener, 8) == 0 else {
    print("setup failed: bind/listen errno \(errno)")
    exit(2)
}
let queue = DispatchQueue(label: "unix-socket-interleaving-check")
var failures = 0

func report(_ passed: Bool, _ name: String, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
    if !passed { failures += 1 }
}

// Case 1: close() before writeAll().
do {
    let socket = try UnixSocket.connect(path: path, queue: queue)
    let number = socket.descriptor
    socket.close()
    let pair = unrelatedSocketPair()
    var outcome = "returned normally"
    do { try socket.writeAll(Data("{\"id\":\"check-1\",\"method\":\"ping\",\"params\":{}}\n".utf8)) } catch { outcome = "threw \(error)" }
    let stray = strayBytes(in: pair)
    report(stray == 0, "case 1 (close, then writeAll)",
           "descriptor \(number) reused by \(pair); writeAll \(outcome); stray bytes in the unrelated socket: \(stray)")
    pair.forEach { _ = close($0) }
    let peer = accept(listener, nil, nil)
    if peer >= 0 { _ = close(peer) }
}

// Case 2: close() while writeAll() is blocked (the peer is never read, so its buffer fills).
do {
    let socket = try UnixSocket.connect(path: path, queue: queue)
    let number = socket.descriptor
    var outcome = "none"
    let writer = onThread {
        do { try socket.writeAll(Data(repeating: 0x41, count: 4_000_000)); outcome = "returned normally" } catch { outcome = "threw \(error)" }
    }
    usleep(150_000)
    socket.close()
    let woke = writer.wait(timeout: .now() + 2) == .success
    let closed = !isOpen(number)
    report(woke && closed, "case 2 (close during a blocked writeAll)",
           "writer woke: \(woke), \(outcome); descriptor \(number) closed afterwards: \(closed)")
    let peer = accept(listener, nil, nil)
    if peer >= 0 { _ = close(peer) }
}

// Case 3: writeAll() returns while close() is paused at its shutdown() call.
do {
    let socket = try UnixSocket.connect(path: path, queue: queue)
    let number = socket.descriptor
    var outcome = "none"
    let writer = onThread {
        do { try socket.writeAll(Data(repeating: 0x42, count: 1_000_000)); outcome = "returned normally" } catch { outcome = "threw \(error)" }
    }
    usleep(150_000)   // the writer is now blocked: nobody reads the peer
    let hookEntered = DispatchSemaphore(value: 0)
    let hookRelease = DispatchSemaphore(value: 0)
    installShutdownHook {
        hookEntered.signal()
        hookRelease.wait()
    }
    let closer = onThread { socket.close() }
    if hookEntered.wait(timeout: .now() + 2) == .timedOut {
        installShutdownHook {}
        report(false, "case 3 (writeAll returns while close is at shutdown)",
               "close() never called shutdown(); this version closes a descriptor that is being written to")
    } else {
        // Let the blocked write finish: accept the peer and drain it.
        let peer = accept(listener, nil, nil)
        let drained = onThread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while read(peer, &buffer, buffer.count) > 0 {}
        }
        // A writeAll that is not ordered after close()'s shutdown now closes the descriptor.
        let deadline = Date().addingTimeInterval(0.5)
        while isOpen(number) && Date() < deadline { usleep(5_000) }
        let closedWhilePaused = !isOpen(number)
        let pair = unrelatedSocketPair()
        hookRelease.signal()
        _ = closer.wait(timeout: .now() + 2)
        _ = writer.wait(timeout: .now() + 2)
        let intact = pairIsIntact(pair)
        let closedAfter = !isOpen(number) || pair.contains(number)
        report(intact && !closedWhilePaused && closedAfter, "case 3 (writeAll returns while close is at shutdown)",
               "writer \(outcome); descriptor \(number) closed while close() was paused: \(closedWhilePaused); "
                   + "unrelated socket \(pair) intact after close(): \(intact)")
        pair.forEach { _ = close($0) }
        if peer >= 0 { _ = close(peer) }
        _ = drained.wait(timeout: .now() + 2)
    }
}

_ = close(listener)
unlink(path)
print(failures == 0 ? "unix-socket interleaving check: all cases passed" : "unix-socket interleaving check: \(failures) case(s) failed")
exit(failures == 0 ? 0 : 1)

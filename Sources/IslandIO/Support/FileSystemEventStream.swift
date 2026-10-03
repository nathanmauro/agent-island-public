import CoreServices
import Foundation

/// A small FSEvents wrapper shared by the Claude registry and Codex feeds.
/// The handler runs on `queue` with the paths FSEvents reported (real paths,
/// for example /private/var/... rather than /var/...).
public final class FileSystemEventStream {
    /// Owned by the FSEvents stream through the context retain/release callbacks, so a
    /// callback already queued when `stop()` runs never touches a freed object.
    private final class CallbackBox {
        let handler: @Sendable ([String]) -> Void

        init(handler: @escaping @Sendable ([String]) -> Void) {
            self.handler = handler
        }
    }

    private let paths: [String]
    private let latency: TimeInterval
    private let fileEvents: Bool
    private let queue: DispatchQueue
    private let box: CallbackBox
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(
        paths: [String],
        latency: TimeInterval = 0.1,
        fileEvents: Bool = true,
        queue: DispatchQueue,
        handler: @escaping @Sendable (_ changedPaths: [String]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.fileEvents = fileEvents
        self.queue = queue
        box = CallbackBox(handler: handler)
    }

    deinit {
        stop()
    }

    /// Starts watching. Returns false when FSEvents refuses the stream. Calling it
    /// again while running is a no-op that returns true.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        if fileEvents {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            FileSystemEventStream.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Stops and releases the stream. Idempotent; also called from deinit.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
        box.handler(array.compactMap { $0 as? String })
    }
}

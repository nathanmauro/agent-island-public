import Darwin
import Foundation
import IslandCore
import IslandIO
import IslandTestSupport

private final class IOSupportPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ paths: [String]) {
        lock.lock()
        recorded.append(contentsOf: paths)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

@MainActor
private final class IOSupportOutcome {
    var finished = false
    var failure: Error?
}

func testIOSupportFileSystemEventStreamReportsAWrite() throws {
    let directory = try TemporaryDirectory()
    let recorder = IOSupportPathRecorder()
    let stream = FileSystemEventStream(
        paths: [directory.url.path],
        latency: 0.05,
        queue: DispatchQueue(label: "island-tests.fsevents.write")
    ) { paths in
        recorder.append(paths)
    }
    try expectTrue(stream.start(), "the stream starts")
    defer { stream.stop() }

    try Data("{}".utf8).write(to: directory.file("probe.json"))
    try spinMainRunLoop(timeout: 2) {
        recorder.paths.contains { $0.hasSuffix("/probe.json") }
    }
    try expectTrue(
        recorder.paths.contains(directory.file("probe.json").path),
        "FSEvents' real path for the write matches TemporaryDirectory's own path exactly (both resolve through /private)"
    )
}

func testIOSupportFileSystemEventStreamStopIsIdempotentAndReleasesDescriptors() throws {
    let directory = try TemporaryDirectory()
    let queue = DispatchQueue(label: "island-tests.fsevents.stop")
    // The first stream in a process may load framework state; measure after it.
    let warmUp = FileSystemEventStream(paths: [directory.url.path], queue: queue) { _ in }
    _ = warmUp.start()
    warmUp.stop()
    queue.sync {}
    let baseline = openFileDescriptorCount()

    for _ in 0..<5 {
        let stream = FileSystemEventStream(paths: [directory.url.path], queue: queue) { _ in }
        try expectTrue(stream.start(), "start")
        try expectTrue(stream.start(), "a second start while running is a no-op")
        stream.stop()
        stream.stop()
    }
    do {
        let dropped = FileSystemEventStream(paths: [directory.url.path], queue: queue) { _ in }
        _ = dropped.start()
    }
    queue.sync {}
    let after = openFileDescriptorCount()
    try expectTrue(after <= baseline, "descriptors return to the baseline after stop and deinit (\(baseline) → \(after))")
}

@MainActor
func testIOSupportRecordingJumpPerformerRecordsCallsInOrder() throws {
    let performer = RecordingJumpPerformer()
    let first: [JumpAction] = [.herdrFocus(paneID: "w1:p1")]
    let second: [JumpAction] = [
        .activateApp(bundleID: KnownBundleIDs.ghostty, onlyIfPreviousFailed: false),
        .tmuxSwitchClient(target: "main:@1.%2"),
    ]
    let outcome = IOSupportOutcome()
    Task { @MainActor in
        do {
            try await performer.perform(first)
            try await performer.perform(second)
            try await performer.perform([])
        } catch {
            outcome.failure = error
        }
        outcome.finished = true
    }
    try spinMainRunLoop(timeout: 2) { outcome.finished }
    try expectTrue(outcome.failure == nil, "perform never throws")
    try expect(performer.performedLog, equals: [first, second, []], "every call is recorded in order, including an empty plan")
}

@MainActor
private func startControlledJump(_ performer: RecordingJumpPerformer) -> (IOSupportOutcome, Task<Void, Never>) {
    let outcome = IOSupportOutcome()
    let task = Task { @MainActor in
        do { try await performer.perform([.herdrFocus(paneID: "fixture")]) }
        catch { outcome.failure = error }
        outcome.finished = true
    }
    return (outcome, task)
}

@MainActor
func testIOSupportControlledJumpsResolveOnlyTheirOwnAttempts() throws {
    let directory = try TemporaryDirectory()
    let performer = RecordingJumpPerformer(controlDirectory: directory.url)
    let (first, firstTask) = startControlledJump(performer)
    defer { firstTask.cancel() }
    try spinMainRunLoop(timeout: 1) { performer.performedLog.count == 1 }
    let (second, secondTask) = startControlledJump(performer)
    defer { secondTask.cancel() }
    try spinMainRunLoop(timeout: 1) { performer.performedLog.count == 2 }
    try expectTrue(!first.finished && !second.finished, "missing outcomes hold both attempts")
    try SecureFileWriter.writeAtomically(Data("success\n".utf8), to: directory.file("2.result"))
    try spinMainRunLoop(timeout: 1) { second.finished }
    try expectTrue(second.failure == nil && !first.finished, "second success cannot finish first attempt")
    try SecureFileWriter.writeAtomically(Data("failure".utf8), to: directory.file("1.result"))
    try spinMainRunLoop(timeout: 1) { first.finished }
    try expect(first.failure as? RecordingJumpPerformer.ControlError, equals: .failed, "first outcome fails")
}

@MainActor
func testIOSupportControlledJumpTimesOutAndCancels() throws {
    let directory = try TemporaryDirectory()
    let performer = RecordingJumpPerformer(controlDirectory: directory.url, controlTimeout: .milliseconds(40))
    let (outcome, task) = startControlledJump(performer)
    defer { task.cancel() }
    try spinMainRunLoop(timeout: 1) { outcome.finished }
    try expect(outcome.failure as? RecordingJumpPerformer.ControlError, equals: .timedOut, "missing outcome is bounded")

    let cancellable = RecordingJumpPerformer(controlDirectory: directory.url)
    let (cancelled, pending) = startControlledJump(cancellable)
    try spinMainRunLoop(timeout: 1) { cancellable.performedLog.count == 1 }
    pending.cancel()
    try spinMainRunLoop(timeout: 1) { cancelled.finished }
    try expectTrue(cancelled.failure is CancellationError, "cancellation promptly propagates")
}

@MainActor
func testIOSupportControlledJumpRejectsInvalidAndUnsafeOutcomes() throws {
    for fixture in ["invalid", "oversized", "public", "symlink"] {
        let directory = try TemporaryDirectory()
        let destination = directory.file("1.result")
        let contents = fixture == "invalid" ? "maybe" : fixture == "oversized" ? String(repeating: "x", count: 33) : "success"
        let target = fixture == "symlink" ? directory.file("target") : destination
        try SecureFileWriter.writeAtomically(Data(contents.utf8), to: target,
                                             permissions: fixture == "public" ? 0o644 : 0o600)
        if fixture == "public" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        }
        if fixture == "symlink" {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        }
        let performer = RecordingJumpPerformer(controlDirectory: directory.url)
        let (outcome, task) = startControlledJump(performer)
        defer { task.cancel() }
        try spinMainRunLoop(timeout: 1) { outcome.finished }
        try expectTrue(outcome.failure != nil, "\(fixture) must fail closed")
        if fixture == "invalid" {
            try expect(outcome.failure as? RecordingJumpPerformer.ControlError, equals: .invalidOutcome, "unknown value rejected")
        }
    }
}

func testIOSupportTemporaryDirectoryIsRemovedOnDeinit() throws {
    var path = ""
    do {
        let directory = try TemporaryDirectory(prefix: "island-tests-deinit")
        path = directory.url.path
        try Data("x".utf8).write(to: directory.file("inside.txt"))
        try expectTrue(FileManager.default.fileExists(atPath: directory.file("inside.txt").path), "file written")
        try expectTrue(directory.url.lastPathComponent.hasPrefix("island-tests-deinit-"), "prefix is used")
    }
    try expect(FileManager.default.fileExists(atPath: path), equals: false, "directory removed on deinit")
}

func testIOSupportFixturesResolveTheCommittedFixturesDirectory() throws {
    try expectTrue(
        FileManager.default.fileExists(atPath: Fixtures.repositoryRoot.appendingPathComponent("Package.swift").path),
        "repositoryRoot contains Package.swift"
    )
    try expect(Fixtures.root.path, equals: Fixtures.repositoryRoot.appendingPathComponent("Tests/Fixtures").path, "root")
    try expectTrue(FileManager.default.fileExists(atPath: Fixtures.url(".gitkeep").path), "Tests/Fixtures/.gitkeep exists")
    try expect(try Fixtures.data(".gitkeep"), equals: Data(), ".gitkeep is empty")
    try expect(try Fixtures.string(".gitkeep"), equals: "", ".gitkeep reads as an empty string")
}

@MainActor
func testIOSupportSpinMainRunLoopDrainsMainWorkAndTimesOut() throws {
    let outcome = IOSupportOutcome()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { outcome.finished = true }
    }
    try spinMainRunLoop(timeout: 1) { outcome.finished }

    let actorOutcome = IOSupportOutcome()
    Task { @MainActor in actorOutcome.finished = true }
    try spinMainRunLoop(timeout: 1) { actorOutcome.finished }

    do {
        try spinMainRunLoop(timeout: 0.05) { false }
        throw TestFailure.expectation("spinMainRunLoop should have timed out")
    } catch is SpinTimeout {}
}

func testIOSupportOpenFileDescriptorCountTracksOpenAndClose() throws {
    try expectTrue(openFileDescriptorCount() >= 3, "stdin, stdout and stderr are counted")
    let descriptors = (0..<3).map { _ in Darwin.open("/dev/null", O_RDONLY) }
    try expectTrue(descriptors.allSatisfy { $0 >= 0 }, "opened /dev/null three times")
    let whileOpen = openFileDescriptorCount()
    descriptors.forEach { _ = Darwin.close($0) }
    let afterClose = openFileDescriptorCount()
    try expect(whileOpen - afterClose, equals: 3, "closing three descriptors lowers the count by three")
}

func testIOSupportSecureFileAccessIsPackageVisible() throws {
    let directory = try TemporaryDirectory()
    let target = directory.file("private.json")
    let payload = Data(#"{"a":1}"#.utf8)
    try SecureFileWriter.writeAtomically(payload, to: target)
    try expect(try SecureFileReader.read(at: target), equals: payload, "round trip through the kept secure file helpers")
    let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
    try expect(permissions, equals: 0o600, "written with 0600")
}

let ioSupportTests: [TestCase] = [
    ("ioSupport: file system event stream reports a write within 2 s", testIOSupportFileSystemEventStreamReportsAWrite),
    ("ioSupport: file system event stream stop is idempotent and releases descriptors", testIOSupportFileSystemEventStreamStopIsIdempotentAndReleasesDescriptors),
    ("ioSupport: recording jump performer records calls in order", testIOSupportRecordingJumpPerformerRecordsCallsInOrder),
    ("ioSupport: controlled jumps resolve only their own attempts", testIOSupportControlledJumpsResolveOnlyTheirOwnAttempts),
    ("ioSupport: controlled jump times out and cancels", testIOSupportControlledJumpTimesOutAndCancels),
    ("ioSupport: controlled jump rejects invalid and unsafe outcomes", testIOSupportControlledJumpRejectsInvalidAndUnsafeOutcomes),
    ("ioSupport: temporary directory is removed on deinit", testIOSupportTemporaryDirectoryIsRemovedOnDeinit),
    ("ioSupport: fixtures resolve the committed fixtures directory", testIOSupportFixturesResolveTheCommittedFixturesDirectory),
    ("ioSupport: spinMainRunLoop drains main work and times out", testIOSupportSpinMainRunLoopDrainsMainWorkAndTimesOut),
    ("ioSupport: open file descriptor count tracks open and close", testIOSupportOpenFileDescriptorCountTracksOpenAndClose),
    ("ioSupport: secure file reader and writer are package visible", testIOSupportSecureFileAccessIsPackageVisible),
]

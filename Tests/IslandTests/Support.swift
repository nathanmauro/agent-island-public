import Foundation

// MARK: - Runner types (new in agent-island)

/// One registered test: its display name ("<prefix> <description>") and body.
/// Every body runs on the main thread inside the runner's
/// `MainActor.assumeIsolated` loop, so `@MainActor` test functions convert
/// implicitly.
typealias TestCase = (String, @MainActor () throws -> Void)

/// Thrown by a test that cannot run in this environment (for example a live
/// contract test without its opt-in variable). The runner prints SKIP.
struct TestSkipped: Error {
    let reason: String
}

func expectTrue(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw TestFailure.expectation("\(message): expected true, got false")
    }
}

/// Parses the runner's arguments (argv without the program name):
/// `[--filter <prefix>]...`. Returns nil for anything else, including a
/// missing or empty prefix, so main.swift can print usage and exit 2.
func parseTestFilters(_ arguments: [String]) -> [String]? {
    var filters: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
        guard arguments[index] == "--filter",
              index + 1 < arguments.endIndex,
              !arguments[index + 1].isEmpty else { return nil }
        filters.append(arguments[index + 1])
        index += 2
    }
    return filters
}

/// The tests whose display name starts with any of `filters`, compared
/// case-insensitively, in registration order. No filters selects every test.
func selectTests(_ tests: [TestCase], filters: [String]) -> [TestCase] {
    guard !filters.isEmpty else { return tests }
    let prefixes = filters.map { $0.lowercased() }
    return tests.filter { test in
        let name = test.0.lowercased()
        return prefixes.contains { name.hasPrefix($0) }
    }
}

// MARK: - Helpers moved verbatim from Moonglade's upstream test runner (main.swift)

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case let .expectation(message): message
        }
    }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        value -= 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class TestOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        isOpen = false
        return true
    }
}

func expect<T: Equatable>(_ actual: T, equals expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.expectation("\(message): expected \(expected), got \(actual)")
    }
}

final class AsyncTestResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// Blocks the calling (main) thread on a semaphore until `operation` finishes
/// on a detached task. Use it only for work that never needs the main actor.
func waitForAsync<Value: Sendable>(
    timeout: TimeInterval = 10,
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let completion = DispatchSemaphore(value: 0)
    let box = AsyncTestResultBox<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        completion.signal()
    }
    guard completion.wait(timeout: .now() + timeout) == .success,
          let result = box.load() else {
        throw TestFailure.expectation("async test timed out")
    }
    return try result.get()
}

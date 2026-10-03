import Foundation
import IslandCore
import IslandIO

// Live, read-only contract tests against the running Herdr server. Opt in with HERDR_CONTRACT=1 and
// rerun after every Herdr update. They never call agent.focus or any mutating method.

private func herdrContractClient() throws -> HerdrClient {
    let environment = ProcessInfo.processInfo.environment
    guard DebugFlags.resolve(environment: environment).herdrContract else {
        throw TestSkipped(reason: "set HERDR_CONTRACT=1 to run against the live Herdr server")
    }
    let paths = FeedPaths.resolve(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
    return HerdrClient(socketPath: paths.herdrSocket.path, requestTimeout: 5)
}

private func herdrContractSnapshot(_ client: HerdrClient) throws -> HerdrSnapshot {
    let result = try waitForAsync(timeout: 10) { try await client.request(.snapshot) }
    guard case let .snapshot(snapshot) = result else {
        throw TestFailure.expectation("session.snapshot returned \(result)")
    }
    return snapshot
}

private func herdrContractAgentPane(_ client: HerdrClient) throws -> String {
    guard let paneID = try herdrContractSnapshot(client).agents.first?.paneID else {
        throw TestSkipped(reason: "no agent pane is running in Herdr")
    }
    return paneID
}

func testHerdrContractPingReportsProtocol22() throws {
    let client = try herdrContractClient()
    let result = try waitForAsync(timeout: 10) { try await client.request(.ping) }
    guard case let .pong(version, protocolVersion) = result else { throw TestFailure.expectation("ping returned \(result)") }
    print("herdrContract: Herdr server version \(version), protocol \(protocolVersion)")
    try expect(protocolVersion, equals: HerdrCodec.supportedProtocol, "protocol")
}

func testHerdrContractSnapshotDecodes() throws {
    let snapshot = try herdrContractSnapshot(try herdrContractClient())
    try expect(snapshot.protocolVersion, equals: HerdrCodec.supportedProtocol, "snapshot protocol")
    try expectTrue(!snapshot.workspaces.isEmpty, "at least one workspace")
    try expectTrue(!snapshot.panes.isEmpty, "at least one pane")
}

func testHerdrContractGlobalAndPaneSubscriptionsAreAcknowledged() throws {
    let client = try herdrContractClient()
    guard let paneID = try herdrContractSnapshot(client).panes.first?.paneID else {
        throw TestSkipped(reason: "Herdr has no panes")
    }
    // subscribe returns only after subscription_started; the streams are released (and closed) right away.
    let global = try waitForAsync(timeout: 10) { try await client.subscribe(HerdrSubscription.globalStream) }
    let pane = try waitForAsync(timeout: 10) { try await client.subscribe([.paneStatus(paneID: paneID)]) }
    withExtendedLifetime((global, pane)) {}
}

func testHerdrContractDetectionReadReturnsText() throws {
    let client = try herdrContractClient()
    let paneID = try herdrContractAgentPane(client)
    let result = try waitForAsync(timeout: 10) { try await client.request(.readDetection(paneID: paneID)) }
    guard case let .read(read) = result else { throw TestFailure.expectation("agent.read returned \(result)") }
    try expectTrue(!read.text.isEmpty, "detection text is non-empty")
}

func testHerdrContractProcessInfoReturnsPIDs() throws {
    let client = try herdrContractClient()
    let paneID = try herdrContractAgentPane(client)
    let result = try waitForAsync(timeout: 10) { try await client.request(.processInfo(paneID: paneID)) }
    guard case let .processInfo(info) = result else { throw TestFailure.expectation("pane.process_info returned \(result)") }
    let pids = (info.shellPID.map { [$0] } ?? []) + info.foregroundPIDs
    try expectTrue(!pids.isEmpty, "at least one pid")
}

func testHerdrContractUnknownMethodIsUnsupported() throws {
    let client = try herdrContractClient()
    do {
        _ = try waitForAsync(timeout: 10) { try await client.request(.raw(method: "island.contract_unknown", params: [:])) }
        throw TestFailure.expectation("an unknown method succeeded")
    } catch let HerdrClientError.server(error) {
        try expectTrue(error.isUnsupportedMethod, "unknown method maps to unsupported: \(error)")
    }
}

let herdrContractTests: [TestCase] = [
    ("herdrContract: ping reports protocol 22", testHerdrContractPingReportsProtocol22),
    ("herdrContract: session.snapshot decodes", testHerdrContractSnapshotDecodes),
    ("herdrContract: global and per-pane subscriptions are acknowledged", testHerdrContractGlobalAndPaneSubscriptionsAreAcknowledged),
    ("herdrContract: detection read on an agent pane returns text", testHerdrContractDetectionReadReturnsText),
    ("herdrContract: pane.process_info returns pids", testHerdrContractProcessInfoReturnsPIDs),
    ("herdrContract: an unknown method maps to unsupported", testHerdrContractUnknownMethodIsUnsupported),
]

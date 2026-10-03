import Darwin
import Foundation

import IslandCore

let allTests: [TestCase] = [moongladeKeptTests, environmentTests, modelTests, jumpPlannerTests, staticGuardTests, ioSupportTests, stateStoreTests, herdrCodecTests, herdrClientTests, herdrContractTests, detectionParserTests, herdrReducerTests, herdrFeedTests, claudeRegistryTests, codexCoreTests, codexFeedTests, displayTests, boardTests, interruptPolicyTests, peekTests, jumpPerformerTests, observabilityTests].flatMap { $0 }

/// Runs the selected tests on the main actor, continuing past failures.
/// Returns the process exit status.
func runIslandTests(_ tests: [TestCase], filters: [String]) -> Int32 {
    MainActor.assumeIsolated {
        let selected = selectTests(tests, filters: filters)
        if selected.isEmpty, !filters.isEmpty {
            FileHandle.standardError.write(
                Data("island-tests: no test matches \(filters.joined(separator: " "))\n".utf8)
            )
            return 1
        }
        var passed = 0
        var failed = 0
        var skipped = 0
        for (name, test) in selected {
            do {
                try test()
                print("PASS: \(name)")
                passed += 1
            } catch let skip as TestSkipped {
                print("SKIP: \(name) — \(skip.reason)")
                skipped += 1
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
                failed += 1
            }
        }
        print("island-tests: \(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed > 0 ? 1 : 0
    }
}

guard let filters = parseTestFilters(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: island-tests [--filter <prefix>]...\n".utf8))
    exit(2)
}
exit(runIslandTests(allTests, filters: filters))

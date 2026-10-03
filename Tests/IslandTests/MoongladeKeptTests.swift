// Upstream Moonglade be0c5b4 tests that survive Task 1 (display prefix "kept:").
// Moved here verbatim from the upstream test runner (main.swift) by the Task 1 split.
// Tasks 2, 3, 11 and 12 prune or adapt entries; see docs/plans.
import Foundation
import Observation

import IslandCore
import IslandTestSupport

func testASubprocessThatNeverExitsIsTerminatedAtItsDeadline() throws {
    let startedAt = Date()
    do {
        _ = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.2
        )
        throw TestFailure.expectation("non-terminating process was accepted")
    } catch let error as POSIXError {
        try expect(error.code, equals: .ETIMEDOUT, "process timeout error")
    }
    try expect(Date().timeIntervalSince(startedAt) < 1, equals: true, "timeout is bounded")
}

func testASubprocessThatOverfillsItsPipeStillCompletes() throws {
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/dd"),
        arguments: ["if=/dev/zero", "bs=1048576", "count=1"],
        timeout: 2,
        maximumOutputBytes: 2 * 1_048_576
    )

    try expect(result.status, equals: 0, "large-output process status")
    try expect(result.output.count, equals: 1_048_576, "large output is drained")
}

func testAnOrphanHoldingThePipeDoesNotTurnSuccessIntoATimeout() throws {
    // A child may leave behind a grandchild that inherited its stdout — a
    // shell backgrounding a helper is enough. The command itself exited
    // successfully and wrote everything it ever will, so the runner must
    // return that output after its drain grace instead of throwing ETIMEDOUT.
    // The shell here is a test fixture creating the orphan, not a production
    // codepath; product code never executes strings through a shell.
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo ready; sleep 5 &"],
        timeout: 3
    )

    try expect(result.status, equals: 0, "the command itself exited cleanly")
    try expect(
        String(decoding: result.output, as: UTF8.self),
        equals: "ready\n",
        "output written before exit is returned despite the held pipe"
    )
}

func testBoundedProcessRunnerMergesEnvironmentOverrides() throws {
    let result = try BoundedProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [],
        environment: ["MOONGLADE_TEST_OVERRIDE": "herdr"],
        timeout: 2
    )
    let output = String(decoding: result.output, as: UTF8.self)
    try expect(output.contains("MOONGLADE_TEST_OVERRIDE=herdr"), equals: true, "environment override")
    try expect(output.contains("PATH="), equals: true, "base environment is preserved")
}

func testUserLocalExecutableDirectoriesAreScopedToFocusIntegrations() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let userLocal = "\(home)/.local/bin"
    let miseShim = "\(home)/.local/share/mise/shims"
    let nixProfile = "\(home)/.nix-profile/bin"

    try expect(
        FocusActionRunner.trustedDirectories(for: "herdr").contains(userLocal),
        equals: true,
        "Herdr supports its documented user-local install"
    )
    try expect(
        FocusActionRunner.trustedDirectories(for: "tmux").contains(userLocal),
        equals: false,
        "tmux lookup is not broadened to user-local directories"
    )
    try expect(
        FocusActionRunner.trustedDirectories(for: "orca").contains(userLocal),
        equals: true,
        "Orca supports its documented user-local install"
    )
    try expect(
        FocusActionRunner.trustedDirectories(for: "orca").contains(miseShim),
        equals: false,
        "Orca lookup excludes Herdr-only mise shims"
    )
    try expect(
        FocusActionRunner.trustedDirectories(for: "orca").contains(nixProfile),
        equals: false,
        "Orca lookup excludes Herdr-only Nix profiles"
    )
}

func testTheCardHeightBudgetIncludesTheErrorRow() throws {
    try expect(SessionMenuLayout.maximumCardHeight(), equals: 316, "card height without error")
    try expect(SessionMenuLayout.maximumCardHeight(hasError: true), equals: 341, "card height with error")
    try expect(NotchLayout.menuMaxHeight, equals: 341, "the panel budget always reserves the error row")
    let legacy = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31
    )
    try expect(legacy.boardMaxHeight, equals: 341, "without a visible frame the board keeps the legacy budget")
    let capped = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 31,
        visibleFrameHeight: 1_409
    )
    try expect(capped.boardMaxHeight, equals: 845.4, "a visible frame caps the board at 60 %")
    try expect(
        capped.boardMaxHeight - SessionMenuLayout.boardListMaximumHeight(boardMaxHeight: capped.boardMaxHeight),
        equals: SessionMenuLayout.maximumCardHeight(hasError: true) - SessionMenuLayout.maximumSessionListHeight,
        "the capped board still reserves the error row"
    )
}

func testAHardwareNotchWithNoMenuBarStillUsesNotchGeometry() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 0,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    try expect(layout.presentation, equals: .notch, "hardware notch presentation")
    // A zero-height bar would be invisible and unhoverable; the standard
    // menu-bar height stands in until the safe area returns.
    try expect(layout.height, equals: 24, "the bar keeps a usable height without a safe area")
}

func testNotchLayoutSupportsASecondaryDisplayOrigin() throws {
    let layout = NotchLayout(
        screenMinX: 1_920,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 2_586,
        rightNotchEdgeX: 2_766
    )
    try expect(layout.originX >= 1_920, equals: true, "secondary display origin")
}

func testNotchLayoutGuardsNonFiniteGeometry() throws {
    let layout = NotchLayout(
        screenMinX: .nan,
        screenWidth: .infinity,
        screenMaxY: .nan,
        safeAreaTop: .infinity,
        leftNotchEdgeX: .nan,
        rightNotchEdgeX: .infinity,
        menuBarHeight: .nan
    )
    try expect(layout.originX.isFinite, equals: true, "finite origin")
    try expect(layout.originY.isFinite, equals: true, "finite vertical origin")
    try expect(layout.width.isFinite, equals: true, "finite width")
}

func testAppleScriptStringEscapesEverySpecialCharacter() throws {
    let values = [
        "quote\"value": "quote\\\"value",
        "slash\\value": "slash\\\\value",
        "trailing\\": "trailing\\\\",
        "line\nvalue": "line value",
        "return\rvalue": "return value",
        #"curly“quote”"#: #"curly“quote”"#,
        "emoji 🧪": "emoji 🧪",
    ]
    for (input, expected) in values {
        try expect(AppleScriptText.escape(input), equals: expected, "AppleScript escaping")
    }
}

func testSessionDurationFormatterRendersCompactDurations() throws {
    let start = Date(timeIntervalSince1970: 0)
    let cases: [(elapsed: TimeInterval, expected: String)] = [
        (30, "<1m"),
        (59, "<1m"),
        (60, "1m"),
        (47 * 60, "47m"),
        (3_600, "1h"),
        (3_600 + 12 * 60, "1h 12m"),
        (26 * 3_600, "1d 2h"),
        (3 * 86_400, "3d"),
        (-5, "<1m"),
    ]
    for (elapsed, expected) in cases {
        try expect(
            SessionDurationFormatter.string(from: start, to: start.addingTimeInterval(elapsed)),
            equals: expected,
            "duration for \(elapsed)s"
        )
    }
}

func testPointerMovementGateStaysLockedUntilPointerMoves() throws {
    var gate = PointerMovementGate()

    try expect(gate.isUnlocked, equals: true, "a fresh gate starts unlocked")

    gate.lock(at: DisplayPoint(x: 100, y: 100))

    try expect(gate.isUnlocked, equals: false, "locking arms the gate")
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 102, y: 101)),
        equals: false,
        "a stationary pointer stays locked"
    )
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 140, y: 100)),
        equals: true,
        "real movement unlocks hover expansion"
    )
    try expect(
        gate.update(pointerLocation: DisplayPoint(x: 140, y: 100)),
        equals: true,
        "once unlocked the gate stays open"
    )
}

func testPointerSamplesPublishOnlyContainmentTransitions() throws {
    var reducer = PointerSampleReducer()
    var gate = PointerMovementGate()
    gate.lock(at: DisplayPoint(x: 100, y: 100))
    var publications: [PointerContainmentState] = []
    let outsideBeforeEntry = (0..<50).map { offset in
        (isInside: false, location: DisplayPoint(x: CGFloat(100 + offset % 2), y: 100))
    }
    let insideMoves = (0..<100).map { offset in
        (isInside: true, location: DisplayPoint(x: CGFloat(102 + offset), y: 100))
    }
    let outsideAfterLeave = (0..<50).map { offset in
        (isInside: false, location: DisplayPoint(x: CGFloat(202 + offset), y: 100))
    }
    let samples = outsideBeforeEntry + insideMoves + outsideAfterLeave

    for sample in samples {
        let reduction = reducer.reduce(
            isInside: sample.isInside,
            location: sample.location
        )
        if sample.isInside {
            _ = gate.update(pointerLocation: reduction.location)
        }
        if let containment = reduction.containmentChange {
            publications.append(containment)
        }
    }

    try expect(
        publications,
        equals: [
            PointerContainmentState(isInside: true, revision: 1),
            PointerContainmentState(isInside: false, revision: 2),
        ],
        "only entering and leaving publish observable pointer state"
    )
    try expect(gate.isUnlocked, equals: true, "unpublished coordinates still reach movement gate")
    try expect(reducer.revision, equals: 2, "same-containment moves do not advance revision")
}

func testHoverInteractionIgnoresSyntheticExitWhilePointerRemainsInside() throws {
    let compactFrame = DisplayFrame(minX: 20, minY: 0, width: 100, height: 30)

    try expect(
        HoverInteraction.pointerIsInside(
            DisplayPoint(x: 150, y: 885),
            localTopLeadingFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900
        ),
        equals: true,
        "tracking-area replacement does not turn an inside pointer into a real exit"
    )
    try expect(
        HoverInteraction.pointerIsInside(
            DisplayPoint(x: 150, y: 850),
            localTopLeadingFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900
        ),
        equals: false,
        "a pointer below the interactive frame is a real exit"
    )
}

func testHoverInteractionKeepsCompactTargetOnTheVisibleBar() throws {
    let compactFrame = DisplayFrame(minX: 192, minY: 0, width: 300, height: 38)

    let frame = HoverInteraction.interactiveFrame(
        compactFrame: compactFrame,
        expandedPanelWidth: 800,
        expandedMaximumHeight: 398,
        measuredContentHeight: 240,
        isExpanded: false,
        isHidden: false
    )

    try expect(
        frame,
        equals: compactFrame,
        "stale broad-panel geometry cannot offset the collapsed hover target"
    )
}

func testHoverInteractionOpensTheWholeExpandedSurfaceToClicks() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 210),
        "settings, rows, and chevrons across the expanded card all receive clicks"
    )
    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: compactFrame.height,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 384),
        "expansion accepts the full destination while SwiftUI is still measuring it"
    )
}

func testHoverInteractionUsesOnlyVisibleContentForHoverExit() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: 120,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 120),
        "transparent space below the measured card does not keep hover alive"
    )
    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 384,
            measuredContentHeight: compactFrame.height,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 0, width: 800, height: 384),
        "the provisional expanded card stays hoverable before its first measurement"
    )
}

func testHoverInteractionDoesNotReexpandFromTheCollapsingCard() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 0, width: 102, height: 24)

    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 460, y: 750),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false
        ),
        equals: false,
        "an active event from the former session-card area cannot reverse collapse"
    )
    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 460, y: 890),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false
        ),
        equals: true,
        "a real hover over the final compact pill still expands"
    )
    try expect(
        HoverInteraction.shouldScheduleExpansion(
            pointer: DisplayPoint(x: 410, y: 895),
            compactFrame: compactFrame,
            panelOriginX: 100,
            panelTopY: 900,
            isExpanded: false,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the transparent concave shoulder cannot trigger expansion"
    )
}

func testSingleInstanceLockExcludesBundledAndUnbundledProcesses() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent(".app.lock")

    var firstLock = try SingleInstanceLock.acquire(at: lockURL)
    try expect(firstLock != nil, equals: true, "first app instance acquires the lock")
    try expect(
        try SingleInstanceLock.acquire(at: lockURL) == nil,
        equals: true,
        "a second process identity cannot acquire the same lock"
    )
    let permissions = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]
        as? NSNumber
    try expect(permissions?.intValue, equals: 0o600, "instance lock is user-private")

    func externalLockAttemptStatus() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", lockURL.path, "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    try expect(
        try externalLockAttemptStatus() == 0,
        equals: false,
        "a separate process cannot acquire the application lock"
    )

    firstLock = nil
    let replacementLock = try SingleInstanceLock.acquire(at: lockURL)
    try expect(replacementLock != nil, equals: true, "lock is released when the first instance exits")
    withExtendedLifetime(replacementLock) {}
}

func testSingleInstanceLockRejectsNonRegularLockPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target")
    try Data("user-owned".utf8).write(to: target)
    let symlink = root.appendingPathComponent("symlink-lock")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let directory = root.appendingPathComponent("directory-lock", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for unsafePath in [symlink, directory] {
        do {
            _ = try SingleInstanceLock.acquire(at: unsafePath)
            throw TestFailure.expectation("non-regular lock path was accepted: \(unsafePath.lastPathComponent)")
        } catch is TestFailure {
            throw TestFailure.expectation("non-regular lock path was accepted: \(unsafePath.lastPathComponent)")
        } catch {
            // O_NOFOLLOW and the regular-file check must reject an existing
            // user-controlled link or directory instead of mutating it.
        }
    }
    try expect(
        try String(contentsOf: target, encoding: .utf8),
        equals: "user-owned",
        "symlink target remains untouched"
    )
}

func testNotchLayoutStatusWingWidthHidesZeroCountIndicators() throws {
    try expect(
        NotchLayout.statusWingWidth(visibleIndicatorCount: 0, showsIdleMark: false),
        equals: 0,
        "an empty wing claims no width"
    )
    try expect(
        NotchLayout.statusWingWidth(visibleIndicatorCount: 0, showsIdleMark: true),
        equals: 46,
        "the quiet idle drop bottoms out at the minimum capsule width"
    )
    try expect(NotchLayout.statusWingEdgePadding, equals: 6, "compact pill hugs its counters instead of padding them out")
    let one = NotchLayout.statusWingWidth(visibleIndicatorCount: 1, showsIdleMark: false)
    let two = NotchLayout.statusWingWidth(visibleIndicatorCount: 2, showsIdleMark: false)
    try expect(
        one,
        equals: NotchLayout.statusIndicatorSlotWidth + 2 * NotchLayout.statusWingEdgePadding,
        "one visible indicator: slot plus symmetric edge padding"
    )
    try expect(
        two,
        equals: 2 * NotchLayout.statusIndicatorSlotWidth
            + NotchLayout.statusIndicatorSpacing
            + 2 * NotchLayout.statusWingEdgePadding,
        "two visible indicators: slots, one gap, symmetric edge padding"
    )
}

func testScreenSelectionReturnsEveryDisplayWhenConfiguredForAllDisplays() throws {
    let displays = [
        DisplaySnapshot(id: 11, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982)),
        DisplaySnapshot(id: 22, frame: DisplayFrame(minX: 1_512, minY: 0, width: 2_560, height: 1_440)),
    ]

    try expect(
        ScreenSelection.selectDisplayIDs(
            mode: .allDisplays,
            mainDisplayID: 11,
            displays: displays
        ),
        equals: [11, 22],
        "all-displays mode keeps a notch panel on every connected display"
    )
}

func testGitWorkspaceInspectorResolvesBranchNames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = FileManager.default

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try filesystem.createDirectory(
        at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("ref: refs/heads/feat/notch-menu\n".utf8)
        .write(to: repo.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: repo.path),
        equals: "feat/notch-menu",
        "branch of a normal repository"
    )

    let nested = repo.appendingPathComponent("deep/subdir", isDirectory: true)
    try filesystem.createDirectory(at: nested, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: nested.path),
        equals: "feat/notch-menu",
        "branch found walking up from a subdirectory"
    )

    let homeWorktreeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".moonglade-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeWorktreeRoot) }
    let worktreeMetadata = homeWorktreeRoot.appendingPathComponent("worktrees/glance", isDirectory: true)
    try filesystem.createDirectory(at: worktreeMetadata, withIntermediateDirectories: true)
    try Data("ref: refs/heads/fix/menu\n".utf8)
        .write(to: worktreeMetadata.appendingPathComponent("HEAD"))
    let linkedWorktree = root.appendingPathComponent("repo.fix-menu", isDirectory: true)
    try filesystem.createDirectory(at: linkedWorktree, withIntermediateDirectories: true)
    try Data("gitdir: \(worktreeMetadata.path)\n".utf8)
        .write(to: linkedWorktree.appendingPathComponent(".git"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: linkedWorktree.path),
        equals: "fix/menu",
        "branch of a linked worktree"
    )

    let detached = root.appendingPathComponent("detached", isDirectory: true)
    try filesystem.createDirectory(
        at: detached.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
        .write(to: detached.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: detached.path),
        equals: "0123456",
        "short hash for a detached HEAD"
    )

    let bare = root.appendingPathComponent("not-a-repo", isDirectory: true)
    try filesystem.createDirectory(at: bare, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: bare.path),
        equals: nil,
        "nil outside any repository"
    )
}

final class GitBranchResolverProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)

    private let blocks: Bool
    private let lock = NSLock()
    private var invocationCounts: [String: Int] = [:]
    private var activeCount = 0
    private var highestActiveCount = 0

    init(blocks: Bool) {
        self.blocks = blocks
    }

    func resolve(_ path: String) -> String? {
        lock.lock()
        invocationCounts[path, default: 0] += 1
        activeCount += 1
        highestActiveCount = max(highestActiveCount, activeCount)
        lock.unlock()

        if blocks {
            _ = release.wait(timeout: .now() + 5)
        }

        lock.lock()
        activeCount -= 1
        lock.unlock()
        return "branch-\(URL(fileURLWithPath: path).lastPathComponent)"
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCounts.values.reduce(0, +)
    }

    func invocations(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCounts[path, default: 0]
    }

    var maximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return highestActiveCount
    }

    func waitForInvocations(_ expectedCount: Int) async throws {
        for _ in 0..<2_000 {
            if invocationCount >= expectedCount { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestFailure.expectation("Git resolver did not receive \(expectedCount) requests")
    }
}

func testGitBranchResolutionCoordinatorCoalescesAndCachesWorkingDirectory() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: true)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 4,
            maximumCacheEntries: 8,
            resolver: { path in probe.resolve(path) }
        )
        let requests = [
            Task { await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo") },
            Task { await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo/./") },
        ]
        try await probe.waitForInvocations(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(probe.invocationCount, equals: 1, "concurrent normalized requests coalesce")

        probe.release.signal()
        var concurrentResults: [String?] = []
        for request in requests {
            concurrentResults.append(await request.value)
        }
        try expect(
            concurrentResults,
            equals: ["branch-shared-repo", "branch-shared-repo"],
            "coalesced callers receive the same branch"
        )
        let repeated = await coordinator.branchName(forWorkingDirectory: "/tmp/shared-repo")
        try expect(repeated, equals: "branch-shared-repo", "repeated request returns cached branch")
        try expect(probe.invocationCount, equals: 1, "repeated request avoids another probe")
    }
}

func testGitBranchResolutionCoordinatorBoundsConcurrentProbes() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: true)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 2,
            maximumCacheEntries: 8,
            resolver: { path in probe.resolve(path) }
        )
        let requests = (0..<6).map { index in
            Task {
                await coordinator.branchName(forWorkingDirectory: "/tmp/repo-\(index)")
            }
        }
        try await probe.waitForInvocations(2)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(probe.invocationCount, equals: 2, "queued probes wait for a concurrency slot")
        try expect(probe.maximumActiveCount, equals: 2, "active Git probes respect the bound")

        for _ in requests { probe.release.signal() }
        for request in requests { _ = await request.value }
        try expect(probe.invocationCount, equals: 6, "every distinct directory eventually resolves")
        try expect(probe.maximumActiveCount, equals: 2, "later probes also respect the bound")
    }
}

func testGitBranchResolutionCoordinatorEvictsLeastRecentlyUsedEntry() throws {
    try waitForAsync {
        let probe = GitBranchResolverProbe(blocks: false)
        let coordinator = GitBranchResolutionCoordinator(
            maximumConcurrentResolutions: 1,
            maximumCacheEntries: 2,
            resolver: { path in probe.resolve(path) }
        )
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-b")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-c")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-a")
        _ = await coordinator.branchName(forWorkingDirectory: "/tmp/repo-b")

        try expect(probe.invocations(for: "/tmp/repo-a"), equals: 1, "recent entry stays cached")
        try expect(probe.invocations(for: "/tmp/repo-b"), equals: 2, "least-recent entry is evicted")
        try expect(probe.invocations(for: "/tmp/repo-c"), equals: 1, "new entry is cached")
    }
}

func testNotchLayoutExtendsFromLeftSideOfHardwareNotch() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.presentation, equals: .notch, "a screen with a camera housing keeps the notch")
    try expect(layout.width, equals: 800, "wide expanded panel leaves room for smooth side curves")
    try expect(layout.height, equals: 38, "collapsed panel height")
    try expect(layout.expandedHeight, equals: 387, "expanded panel reserves the error row")
    try expect(layout.originX, equals: 356, "expanded panel x")
    try expect(layout.originY, equals: 944, "panel y")
    try expect(layout.notchWidth, equals: 180, "hardware notch width")
}

func testNotchLayoutKeepsExpandedContentCloseToTheSideEdges() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.width, equals: 800, "outer panel keeps its rounded outer shape")
    try expect(NotchLayout.expandedContentWidth, equals: 784, "session content sits close to the expanded side edges")
    try expect(
        NotchLayout.contentWidth(forExpandedPanelWidth: 600),
        equals: 584,
        "narrow screens keep only a small safe gutter"
    )
}

func testNotchLayoutPinsCompactBarToPhysicalNotchWhenExpandedPanelIsClamped() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 600,
        screenMaxY: 900,
        safeAreaTop: 32,
        leftNotchEdgeX: 350,
        rightNotchEdgeX: 430
    )

    try expect(layout.originX, equals: 0, "expanded panel is clamped to the narrow display")
    try expect(
        layout.barLeadingOffset(leftWidth: 42, rightWidth: 0),
        equals: 308,
        "compact left wing remains attached to the physical notch edge"
    )
    try expect(
        layout.barLeadingOffset(leftWidth: 0, rightWidth: 42),
        equals: 350,
        "same-width status transition still moves the interactive origin"
    )
}

func testNotchLayoutExpandedHeaderWingsFlankTheCamera() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let notchedWings = notched.expandedHeaderWingWidths()
    try expect(notchedWings.left, equals: 310, "left wing spans the panel edge to the camera")
    try expect(notchedWings.right, equals: 310, "right wing spans the camera to the panel edge")
    try expect(
        notchedWings.left + notched.notchWidth + notchedWings.right,
        equals: notched.width,
        "wings and camera cutout tile the expanded panel exactly"
    )

    // A panel clamped to a narrow display keeps the camera cutout pinned to
    // the physical notch, so the wings become asymmetric but still tile.
    let clamped = NotchLayout(
        screenMinX: 0,
        screenWidth: 600,
        screenMaxY: 900,
        safeAreaTop: 32,
        leftNotchEdgeX: 350,
        rightNotchEdgeX: 430
    )
    let clampedWings = clamped.expandedHeaderWingWidths()
    try expect(clampedWings.left, equals: 350, "clamped left wing reaches the physical notch edge")
    try expect(
        clampedWings.left + clamped.notchWidth + clampedWings.right,
        equals: clamped.width,
        "clamped wings and cutout still tile the panel"
    )

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    let pillWings = pill.expandedHeaderWingWidths()
    try expect(pillWings.left, equals: 400, "pill has no cutout so the wings split the panel")
    try expect(pillWings.right, equals: 400, "pill wings stay symmetric")
    try expect(pill.notchWidth, equals: 0, "no phantom camera gap between pill wings")

    try expect(
        SessionMenuLayout.maximumCardHeight(),
        equals: 316,
        "headerless card holds only the list and its vertical insets"
    )
}

func testNotchLayoutAddsOnlyAMinimalFixedRightWing() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let activeNotchWing = notched.statusWingWidth(
        side: .left,
        visibleIndicatorCount: 1,
        showsIdleMark: false
    )
    try expect(
        notched.statusWingEdgePadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "hardware-notch outer edge clears the concave shoulder with breathing room"
    )
    try expect(
        notched.leftStatusWingLeadingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "left wing outer glyph clears the black's straight side, not hugging the curve"
    )
    try expect(notched.leftStatusWingTrailingPadding, equals: 12, "left wing leaves a small camera-facing gap")
    try expect(notched.rightStatusWingLeadingPadding, equals: 12, "right wing mirrors the small camera gap")
    try expect(
        notched.rightStatusWingTrailingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "right count clears the curve exactly like the left dot"
    )
    try expect(
        activeNotchWing,
        equals: NotchLayout.statusIndicatorSlotWidth + 12 + NotchLayout.hardwareNotchOuterWingPadding,
        "hardware-notch wing = slot + camera gap + outer shoulder clearance"
    )
    let balanced = notched.balancedStatusWingWidths(leftWidth: activeNotchWing, rightWidth: 0)

    try expect(balanced.left, equals: activeNotchWing, "visible left wing keeps its real content width")
    try expect(balanced.right, equals: 28, "empty right wing is only a minimal fixed visual extension")

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    try expect(pill.statusWingEdgePadding, equals: 6, "virtual pill keeps a slim horizontal padding")
    let unbalanced = pill.balancedStatusWingWidths(leftWidth: 54, rightWidth: 0)
    try expect(unbalanced.left, equals: 54, "notchless drop preserves its real left content")
    try expect(unbalanced.right, equals: 0, "notchless drop adds no phantom status wing")
}

func testNotchLayoutAddsOnlyAMinimalFixedLeftWing() throws {
    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    let activeRightWing = notched.statusWingWidth(
        side: .right,
        visibleIndicatorCount: 1,
        showsIdleMark: false
    )
    let balanced = notched.balancedStatusWingWidths(leftWidth: 0, rightWidth: activeRightWing)

    try expect(balanced.left, equals: 28, "empty left wing is only a minimal fixed visual extension")
    try expect(balanced.right, equals: activeRightWing, "visible right wing keeps its real content width")

    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    let unbalanced = pill.balancedStatusWingWidths(leftWidth: 0, rightWidth: 54)
    try expect(unbalanced.left, equals: 0, "notchless drop adds no phantom status wing")
    try expect(unbalanced.right, equals: 54, "notchless drop preserves its real right content")
}

func testNotchLayoutReservesRightOuterCurveClearanceForBlockedCount() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(
        layout.rightStatusWingTrailingPadding,
        equals: layout.leftStatusWingLeadingPadding,
        "both outer insets match so a bar with wings on each side reads symmetric"
    )
    // The core invariant behind the bisected-dot fix: neither outer inset may
    // be smaller than the shoulder radius, or the outermost glyph enters the
    // concave band the black has curved away from and spills onto the
    // wallpaper. Guarding both wings keeps the fix from silently regressing.
    try expect(
        layout.leftStatusWingLeadingPadding >= HangingNotchMetrics.topShoulderRadius,
        equals: true,
        "left outer inset covers the concave shoulder"
    )
    try expect(
        layout.rightStatusWingTrailingPadding >= HangingNotchMetrics.topShoulderRadius,
        equals: true,
        "right outer inset covers the concave shoulder"
    )
    try expect(
        layout.statusWingWidth(
            side: .right,
            visibleIndicatorCount: 1,
            showsIdleMark: false
        ),
        equals: NotchLayout.statusIndicatorSlotWidth
            + layout.rightStatusWingLeadingPadding
            + layout.rightStatusWingTrailingPadding,
        "the right wing width is calculated from its own mirrored paddings"
    )
}

func testNotchLayoutUsesPillStyleOnNotchlessScreen() throws {
    // A Studio Display: no safe area, no camera housing, a real 24 pt menu
    // bar. The compact surface floats as a detached capsule slightly below
    // the top edge instead of fusing with it like a notch.
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )

    try expect(layout.presentation, equals: .pill, "notchless screen gets the pill")
    try expect(layout.cornerStyle, equals: .bubble, "detached pill rounds every corner instead of faking a notch")
    try expect(layout.notchWidth, equals: 0, "no phantom camera gap")
    try expect(layout.topGap, equals: 4, "pill floats below the top edge")
    try expect(layout.height, equals: 16, "gap, pill, and bottom inset stay within the real menu bar")
    try expect(layout.originY, equals: 1_424, "panel keeps its top on the screen edge; the gap lives inside it")
    try expect(layout.originY + layout.height, equals: 1_440, "pill and notch panels share the top edge")
    try expect(layout.width, equals: 800, "panel wide enough for session details and side curves")
    try expect(layout.originX, equals: 880, "centered on screen")
    try expect(layout.expandedTopGap, equals: 8, "open bubble detaches further from the screen edge")
    try expect(layout.expandedContentSideInset, equals: 0, "bubble sides are the panel edges, no extra content inset")
    try expect(layout.expandedHeaderTopPadding, equals: 14, "expanded bubble grows breathing room above its header")
    try expect(layout.expandedBottomPadding, equals: 8, "last row clears the bubble's rounded bottom corners")
    try expect(layout.expandedHeight, equals: 387, "expanded shell reserves the error row")
}

func testNotchLayoutPillFallsBackToStandardMenuBarHeight() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 0
    )

    try expect(layout.height, equals: 16, "standard menu bar minus both margins bounds the virtual pill height")
}

func testNotchLayoutNotchKeepsScreenEdgeAttachment() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.cornerStyle, equals: .hangingNotch, "hardware notch keeps its concave shoulders")
    try expect(layout.topGap, equals: 0, "hardware notch stays fused to the screen edge")
    try expect(layout.expandedTopGap, equals: 0, "notch stays fused to the edge while open too")
    try expect(
        layout.expandedContentSideInset,
        equals: HangingNotchMetrics.topShoulderRadius,
        "notch content absorbs the shoulder radius that pulls its sides inward"
    )
    try expect(layout.expandedHeaderTopPadding, equals: 0, "notch header sits beside the camera and needs no extra room")
    try expect(layout.expandedBottomPadding, equals: 8, "notch card matches its lateral margins below the list")
    try expect(layout.expandedHeight, equals: 387, "the notch shell reserves the error row")
}

func testHangingNotchGeometryCreatesConcaveShouldersAndRoundedBase() throws {
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "compact drop cuts out the upper-left shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 16, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "compact drop keeps the body beside the concave shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 101, y: 7),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "upper shoulders stay symmetric"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 11, y: 37),
            width: 102,
            height: 38,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "compact drop rounds away the lower-left corner"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 400, y: 119),
            width: 800,
            height: 120,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "expanded drop preserves its broad rounded body"
    )
}

func testHangingNotchGeometryKeepsExpandedSidesStraightWithCircularCorners() throws {
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 13, y: 150),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the expanded side begins just inside the shallow top shoulder"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 15, y: 150),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "the expanded side remains a vertical line between its corners"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 17, y: 291),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "the lower corner follows a true rounded arc instead of an S sweep"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 19, y: 291),
            width: 800,
            height: 300,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "the lower corner retains the visible interior of its circular arc"
    )
}

func testBubbleGeometryRoundsEveryCornerAndCapsulesWhenShort() throws {
    // Collapsed pill: 102×20 with the 20 pt profile radius clamps to the
    // half-height, a true capsule.
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 1),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "capsule rounds away the upper-left corner instead of flaring into it"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 1, y: 10),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "capsule keeps its rounded tip at mid-height"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 101, y: 19),
            width: 102,
            height: 20,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "capsule rounds away the lower-right corner symmetrically"
    )

    // Expanded bubble: the sides span the full width — no shoulder inset —
    // and the top corners are convex arcs of the profile radius.
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 13, y: 150),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "bubble sides reach the full panel width instead of the notch body inset"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 3, y: 3),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "bubble top corner is a convex arc, not a concave shoulder flare"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 400, y: 1),
            width: 800,
            height: 300,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "bubble keeps a straight top edge between its corner arcs"
    )
}

func testHangingNotchMetricsShareOneCornerProfileAcrossModes() throws {
    try expect(
        HangingNotchMetrics.topShoulderRadius,
        equals: 14,
        "one shoulder gives physical and virtual notches the same curve"
    )
    try expect(
        HangingNotchMetrics.bottomCornerRadius,
        equals: 20,
        "one generous lower radius serves compact and expanded alike"
    )
    try expect(
        HangingNotchMetrics.topShoulderRadius + HangingNotchMetrics.bottomCornerRadius,
        equals: 34,
        "both curves fit the shared compact-notch height without being distorted"
    )
    try expect(
        SessionMenuLayout.contentHorizontalInset,
        equals: 4,
        "expanded content hugs the bubble sides with a slim inset"
    )
    try expect(
        SessionMenuLayout.expandedHeaderLeadingInset,
        equals: SessionMenuLayout.contentHorizontalInset
            + SessionMenuLayout.sessionRowLeadingInset
            + NotchLayout.expandedCurveGutter,
        "the header title stays column-aligned with the row icons below"
    )
    try expect(
        SessionMenuLayout.sessionRowHeight,
        equals: 28,
        "board rows are compact single lines"
    )
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 1, hasExpandedActions: true),
        equals: 139,
        "one row grows to reveal its three-action list"
    )
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 7, hasExpandedActions: true),
        equals: 300,
        "several rows scroll instead of escaping the panel"
    )
}

func testSessionMenuLayoutKeepsThreeExpandedSessionsOutOfAScrollView() throws {
    try expect(
        SessionMenuLayout.sessionListHeight(sessionCount: 3, hasExpandedActions: true),
        equals: 195,
        "three sessions plus the expanded action area fit before scrolling"
    )
    try expect(
        SessionMenuLayout.requiresScrolling(sessionCount: 6, hasExpandedActions: true),
        equals: false,
        "six compact rows plus open actions (279 pt) still fit without a scroll bar"
    )
    try expect(
        SessionMenuLayout.requiresScrolling(sessionCount: 7, hasExpandedActions: true),
        equals: true,
        "a seventh expanded session (307 pt) scrolls instead of exceeding the menu"
    )
}

func testHoverInteractionKeepsInlineRowInteractionsOpenDuringDelayedExit() throws {
    try expect(
        HoverInteraction.shouldCollapse(
            isExpanded: true,
            isHoveringPanel: false,
            openMenuTrackingCount: 0,
            rowInteractionActive: true
        ),
        equals: false,
        "a delayed exit cannot collapse an inline row interaction"
    )
}

func testNotchLayoutUsesNormalizedCameraClearance() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(
        layout.leftStatusWingLeadingPadding,
        equals: NotchLayout.hardwareNotchOuterWingPadding,
        "the running spinner clears the concave shoulder instead of riding it"
    )
    try expect(
        layout.leftStatusWingTrailingPadding,
        equals: 12,
        "the waiting counter has a small camera-facing gap"
    )
    try expect(
        layout.rightStatusWingLeadingPadding,
        equals: 12,
        "the opposite wing mirrors the camera clearance"
    )

    let leftWingWidth = layout.statusWingWidth(
        side: .left,
        visibleIndicatorCount: 2,
        showsIdleMark: false
    )
    let balancedWings = layout.balancedStatusWingWidths(
        leftWidth: leftWingWidth,
        rightWidth: 0
    )
    let barLeadingX = layout.originX + layout.barLeadingOffset(
        leftWidth: balancedWings.left,
        rightWidth: balancedWings.right
    )
    let waitingCounterTrailingX = barLeadingX
        + balancedWings.left
        - layout.leftStatusWingTrailingPadding
    try expect(
        waitingCounterTrailingX,
        equals: 654,
        "the waiting counter ends 12 points before the physical notch edge"
    )
}

func testHangingNotchInteractionRegionPassesTransparentCornersThrough() throws {
    let region = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 309, minY: 0, width: 102, height: 24),
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    try expect(
        region.contains(DisplayPoint(x: 310, y: 7)),
        equals: false,
        "AppKit gate passes the concave shoulder through"
    )
    try expect(
        region.contains(DisplayPoint(x: 325, y: 7)),
        equals: true,
        "AppKit gate accepts the visible drop body"
    )
    try expect(
        region.contains(DisplayPoint(x: 360, y: 25)),
        equals: false,
        "AppKit gate passes space below the compact drop through"
    )
}

func testBubbleInteractionRegionFloatsBelowTheTopEdge() throws {
    // A detached pill: the region starts 4 pt below the panel top and hit
    // tests as a capsule, so both the gap strip and the rounded corner
    // pockets pass through to whatever sits behind the panel.
    let region = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 309, minY: 4, width: 102, height: 20),
        cornerStyle: .bubble,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    try expect(
        region.contains(DisplayPoint(x: 360, y: 2)),
        equals: false,
        "the top gap strip passes through to the menu bar behind the panel"
    )
    try expect(
        region.contains(DisplayPoint(x: 310, y: 5)),
        equals: false,
        "the capsule's rounded corner pocket passes through"
    )
    try expect(
        region.contains(DisplayPoint(x: 360, y: 14)),
        equals: true,
        "the capsule body accepts events"
    )
    try expect(
        region.contains(DisplayPoint(x: 310, y: 14)),
        equals: true,
        "the capsule tip accepts events at mid-height"
    )
}

func testHoverInteractionPreservesTheTopGapWhileExpanded() throws {
    let compactFrame = DisplayFrame(minX: 309, minY: 4, width: 102, height: 20)

    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false
        ),
        equals: DisplayFrame(minX: 0, minY: 4, width: 800, height: 210),
        "without its own inset the expanded gate inherits the compact bar's gap"
    )
    try expect(
        HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 210,
            isExpanded: true,
            isHidden: false,
            expandedTopInset: 8
        ),
        equals: DisplayFrame(minX: 0, minY: 8, width: 800, height: 210),
        "the open bubble's own larger gap moves the click gate down with it"
    )
    try expect(
        HoverInteraction.visibleHoverFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: 800,
            expandedMaximumHeight: 340,
            measuredContentHeight: 120,
            isExpanded: true,
            isHidden: false,
            expandedTopInset: 8
        ),
        equals: DisplayFrame(minX: 0, minY: 8, width: 800, height: 120),
        "the hover surface follows the bubble's gap so the strip above never holds hover"
    )
}

func testNotchLayoutMenuCardWidthNeverCrampedInPillMode() throws {
    let pill = NotchLayout(
        screenMinX: 0,
        screenWidth: 2_560,
        screenMaxY: 1_440,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )
    try expect(pill.width, equals: 800, "outer pill panel gives its curves lateral room")

    let notched = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )
    try expect(notched.width, equals: 800, "outer notch panel gives its curves lateral room")
}

func testFocusActionRunnerKeepsEarlierHerdrFailureAfterOuterActivation() throws {
    do {
        try FocusActionRunner.run([
            .run(executable: "/usr/bin/false", arguments: ["herdr"], environment: [:]),
            .run(executable: "/usr/bin/true", arguments: [], environment: [:]),
        ])
        throw TestFailure.expectation("a failed Herdr action was hidden by a later activation")
    } catch let error as FocusError {
        try expect(
            error,
            equals: .commandFailed("/usr/bin/false", 1),
            "the first Herdr failure remains visible after the later action"
        )
    }
}

/// SwiftPM's generated `Bundle.module` resolves exactly two locations: the
/// directory holding the running executable, and the absolute build directory
/// of the machine that compiled it. A shipped binary has no bundle beside it,
/// so both installed CLIs loaded their scripts out of the developer's `.build`
/// tree and trapped the moment that directory was renamed. The search must
/// cover the layouts Moonglade actually installs into, and name no build path.
func testResourceBundleSearchCoversEveryInstalledLayout() throws {
    let appResources = "/Users/someone/Applications/AgentIsland.app/Contents/Resources"
    let appPaths = BundledResources.bundleSearchPaths(
        executableURL: URL(
            fileURLWithPath: "/Users/someone/Applications/AgentIsland.app/Contents/MacOS/AgentIsland"
        ),
        mainResourceURL: URL(fileURLWithPath: appResources, isDirectory: true)
    )
    try expect(
        appPaths.contains("\(appResources)/\(BundledResources.bundleName)"),
        equals: true,
        "the app binary searches its own Resources directory"
    )
    try expect(
        appPaths.contains(where: { $0.contains("/.build/") }),
        equals: false,
        "no build directory is baked into the search"
    )
    try expect(
        BundledResources.bundleSearchPaths(
            executableURL: URL(fileURLWithPath: "/tmp/repo/.build/release/AgentIsland"),
            mainResourceURL: nil
        ).contains("/tmp/repo/.build/release/\(BundledResources.bundleName)"),
        equals: true,
        "a development binary searches its own directory"
    )
    try expect(
        BundledResources.bundleName,
        equals: "AgentIsland_IslandCore.bundle",
        "SwiftPM names the bundle <package>_<target>"
    )
}

func testSessionNameOverridesRenameAndPrune() throws {
    let row = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .working)
    var overrides = SessionNameOverrides()
    try expect(overrides.displayName(for: row.id), equals: nil, "no override yet")

    overrides.rename(row.id, to: "API refactor")
    try expect(overrides.displayName(for: row.id), equals: "API refactor", "renamed")

    // A name sticks to the row identity, not to its momentary state.
    let laterActivity = AgentRow.fixture(source: .herdr, key: "w1:p1", state: .idle)
    try expect(overrides.displayName(for: laterActivity.id), equals: "API refactor", "survives status change")

    overrides.rename(row.id, to: "   ")
    try expect(overrides.displayName(for: row.id), equals: nil, "blank input clears the override")

    overrides.rename(row.id, to: "kept")
    let doomed = AgentRow.fixture(source: .herdr, key: "w1:p2", state: .working)
    overrides.rename(doomed.id, to: "gone")
    let otherSource = RowID(source: .codexDesktop, key: "thread-1")
    overrides.rename(otherSource, to: "codex name")
    overrides.prune(keeping: [row.id], sources: [.herdr])
    try expect(overrides.displayName(for: row.id), equals: "kept", "prune keeps live session names")
    try expect(overrides.displayName(for: doomed.id), equals: nil, "prune drops dead session names")
    try expect(overrides.displayName(for: otherSource), equals: "codex name",
               "prune leaves sources it was not asked to prune")
}

func testSessionTitleFormatterCleansTabTitles() throws {
    // Agent status decorations — emoji dots, spinners, separators — and
    // ellipses are stripped; whitespace collapses. Width-aware truncation
    // belongs to the row's single-line Text; the formatter only caps
    // pathological lengths.
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "🟢 | Ideas de naming... · main", fallback: "repo"),
        equals: "Ideas de naming · main",
        "opencode-style tab title keeps everything the row can fit"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "✳ Moonglade — claude", fallback: "repo"),
        equals: "Moonglade — claude",
        "claude-style tab title"
    )
    try expect(
        SessionTitleFormatter.rowTitle(
            tabTitle: String(repeating: "long title ", count: 30),
            fallback: "repo"
        ).count,
        equals: SessionTitleFormatter.maximumTitleLength,
        "a runaway tab string still hits the safety cap"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "convoy", fallback: "repo"),
        equals: "convoy",
        "plain short title"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: "● ● ●", fallback: "repo"),
        equals: "repo",
        "decoration-only title falls back"
    )
    try expect(
        SessionTitleFormatter.rowTitle(tabTitle: nil, fallback: "repo"),
        equals: "repo",
        "missing title falls back"
    )
    try expect(
        SessionTitleFormatter.truncate("really-long-directory-name", to: 14),
        equals: "really-long-d…",
        "directory truncation"
    )
    try expect(
        SessionTitleFormatter.truncate("Moonglade", to: 14),
        equals: "Moonglade",
        "short directory untouched"
    )
}

func testNotchGlassScrimKeepsCollapsedBarSolidAndFadesExpanded() throws {
    // Collapsed bar (32pt) sits entirely inside the 38pt solid band: every
    // stop stays fully opaque, so the compact notch renders flat black.
    let collapsed = NotchGlassStyle.scrimStops(height: 32, solidBandHeight: 38)
    try expect(collapsed.allSatisfy { $0.opacity == 1 }, equals: true, "collapsed bar stays solid black")
    try expect(collapsed.first?.location, equals: 0, "collapsed gradient starts at top")
    try expect(collapsed.last?.location, equals: 1, "collapsed gradient reaches bottom")

    // Fully expanded: pure black through the band, then a smootherstep
    // dissolve down to the smoked floor at the bottom edge.
    let expanded = NotchGlassStyle.scrimStops(
        height: 354,
        solidBandHeight: 38,
        bottomOpacity: 0.15,
        fadeStartFraction: 0
    )
    try expect(expanded.first, equals: NotchGlassStyle.Stop(location: 0, opacity: 1), "expanded starts solid")
    try expect(expanded[1], equals: NotchGlassStyle.Stop(location: 38.0 / 354.0, opacity: 1), "solid band ends at 38pt")
    try expect(expanded.last, equals: NotchGlassStyle.Stop(location: 1, opacity: 0.15), "expanded holds the smoked floor")
    // With the symmetric curve (bias 1), the dissolve crosses exactly half
    // the fade range at the middle of the run.
    let midRun = expanded[expanded.count / 2]
    try expect(
        abs(midRun.opacity - (1 - 0.85 * 0.5)) < 0.000001,
        equals: true,
        "symmetric dissolve crosses half the range at mid-run"
    )

    // Mid-spring height: same smooth run compressed into the shorter drop,
    // still ending at the smoked floor.
    let midSpring = NotchGlassStyle.scrimStops(
        height: 60,
        solidBandHeight: 38,
        bottomOpacity: 0.15,
        fadeStartFraction: 0
    )
    try expect(midSpring.first, equals: NotchGlassStyle.Stop(location: 0, opacity: 1), "mid-spring starts solid")
    try expect(midSpring.last, equals: NotchGlassStyle.Stop(location: 1, opacity: 0.15), "mid-spring keeps the smoked floor")

    // Locations must be non-decreasing and opacities non-increasing at every
    // height or the gradient renders undefined or non-monotonic.
    for height: CGFloat in [1, 32, 38, 60, 98, 150, 158, 354, 720] {
        let stops = NotchGlassStyle.scrimStops(height: height, solidBandHeight: 38)
        let locations = stops.map(\.location)
        try expect(
            locations,
            equals: locations.sorted(),
            "stop locations monotonic at height \(height)"
        )
        let opacities = stops.map(\.opacity)
        try expect(
            opacities,
            equals: opacities.sorted(by: >),
            "stop opacities non-increasing at height \(height)"
        )
    }
}

func testCompactStatusDotRidesEachWingsOuterScreenEdge() throws {
    // The concave notch shoulder (and the pill's capsule end) meets each
    // wing's outer screen-edge: leading on the left, trailing on the right.
    try expect(
        NotchLayout.StatusWingSide.left.outerEdge,
        equals: .leading,
        "left wing outer edge"
    )
    try expect(
        NotchLayout.StatusWingSide.right.outerEdge,
        equals: .trailing,
        "right wing outer edge"
    )
    // The round dot always takes that outer slot so both wings present a
    // round glyph to the shoulder; a flat numeral there looked cramped on
    // the blocked (right) wing.
    try expect(
        StatusIndicatorLayout.forWing(.left).dotEdge,
        equals: .leading,
        "left wing dot rides the leading/outer edge"
    )
    try expect(
        StatusIndicatorLayout.forWing(.right).dotEdge,
        equals: .trailing,
        "right wing dot rides the trailing/outer edge"
    )
}

func testBrailleSpinnerCycleCoversEveryFrameExactlyOnce() throws {
    // The layer animation is built from these three values alone: it holds each
    // pre-rendered frame for `stepInterval` and repeats over `cyclePeriod`.
    // Adding or dropping a frame without the period following it stretches or
    // truncates the cycle, so pin that relationship rather than restating 0.8.
    try expect(
        BrailleSpinner.cyclePeriod,
        equals: BrailleSpinner.stepInterval * Double(BrailleSpinner.frames.count),
        "cycle period covers every frame exactly once"
    )
    try expect(
        Set(BrailleSpinner.frames).count,
        equals: BrailleSpinner.frames.count,
        "frames are distinct so the cycle never stutters"
    )
    try expect(BrailleSpinner.frames.first, equals: "⠋", "first frame character")
}

func testBrailleSpinnerFramesAreSingleBraillePatternGlyphs() throws {
    // Frames are rasterized one glyph per image into a fixed 11x11 slot. A
    // multi-scalar or non-braille character would render at a different advance
    // width and make the spinner jitter inside its slot.
    let allBraille = BrailleSpinner.frames.allSatisfy { character in
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }
    try expect(allBraille, equals: true, "every frame is one braille pattern glyph")
}

private func pinnedOrderRow(_ key: String, since seconds: TimeInterval = 0) -> AgentRow {
    AgentRow.fixture(source: .claudeRegistry, key: key, since: Date(timeIntervalSince1970: seconds))
}

func testPinnedSessionOrderPassesThroughBeforeAnythingIsRecorded() throws {
    let order = PinnedSessionOrder()
    let rows = [pinnedOrderRow("a"), pinnedOrderRow("b")]

    try expect(
        order.ordered(rows).map(\.id.key),
        equals: ["a", "b"],
        "an empty pin leaves the store's own ordering alone"
    )
}

func testPinnedSessionOrderKeepsRecordedSlotsWhenTheStoreResorts() throws {
    var order = PinnedSessionOrder()
    order.record([pinnedOrderRow("a"), pinnedOrderRow("b"), pinnedOrderRow("c")])

    // The store re-sorts on every state change: `b` just changed state and
    // now leads. The open menu must not shuffle underneath the pointer.
    let resorted = [
        pinnedOrderRow("b", since: 30),
        pinnedOrderRow("c", since: 20),
        pinnedOrderRow("a", since: 10),
    ]

    try expect(
        order.ordered(resorted).map(\.id.key),
        equals: ["a", "b", "c"],
        "recorded slots survive a re-sort of the same rows"
    )
}

func testPinnedSessionOrderAppendsSessionsItHasNotSeen() throws {
    var order = PinnedSessionOrder()
    order.record([pinnedOrderRow("a"), pinnedOrderRow("b")])

    // A brand-new row must still reach the list — appended, so it cannot
    // displace a row the pointer is already resting on.
    let withNewcomer = [
        pinnedOrderRow("new", since: 99),
        pinnedOrderRow("a"),
        pinnedOrderRow("b"),
    ]

    try expect(
        order.ordered(withNewcomer).map(\.id.key),
        equals: ["a", "b", "new"],
        "an unrecorded row lands at the end rather than jumping the queue"
    )
}

func testPinnedSessionOrderDropsSessionsThatEnded() throws {
    var order = PinnedSessionOrder()
    order.record([pinnedOrderRow("a"), pinnedOrderRow("b"), pinnedOrderRow("c")])
    order.record([pinnedOrderRow("a"), pinnedOrderRow("c")])

    try expect(
        order.ordered([pinnedOrderRow("a"), pinnedOrderRow("b"), pinnedOrderRow("c")])
            .map(\.id.key),
        equals: ["a", "c", "b"],
        "a row that left the list forfeits its old slot instead of resurrecting into it"
    )
}

func testPinnedSessionOrderRecordingIsAdditiveRatherThanResorting() throws {
    var order = PinnedSessionOrder()
    order.record([pinnedOrderRow("a"), pinnedOrderRow("b")])
    // Recording again with a different incoming order must not renumber the
    // slots it already holds; only the newcomer is learned.
    order.record([
        pinnedOrderRow("c", since: 40),
        pinnedOrderRow("b", since: 30),
        pinnedOrderRow("a", since: 20),
    ])

    try expect(
        order.ordered([pinnedOrderRow("a"), pinnedOrderRow("b"), pinnedOrderRow("c")])
            .map(\.id.key),
        equals: ["a", "b", "c"],
        "learning a new row does not reshuffle the ones already pinned"
    )
}

func testHoverSelectionFollowsThePointerAcrossRows() throws {
    var selection = HoverSelection<String>()
    selection.update("rename", isHovered: true)
    try expect(selection.hovered, equals: "rename", "entering a row selects it")

    selection.update("rename", isHovered: false)
    selection.update("kill", isHovered: true)
    try expect(selection.hovered, equals: "kill", "an orderly hand-off follows the pointer")
}

func testHoverSelectionSurvivesAnExitThatArrivesAfterTheNextEnter() throws {
    // The failure this type exists for. Resizing an animated view replaces its
    // tracking area, so a fast pointer gets the new row's enter before the old
    // row's exit. Independent per-row flags would end up with both rows lit —
    // or, once the late exit lands, with none.
    var selection = HoverSelection<String>()
    selection.update("rename", isHovered: true)
    selection.update("kill", isHovered: true)
    try expect(selection.hovered, equals: "kill", "the newest enter wins")

    selection.update("rename", isHovered: false)
    try expect(
        selection.hovered,
        equals: "kill",
        "a late exit from the row the pointer already left must not clear the highlight"
    )
}

func testHoverSelectionClearsWhenTheSelectedRowExits() throws {
    var selection = HoverSelection<String>()
    selection.update("kill", isHovered: true)
    selection.update("kill", isHovered: false)
    try expect(selection.hovered, equals: nil, "the pointer left the row it was on")
}

func testHoverSelectionDropsEverythingWhenTheListIsReplaced() throws {
    var selection = HoverSelection<String>()
    selection.update("kill", isHovered: true)
    selection.clear()
    try expect(
        selection.hovered,
        equals: nil,
        "swapping the action list out cannot leave a highlight owed to a row that no longer exists"
    )
}

func testActionListHoverGeometryResolvesTheRowUnderThePointer() throws {
    // Enter/exit pairs from animated tracking areas arrive late or out of
    // order; deriving the highlight from the pointer's list-local position on
    // every move cannot lag behind the pointer.
    let width: CGFloat = 200
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 0, listWidth: width, rowCount: 4),
        equals: 0,
        "the list's top edge belongs to the first row"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 31.9, listWidth: width, rowCount: 4),
        equals: 0,
        "the bottom of the first row still highlights it"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 32.5, listWidth: width, rowCount: 4),
        equals: 0,
        "the hairline gap joins the row above it — no dead zones inside the list"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 33, listWidth: width, rowCount: 4),
        equals: 1,
        "crossing the gap hands the highlight to the next row"
    )
    // Four rows of 32 with three 1pt gaps span 131 points.
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 130.9, listWidth: width, rowCount: 4),
        equals: 3,
        "the bottom of the last row still highlights it"
    )
}

func testActionListHoverGeometryRejectsPointsOutsideTheList() throws {
    let width: CGFloat = 200
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: -0.1, listWidth: width, rowCount: 4),
        equals: nil,
        "above the list nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 131, listWidth: width, rowCount: 4),
        equals: nil,
        "below the last row nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: -1, y: 10, listWidth: width, rowCount: 4),
        equals: nil,
        "left of the list nothing is highlighted"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 200, y: 10, listWidth: width, rowCount: 4),
        equals: nil,
        "the trailing edge is exclusive"
    )
    try expect(
        SessionMenuLayout.actionRowIndex(x: 10, y: 10, listWidth: width, rowCount: 0),
        equals: nil,
        "an empty list has no rows to highlight"
    )
}

func testInlineActionsClickGateLetsPlainHoverThrough() throws {
    // The whole point: with no button held the catcher must be transparent, or
    // it swallows every hover and click aimed at the row beneath it.
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 0, controlKeyIsDown: false),
        equals: false,
        "a pointer with no button held belongs to the row, not the catcher"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 0, controlKeyIsDown: true),
        equals: false,
        "holding control without clicking is still just hover"
    )
}

func testInlineActionsClickGateClaimsRightAndControlClicks() throws {
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1 << 1, controlKeyIsDown: false),
        equals: true,
        "a held right button opens the inline actions"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1, controlKeyIsDown: true),
        equals: true,
        "control-click is the trackpad spelling of a right click"
    )
    try expect(
        InlineActionsClickGate.claimsPointer(pressedMouseButtons: 1, controlKeyIsDown: false),
        equals: false,
        "a plain left click must reach the focus button underneath"
    )
}

let moongladeKeptTests: [TestCase] = [
    ("kept: notch glass scrim keeps collapsed bar solid and fades expanded", testNotchGlassScrimKeepsCollapsedBarSolidAndFadesExpanded),
    ("kept: compact status dot rides each wing's outer screen edge", testCompactStatusDotRidesEachWingsOuterScreenEdge),
    ("kept: a subprocess that never exits is terminated at its deadline", testASubprocessThatNeverExitsIsTerminatedAtItsDeadline),
    ("kept: a subprocess that overfills its pipe still completes", testASubprocessThatOverfillsItsPipeStillCompletes),
    ("kept: an orphan holding the pipe does not turn success into a timeout", testAnOrphanHoldingThePipeDoesNotTurnSuccessIntoATimeout),
    ("kept: bounded process runner merges environment overrides", testBoundedProcessRunnerMergesEnvironmentOverrides),
    ("kept: user-local executable directories are scoped to focus integrations", testUserLocalExecutableDirectoriesAreScopedToFocusIntegrations),
    ("kept: the card height budget includes the error row", testTheCardHeightBudgetIncludesTheErrorRow),
    ("kept: a hardware notch with no menu bar still uses notch geometry", testAHardwareNotchWithNoMenuBarStillUsesNotchGeometry),
    ("kept: notch layout supports a secondary display origin", testNotchLayoutSupportsASecondaryDisplayOrigin),
    ("kept: notch layout guards non-finite geometry", testNotchLayoutGuardsNonFiniteGeometry),
    ("kept: AppleScript string escapes every special character", testAppleScriptStringEscapesEverySpecialCharacter),
    ("kept: session duration formatter renders compact durations", testSessionDurationFormatterRendersCompactDurations),
    ("kept: pointer movement gate stays locked until pointer moves", testPointerMovementGateStaysLockedUntilPointerMoves),
    ("kept: pointer samples publish only containment transitions", testPointerSamplesPublishOnlyContainmentTransitions),
    ("kept: hover interaction ignores synthetic exit while pointer remains inside", testHoverInteractionIgnoresSyntheticExitWhilePointerRemainsInside),
    ("kept: hover interaction keeps compact target on visible bar", testHoverInteractionKeepsCompactTargetOnTheVisibleBar),
    ("kept: hover interaction opens whole expanded surface to clicks", testHoverInteractionOpensTheWholeExpandedSurfaceToClicks),
    ("kept: hover interaction uses visible content for hover exit", testHoverInteractionUsesOnlyVisibleContentForHoverExit),
    ("kept: hover interaction does not reexpand from collapsing card", testHoverInteractionDoesNotReexpandFromTheCollapsingCard),
    ("kept: single instance lock excludes bundled and unbundled processes", testSingleInstanceLockExcludesBundledAndUnbundledProcesses),
    ("kept: single instance lock rejects non-regular lock paths", testSingleInstanceLockRejectsNonRegularLockPaths),
    ("kept: notch layout status wing width hides zero count indicators", testNotchLayoutStatusWingWidthHidesZeroCountIndicators),
    ("kept: screen selection returns every display when configured for all displays", testScreenSelectionReturnsEveryDisplayWhenConfiguredForAllDisplays),
    ("kept: git workspace inspector resolves branch names", testGitWorkspaceInspectorResolvesBranchNames),
    ("kept: Git branch coordinator coalesces and caches working directory", testGitBranchResolutionCoordinatorCoalescesAndCachesWorkingDirectory),
    ("kept: Git branch coordinator bounds concurrent probes", testGitBranchResolutionCoordinatorBoundsConcurrentProbes),
    ("kept: Git branch coordinator evicts least-recent cache entry", testGitBranchResolutionCoordinatorEvictsLeastRecentlyUsedEntry),
    ("kept: notch layout extends from left side of hardware notch", testNotchLayoutExtendsFromLeftSideOfHardwareNotch),
    ("kept: notch layout keeps expanded content close to the side edges", testNotchLayoutKeepsExpandedContentCloseToTheSideEdges),
    ("kept: notch layout pins compact bar to physical notch when panel is clamped", testNotchLayoutPinsCompactBarToPhysicalNotchWhenExpandedPanelIsClamped),
    ("kept: notch layout expanded header wings flank the camera", testNotchLayoutExpandedHeaderWingsFlankTheCamera),
    ("kept: notch layout adds only a minimal fixed right wing", testNotchLayoutAddsOnlyAMinimalFixedRightWing),
    ("kept: notch layout adds only a minimal fixed left wing", testNotchLayoutAddsOnlyAMinimalFixedLeftWing),
    ("kept: notch layout reserves right outer curve clearance for blocked count", testNotchLayoutReservesRightOuterCurveClearanceForBlockedCount),
    ("kept: notch layout uses pill style on notchless screen", testNotchLayoutUsesPillStyleOnNotchlessScreen),
    ("kept: notch layout pill falls back to standard menu bar height", testNotchLayoutPillFallsBackToStandardMenuBarHeight),
    ("kept: notch layout notch keeps screen edge attachment", testNotchLayoutNotchKeepsScreenEdgeAttachment),
    ("kept: hanging notch geometry creates concave shoulders and rounded base", testHangingNotchGeometryCreatesConcaveShouldersAndRoundedBase),
    ("kept: hanging notch geometry keeps expanded sides straight with circular corners", testHangingNotchGeometryKeepsExpandedSidesStraightWithCircularCorners),
    ("kept: bubble geometry rounds every corner and capsules when short", testBubbleGeometryRoundsEveryCornerAndCapsulesWhenShort),
    ("kept: bubble interaction region floats below the top edge", testBubbleInteractionRegionFloatsBelowTheTopEdge),
    ("kept: hover interaction preserves the top gap while expanded", testHoverInteractionPreservesTheTopGapWhileExpanded),
    ("kept: hanging notch metrics share one corner profile across modes", testHangingNotchMetricsShareOneCornerProfileAcrossModes),
    ("kept: session menu layout keeps three expanded sessions out of a scroll view", testSessionMenuLayoutKeepsThreeExpandedSessionsOutOfAScrollView),
    ("kept: hover interaction keeps inline row interactions open during delayed exit", testHoverInteractionKeepsInlineRowInteractionsOpenDuringDelayedExit),
    ("kept: notch layout uses normalized camera clearance", testNotchLayoutUsesNormalizedCameraClearance),
    ("kept: hanging notch interaction region passes transparent corners through", testHangingNotchInteractionRegionPassesTransparentCornersThrough),
    ("kept: notch layout menu card width never cramped in pill mode", testNotchLayoutMenuCardWidthNeverCrampedInPillMode),
    ("kept: focus action runner keeps earlier Herdr failure after outer activation", testFocusActionRunnerKeepsEarlierHerdrFailureAfterOuterActivation),
    ("kept: resource bundle search covers every installed layout", testResourceBundleSearchCoversEveryInstalledLayout),
    ("kept: session name overrides rename and prune", testSessionNameOverridesRenameAndPrune),
    ("kept: braille spinner cycle covers every frame exactly once", testBrailleSpinnerCycleCoversEveryFrameExactlyOnce),
    ("kept: braille spinner frames are single braille pattern glyphs", testBrailleSpinnerFramesAreSingleBraillePatternGlyphs),
    ("kept: session title formatter cleans tab titles", testSessionTitleFormatterCleansTabTitles),
    ("kept: pinned session order passes through before anything is recorded", testPinnedSessionOrderPassesThroughBeforeAnythingIsRecorded),
    ("kept: pinned session order keeps recorded slots when the store resorts", testPinnedSessionOrderKeepsRecordedSlotsWhenTheStoreResorts),
    ("kept: pinned session order appends sessions it has not seen", testPinnedSessionOrderAppendsSessionsItHasNotSeen),
    ("kept: pinned session order drops sessions that ended", testPinnedSessionOrderDropsSessionsThatEnded),
    ("kept: pinned session order recording is additive rather than resorting", testPinnedSessionOrderRecordingIsAdditiveRatherThanResorting),
    ("kept: hover selection follows the pointer across rows", testHoverSelectionFollowsThePointerAcrossRows),
    ("kept: hover selection survives an exit that arrives after the next enter", testHoverSelectionSurvivesAnExitThatArrivesAfterTheNextEnter),
    ("kept: hover selection clears when the selected row exits", testHoverSelectionClearsWhenTheSelectedRowExits),
    ("kept: hover selection drops everything when the list is replaced", testHoverSelectionDropsEverythingWhenTheListIsReplaced),
    ("kept: action list hover geometry resolves the row under the pointer", testActionListHoverGeometryResolvesTheRowUnderThePointer),
    ("kept: action list hover geometry rejects points outside the list", testActionListHoverGeometryRejectsPointsOutsideTheList),
    ("kept: inline actions click gate lets plain hover through", testInlineActionsClickGateLetsPlainHoverThrough),
    ("kept: inline actions click gate claims right and control clicks", testInlineActionsClickGateClaimsRightAndControlClicks),
]

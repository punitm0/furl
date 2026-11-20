import XCTest
@testable import Furl

/// The Overview's big number, the menu bar and the low-disk alert all use `safeCleanupPlan`
/// (GetSpaceBack board: "the same number everywhere"). It must hold only safe, ticked items.
final class SafeNumberTests: XCTestCase {
    private func junk(_ id: String, _ path: String, risk: RiskLevel = .safe, bytes: Int64 = 100,
                      command: JunkCommand? = nil, extra: [String] = []) -> JunkItem {
        JunkItem(id: id, name: id, path: path, category: .devArtifacts, risk: risk, sizeBytes: bytes,
                 modifiedDate: nil, reason: "", command: command, extraPaths: extra)
    }

    private func worktree(_ id: String, _ path: String, bytes: Int64 = 1000) -> WorktreeItem {
        WorktreeItem(id: id, repoPath: "/r", repoName: "r", worktreePath: path, branchName: id, baseBranch: "main",
                     commitHash: "abc", lastCommitDate: nil, mergeStatus: .merged, isDirty: false, isLocked: false,
                     isPrunable: false, sizeBytes: bytes)
    }

    private func plan(_ items: [JunkItem], ticked: Set<String>? = nil,
                      protected: Set<String> = []) -> AppState.SafeCleanupPlan {
        AppState.safeCleanupPlan(junk: items, ticked: ticked ?? Set(items.map(\.id)),
                                 isProtected: { protected.contains($0) })
    }

    func testOnlySafeItemsCount() {
        let p = plan([junk("safe", "/a/cache", bytes: 300),
                      junk("review", "/a/logs", risk: .review, bytes: 5000),
                      junk("moderate", "/a/models", risk: .moderate, bytes: 7000)])
        XCTAssertEqual(p.paths, ["/a/cache"])
        XCTAssertEqual(p.bytes, 300)
    }

    func testUntickedSafeItemsAreLeftOut() {
        let p = plan([junk("kept", "/a/one", bytes: 100), junk("unticked", "/a/two", bytes: 900)], ticked: ["kept"])
        XCTAssertEqual(p.paths, ["/a/one"])
        XCTAssertEqual(p.bytes, 100)
    }

    func testPermanentItemsAreNeverCounted() {
        // Docker and Simulator items can't go to the Trash, even when rated Safe and ticked.
        let docker = junk("docker", "docker://build-cache", bytes: 9000,
                          command: JunkCommand(executable: "/usr/bin/true", arguments: []))
        let p = plan([docker, junk("cache", "/a/cache", bytes: 10)])
        XCTAssertEqual(p.paths, ["/a/cache"])
        XCTAssertEqual(p.bytes, 10)
    }

    func testProtectedPathsAreLeftOut() {
        let p = plan([junk("sys", "/System/Library/Caches", bytes: 50),
                      junk("withExtra", "/a/model", bytes: 70, extra: ["/System/blob"]),
                      junk("ok", "/a/ok", bytes: 5)],
                     protected: ["/System/Library/Caches", "/System/blob"])
        XCTAssertEqual(p.paths, ["/a/ok"])
    }

    func testNestedItemsCountOnce() {
        let p = plan([junk("outer", "/a/build", bytes: 1000), junk("inner", "/a/build/cache", bytes: 400)])
        XCTAssertEqual(p.paths, ["/a/build"])
        XCTAssertEqual(p.bytes, 1000)
    }

    func testStepsKeepWorktreesDuplicatesLeftoversAndLargeFilesOutOfSafe() {
        let p = plan([junk("nm", "/w/merged/node_modules", bytes: 300), junk("cache", "/a/cache", bytes: 200)])
        let old = Date(timeIntervalSince1970: 0)
        let now = Date()
        let steps = SpaceSteps.make(
            plan: p,
            worktrees: [worktree("merged", "/w/merged", bytes: 1000)],
            duplicates: [DuplicateGroup(id: "d", sizeBytes: 40, files: [
                DuplicateFile(id: "1", path: "/d/1", name: "1", modifiedDate: now, privateBytes: 40),
                DuplicateFile(id: "2", path: "/d/2", name: "2", modifiedDate: old, privateBytes: 40),
            ])],
            leftovers: [OrphanedAppDataGroup(id: "g", appIdentifier: "com.x", displayName: "X", items: [
                AppDataItem(id: "l", path: "/l/x", name: "x", location: .caches, sizeBytes: 60, modifiedDate: nil,
                            isStrongMatch: true),
                // Also a safe junk item: counted once, in step one.
                AppDataItem(id: "c", path: "/a/cache", name: "c", location: .caches, sizeBytes: 200, modifiedDate: nil,
                            isStrongMatch: true),
            ])],
            largeFiles: [LargeFileItem(id: "big", name: "big", path: "/f/big.mov", sizeBytes: 5000, modifiedDate: old, kind: .media),
                         LargeFileItem(id: "new", name: "new", path: "/f/new.mov", sizeBytes: 8000, modifiedDate: now, kind: .media),
                         LargeFileItem(id: "dup", name: "dup", path: "/d/2", sizeBytes: 40, modifiedDate: old, kind: .other)],
            now: now
        )
        XCTAssertEqual(steps.safeBytes, 500, "Only the ticked Safe junk")
        XCTAssertEqual(steps.worktreeBytes, 700, "The worktree minus the safe node_modules inside it")
        XCTAssertEqual(steps.duplicateBytes, 40)
        XCTAssertEqual(steps.leftoverBytes, 60)
        XCTAssertEqual(steps.quickLookBytes, 800)
        XCTAssertEqual(steps.largeFileBytes, 5000, "Only files unchanged for a year, not already a duplicate")
    }

    func testBiggestWinSumsByName() {
        let entries = [
            TrashLedgerEntry(originalPath: "/a/node_modules", trashPath: "/t/1", date: Date(), bytes: 300),
            TrashLedgerEntry(originalPath: "/b/node_modules", trashPath: "/t/2", date: Date(), bytes: 300),
            TrashLedgerEntry(originalPath: "/c/DerivedData", trashPath: "/t/3", date: Date(), bytes: 500),
        ]
        let names = ["/a/node_modules": "node_modules", "/b/node_modules": "node_modules", "/c/DerivedData": "DerivedData"]
        let win = SafeCleanSummary.biggestWin(trashed: entries, names: names, sizes: [:])
        XCTAssertEqual(win?.name, "node_modules")
        XCTAssertEqual(win?.bytes, 600)
    }
}

/// Review fixes: what a safe clean may move, unticks while checking, one run at a time, Undo.
@MainActor
final class SafeCleanRunTests: XCTestCase {
    private func junk(_ id: String, _ path: String, category: JunkCategory = .devArtifacts) -> JunkItem {
        JunkItem(id: id, name: id, path: path, category: category, risk: .safe, sizeBytes: 100,
                 modifiedDate: nil, reason: "")
    }

    func testTargetsAreConfirmedPlanItemsMinusVetoes() {
        let plan = AppState.safeCleanupPlan(junk: [junk("a", "/x/a"), junk("b", "/x/b"), junk("c", "/x/c")],
                                            ticked: ["a", "b", "c"], isProtected: { _ in false })
        // "/x/new" was found after the confirm; "/x/c" wasn't confirmed; "/x/b" was unticked while checking.
        let targets = AppState.safeCleanTargets(plan: plan, confirmed: ["/x/a", "/x/b", "/x/new"], vetoed: ["/x/b"])
        XCTAssertEqual(targets.map(\.path), ["/x/a"])
    }

    func testTargetsDropItemsNoLongerTickedOrSafe() {
        // After a rescan, only what is still Safe and ticked is in the plan.
        let plan = AppState.safeCleanupPlan(junk: [junk("a", "/x/a"), junk("b", "/x/b")], ticked: ["a"],
                                            isProtected: { _ in false })
        XCTAssertEqual(AppState.safeCleanTargets(plan: plan, confirmed: ["/x/a", "/x/b"], vetoed: []).map(\.path), ["/x/a"])
    }

    func testBrowserCachesOfARunningBrowserAreLeftOut() {
        let plan = AppState.safeCleanupPlan(
            junk: [junk("chrome", "/c/chrome", category: .browserCaches), junk("cache", "/c/npm")],
            ticked: ["chrome", "cache"], isProtected: { _ in false },
            isBrowserRunning: { $0 == "/c/chrome" })
        XCTAssertEqual(plan.paths, ["/c/npm"])
        XCTAssertEqual(plan.bytes, 100)
    }

    func testUntickWhileCheckingSticksThroughARetick() {
        let state = AppState()
        state.junkItems = [junk("a", "/x/a"), junk("b", "/x/b")]
        state.selectedJunkIDs = ["a", "b"]
        state.trackSafeCleanVetoes(true)
        state.selectedJunkIDs.remove("b")
        // A rescan during "Checking…" ticks every Safe item again.
        state.selectedJunkIDs.insert("b")
        XCTAssertEqual(state.safeCleanVetoes, ["/x/b"])
        let targets = AppState.safeCleanTargets(plan: state.safeCleanupPlan, confirmed: ["/x/a", "/x/b"],
                                                vetoed: state.safeCleanVetoes ?? [])
        XCTAssertEqual(targets.map(\.path), ["/x/a"])
        state.trackSafeCleanVetoes(false)
        XCTAssertNil(state.safeCleanVetoes)
    }

    func testUnticksOutsideACleanAreNotVetoes() {
        let state = AppState()
        state.junkItems = [junk("a", "/x/a")]
        state.selectedJunkIDs = ["a"]
        state.selectedJunkIDs.remove("a")
        XCTAssertNil(state.safeCleanVetoes)
    }

    func testCachedPlanFollowsTicks() {
        let state = AppState()
        state.junkItems = [junk("a", "/x/a"), junk("b", "/x/b")]
        state.selectedJunkIDs = ["a", "b"]
        XCTAssertEqual(state.safeCleanupPlan.bytes, 200)
        state.selectedJunkIDs = ["a"]
        XCTAssertEqual(state.safeCleanupPlan.paths, ["/x/a"])
        state.junkItems = []
        XCTAssertTrue(state.safeCleanupPlan.isEmpty)
    }

    func testOnlyOneSafeCleanRunsAtATime() {
        let state = AppState()
        XCTAssertTrue(state.canStartSafeClean(confirmedPaths: ["/x/a"]))
        XCTAssertFalse(state.canStartSafeClean(confirmedPaths: []), "Nothing confirmed, nothing to do")
        state.isCleaning = true
        XCTAssertFalse(state.canStartSafeClean(confirmedPaths: ["/x/a"]), "A second run is refused while one runs")
    }

    private func summary() -> SafeCleanSummary {
        let run = AutoSweepRun(date: Date(), trigger: .overview,
                               parts: [AutoSweepRunPart(rule: .safeClean, itemCount: 1, bytes: 100)],
                               trashed: [TrashLedgerEntry(originalPath: "/x/a", trashPath: "/t/a", date: Date(), bytes: 100)],
                               errors: [])
        return SafeCleanSummary(run: run, freedBytes: 100, itemCount: 1,
                                diskBefore: .init(totalBytes: 1000, usedBytes: 800, availableBytes: 200), biggestWin: nil)
    }

    func testUndoKeepsItsPromptUntilTheRunIsUndone() async {
        let state = AppState()
        state.lastSafeClean = summary()
        await state.undoSafeClean(using: { _ in false })
        XCTAssertNotNil(state.lastSafeClean, "A failed undo keeps Undo on screen")
        await state.undoSafeClean(using: { _ in true })
        XCTAssertNil(state.lastSafeClean)
    }

    func testUndoWaitsWhileAnotherCleanupRuns() async {
        let state = AppState()
        state.lastSafeClean = summary()
        state.isCleaning = true
        var called = false
        await state.undoSafeClean(using: { _ in called = true; return true })
        XCTAssertFalse(called)
        XCTAssertNotNil(state.lastSafeClean)
    }
}

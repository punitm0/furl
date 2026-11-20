import XCTest
@testable import Furl

final class ShortcutsBridgeTests: XCTestCase {
    private typealias Item = ShortcutsBridge.SafeItem

    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000

    private func junk(_ id: String, _ path: String, risk: RiskLevel = .safe, bytes: Int64,
                      command: JunkCommand? = nil) -> JunkItem {
        JunkItem(id: id, name: id, path: path, category: .systemCaches, risk: risk, sizeBytes: bytes,
                 modifiedDate: nil, reason: "", command: command, extraPaths: [])
    }

    private func worktree(_ path: String, bytes: Int64) -> WorktreeItem {
        WorktreeItem(id: path, repoPath: "/r", repoName: "r", worktreePath: path, branchName: "b", baseBranch: "main",
                     commitHash: "abc", lastCommitDate: nil, mergeStatus: .merged, isDirty: false, isLocked: false,
                     isPrunable: false, sizeBytes: bytes)
    }

    // MARK: - Same safe set as the Overview

    func testGetSafeSpaceEqualsOverviewSafeNumber() {
        let items = [junk("cache", "/u/Library/Caches/app", bytes: 3 * gb),
                     junk("logs", "/u/Library/Logs/app", bytes: 2 * gb),
                     junk("review", "/u/models", risk: .review, bytes: 40 * gb)]
        let plan = AppState.safeCleanupPlan(junk: items, ticked: Set(items.map(\.id)), isProtected: { _ in false })
        let safe = ShortcutsBridge.safeNow(from: plan)
        // The Overview's big number is SpaceSteps.safeBytes (= plan.bytes).
        let overview = SpaceSteps.make(plan: plan, worktrees: [], duplicates: [], leftovers: [], largeFiles: [])
        XCTAssertEqual(safe.bytes, overview.safeBytes)
        XCTAssertEqual(safe.bytes, 5 * gb)
        XCTAssertEqual(safe.items.map(\.path), plan.paths)
    }

    func testSafeSetNeverHoldsWorktreesOrPermanentItems() {
        // Docker/Simulator items are permanent (no file to Trash); worktrees aren't junk at all.
        let docker = junk("docker", "docker://build-cache", bytes: 9 * gb,
                          command: JunkCommand(executable: "/usr/bin/true", arguments: []))
        let items = [docker, junk("cache", "/u/Library/Caches/app", bytes: gb)]
        let plan = AppState.safeCleanupPlan(junk: items, ticked: Set(items.map(\.id)), isProtected: { _ in false })
        let safe = ShortcutsBridge.safeNow(from: plan)
        XCTAssertEqual(safe.items.map(\.path), ["/u/Library/Caches/app"])
        // A merged worktree shows up only in the Overview's "Quick look" step, never in "Safe now".
        let steps = SpaceSteps.make(plan: plan, worktrees: [worktree("/code/wt", bytes: 5 * gb)],
                                    duplicates: [], leftovers: [], largeFiles: [])
        XCTAssertEqual(steps.worktreeCount, 1)
        XCTAssertFalse(safe.items.contains { $0.path == "/code/wt" })
        XCTAssertEqual(safe.bytes, steps.safeBytes)
    }

    // MARK: - Free up to…

    func testPickDoesNotOvershootWithOneHugeItem() {
        let items = [Item(path: "/huge", bytes: 50 * gb), Item(path: "/a", bytes: 600 * mb), Item(path: "/b", bytes: 500 * mb)]
        // 600 MB fits; 400 MB is left, and the smallest item covering it is the 500 MB one.
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: gb).map(\.path), ["/a", "/b"])
    }

    func testPickFillsBiggestFirstThenFinishesWithSmallestCover() {
        let items = [Item(path: "/4", bytes: 4 * gb), Item(path: "/1", bytes: gb),
                     Item(path: "/9", bytes: 9 * gb), Item(path: "/2", bytes: 2 * gb)]
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 4 * gb).map(\.path), ["/4"])
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 5 * gb).map(\.path), ["/4", "/1"])
        // 4 + 2 = 6 fits; 0.5 GB left, covered by the 1 GB item rather than the 9 GB one.
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 6_500 * mb).map(\.path), ["/4", "/2", "/1"])
        // 4 + 2 + 1 = 7 fits and the 9 GB item would finish it (16 GB); the 9 GB item alone moves less.
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 8 * gb).map(\.path), ["/9"])
    }

    func testPickTakesEverythingWhenTargetExceedsTotal() {
        let items = [Item(path: "/a", bytes: 2 * gb), Item(path: "/b", bytes: 2 * gb)]
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 100 * gb).map(\.path), ["/a", "/b"])
        // Ties keep the original order.
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 2 * gb).map(\.path), ["/a"])
    }

    func testPickWithNoTargetOrEmptyItemsTakesNothing() {
        let items = [Item(path: "/a", bytes: gb), Item(path: "/zero", bytes: 0)]
        XCTAssertTrue(ShortcutsBridge.pick(items, toFree: 0).isEmpty)
        XCTAssertTrue(ShortcutsBridge.pick([], toFree: gb).isEmpty)
        // A zero-byte item never helps reach a target.
        XCTAssertEqual(ShortcutsBridge.pick(items, toFree: 2 * gb).map(\.path), ["/a"])
    }

    // MARK: - Copy

    @MainActor
    func testCopyMatchesBoard() {
        XCTAssertEqual(ShortcutsBridge.confirmTitle(bytes: 17_900_000_000), "Move 17.9 GB to the Trash?")
        XCTAssertTrue(ShortcutsBridge.confirmBody.hasSuffix("You can undo this in Furl."))
        XCTAssertEqual(ShortcutsBridge.resultText(bytes: 17_900_000_000, percentFull: 79, skipped: 0),
                       "Moved 17.9 GB to the Trash. Now 79% full.")
        XCTAssertTrue(ShortcutsBridge.resultText(bytes: gb, percentFull: 80, skipped: 1)
            .hasSuffix("1 item changed since the scan and was left alone."))
    }
}

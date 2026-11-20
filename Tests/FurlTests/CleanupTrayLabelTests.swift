import XCTest
@testable import Furl

/// The tray's button label, unmatched-item warning and worktree row titles.
final class CleanupTrayLabelTests: XCTestCase {
    private func item(_ source: TraySource, _ title: String, permanent: Bool = false) -> TrayItem {
        TrayItem(source: source, key: title, path: "/x/" + title, title: title, subtitle: "",
                 bytes: 1, isPermanent: permanent)
    }

    private func title(included: Int, permanent: Int, mode: DeletionMode = .moveToTrash) -> String {
        CleanupTray.primaryTitle(hasItems: true, includedCount: included, permanentCount: permanent,
                                 bytes: 1_000_000_000, mode: mode)
    }

    func testButtonOnlyPromisesTheTrashWhenNothingIsPermanent() {
        let size = FileSizeHelper.formatBytes(1_000_000_000)
        XCTAssertEqual(title(included: 3, permanent: 0), "Move \(size) to Trash")
        XCTAssertEqual(title(included: 3, permanent: 2), "Clean \(size)")
        XCTAssertEqual(title(included: 3, permanent: 3), "Remove \(size)")
        XCTAssertEqual(title(included: 3, permanent: 1, mode: .permanent), "Delete \(size)")
    }

    func testEmptyTrayButton() {
        XCTAssertEqual(CleanupTray.primaryTitle(hasItems: false, includedCount: 0, permanentCount: 0,
                                                bytes: 0, mode: .moveToTrash), "Move to Trash")
        XCTAssertEqual(CleanupTray.primaryTitle(hasItems: false, includedCount: 0, permanentCount: 0,
                                                bytes: 0, mode: .permanent), "Delete")
    }

    func testUnmatchedMessageNamesASingleItem() {
        let message = CleanupTray.unmatchedMessage([item(.worktrees, "claude/foo-1234")])
        XCTAssertEqual(message, "Took claude/foo-1234 off the tray: Git Worktrees doesn't list it anymore, so Furl didn't touch it. Rescan to check it.")
    }

    func testUnmatchedMessageCountsSeveralItems() {
        let one = CleanupTray.unmatchedMessage([item(.worktrees, "a/1"), item(.worktrees, "a/2")])
        XCTAssertEqual(one, "Took 2 items off the tray that Git Worktrees doesn't list anymore. Furl didn't touch them. Rescan to check them.")
        let two = CleanupTray.unmatchedMessage([item(.worktrees, "a/1"), item(.junk, "cache")])
        XCTAssertEqual(two, "Took 2 items off the tray that Caches & Junk and Git Worktrees don't list anymore. Furl didn't touch them. Rescan to check them.")
    }

    func testUnmatchedSectionsAreUniqueAndInTrayOrder() {
        let sections = CleanupTray.sections(of: [item(.worktrees, "a"), item(.junk, "b"), item(.worktrees, "c")])
        XCTAssertEqual(sections, [.junk, .worktrees])
    }

    func testSharedBranchPrefixIsDroppedFromWorktreeRows() {
        let rows = [item(.worktrees, "claude/dodo-payments-836c68"), item(.worktrees, "claude/auto-updates-385d43")]
        let prefix = CleanupTray.sharedBranchPrefix(rows)
        XCTAssertEqual(prefix, "claude/")
        XCTAssertEqual(CleanupTray.displayTitle(rows[0], sharedPrefix: prefix), "dodo-payments-836c68")
        // Other sections keep their titles.
        XCTAssertEqual(CleanupTray.displayTitle(item(.junk, "claude/x"), sharedPrefix: prefix), "claude/x")
    }

    func testPrefixStopsAtTheLastSharedSlash() {
        XCTAssertEqual(CleanupTray.sharedBranchPrefix([item(.worktrees, "claude/do-1"), item(.worktrees, "claude/dx-2")]), "claude/")
        XCTAssertEqual(CleanupTray.sharedBranchPrefix([item(.worktrees, "feat/a/1"), item(.worktrees, "feat/a/2")]), "feat/a/")
    }

    func testNoPrefixWhenNotShared() {
        XCTAssertEqual(CleanupTray.sharedBranchPrefix([item(.worktrees, "claude/a")]), "")
        XCTAssertEqual(CleanupTray.sharedBranchPrefix([item(.worktrees, "claude/a"), item(.worktrees, "main")]), "")
        XCTAssertEqual(CleanupTray.sharedBranchPrefix([item(.worktrees, "claudeA"), item(.worktrees, "claudeB")]), "")
    }
}

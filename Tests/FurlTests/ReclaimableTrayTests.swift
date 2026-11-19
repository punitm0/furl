import XCTest
@testable import Furl

/// "Review items first" on the Overview hero fills the tray with what the hero total counts.
final class ReclaimableTrayTests: XCTestCase {
    private func junk(_ id: String, _ path: String, risk: RiskLevel = .safe, bytes: Int64 = 100,
                      command: JunkCommand? = nil) -> JunkItem {
        JunkItem(id: id, name: id, path: path, category: .devArtifacts, risk: risk, sizeBytes: bytes,
                 modifiedDate: nil, reason: "", command: command)
    }

    private func worktree(_ id: String, _ path: String, status: WorktreeMergeStatus = .merged,
                          dirty: Bool = false) -> WorktreeItem {
        WorktreeItem(id: id, repoPath: "/r", repoName: "r", worktreePath: path, branchName: id, baseBranch: "main",
                     commitHash: "abc", lastCommitDate: nil, mergeStatus: status, isDirty: dirty, isLocked: false,
                     isPrunable: false, sizeBytes: 1000)
    }

    private func leftover(_ id: String, _ path: String, strong: Bool) -> AppDataItem {
        AppDataItem(id: id, path: path, name: id, location: .caches, sizeBytes: 50, modifiedDate: nil,
                    isStrongMatch: strong)
    }

    func testTicksWhatEachSectionPreselects() {
        let items = TrayItem.reclaimable(
            junk: [junk("safe", "/a/cache"), junk("review", "/a/logs", risk: .review)],
            worktrees: [worktree("merged", "/w/merged"), worktree("dirty", "/w/dirty", dirty: true),
                        worktree("active", "/w/active", status: .unmerged)],
            leftovers: [OrphanedAppDataGroup(id: "g", appIdentifier: "com.x", displayName: "X",
                                             items: [leftover("strong", "/l/strong", strong: true),
                                                     leftover("loose", "/l/loose", strong: false)])],
            duplicates: []
        )
        let included = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.included) })
        XCTAssertEqual(included["safe"], true)
        XCTAssertEqual(included["review"], false)
        XCTAssertEqual(included["merged"], true)
        XCTAssertNil(included["dirty"], "Worktrees the total doesn't count stay out")
        XCTAssertNil(included["active"])
        XCTAssertEqual(included["data:strong"], false, "Leftovers are a guess; the Leftovers screen never pre-selects them")
        XCTAssertEqual(included["data:loose"], false)
    }

    func testPermanentJunkIsListedButNotTicked() {
        let docker = junk("docker", "docker://build-cache", command: JunkCommand(executable: "/usr/bin/true", arguments: []))
        let items = TrayItem.reclaimable(junk: [docker], worktrees: [], leftovers: [], duplicates: [])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].included)
    }

    func testItemsInsideATickedItemAreLeftOut() {
        let items = TrayItem.reclaimable(
            junk: [junk("nm", "/w/merged/node_modules"), junk("inReview", "/a/big/cache"),
                   junk("big", "/a/big", risk: .review)],
            worktrees: [worktree("merged", "/w/merged")],
            leftovers: [], duplicates: []
        )
        let keys = Set(items.map(\.key))
        XCTAssertFalse(keys.contains("nm"), "Goes with the merged worktree")
        // The parent isn't ticked, so the Safe item inside it still stands on its own.
        XCTAssertTrue(keys.contains("inReview"))
        XCTAssertTrue(keys.contains("big"))
    }

    func testDuplicatesKeepTheCheapestCopyAndStayUnticked() {
        let old = Date(timeIntervalSince1970: 0)
        let group = DuplicateGroup(id: "d", sizeBytes: 10, files: [
            DuplicateFile(id: "1", path: "/d/1", name: "1", modifiedDate: Date(), privateBytes: 10),
            DuplicateFile(id: "clone", path: "/d/clone", name: "clone", modifiedDate: old, privateBytes: 0),
            DuplicateFile(id: "3", path: "/d/3", name: "3", modifiedDate: old, privateBytes: 10),
        ])
        let items = TrayItem.reclaimable(junk: [], worktrees: [], leftovers: [], duplicates: [group])
        XCTAssertEqual(Set(items.map(\.key)), ["1", "3"])
        XCTAssertTrue(items.allSatisfy { !$0.included })
        XCTAssertEqual(items.reduce(0) { $0 + $1.bytes }, group.reclaimableBytes)
    }

    func testAFolderThatIsBothJunkAndALeftoverIsListedOnce() {
        let cache = "/u/Library/Caches/go-build"
        let items = TrayItem.reclaimable(
            junk: [junk("go", cache, risk: .review, bytes: 500)],
            worktrees: [],
            leftovers: [OrphanedAppDataGroup(id: "g", appIdentifier: "go", displayName: "Go",
                                             items: [AppDataItem(id: "go", path: cache, name: "go-build", location: .caches,
                                                                 sizeBytes: 500, modifiedDate: nil, isStrongMatch: true)])],
            duplicates: []
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].included, "A leftover never raises Review junk to ticked")
        XCTAssertEqual(CleanupTray.nestedAwareTotal(items), 500)
    }

    func testSafeJunkThatIsAlsoALeftoverStaysTicked() {
        let cache = "/u/Library/Caches/node-gyp"
        let items = TrayItem.reclaimable(
            junk: [junk("gyp", cache, risk: .safe, bytes: 300)],
            worktrees: [],
            leftovers: [OrphanedAppDataGroup(id: "g", appIdentifier: "gyp", displayName: "node-gyp",
                                             items: [AppDataItem(id: "gyp", path: cache, name: "node-gyp", location: .caches,
                                                                 sizeBytes: 300, modifiedDate: nil, isStrongMatch: true)])],
            duplicates: []
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].included, "Safe junk keeps its tick")
    }

    func testTrayTotalCountsTheSamePathOnce() {
        let a = TrayItem.junk(junk("a", "/x/cache", bytes: 300))
        let b = TrayItem.leftover(AppDataItem(id: "b", path: "/x/cache", name: "cache", location: .caches,
                                              sizeBytes: 300, modifiedDate: nil), appName: "X")
        XCTAssertEqual(CleanupTray.nestedAwareTotal([a, b]), 300)
    }
}

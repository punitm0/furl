import XCTest
@testable import Furl

/// WorktreesSimple: removing a worktree deletes it for good, so these pin down what can be ticked,
/// which branches go, and that "Remove anyway…" re-checks right before acting. Real git repos.
final class WorktreeSafetyTests: XCTestCase {
    private var base: TempDir!
    /// `TempDir` drops `/private`; git reports the real path, so compare against that.
    private var root: String { realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? base.path }
    private var repo: String { (root as NSString).appendingPathComponent("repo") }
    private func file(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    override func setUpWithError() throws {
        base = try TempDir()
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try write("README.md", "hello\n", in: repo)
        try git("add", "README.md")
        try git("commit", "-q", "-m", "init")
    }

    override func tearDown() { base = nil }

    // MARK: - Ticking

    func testDirtyWorktreeCanNeverBeBulkSelected() {
        let dirty = item(.merged, dirty: true, changed: 3)
        XCTAssertFalse(dirty.isBulkSelectable)
        XCTAssertFalse(dirty.canAutoSelect)
        XCTAssertTrue(dirty.canRemoveAnyway)
        // Git couldn't list the changes: not tickable, and not offered "Remove anyway…" either.
        let unknown = item(.merged, dirty: true, changed: nil)
        XCTAssertFalse(unknown.isBulkSelectable)
        XCTAssertFalse(unknown.canRemoveAnyway)
        XCTAssertFalse(item(.main).isBulkSelectable)
        XCTAssertTrue(item(.merged).isBulkSelectable)
        XCTAssertFalse(item(.merged).canRemoveAnyway)
    }

    func testScanCountsChangedFilesAndKeepsDirtyWorktreeUnselectable() throws {
        let wt = try addWorktree("feat/dirty")
        try write("notes.md", "new\n", in: wt)
        try write("README.md", "edited\n", in: wt)
        let found = WorktreeScanner.scan(roots: [root]).first { $0.worktreePath == wt }
        let scanned = try XCTUnwrap(found)
        XCTAssertTrue(scanned.isDirty)
        XCTAssertEqual(scanned.changedFileCount, 2)
        XCTAssertFalse(scanned.isBulkSelectable)
        XCTAssertTrue(scanned.canRemoveAnyway)
    }

    // MARK: - Branches

    @MainActor
    func testBranchDeletionIsOffByDefault() {
        XCTAssertFalse(WorktreeConfirm.RemoveChoice().deleteMergedBranches)
    }

    func testUnmergedBranchIsAlwaysKept() throws {
        let wt = try addWorktree("feat/wip")
        try write("work.txt", "work\n", in: wt)
        try git(in: wt, "add", "work.txt")
        try git(in: wt, "commit", "-q", "-m", "wip")
        let target = scanned(wt)
        XCTAssertEqual(target.mergeStatus, .unmerged)
        XCTAssertFalse(target.hasDeletableMergedBranch)
        // Even asked to delete branches, and even forced, an unmerged branch stays.
        let result = WorktreeScanner.removeWorktree(item: target, force: true, deleteLocalBranch: true)
        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(branchExists("feat/wip"))
    }

    func testMergedBranchKeptUnlessAsked() throws {
        let wt = try mergedWorktree("feat/done")
        _ = try WorktreeScanner.removeWorktree(item: scanned(wt), force: false, deleteLocalBranch: false).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(branchExists("feat/done"))
    }

    func testMergedBranchDeletedWhenAsked() throws {
        let wt = try mergedWorktree("feat/done")
        let outcome = try WorktreeScanner.removeWorktree(item: scanned(wt), force: false, deleteLocalBranch: true).get()
        XCTAssertNil(outcome.warning)
        XCTAssertFalse(branchExists("feat/done"))
    }

    func testMergedBranchThatMovedSinceScanIsKept() throws {
        let wt = try mergedWorktree("feat/done")
        let target = scanned(wt)
        try write("later.txt", "later\n", in: wt)
        try git(in: wt, "add", "later.txt")
        try git(in: wt, "commit", "-q", "-m", "later")
        try git(in: wt, "checkout", "-q", "--detach")
        let outcome = try WorktreeScanner.removeWorktree(item: target, force: false, deleteLocalBranch: true).get()
        XCTAssertNotNil(outcome.warning)
        XCTAssertTrue(branchExists("feat/done"))
    }

    // MARK: - Remove anyway re-check

    func testRemoveAnywayPassesOnlyWithTheSameChanges() throws {
        let wt = try addWorktree("spike/router")
        try write("notes.md", "new\n", in: wt)
        let target = scanned(wt)
        let stamps = CleanupStamp.read([wt])
        let shown = try XCTUnwrap(WorktreeChangeSnapshot.take(in: wt))
        XCTAssertEqual(shown.changes, [WorktreeChange(path: "notes.md", kind: .new)])

        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.expectedWorktreeChanges = shown
        XCTAssertTrue(CleanupRecheck.passes(check, stamps: stamps))

        // A file changed after the confirm was shown: it wasn't listed, so nothing is removed.
        try write("README.md", "edited later\n", in: wt)
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testUntrackedFolderListsEveryFile() throws {
        let wt = try addWorktree("spike/feature")
        try FileManager.default.createDirectory(atPath: (wt as NSString).appendingPathComponent("src/feature"),
                                                withIntermediateDirectories: true)
        for name in ["a.ts", "b.ts", "c.ts"] { try write("src/feature/\(name)", "x\n", in: wt) }
        XCTAssertEqual(scanned(wt).changedFileCount, 3)
        let shown = try XCTUnwrap(WorktreeChangeSnapshot.take(in: wt))
        XCTAssertEqual(Set(shown.changes.map(\.path)), ["src/feature/a.ts", "src/feature/b.ts", "src/feature/c.ts"])
    }

    func testFileAddedInsideListedFolderFailsRecheck() throws {
        let wt = try addWorktree("spike/feature")
        try FileManager.default.createDirectory(atPath: (wt as NSString).appendingPathComponent("src/feature"),
                                                withIntermediateDirectories: true)
        try write("src/feature/a.ts", "x\n", in: wt)
        let target = scanned(wt)
        let stamps = CleanupStamp.read([wt])
        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.expectedWorktreeChanges = try XCTUnwrap(WorktreeChangeSnapshot.take(in: wt))
        XCTAssertTrue(CleanupRecheck.passes(check, stamps: stamps))
        try write("src/feature/added-later.ts", "y\n", in: wt)
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testEditToListedFileFailsRecheck() throws {
        let wt = try addWorktree("spike/router")
        try write("notes.md", "new\n", in: wt)
        let target = scanned(wt)
        let stamps = CleanupStamp.read([wt])
        let shown = try XCTUnwrap(WorktreeChangeSnapshot.take(in: wt))
        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.expectedWorktreeChanges = shown
        // Same status line ("?? notes.md"), different content: the fingerprint catches it.
        try write("notes.md", "new, and an hour of work more\n", in: wt)
        XCTAssertEqual(ShellRunner.gitStatusPorcelain(in: wt, everyFile: true), shown.status)
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testNestedRepositoryCantBeListed() throws {
        let wt = try addWorktree("spike/nested")
        let inner = (wt as NSString).appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try git(in: inner, "init", "-q")
        try write("work.txt", "x\n", in: inner)
        XCTAssertNil(WorktreeChangeSnapshot.take(in: wt))
    }

    func testRemoveAnywayFailsWhenHeadMoved() throws {
        let wt = try addWorktree("spike/router")
        try write("notes.md", "new\n", in: wt)
        let target = scanned(wt)
        let stamps = CleanupStamp.read([wt])
        let shown = try XCTUnwrap(WorktreeChangeSnapshot.take(in: wt))
        try write("README.md", "committed\n", in: wt)
        try git(in: wt, "commit", "-q", "-am", "new commit")
        XCTAssertEqual(ShellRunner.gitStatusPorcelain(in: wt, everyFile: true), shown.status)
        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.expectedWorktreeChanges = shown
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testBulkRecheckRefusesWorktreeThatGotChanges() throws {
        let wt = try mergedWorktree("feat/done")
        let target = scanned(wt)
        let stamps = CleanupStamp.read([wt])
        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.requireCleanWorktree = true
        XCTAssertTrue(CleanupRecheck.passes(check, stamps: stamps))
        try write("sub.txt", "x\n", in: wt)
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testBulkTargetsDropDirtyIDStillSelected() {
        let clean = item(.merged)
        var dirty = item(.merged, dirty: true, changed: 2)
        dirty = WorktreeItem(id: "dirty", repoPath: dirty.repoPath, repoName: dirty.repoName, worktreePath: "/r/api-wt/y",
                             branchName: "feat/y", baseBranch: "main", commitHash: "abc1234", lastCommitDate: nil,
                             mergeStatus: .merged, isDirty: true, isLocked: false, isPrunable: false, sizeBytes: 10,
                             changedFileCount: 2)
        let targets = AppState.bulkWorktreeTargets([clean, dirty], selected: [clean.id, dirty.id])
        XCTAssertEqual(targets.map(\.id), [clean.id])
    }

    // MARK: - No branch

    func testDetachedWorktreeOnABranchCanBeTicked() throws {
        let wt = file("detached")
        try git("worktree", "add", "-q", "--detach", wt)
        let found = scanned(wt)
        XCTAssertEqual(found.mergeStatus, .detached)
        XCTAssertTrue(found.headOnBranch)
        XCTAssertTrue(found.isBulkSelectable)
        XCTAssertFalse(found.canRemoveAnyway)
    }

    func testDetachedWorktreeWithLostCommitsNeedsRemoveAnyway() throws {
        let wt = file("detached")
        try git("worktree", "add", "-q", "--detach", wt)
        try write("experiment.txt", "x\n", in: wt)
        try git(in: wt, "add", "experiment.txt")
        try git(in: wt, "commit", "-q", "-m", "experiment")
        let found = scanned(wt)
        XCTAssertFalse(found.headOnBranch)
        XCTAssertTrue(found.losesCommitsIfRemoved)
        XCTAssertFalse(found.isBulkSelectable)
        XCTAssertTrue(found.canRemoveAnyway)
    }

    func testBulkRecheckRefusesDetachedWhoseBranchWasDeleted() throws {
        // HEAD is on a branch at scan time; the branch goes away before the remove.
        let keep = try addWorktree("tmp/holder")
        try write("held.txt", "x\n", in: keep)
        try git(in: keep, "add", "held.txt")
        try git(in: keep, "commit", "-q", "-m", "held")
        let wt = file("detached")
        try git("worktree", "add", "-q", "--detach", wt, "tmp/holder")
        let target = scanned(wt)
        XCTAssertTrue(target.isBulkSelectable)
        let stamps = CleanupStamp.read([wt])
        var check = CleanupItem(path: wt)
        check.worktreeCommit = target.commitHash
        check.requireCleanWorktree = true
        check.requireHeadOnBranch = true
        XCTAssertTrue(CleanupRecheck.passes(check, stamps: stamps))
        try git("worktree", "remove", "--force", keep)
        try git("branch", "-D", "tmp/holder")
        XCTAssertFalse(CleanupRecheck.passes(check, stamps: stamps))
    }

    func testLockedWorktreeIsNotOfferedRemoveAnyway() {
        let locked = WorktreeItem(id: "wt", repoPath: "/r/api", repoName: "api", worktreePath: "/r/api-wt/x",
                                  branchName: "feat/x", baseBranch: "main", commitHash: "abc1234", lastCommitDate: nil,
                                  mergeStatus: .unmerged, isDirty: true, isLocked: true, isPrunable: false, sizeBytes: 10,
                                  changedFileCount: 3)
        XCTAssertFalse(locked.canRemoveAnyway)
    }

    // MARK: - Branch edge cases

    func testBranchCheckedOutElsewhereIsKept() throws {
        let wt = try mergedWorktree("feat/done")
        let target = scanned(wt)
        try git("worktree", "add", "-q", "--force", file("second"), "feat/done")
        let outcome = try WorktreeScanner.removeWorktree(item: target, force: false, deleteLocalBranch: true).get()
        XCTAssertNotNil(outcome.warning)
        XCTAssertTrue(branchExists("feat/done"))
    }

    func testSquashMergedBranchDeletedWhileStillMerged() throws {
        let wt = try squashMergedWorktree("fix/sq")
        let outcome = try WorktreeScanner.removeWorktree(item: scanned(wt), force: false, deleteLocalBranch: true).get()
        XCTAssertNil(outcome.warning)
        XCTAssertFalse(branchExists("fix/sq"))
    }

    func testSquashMergedBranchKeptWhenNoLongerMerged() throws {
        let wt = try squashMergedWorktree("fix/sq")
        let target = scanned(wt)
        // The squash commit leaves main after the scan: -D would now drop unmerged work.
        try git("reset", "-q", "--hard", "HEAD~1")
        let outcome = try WorktreeScanner.removeWorktree(item: target, force: false, deleteLocalBranch: true).get()
        XCTAssertNotNil(outcome.warning)
        XCTAssertTrue(branchExists("fix/sq"))
    }

    func testSymlinkedWorktreePathIsRefused() throws {
        let wt = try mergedWorktree("feat/done")
        let link = file("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: wt)
        let real = scanned(wt)
        let viaLink = WorktreeItem(id: link, repoPath: real.repoPath, repoName: real.repoName, worktreePath: link,
                                   branchName: real.branchName, baseBranch: real.baseBranch, commitHash: real.commitHash,
                                   lastCommitDate: nil, mergeStatus: .merged, isDirty: false, isLocked: false,
                                   isPrunable: false, sizeBytes: 0)
        XCTAssertThrowsError(try WorktreeScanner.removeWorktree(item: viaLink, force: true, deleteLocalBranch: true).get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))
        XCTAssertTrue(branchExists("feat/done"))
    }

    // MARK: - Parsing and display

    func testParsesPorcelainZ() {
        let changes = WorktreeChange.parse(" M src/a.ts\0?? a -> b\0 D old.txt\0R  c.ts\0b.ts\0?? with space.txt\0")
        XCTAssertEqual(changes, [
            .init(path: "src/a.ts", kind: .changed), .init(path: "a -> b", kind: .new),
            .init(path: "old.txt", kind: .deleted), .init(path: "c.ts", kind: .renamed),
            .init(path: "with space.txt", kind: .new),
        ])
    }

    func testControlAndBidiCharactersAreEscaped() {
        let shown = WorktreeChange.displaySafe("invoice\u{202E}fdp.exe\nnext")
        XCTAssertFalse(shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x0A })
        XCTAssertTrue(shown.contains("\\u{202E}"))
        XCTAssertEqual(WorktreeChange.displaySafe("src/café.ts"), "src/café.ts")
    }

    func testMissingFoldersToast() {
        XCTAssertEqual(AppState.missingFoldersMessage(1), "Cleaned up 1 missing folder. Git no longer lists it.")
        XCTAssertEqual(AppState.missingFoldersMessage(2), "Cleaned up 2 missing folders. Git no longer lists them.")
    }

    // MARK: - Helpers

    private func item(_ status: WorktreeMergeStatus, dirty: Bool = false, changed: Int? = 0) -> WorktreeItem {
        WorktreeItem(id: "wt", repoPath: "/r/api", repoName: "api", worktreePath: "/r/api-wt/x",
                     branchName: "feat/x", baseBranch: "main", commitHash: "abc1234", lastCommitDate: nil,
                     mergeStatus: status, isDirty: dirty, isLocked: false, isPrunable: false, sizeBytes: 10,
                     changedFileCount: dirty ? changed : 0)
    }

    private func scanned(_ path: String) -> WorktreeItem {
        WorktreeScanner.scan(roots: [root]).first { $0.worktreePath == path }!
    }

    private func addWorktree(_ branch: String) throws -> String {
        let path = file(branch.replacingOccurrences(of: "/", with: "-"))
        try git("worktree", "add", "-q", "-b", branch, path)
        return path
    }

    /// A worktree whose branch has a commit that is merged into main.
    private func mergedWorktree(_ branch: String) throws -> String {
        let wt = try addWorktree(branch)
        try write("feature.txt", "feature\n", in: wt)
        try git(in: wt, "add", "feature.txt")
        try git(in: wt, "commit", "-q", "-m", "feature")
        try git("merge", "-q", "--no-ff", "-m", "merge", branch)
        XCTAssertEqual(scanned(wt).mergeStatus, .merged)
        return wt
    }

    /// A worktree whose branch's changes are on main as one squash commit (the branch itself isn't merged).
    private func squashMergedWorktree(_ branch: String) throws -> String {
        let wt = try addWorktree(branch)
        try write("squash.txt", "one\n", in: wt)
        try git(in: wt, "add", "squash.txt")
        try git(in: wt, "commit", "-q", "-m", "one")
        try write("squash.txt", "one\ntwo\n", in: wt)
        try git(in: wt, "commit", "-q", "-am", "two")
        try git("merge", "-q", "--squash", branch)
        try git("commit", "-q", "-m", "squash")
        XCTAssertEqual(scanned(wt).mergeStatus, .squashMerged)
        return wt
    }

    private func branchExists(_ name: String) -> Bool {
        ShellRunner.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: repo).exitCode == 0
    }

    private func write(_ name: String, _ contents: String, in dir: String) throws {
        try contents.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func git(_ args: String...) throws { try git(in: repo, args) }
    private func git(in dir: String, _ args: String...) throws { try git(in: dir, args) }

    private func git(in dir: String, _ args: [String]) throws {
        let out = ShellRunner.run(ShellRunner.gitPath, arguments: args, workingDirectory: dir, timeout: 30)
        guard out.exitCode == 0 else {
            throw NSError(domain: "git", code: Int(out.exitCode), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
    }
}

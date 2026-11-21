import XCTest
@testable import Furl

/// WorktreesShortcuts board: merged worktrees start unticked, "safe" never means a worktree, and the
/// two new Shortcuts actions only touch what they promise.
final class WorktreesShortcutsTests: XCTestCase {

    private func worktree(_ id: String, status: WorktreeMergeStatus = .merged, dirty: Bool = false,
                          locked: Bool = false, bytes: Int64 = 1000) -> WorktreeItem {
        WorktreeItem(id: id, repoPath: "/r", repoName: "r", worktreePath: "/w/\(id)", branchName: id, baseBranch: "main",
                     commitHash: "abc", lastCommitDate: nil, mergeStatus: status, isDirty: dirty, isLocked: locked,
                     isPrunable: false, sizeBytes: bytes)
    }

    private func junk(_ id: String, _ path: String, risk: RiskLevel = .safe, bytes: Int64 = 100) -> JunkItem {
        JunkItem(id: id, name: id, path: path, category: .devArtifacts, risk: risk, sizeBytes: bytes,
                 modifiedDate: nil, reason: "")
    }

    // MARK: - Default selection

    func testSelectMergedTicksOnlyMergedCleanWorktrees() {
        let trees = [worktree("merged"), worktree("squash", status: .squashMerged), worktree("dirty", dirty: true),
                     worktree("locked", locked: true), worktree("active", status: .unmerged),
                     worktree("main", status: .main)]
        let picked = AppState.mergedWorktreeSelection(trees).map(\.id)
        XCTAssertEqual(Set(picked), ["merged", "squash"])
    }

    func testReviewItemsFirstListsMergedWorktreesUnticked() {
        let items = TrayItem.reclaimable(junk: [junk("cache", "/a/cache")], worktrees: [worktree("merged")],
                                         leftovers: [], duplicates: [])
        XCTAssertEqual(items.first { $0.key == "merged" }?.included, false)
        XCTAssertEqual(items.first { $0.key == "cache" }?.included, true)
    }

    func testToolbarAndBottomBarCopy() {
        XCTAssertEqual(WorktreesView.selectMergedTitle(count: 4), "Select merged (4)")
        XCTAssertEqual(WorktreesView.selectMergedTitle(count: 0), "Select merged")
        let four = WorktreesView.nothingTickedText(count: 4, bytes: 4_200_000_000)
        XCTAssertTrue(four.hasPrefix("ticks the 4 merged, clean worktrees ("), four)
        XCTAssertTrue(four.hasSuffix("). Removing them is permanent."), four)
        XCTAssertTrue(WorktreesView.nothingTickedText(count: 1, bytes: 1).contains("the 1 merged, clean worktree ("))
    }

    // MARK: - Safe set

    func testSafeSetNeverIncludesMergedWorktrees() {
        // A merged, clean worktree next to safe junk: the menu bar's "Clean safe items", Auto-Sweep's
        // safe clean and Shortcuts' "Move safe items to Trash" all move `safeCleanupPlan`, which only
        // takes junk. The worktree lands in the Overview's Quick look step instead.
        let items = [junk("cache", "/u/Library/Caches/app", bytes: 300)]
        let tree = worktree("merged", bytes: 5000)
        let plan = AppState.safeCleanupPlan(junk: items, ticked: Set(items.map(\.id)), isProtected: { _ in false })
        XCTAssertEqual(plan.paths, ["/u/Library/Caches/app"])
        XCTAssertFalse(plan.paths.contains(tree.worktreePath))
        XCTAssertFalse(ShortcutsBridge.safeNow(from: plan).items.contains { $0.path == tree.worktreePath })
        let steps = SpaceSteps.make(plan: plan, worktrees: [tree], duplicates: [], leftovers: [], largeFiles: [])
        XCTAssertEqual(steps.safeBytes, 300)
        XCTAssertEqual(steps.worktreeBytes, 5000)
    }

    // MARK: - Tidy project

    private func mkdir(_ dir: TempDir, _ name: String, file: String = "f", bytes: Int = 64) throws {
        let path = dir.file(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: (path as NSString).appendingPathComponent(file)))
    }

    func testTidyFindsRebuildableFoldersOnly() throws {
        let dir = try TempDir()
        try dir.write("package.json", "{}")
        try dir.write(".env", "SECRET=1")
        try mkdir(dir, "node_modules")
        try mkdir(dir, ".next")
        try mkdir(dir, "src")
        try mkdir(dir, "packages/ui/node_modules") // no package.json next to it
        let found = ProjectTidy.find(in: dir.path, isIgnored: { _ in nil }, isProtected: { _ in false })
        XCTAssertEqual(Set(found.map(\.name)), ["node_modules", ".next"])
        XCTAssertTrue(found.allSatisfy { $0.path.hasPrefix(dir.path + "/") })
    }

    func testTidyNeedsGitForGenericNamesAndSkipsTrackedFolders() throws {
        let dir = try TempDir()
        try dir.write("package.json", "{}")
        try mkdir(dir, "dist")
        try mkdir(dir, "build")
        try mkdir(dir, ".next")
        // Not in a repo: generic names are never offered.
        var found = ProjectTidy.find(in: dir.path, isIgnored: { _ in nil }, isProtected: { _ in false })
        XCTAssertEqual(found.map(\.name), [".next"])
        // In a repo: only what git ignores. `build` is tracked here, so it stays.
        found = ProjectTidy.find(in: dir.path, isIgnored: { !$0.hasSuffix("/build") }, isProtected: { _ in false })
        XCTAssertEqual(Set(found.map(\.name)), ["dist", ".next"])
        XCTAssertEqual(found.first { $0.name == "dist" }?.detail, "build output")
    }

    func testTidyNeverFollowsSymlinks() throws {
        let outside = try TempDir()
        try outside.write("package.json", "{}")
        try mkdir(outside, "node_modules")
        let dir = try TempDir()
        try dir.write("package.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: dir.file("linked"), withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: dir.file("node_modules"),
                                                   withDestinationPath: outside.file("node_modules"))
        let found = ProjectTidy.find(in: dir.path, isIgnored: { _ in nil }, isProtected: { _ in false })
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testTidyUsesGitIgnoreForReal() throws {
        let dir = try TempDir()
        guard ShellRunner.git(["init", "-q"], in: dir.path).exitCode == 0 else { throw XCTSkip("git unavailable") }
        try dir.write("package.json", "{}")
        try dir.write(".gitignore", "dist/\n")
        try mkdir(dir, "dist")
        try mkdir(dir, "build")
        XCTAssertEqual(ProjectTidy.gitIgnores(dir.file("dist")), true)
        XCTAssertEqual(ProjectTidy.gitIgnores(dir.file("build")), false)
        let found = ProjectTidy.find(in: dir.path, isProtected: { _ in false })
        XCTAssertEqual(found.map(\.name), ["dist"])
    }

    func testTidyRefusesBroadOrMissingRoots() throws {
        let dir = try TempDir()
        XCTAssertNil(ProjectTidy.check(root: dir.path, home: "/Users/nobody", isProtected: { _ in false }))
        XCTAssertEqual(ProjectTidy.check(root: dir.path, home: dir.path, isProtected: { _ in false }), .tooBroad)
        XCTAssertEqual(ProjectTidy.check(root: "/", home: "/Users/nobody", isProtected: { _ in false }), .tooBroad)
        XCTAssertEqual(ProjectTidy.check(root: dir.file("missing"), isProtected: { _ in false }), .notAFolder)
        XCTAssertEqual(ProjectTidy.check(root: dir.path, home: "/Users/nobody", isProtected: { _ in true }), .protected)
    }

    // MARK: - Stop leftover servers

    private func leftover(_ pid: Int32, category: LeftoverCategory = .devServer,
                          exemption: AutoStopExemption? = nil, ports: [Int] = [5173]) -> LeftoverProcess {
        let ref = ProcessRef(pid: pid, startMicros: 1)
        var item = LeftoverProcess(ref: ref, members: [ref, ProcessRef(pid: pid + 1000, startMicros: 1)],
                                   memberMemory: [410_000_000, 0], displayName: "vite", executableName: "node",
                                   category: category, agent: .claudeCode, agentName: "Claude Code",
                                   cwd: "/Users/x/code/web-app", ports: ports, memoryBytes: 410_000_000, workerCount: 0,
                                   startedAt: Date(timeIntervalSinceNow: -2 * 86_400), agentExitedAt: nil,
                                   summary: "", evidence: [])
        item.autoStopExemption = exemption
        return item
    }

    func testStopOnlyDetachedNonExemptServers() {
        let items = [leftover(10), leftover(20, category: .database, exemption: .database),
                     leftover(30, category: .tunnel, exemption: .tunnel), leftover(40, category: .container),
                     leftover(50), leftover(60, category: .watcher)]
        // pid 1050 (a child of 50) is still in a terminal tab.
        let eligible = LeftoverServers.eligible(items, isAttachedToTerminal: { $0 == 1050 })
        XCTAssertEqual(eligible.map(\.ref.pid), [10, 60])
    }

    func testStopCopy() {
        let line = LeftoverServers.confirmLine(leftover(10))
        XCTAssertTrue(line.hasPrefix("vite · web-app · port 5173 · started "), line)
        XCTAssertTrue(line.contains("· no terminal · "), line)
        XCTAssertEqual(LeftoverServers.confirmTitle(count: 3), "Stop 3 leftover servers?")
        XCTAssertEqual(LeftoverServers.acceptLabel(count: 3), "Stop 3 Servers")
        XCTAssertTrue(LeftoverServers.resultText(count: 3, bytes: 1_100_000_000, stuck: 0)
            .hasPrefix("Stopped 3 leftover servers. Freed "))
    }
}

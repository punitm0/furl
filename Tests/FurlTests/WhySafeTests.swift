import XCTest
@testable import Furl

final class WhySafeTests: XCTestCase {
    private func junk(_ category: JunkCategory, name: String = "Thing", path: String = "/tmp/x/thing",
                      risk: RiskLevel = .safe, id: String? = nil, command: JunkCommand? = nil) -> JunkItem {
        JunkItem(id: id ?? path, name: name, path: path, category: category, risk: risk,
                 sizeBytes: 1_000, modifiedDate: Date(), reason: "", command: command)
    }

    private func worktree(_ status: WorktreeMergeStatus, dirty: Bool = false, locked: Bool = false,
                          baseTip: Bool = false, prunable: Bool = false) -> WorktreeItem {
        WorktreeItem(id: "wt", repoPath: "/r/api", repoName: "api", worktreePath: "/r/api-wt/x",
                     branchName: "fix/x", baseBranch: "main", commitHash: "abc1234", lastCommitDate: Date(),
                     mergeStatus: status, isDirty: dirty, isLocked: locked, isPrunable: prunable, sizeBytes: 1,
                     pointsAtBaseTip: baseTip)
    }

    private func goesTo(_ e: WhyExplanation) -> String? {
        e.lines.first { $0.label == "Goes to:" }?.text
    }

    func testRiskLevelsCollapseToThreeWords() {
        XCTAssertEqual(RiskLevel.safe.tier.label, "Safe")
        XCTAssertEqual(RiskLevel.moderate.tier.label, "Check first")
        XCTAssertEqual(RiskLevel.review.tier.label, "Check first")
        XCTAssertEqual(RiskTier.permanent.label, "Permanent")
        XCTAssertEqual(InspectorSafety.caution.tier, .checkFirst)
        // Stored raw values stay as they were.
        XCTAssertEqual(RiskLevel.moderate.rawValue, "Moderate")
        XCTAssertEqual(RiskLevel.review.rawValue, "Review")
    }

    func testEveryJunkCategoryHasCopy() {
        for category in JunkCategory.allCases {
            let e = WhySafe.junk(junk(category), deletionMode: .moveToTrash)
            XCTAssertFalse(e.title.isEmpty)
            let what = e.lines.first { $0.label == "What it is:" }?.text ?? ""
            let back = e.lines.first { $0.label == "How it comes back:" }?.text ?? ""
            XCTAssertFalse(what.isEmpty, "\(category)")
            XCTAssertFalse(back.isEmpty, "\(category)")
            XCTAssertEqual(goesTo(e), "the Trash. You can undo from History.")
        }
    }

    func testTitlesFollowTheBoard() {
        XCTAssertEqual(WhySafe.junk(junk(.packageCaches, name: "npm cache"), deletionMode: .moveToTrash).title,
                       "Why npm cache is safe")
        XCTAssertEqual(WhySafe.junk(junk(.mailAttachments, name: "Mail Downloads", risk: .review), deletionMode: .moveToTrash).title,
                       "Why check Mail Downloads first")
    }

    func testPermanentItemsNeverClaimTheTrash() {
        let docker = junk(.docker, name: "Docker · build cache", path: "docker://build-cache", risk: .review,
                          id: "docker://build-cache",
                          command: JunkCommand(executable: "/usr/local/bin/docker", arguments: ["builder", "prune", "-f"]))
        let e = WhySafe.junk(docker, deletionMode: .moveToTrash)
        XCTAssertFalse(goesTo(e)!.contains("Trash"))
        XCTAssertTrue(goesTo(e)!.contains("Docker"))

        let deleteMode = WhySafe.junk(junk(.logsAndCrash), deletionMode: .permanent)
        XCTAssertFalse(goesTo(deleteMode)!.contains("the Trash"))

        let wt = WhySafe.worktree(worktree(.merged))
        XCTAssertTrue(wt.lines.first { $0.label == "Doesn't go to the Trash:" }!.text.hasPrefix("git deletes the folder for good"))
        XCTAssertEqual(wt.tier, .permanent)
        XCTAssertEqual(wt.title, "Why api · fix/x is OK to remove")
        XCTAssertFalse(wt.title.contains("safe"))
    }

    func testNoComesBackStoryIsMarkedHonestly() {
        let archives = junk(.devArtifacts, name: "Xcode Archives", risk: .review)
        let line = WhySafe.junk(archives, deletionMode: .moveToTrash).lines.first { $0.label == "How it comes back:" }!
        XCTAssertEqual(line.mark, .bad)
        XCTAssertTrue(line.text.hasPrefix("It doesn't"))

        let npm = junk(.packageCaches, name: "npm Cache")
        let npmLine = WhySafe.junk(npm, deletionMode: .moveToTrash).lines.first { $0.label == "How it comes back:" }!
        XCTAssertEqual(npmLine.mark, .good)
        XCTAssertTrue(npmLine.text.contains("npm downloads"))
    }

    func testDevFoldersNameTheirTool() {
        let nm = junk(.devArtifacts, name: "web/node_modules", path: "/code/web/node_modules", risk: .moderate)
        let back = WhySafe.junkStory(nm).back
        XCTAssertTrue(back.contains("npm install"))
        XCTAssertTrue(back.contains("web"))
    }

    func testWorktreeTiers() {
        // Canvas v89: merged rows are Permanent only, never Safe.
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.merged)), [.permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.squashMerged)), [.permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.merged, dirty: true)), [.checkFirst, .permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.merged, locked: true)), [.checkFirst, .permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.merged, baseTip: true)), [.checkFirst, .permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.unmerged)), [.checkFirst, .permanent])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.main)), [])
        // A missing folder deletes nothing on disk, so no Permanent.
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.merged, prunable: true)), [])
        XCTAssertEqual(WhySafe.worktreeChips(worktree(.unmerged, prunable: true)), [.checkFirst])
        XCTAssertEqual(WhySafe.worktree(worktree(.merged)).lines.map(\.label),
                       ["What it is:", "Merged:", "Clean:", "Doesn't go to the Trash:"])

        let dirty = WhySafe.worktree(worktree(.unmerged, dirty: true))
        XCTAssertEqual(dirty.title, "Why check api · fix/x first")
        XCTAssertTrue(dirty.lines.contains { $0.label == "Uncommitted changes:" })

        let main = WhySafe.worktree(worktree(.main))
        XCTAssertNil(main.tier)
        XCTAssertNil(goesTo(main))
    }

    func testDuplicatesKeepTheOldestAndCheckTheRest() {
        let old = DuplicateFile(id: "a", path: "/u/Desktop/a.heic", name: "a.heic",
                                modifiedDate: Date(timeIntervalSince1970: 0), privateBytes: 10)
        let new = DuplicateFile(id: "b", path: "/u/Downloads/a.heic", name: "a.heic",
                                modifiedDate: Date(), privateBytes: 10)
        let group = DuplicateGroup(id: "g", sizeBytes: 10, files: [new, old])
        XCTAssertNil(WhySafe.duplicateTier(old, in: group))
        XCTAssertEqual(WhySafe.duplicateTier(new, in: group), .checkFirst)
        let e = WhySafe.duplicate(new, in: group, deletionMode: .moveToTrash)
        let keep = e.lines.first { $0.label == "You keep one:" }?.text ?? ""
        XCTAssertTrue(keep.contains("never removes the last copy"))
        // Auto-Select can keep a different copy, so no path is promised.
        XCTAssertFalse(keep.contains("/u/Desktop/a.heic"))
        XCTAssertEqual(WhySafe.duplicate(old, in: group, deletionMode: .moveToTrash).title, "About the oldest copy")
    }

    func testLeftoverTiersStayCautious() {
        func item(_ location: AppDataLocation, strong: Bool = true) -> AppDataItem {
            AppDataItem(id: "\(location)", path: "/x", name: "com.app", location: location, sizeBytes: 1,
                        modifiedDate: nil, isStrongMatch: strong)
        }
        XCTAssertEqual(WhySafe.leftoverTier(item(.caches)), .safe)
        XCTAssertEqual(WhySafe.leftoverTier(item(.caches, strong: false)), .checkFirst)
        XCTAssertEqual(WhySafe.leftoverTier(item(.preferences)), .checkFirst)
        XCTAssertEqual(WhySafe.leftoverTier(item(.applicationSupport)), .checkFirst)
        XCTAssertEqual(WhySafe.leftoverSubtitle(item(.preferences)), "Settings · keep if you may reinstall")

        let group = OrphanedAppDataGroup(id: "g", appIdentifier: "com.app", displayName: "App", items: [])
        // A loosely matched cache still rebuilds itself.
        let looseCache = WhySafe.leftover(item(.caches, strong: false), group: group, deletionMode: .moveToTrash)
        XCTAssertEqual(looseCache.lines.first { $0.label == "How it comes back:" }?.mark, .good)
        // The Inspector agrees with the list.
        XCTAssertEqual(InspectorItem(leftover: item(.applicationSupport), group: group).safety, .review)
        XCTAssertEqual(InspectorItem(leftover: item(.caches), group: group).safety, .safe)
    }

    func testOldTraysStillLoadWithoutTheNewField() throws {
        let item = TrayItem(source: .junk, key: "k", path: "/x", title: "t", subtitle: "s", bytes: 1, isPermanent: false)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json.removeValue(forKey: "checkFirst")
        let decoded = try JSONDecoder().decode(TrayItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.checkFirst)
    }
}

extension WhySafeTests {
    func testModelsOnlyComeBackWhenTheyCameFromARegistry() {
        for name in ["Ollama · llama3:8b", "LM Studio · pub/model", "Hugging Face · org/repo"] {
            let item = JunkItem(id: name, name: name, path: "/m/" + name, category: .aiModels, risk: .review,
                                sizeBytes: 1, modifiedDate: nil, reason: "")
            let back = WhySafe.junk(item, deletionMode: .moveToTrash).lines.first { $0.label == "How it comes back:" }!
            XCTAssertEqual(back.mark, .bad, name)
            XCTAssertTrue(back.text.hasPrefix("Only if"), name)
        }
    }
}

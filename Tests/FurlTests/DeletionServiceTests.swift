import XCTest
@testable import Furl

final class DeletionServiceTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testSystemAndHomeRootsAreProtected() {
        for path in ["/", "/Users", "/System", "/Applications", home, "\(home)/", "\(home)/Library",
                     "\(home)/Documents", "\(home)/Library/Caches"] {
            XCTAssertTrue(DeletionService.isProtected(path), path)
        }
    }

    func testProtectedSubtreesCoverTheirContents() {
        XCTAssertTrue(DeletionService.isProtected("\(home)/.ssh"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/.ssh/id_ed25519"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/.config/gh/hosts.yml"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/Library/Keychains/login.keychain-db"))
    }

    func testComparisonIgnoresCase() {
        XCTAssertTrue(DeletionService.isProtected("\(home)/.SSH"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/.Ssh/config"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/library/caches"))
        XCTAssertTrue(DeletionService.isProtected("/SYSTEM/Library"))
    }

    func testParentsOfProtectedFoldersAreProtected() {
        // Trashing ~/.config would take ~/.config/gh with it.
        XCTAssertTrue(DeletionService.isProtected("\(home)/.config"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/.CONFIG/"))
        XCTAssertTrue(DeletionService.isProtected("\(home)/Library/Group Containers"))
    }

    func testDotDotIsResolvedBeforeChecking() {
        XCTAssertTrue(DeletionService.isProtected("\(home)/Library/Caches/../../.ssh"))
    }

    func testOrdinaryItemsAreNotProtected() {
        for path in ["\(home)/Library/Caches/com.example.app", "\(home)/.config/nvim",
                     "\(home)/Projects/app/node_modules", "\(home)/Downloads/installer.dmg",
                     "\(home)/.sshkeys-backup", "\(home)/Library/Group Containers/group.com.example"] {
            XCTAssertFalse(DeletionService.isProtected(path), path)
        }
    }

    func testDeletePathsRefusesProtectedPaths() {
        // These tests call the real delete paths on the real home folder: never reach them if the guard is broken.
        guard DeletionService.isProtected("\(home)/.config") else {
            return XCTFail("~/.config must be protected; not calling deletePaths on it")
        }
        let result = DeletionService.deletePaths(["\(home)/.config"], mode: .moveToTrash)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testWorktreeRemovalRefusesProtectedPath() throws {
        guard DeletionService.isProtected(home) else {
            return XCTFail("the home folder must be protected; not calling removeWorktree on it")
        }
        let repo = try TempDir()
        let item = WorktreeItem(id: "x", repoPath: repo.path, repoName: "r", worktreePath: home, branchName: "b",
                                baseBranch: "main", commitHash: "", lastCommitDate: nil, mergeStatus: .merged,
                                isDirty: false, isLocked: false, isPrunable: false, sizeBytes: 0)
        guard case .failure = WorktreeScanner.removeWorktree(item: item, force: true, deleteLocalBranch: false) else {
            return XCTFail("removing the home folder as a worktree must be refused")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home))
    }
}

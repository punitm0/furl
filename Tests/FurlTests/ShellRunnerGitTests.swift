import XCTest
@testable import Furl

/// Repos Furl finds may be crafted. Neither a repo's fsmonitor hook nor its filter drivers may run.
final class ShellRunnerGitTests: XCTestCase {
    private var repo: TempDir!
    private var marker: String { repo.file("ran-a-program") }

    override func setUpWithError() throws {
        repo = try TempDir()
        try git("init", "-q")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try repo.write("tracked.txt", "hello\n")
        try git("add", "tracked.txt")
        try git("commit", "-q", "-m", "init")
        // A program that leaves a marker file if anything runs it.
        try repo.write("evil.sh", "#!/bin/sh\ntouch '\(marker)'\ncat\n", executable: true)
    }

    override func tearDown() { repo = nil }

    func testCleanRepoReportsStatus() {
        XCTAssertTrue(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
        let status = ShellRunner.gitStatusPorcelain(in: repo.path)
        XCTAssertEqual(status?.contains("evil.sh"), true)
    }

    func testFsmonitorHookNeverRuns() throws {
        try git("config", "core.fsmonitor", repo.file("evil.sh"))
        XCTAssertNotNil(ShellRunner.gitStatusPorcelain(in: repo.path))
        _ = ShellRunner.git(["diff", "--stat"], in: repo.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testFilterDriverMakesRepoUnsafeAndNeverRuns() throws {
        try git("config", "filter.evil.clean", repo.file("evil.sh"))
        try repo.write(".gitattributes", "* filter=evil\n")
        try repo.write("tracked.txt", "changed\n")
        XCTAssertFalse(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testFilterInIncludedConfigIsCaught() throws {
        try repo.write("extra.config", "[filter \"evil\"]\n\tclean = \(repo.file("evil.sh"))\n")
        try git("config", "include.path", repo.file("extra.config"))
        XCTAssertFalse(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
    }

    func testTextconvMakesRepoUnsafe() throws {
        try git("config", "diff.evil.textconv", repo.file("evil.sh"))
        XCTAssertFalse(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
    }

    func testFilterInWorktreeConfigIsCaught() throws {
        try git("config", "extensions.worktreeConfig", "true")
        try git("config", "--worktree", "filter.evil.clean", repo.file("evil.sh"))
        try repo.write(".gitattributes", "* filter=evil\n")
        try repo.write("tracked.txt", "changed\n")
        XCTAssertFalse(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testSubmoduleFilterNeverRunsAndRepoCountsAsDirty() throws {
        let sub = try TempDir()
        try git(in: sub.path, "init", "-q")
        try git(in: sub.path, "config", "user.email", "test@example.com")
        try git(in: sub.path, "config", "user.name", "Test")
        try sub.write("inner.txt", "inner\n")
        try git(in: sub.path, "add", "inner.txt")
        try git(in: sub.path, "commit", "-q", "-m", "inner")
        try git("-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "sub")
        try git("commit", "-q", "-m", "add sub")
        let inside = repo.file("sub")
        try git(in: inside, "config", "filter.evil.clean", repo.file("evil.sh"))
        try repo.write("sub/.gitattributes", "* filter=evil\n")
        try repo.write("sub/inner.txt", "changed\n")
        XCTAssertTrue(ShellRunner.repoConfigRunsNoPrograms(in: repo.path))
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testSignatureProgramNeverRuns() throws {
        try git("config", "log.showSignature", "true")
        try git("config", "gpg.program", repo.file("evil.sh"))
        // A signed-looking commit makes git reach for gpg.program when showing it.
        let tree = ShellRunner.run(ShellRunner.gitPath, arguments: ["rev-parse", "HEAD^{tree}"],
                                   workingDirectory: repo.path, timeout: 30).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = """
        tree \(tree)
        author T <t@example.com> 1700000000 +0000
        committer T <t@example.com> 1700000000 +0000
        gpgsig -----BEGIN PGP SIGNATURE-----
         abc
         -----END PGP SIGNATURE-----

        signed

        """
        try repo.write("commit.txt", object)
        let hash = ShellRunner.run(ShellRunner.gitPath,
                                   arguments: ["hash-object", "-t", "commit", "-w", repo.file("commit.txt")],
                                   workingDirectory: repo.path, timeout: 30).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(hash.isEmpty)
        let out = ShellRunner.git(["show", "-s", "--no-show-signature", "--format=%ct", hash], in: repo.path)
        XCTAssertEqual(out.exitCode, 0)
        _ = ShellRunner.git(["log", "-1", hash], in: repo.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testUntrackedFilesShowEvenWhenConfigHidesThem() throws {
        try git("config", "status.showUntrackedFiles", "no")
        try repo.write("new.txt", "new\n")
        XCTAssertEqual(ShellRunner.gitStatusPorcelain(in: repo.path)?.contains("new.txt"), true)
    }

    func testAssumeUnchangedAndSkipWorktreeCountAsDirty() throws {
        try git("update-index", "--assume-unchanged", "tracked.txt")
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
        try git("update-index", "--no-assume-unchanged", "tracked.txt")
        try git("update-index", "--skip-worktree", "tracked.txt")
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: repo.path))
    }

    func testNotARepoIsUnsafe() throws {
        let plain = try TempDir()
        XCTAssertNil(ShellRunner.gitStatusPorcelain(in: plain.path))
    }

    private func git(_ args: String...) throws {
        try git(in: repo.path, args)
    }

    private func git(in directory: String, _ args: String...) throws {
        try git(in: directory, args)
    }

    private func git(in directory: String, _ args: [String]) throws {
        // Plain git for setup, outside the code under test.
        let out = ShellRunner.run(ShellRunner.gitPath, arguments: args, workingDirectory: directory, timeout: 30)
        guard out.exitCode == 0 else {
            throw NSError(domain: "git", code: Int(out.exitCode), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
    }
}

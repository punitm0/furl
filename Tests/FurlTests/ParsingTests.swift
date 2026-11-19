import XCTest
@testable import Furl

final class UpdateCheckerTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.0", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2", than: "1.10"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("3-beta", than: "2.9"))
    }

    func testStrippedTag() {
        XCTAssertEqual(UpdateChecker.strippedTag("v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.strippedTag(" V2.0 "), "2.0")
        XCTAssertEqual(UpdateChecker.strippedTag("1.0"), "1.0")
    }
}

final class OllamaDigestTests: XCTestCase {
    private let hex = String(repeating: "ab12", count: 16)

    func testAcceptsWellFormedDigest() {
        XCTAssertTrue(JunkScanner.isValidOllamaDigest("sha256:\(hex)"))
    }

    func testRejectsTraversalAndMalformedDigests() {
        for digest in ["sha256:../../Documents", "sha256:\(hex)/../../x", "../sha256:\(hex)",
                       "sha256:\(hex.uppercased())", "sha256:\(hex)0", "sha256:\(hex.dropLast())",
                       "sha512:\(hex)", "sha256:\(hex)\n", "", "sha256:"] {
            XCTAssertFalse(JunkScanner.isValidOllamaDigest(digest), digest)
        }
    }
}

final class UninstallerMatchTests: XCTestCase {
    func testSpecificBundleIDs() {
        XCTAssertTrue(AppUninstallerService.isSpecificBundleID("com.vendor.app"))
        XCTAssertTrue(AppUninstallerService.isSpecificBundleID("org.mozilla.firefox"))
        XCTAssertFalse(AppUninstallerService.isSpecificBundleID("com.app"))
        XCTAssertFalse(AppUninstallerService.isSpecificBundleID("com.a.b"))
        XCTAssertFalse(AppUninstallerService.isSpecificBundleID("com..vendorapp"))
        XCTAssertFalse(AppUninstallerService.isSpecificBundleID(""))
    }
}

final class ErrorScrubberTests: XCTestCase {
    func testPathWithSpacesIsFullyRemoved() {
        let out = ErrorScrubber.scrub("Couldn't read /Users/x/My Projects/secret file.txt", area: "Find")
        XCTAssertFalse(out.contains("Projects"), out)
        XCTAssertFalse(out.contains("secret"), out)
        XCTAssertTrue(out.contains("Find"), out)
    }

    func testPathStopsAtPunctuation() {
        let out = ErrorScrubber.scrub("Failed on ~/Secret Stuff/a.txt, try again", area: "Junk")
        XCTAssertEqual(out, "Failed on Junk, try again")
    }

    func testItemPrefixIsDropped() {
        XCTAssertEqual(ErrorScrubber.scrub("report.pdf: Permission denied", area: "Junk"), "Permission denied")
    }

    func testQuotedNamesAreRemoved() {
        let out = ErrorScrubber.scrub("“Tax Return 2025.pdf” couldn’t be moved to the Trash.", area: "Find")
        XCTAssertFalse(out.contains("Tax"), out)
    }

    func testGitSingleQuotedNamesAreRemoved() {
        let out = ErrorScrubber.scrub("error: the branch 'client-x' is not fully merged. It's fine.", area: "Worktrees")
        XCTAssertFalse(out.contains("client-x"), out)
        XCTAssertTrue(out.contains("It's fine"), out)
    }

    func testRedactedNamesAreRemoved() {
        let out = ErrorScrubber.scrub("Secret Tool Pro didn't quit (it may have unsaved changes).", area: "Apps",
                                      redacting: ["Secret Tool", "Secret Tool Pro"])
        XCTAssertFalse(out.contains("Secret"), out)
        XCTAssertFalse(out.contains("Pro "), out)
        XCTAssertTrue(out.hasPrefix("An app didn't quit"), out)
    }

    func testOrdinaryTextIsKept() {
        XCTAssertEqual(ErrorScrubber.scrub("and/or 1/2 done", area: "X"), "and/or 1/2 done")
    }
}

final class CompressionStampTests: XCTestCase {
    func testUnchangedNoticesSubSecondEdits() throws {
        let dir = try TempDir()
        try dir.write("a.txt", "one")
        let path = dir.file("a.txt")
        let before = try XCTUnwrap(CompressionFS.lstatInfo(path))
        XCTAssertTrue(CompressionFS.unchanged(path, since: before))

        // Same second, same size, different nanoseconds.
        var later = before.st_mtimespec
        later.tv_nsec = (later.tv_nsec + 1) % 1_000_000_000
        var times = [before.st_atimespec, later]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
        XCTAssertFalse(CompressionFS.unchanged(path, since: before))
    }

    func testUnchangedNoticesReplacementAndRemoval() throws {
        let dir = try TempDir()
        try dir.write("a.txt", "one")
        let path = dir.file("a.txt")
        let before = try XCTUnwrap(CompressionFS.lstatInfo(path))
        try FileManager.default.removeItem(atPath: path)
        XCTAssertFalse(CompressionFS.unchanged(path, since: before))
        try dir.write("other.txt", "one")
        var times = [before.st_atimespec, before.st_mtimespec]
        utimensat(AT_FDCWD, dir.file("other.txt"), &times, 0)
        try FileManager.default.moveItem(atPath: dir.file("other.txt"), toPath: path)
        XCTAssertFalse(CompressionFS.unchanged(path, since: before))
    }
}

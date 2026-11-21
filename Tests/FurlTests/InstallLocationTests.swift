import XCTest
@testable import Furl

final class InstallLocationTests: XCTestCase {
    private let home = "/Users/sam"

    private func place(_ path: String, original: String? = nil,
                       volume: InstallLocation.VolumeFacts? = nil) -> InstallLocation.Place {
        InstallLocation.classify(bundlePath: path, originalPath: original, homeDirectory: home) { _ in
            volume ?? InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/"), isReadOnly: false, isEjectable: false, isDiskImage: false)
        }
    }

    private let dmg = InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/Volumes/Furl"), isReadOnly: true, isEjectable: true, isDiskImage: true)

    func testApplicationsFoldersNeverOffer() {
        XCTAssertEqual(place("/Applications/Furl.app"), .applications)
        XCTAssertEqual(place("/Applications/Utilities/Furl.app"), .applications)
        XCTAssertEqual(place("/Users/sam/Applications/Furl.app"), .applications)
        XCTAssertEqual(place("/Applications/../Applications/Furl.app"), .applications)
        XCTAssertFalse(place("/Applications/Furl.app").offersMove)
    }

    func testLookalikeFoldersAreNotApplications() {
        XCTAssertEqual(place("/ApplicationsOld/Furl.app"), .otherFolder(URL(fileURLWithPath: "/ApplicationsOld")))
        XCTAssertEqual(place("/Users/other/Applications/Furl.app"),
                       .otherFolder(URL(fileURLWithPath: "/Users/other/Applications")))
        XCTAssertEqual(place("/Users/sam/Downloads/Applications.app/Furl.app"),
                       .otherFolder(URL(fileURLWithPath: "/Users/sam/Downloads/Applications.app")))
    }

    func testDiskImageIsReadOnlyAndEjectable() {
        XCTAssertEqual(place("/Volumes/Furl/Furl.app", volume: dmg), .diskImage(volume: URL(fileURLWithPath: "/Volumes/Furl")))
        // Read-only but not ejectable (a sealed system volume, say): just another folder.
        let sealed = InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/Volumes/X"), isReadOnly: true, isEjectable: false, isDiskImage: true)
        XCTAssertEqual(place("/Volumes/X/Furl.app", volume: sealed), .otherFolder(URL(fileURLWithPath: "/Volumes/X")))
        // A writable USB stick: a folder, not a disk image.
        let stick = InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/Volumes/USB"), isReadOnly: false, isEjectable: true, isDiskImage: false)
        XCTAssertEqual(place("/Volumes/USB/Furl.app", volume: stick), .otherFolder(URL(fileURLWithPath: "/Volumes/USB")))
        // The boot volume is never ejected, whatever it reports.
        let root = InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/"), isReadOnly: true, isEjectable: true, isDiskImage: false)
        XCTAssertEqual(place("/Users/sam/Desktop/Furl.app", volume: root), .otherFolder(URL(fileURLWithPath: "/Users/sam/Desktop")))
        // A write-protected SD card or a read-only share: read-only and ejectable, but not a disk image.
        let card = InstallLocation.VolumeFacts(mountPoint: URL(fileURLWithPath: "/Volumes/CARD"), isReadOnly: true, isEjectable: true, isDiskImage: false)
        XCTAssertEqual(place("/Volumes/CARD/Furl.app", volume: card), .otherFolder(URL(fileURLWithPath: "/Volumes/CARD")))
    }

    func testOtherFoldersOffer() {
        let result = place("/Users/sam/Downloads/Furl.app")
        XCTAssertEqual(result, .otherFolder(URL(fileURLWithPath: "/Users/sam/Downloads")))
        XCTAssertTrue(result.offersMove)
    }

    func testTranslocatedJudgedByOriginal() {
        let translocated = "/private/var/folders/ab/cd/T/AppTranslocation/1234-5678/d/Furl.app"
        XCTAssertTrue(InstallLocation.isTranslocatedPath(translocated))
        XCTAssertEqual(place(translocated, original: "/Users/sam/Downloads/Furl.app"),
                       .translocated(original: URL(fileURLWithPath: "/Users/sam/Downloads/Furl.app")))
        // Unknown original, but this is the copy Furl just opened: done, no second offer.
        XCTAssertEqual(InstallLocation.classify(bundlePath: translocated, originalPath: nil, homeDirectory: home,
                                                cameFromHandoff: true) { _ in nil }, .applications)
        // Unknown original: still offer.
        XCTAssertEqual(place(translocated), .translocated(original: nil))
        XCTAssertTrue(place(translocated).offersMove)
        // A copy in Applications that macOS translocated anyway: done, never offer again (no loop).
        XCTAssertEqual(place(translocated, original: "/Applications/Furl.app"), .applications)
        // Translocated out of a disk image: the disk image wins, so it gets ejected.
        XCTAssertEqual(place(translocated, original: "/Volumes/Furl/Furl.app", volume: dmg),
                       .diskImage(volume: URL(fileURLWithPath: "/Volumes/Furl")))
    }

    func testUnbundledRunIsNotAnApp() {
        XCTAssertEqual(place("/Users/sam/furl/.build/debug"), .notAnApp)
        XCTAssertFalse(place("/Users/sam/furl/.build/debug").offersMove)
    }

    func testCompareExisting() {
        let id = "app.getfurl.furl"
        XCTAssertEqual(InstallLocation.compareExisting(identifier: id, version: "1.3.0", isDirectory: true, ourIdentifier: id, ourVersion: "1.4.0"),
                       .older(version: "1.3.0"))
        XCTAssertEqual(InstallLocation.compareExisting(identifier: id, version: "1.4.0", isDirectory: true, ourIdentifier: id, ourVersion: "1.4.0"),
                       .sameOrNewer(version: "1.4.0"))
        XCTAssertEqual(InstallLocation.compareExisting(identifier: id, version: "1.10.0", isDirectory: true, ourIdentifier: id, ourVersion: "1.9.0"),
                       .sameOrNewer(version: "1.10.0"))
        XCTAssertEqual(InstallLocation.compareExisting(identifier: "com.other", version: "1.0", isDirectory: true, ourIdentifier: id, ourVersion: "1.4.0"),
                       .notFurl)
        XCTAssertEqual(InstallLocation.compareExisting(identifier: id, version: nil, isDirectory: true, ourIdentifier: id, ourVersion: "1.4.0"),
                       .notFurl)
        XCTAssertEqual(InstallLocation.compareExisting(identifier: nil, version: nil, isDirectory: false, ourIdentifier: id, ourVersion: "1.4.0"),
                       .notFurl)
    }

    func testDestinations() {
        XCTAssertEqual(InstallLocation.destinations(homeDirectory: home).map(\.path),
                       ["/Applications/Furl.app", "/Users/sam/Applications/Furl.app"])
    }

    func testLaunchArgumentParsing() {
        let args = ["/Applications/Furl.app/Contents/MacOS/Furl", "-FurlMovedParentPID", "42", "-FurlMovedFrom", "diskImage"]
        XCTAssertEqual(InstallHandoff.value(after: "-FurlMovedFrom", in: args), "diskImage")
        XCTAssertEqual(InstallHandoff.value(after: "-FurlMovedParentPID", in: args), "42")
        XCTAssertNil(InstallHandoff.value(after: "-FurlMovedEjectVolume", in: args))
        XCTAssertNil(InstallHandoff.value(after: "-FurlMovedFrom", in: ["x", "-FurlMovedFrom"]))
    }

    func testEjectOnlyFurlDiskImages() {
        // The boot volume, a path outside /Volumes, and nested paths are all refused.
        XCTAssertNil(InstallHandoff.ejectableFurlVolume("/", identifier: "app.getfurl.furl"))
        XCTAssertNil(InstallHandoff.ejectableFurlVolume("/Users", identifier: "app.getfurl.furl"))
        XCTAssertNil(InstallHandoff.ejectableFurlVolume("/Volumes/Furl/inner", identifier: "app.getfurl.furl"))
        XCTAssertNil(InstallHandoff.ejectableFurlVolume("/Volumes/../Users", identifier: "app.getfurl.furl"))
    }

    func testRealBundleIsNotAnAppUnderTests() {
        // The test runner isn't Furl.app, and it must never ask to move.
        XCTAssertNotEqual(InstallLocation.current(bundleURL: URL(fileURLWithPath: "/tmp/xctest")), .applications)
        XCTAssertEqual(InstallLocation.current(bundleURL: URL(fileURLWithPath: "/tmp/xctest")), .notAnApp)
    }
}

final class AppMoverTests: XCTestCase {
    private let identifier = "app.getfurl.movertest"

    /// A tiny ad-hoc signed app bundle, like the real one.
    private func makeBundle(in dir: TempDir, name: String = "Source.app", version: String = "1.4.0") throws -> URL {
        let app = URL(fileURLWithPath: dir.file(name), isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Furl", "CFBundlePackageType": "APPL"]
        plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Furl").path)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 200_000).write(to: resources.appendingPathComponent("payload"))
        let sign = ShellRunner.run("/usr/bin/codesign", arguments: ["-f", "-s", "-", "--identifier", identifier, app.path])
        XCTAssertEqual(sign.exitCode, 0, sign.stderr)
        return app
    }

    func testCopiesIntactBundleAndKeepsSignature() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Apps"), withIntermediateDirectories: false)
        // An extended attribute must survive the copy (the quarantine flags ride along the same way).
        XCTAssertEqual(setxattr(source.path, "com.getfurl.test", "kept", 4, 0, 0), 0)
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        nonisolated(unsafe) var lastProgress = 0.0
        try AppMover.copy(source, to: destination, replacing: .none, ourIdentifier: identifier, ourVersion: "1.4.0") {
            lastProgress = $0
        }
        XCTAssertEqual(lastProgress, 1)
        XCTAssertTrue(AppMover.signatureIsValid(destination, identifier: identifier))
        XCTAssertEqual(InstallLocation.bundleFacts(at: destination).version, "1.4.0")
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(getxattr(destination.path, "com.getfurl.test", &buffer, buffer.count, 0, 0), 4)
        // The original is left where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testNeverOverwritesSomethingUnexpected() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Apps/Furl.app"), withIntermediateDirectories: true)
        try dir.write("Apps/Furl.app/keep.txt", "mine")
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        // Told nothing was there, but something is: stop, change nothing.
        XCTAssertThrowsError(try AppMover.copy(source, to: destination, replacing: .none, ourIdentifier: identifier,
                                               ourVersion: "1.4.0") { _ in })
        XCTAssertEqual(try String(contentsOfFile: dir.file("Apps/Furl.app/keep.txt"), encoding: .utf8), "mine")
    }

    func testOlderCopyThatChangedIsNotReplaced() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Apps"), withIntermediateDirectories: false)
        _ = try makeBundle(in: dir, name: "Apps/Furl.app", version: "1.3.5")
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        // The user was told about 1.3.0; it's now 1.3.5, so nothing is trashed.
        XCTAssertThrowsError(try AppMover.copy(source, to: destination, replacing: .older(version: "1.3.0"),
                                               ourIdentifier: identifier, ourVersion: "1.4.0") { _ in })
        XCTAssertEqual(InstallLocation.bundleFacts(at: destination).version, "1.3.5")
    }

    func testReplacesOlderCopyAtomically() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Apps"), withIntermediateDirectories: false)
        _ = try makeBundle(in: dir, name: "Apps/Furl.app", version: "1.3.0")
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        let fakeTrash = URL(fileURLWithPath: dir.file("Trash"))
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        try AppMover.copy(source, to: destination, replacing: .older(version: "1.3.0"), ourIdentifier: identifier,
                          ourVersion: "1.4.0",
                          trash: { try FileManager.default.moveItem(at: $0, to: fakeTrash.appendingPathComponent("old.app")) }) { _ in }
        XCTAssertEqual(InstallLocation.bundleFacts(at: destination).version, "1.4.0")
        XCTAssertTrue(AppMover.signatureIsValid(destination, identifier: identifier))
        // The old one went to the Trash, not away.
        XCTAssertEqual(InstallLocation.bundleFacts(at: fakeTrash.appendingPathComponent("old.app")).version, "1.3.0")
    }

    func testOldCopyIsPutBackWhenTrashFails() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Apps"), withIntermediateDirectories: false)
        _ = try makeBundle(in: dir, name: "Apps/Furl.app", version: "1.3.0")
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        struct NoTrash: Error {}
        XCTAssertThrowsError(try AppMover.copy(source, to: destination, replacing: .older(version: "1.3.0"),
                                               ourIdentifier: identifier, ourVersion: "1.4.0",
                                               trash: { _ in throw NoTrash() }) { _ in })
        XCTAssertEqual(InstallLocation.bundleFacts(at: destination).version, "1.3.0")
    }

    func testReadOnlyFolderIsNoPermission() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        try FileManager.default.createDirectory(atPath: dir.file("Locked"), withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.file("Locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.file("Locked")) }
        do {
            try AppMover.copy(source, to: URL(fileURLWithPath: dir.file("Locked/Furl.app")), replacing: .none,
                              ourIdentifier: identifier, ourVersion: "1.4.0") { _ in }
            XCTFail("expected a failure")
        } catch let failure as AppMover.Failure {
            XCTAssertEqual(failure.kind, .noPermission)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.file("Locked/Furl.app")))
    }

    func testBrokenSignatureIsNotInstalled() throws {
        let dir = try TempDir()
        let source = try makeBundle(in: dir)
        // Tamper after signing.
        try Data(repeating: 9, count: 10).write(to: source.appendingPathComponent("Contents/Resources/payload"))
        try FileManager.default.createDirectory(atPath: dir.file("Apps"), withIntermediateDirectories: false)
        let destination = URL(fileURLWithPath: dir.file("Apps/Furl.app"))
        XCTAssertThrowsError(try AppMover.copy(source, to: destination, replacing: .none, ourIdentifier: identifier,
                                               ourVersion: "1.4.0") { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

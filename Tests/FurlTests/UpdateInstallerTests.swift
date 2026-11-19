import CryptoKit
import XCTest
@testable import Furl

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstCheckIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(enabled: true, lastCheck: nil, now: now))
    }

    func testOffNeverChecks() {
        XCTAssertFalse(UpdateSchedule.isDue(enabled: false, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(enabled: false, lastCheck: now.addingTimeInterval(-10 * 86_400), now: now))
    }

    func testAtMostOnceADay() {
        XCTAssertFalse(UpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(UpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(-5 * 86_400), now: now))
    }

    func testClockMovedBackChecksOnce() {
        XCTAssertTrue(UpdateSchedule.isDue(enabled: true, lastCheck: now.addingTimeInterval(3_600), now: now))
    }
}

final class UpdateVerifierTests: XCTestCase {
    private let dmg = Data("pretend this is Furl.dmg".utf8)

    func testChecksumMatchesShasumOutput() {
        let hex = UpdateVerifier.sha256Hex(of: dmg)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(UpdateVerifier.checksumMatches(data: dmg, checksumFile: "\(hex)  Furl.dmg\n"))
        XCTAssertTrue(UpdateVerifier.checksumMatches(data: dmg, checksumFile: hex.uppercased()))
    }

    func testChecksumRejectsMismatchAndGarbage() {
        let other = UpdateVerifier.sha256Hex(of: Data("something else".utf8))
        XCTAssertFalse(UpdateVerifier.checksumMatches(data: dmg, checksumFile: "\(other)  Furl.dmg"))
        XCTAssertFalse(UpdateVerifier.checksumMatches(data: dmg, checksumFile: ""))
        XCTAssertFalse(UpdateVerifier.checksumMatches(data: dmg, checksumFile: "not-a-hash Furl.dmg"))
        XCTAssertFalse(UpdateVerifier.checksumMatches(data: dmg, checksumFile: String(repeating: "z", count: 64)))
        XCTAssertNil(UpdateVerifier.expectedChecksum(from: String(UpdateVerifier.sha256Hex(of: dmg).dropLast())))
    }

    func testKnownSHA256() {
        XCTAssertEqual(UpdateVerifier.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSignatureAcceptsOnlyTheRightKeyAndBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signature = try key.signature(for: dmg).base64EncodedString()

        XCTAssertTrue(UpdateVerifier.isValidSignature(signature + "\n", for: dmg, publicKeyBase64: publicKey))
        // Tampered file.
        XCTAssertFalse(UpdateVerifier.isValidSignature(signature, for: dmg + Data([0]), publicKeyBase64: publicKey))
        // Someone else's key.
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateVerifier.isValidSignature(signature, for: dmg, publicKeyBase64: otherKey))
        // No key configured, or junk.
        XCTAssertFalse(UpdateVerifier.isValidSignature(signature, for: dmg, publicKeyBase64: ""))
        XCTAssertFalse(UpdateVerifier.isValidSignature("", for: dmg, publicKeyBase64: publicKey))
        XCTAssertFalse(UpdateVerifier.isValidSignature("bm90IGEgc2lnbmF0dXJl", for: dmg, publicKeyBase64: publicKey))
    }

    func testAssetURLsMustBeThisRepositorysReleaseDownloads() {
        func ok(_ s: String) -> Bool { UpdateVerifier.isAllowedAssetURL(URL(string: s)!, repository: "punitm0/furl") }
        XCTAssertTrue(ok("https://github.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertTrue(ok("https://github.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg.sig"))
        XCTAssertFalse(ok("http://github.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://github.com/someone/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://evil.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://github.com.evil.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://github.com:8443/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://user@github.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg"))
        XCTAssertFalse(ok("https://github.com/punitm0/furl/releases/download/v1.0.1/Furl.dmg?x=1"))
        XCTAssertFalse(ok("https://github.com/punitm0/furl/releases/download/../x/Furl.dmg"))
        XCTAssertFalse(ok("https://github.com/punitm0/furl/releases/download/v1/a/Furl.dmg"))
    }

    func testRedirectsStayOnGitHubOverHTTPS() {
        XCTAssertTrue(UpdateVerifier.isAllowedRedirect(URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertTrue(UpdateVerifier.isAllowedRedirect(URL(string: "https://release-assets.githubusercontent.com/x")))
        XCTAssertFalse(UpdateVerifier.isAllowedRedirect(URL(string: "http://objects.githubusercontent.com/x")))
        XCTAssertFalse(UpdateVerifier.isAllowedRedirect(URL(string: "https://githubusercontent.com.evil.com/x")))
        XCTAssertFalse(UpdateVerifier.isAllowedRedirect(nil))
    }

    func testVersionMustBeHigher() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))
    }
}

final class UpdateInstallTargetTests: XCTestCase {
    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("furl-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("Furl.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        return app
    }

    func testWritableFolderCanUpdate() throws {
        let app = try makeApp(in: root)
        XCTAssertNil(UpdateInstaller.installProblem(bundleURL: app, bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: key))
    }

    func testNoPublicKeyMeansNoInPlaceInstall() throws {
        let app = try makeApp(in: root)
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: app, bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: ""))
    }

    func testWrongBundleOrNotAnApp() throws {
        let app = try makeApp(in: root)
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: app, bundleIdentifier: "com.example.other", publicKey: key))
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: root.appendingPathComponent("debug"), bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: key))
    }

    func testTranslocatedOrSymlinkedAppIsRefused() throws {
        let translocated = root.appendingPathComponent("AppTranslocation/ABC/d", isDirectory: true)
        try FileManager.default.createDirectory(at: translocated, withIntermediateDirectories: true)
        let app = try makeApp(in: translocated)
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: app, bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: key))

        let real = try makeApp(in: root)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: link, bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: key))
    }

    func testReadOnlyFolderIsRefused() throws {
        let app = try makeApp(in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertNotNil(UpdateInstaller.installProblem(bundleURL: app, bundleIdentifier: UpdateConfig.bundleIdentifier, publicKey: key))
    }
}

/// Runs the real mount → check → copy → swap path against small ad-hoc signed bundles in real DMGs.
final class UpdateInstallSwapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("furl-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A minimal Furl.app: Info.plist plus a signed copy of /usr/bin/true.
    @discardableResult
    private func makeApp(at app: URL, version: String, identifier: String = UpdateConfig.bundleIdentifier,
                         tamperAfterSigning: Bool = false) throws -> URL {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Furl"))
        let plist: NSDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Furl", "CFBundlePackageType": "APPL",
        ]
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        try plist.write(to: plistURL)
        let sign = ShellRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--identifier", identifier, app.path])
        XCTAssertEqual(sign.exitCode, 0, sign.stderr)
        if tamperAfterSigning {
            try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources-extra"))
        }
        return app
    }

    private func makeDMG(containing app: URL) throws -> URL {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = ShellRunner.run("/usr/bin/ditto", arguments: [app.path, stage.appendingPathComponent("Furl.app").path])
        let dmg = root.appendingPathComponent("\(UUID().uuidString).dmg")
        let create = ShellRunner.run("/usr/bin/hdiutil", arguments: [
            "create", "-quiet", "-srcfolder", stage.path, "-volname", "Furl", "-format", "UDZO", dmg.path,
        ], timeout: 120)
        XCTAssertEqual(create.exitCode, 0, create.stderr)
        return dmg
    }

    private func version(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func newWork() throws -> URL {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    func testSwapsInTheNewVersion() throws {
        let installed = try makeApp(at: root.appendingPathComponent("Applications/Furl.app"), version: "1.0.0")
        let dmg = try makeDMG(containing: try makeApp(at: root.appendingPathComponent("new/Furl.app"), version: "1.0.1"))

        let old = try UpdateInstaller.installVerifiedDMG(dmg, work: try newWork(), expectedVersion: "1.0.1",
                                                         currentVersion: "1.0.0", bundleURL: installed)
        XCTAssertEqual(version(at: installed), "1.0.1")
        XCTAssertEqual(version(at: old), "1.0.0")
        XCTAssertEqual(ShellRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", installed.path]).exitCode, 0)
    }

    func testRefusesWithoutTouchingTheInstalledApp() throws {
        let installed = try makeApp(at: root.appendingPathComponent("Applications/Furl.app"), version: "1.0.0")
        let cases: [(String, URL, String, String)] = [
            ("version differs from the release tag",
             try makeDMG(containing: try makeApp(at: root.appendingPathComponent("a/Furl.app"), version: "1.0.1")), "1.0.2", "doesn't match the release"),
            ("not newer",
             try makeDMG(containing: try makeApp(at: root.appendingPathComponent("b/Furl.app"), version: "1.0.0")), "1.0.0", "doesn't match the release"),
            ("other bundle id",
             try makeDMG(containing: try makeApp(at: root.appendingPathComponent("c/Furl.app"), version: "1.0.1",
                                                 identifier: "com.example.notfurl")), "1.0.1", "doesn't contain Furl"),
            ("modified after signing",
             try makeDMG(containing: try makeApp(at: root.appendingPathComponent("d/Furl.app"), version: "1.0.1",
                                                 tamperAfterSigning: true)), "1.0.1", "code signature"),
        ]
        for (name, dmg, expected, reason) in cases {
            XCTAssertThrowsError(try UpdateInstaller.installVerifiedDMG(dmg, work: try newWork(), expectedVersion: expected,
                                                                        currentVersion: "1.0.0", bundleURL: installed), name) { error in
                XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains(reason) == true, "\(name): \(error)")
            }
            XCTAssertEqual(version(at: installed), "1.0.0", name)
        }
    }

    func testRefusesWhenTheInstalledAppChangedMeanwhile() throws {
        let installed = try makeApp(at: root.appendingPathComponent("Applications/Furl.app"), version: "1.0.0")
        let dmg = try makeDMG(containing: try makeApp(at: root.appendingPathComponent("new/Furl.app"), version: "1.0.1"))
        // The running copy believes it is 0.9, but 1.0.0 is on disk: someone replaced it.
        XCTAssertThrowsError(try UpdateInstaller.installVerifiedDMG(dmg, work: try newWork(), expectedVersion: "1.0.1",
                                                                    currentVersion: "0.9", bundleURL: installed)) { error in
            XCTAssertTrue((error as? UpdateInstaller.Failure)?.message.contains("changed on disk") == true, "\(error)")
        }
        XCTAssertEqual(version(at: installed), "1.0.0")
    }

    func testRejectsAnImageWithoutFurl() throws {
        let installed = try makeApp(at: root.appendingPathComponent("Applications/Furl.app"), version: "1.0.0")
        let other = try makeApp(at: root.appendingPathComponent("x/Other.app"), version: "1.0.1")
        let stage = root.appendingPathComponent("emptystage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = ShellRunner.run("/usr/bin/ditto", arguments: [other.path, stage.appendingPathComponent("Other.app").path])
        let dmg = root.appendingPathComponent("other.dmg")
        _ = ShellRunner.run("/usr/bin/hdiutil", arguments: ["create", "-quiet", "-srcfolder", stage.path, "-format", "UDZO", dmg.path], timeout: 120)
        XCTAssertThrowsError(try UpdateInstaller.installVerifiedDMG(dmg, work: try newWork(), expectedVersion: "1.0.1",
                                                                    currentVersion: "1.0.0", bundleURL: installed))
        XCTAssertEqual(version(at: installed), "1.0.0")
    }
}

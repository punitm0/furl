import XCTest
@testable import Furl

final class TrashedAppLeftoversTests: XCTestCase {
    private func item(_ name: String, _ location: AppDataLocation = .applicationSupport,
                      bytes: Int64 = 30_000_000, strong: Bool = true) -> AppDataItem {
        let path = "/Users/me/Library/\(location.rawValue)/\(name)"
        return AppDataItem(id: path, path: path, name: name, location: location, sizeBytes: bytes,
                           modifiedDate: nil, isStrongMatch: strong)
    }

    // MARK: Notify rules

    func testNotifiesAtFiftyMBWithASureMatch() {
        let items = [item("com.vendor.app", bytes: 40_000_000), item("App", .logs, bytes: 10_000_000, strong: false)]
        XCTAssertTrue(TrashedAppLeftovers.shouldNotify(items: items, bundleID: "com.vendor.app",
                                                       enabled: true, alreadyNotified: []))
    }

    func testBelowFiftyMBStaysQuiet() {
        let items = [item("com.vendor.app", bytes: 49_999_999)]
        XCTAssertFalse(TrashedAppLeftovers.shouldNotify(items: items, bundleID: "com.vendor.app",
                                                        enabled: true, alreadyNotified: []))
    }

    func testOnlyPossibleMatchesStayQuiet() {
        let items = [item("App", bytes: 900_000_000, strong: false)]
        XCTAssertFalse(TrashedAppLeftovers.shouldNotify(items: items, bundleID: "com.vendor.app",
                                                        enabled: true, alreadyNotified: []))
    }

    func testOncePerAppAndSwitchOff() {
        let items = [item("com.vendor.app", bytes: 900_000_000)]
        XCTAssertFalse(TrashedAppLeftovers.shouldNotify(items: items, bundleID: "com.Vendor.App",
                                                        enabled: true, alreadyNotified: ["com.vendor.app"]))
        XCTAssertFalse(TrashedAppLeftovers.shouldNotify(items: items, bundleID: "com.vendor.app",
                                                        enabled: false, alreadyNotified: []))
    }

    func testRecordNotifiedIsRememberedAndOnByDefault() throws {
        let suite = "FurlTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TrashedAppLeftovers.isEnabled(defaults))
        TrashedAppLeftovers.recordNotified("com.Vendor.App", defaults: defaults)
        TrashedAppLeftovers.recordNotified("com.vendor.app", defaults: defaults)
        XCTAssertEqual(TrashedAppLeftovers.notified(defaults), ["com.vendor.app"])
    }

    func testBodyMatchesBoard() {
        let size = FileSizeHelper.formatBytes(1_400_000_000)
        XCTAssertEqual(TrashedAppLeftovers.body(appName: "Sketch", bytes: 1_400_000_000),
                       "Sketch is in the Trash. It left \(size) in your Library. Remove that too?")
    }

    // MARK: Groups

    func testGroupsPutTheAppsOwnIDFirstAndSplitPossibleMatches() {
        let items = [
            item("com.vendor.app", bytes: 10),
            item("com.vendor.app.plist", .preferences, bytes: 1),
            item("App", .logs, bytes: 500, strong: false)
        ]
        let groups = TrashedAppLeftovers.groups(from: items, bundleID: "com.Vendor.App", appName: "App")
        XCTAssertEqual(groups.map(\.id), ["com.vendor.app", "app"])
        XCTAssertTrue(groups[0].isSureMatch)
        XCTAssertEqual(groups[0].shownName, "App")
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertFalse(groups[1].isSureMatch)
    }

    // MARK: Reading the app in the Trash

    private func makeApp(in dir: TempDir, name: String = "Sketch.app", plist: [String: Any]) throws -> URL {
        let app = URL(fileURLWithPath: dir.file(name))
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testReadsBundleIDAndName() throws {
        let dir = try TempDir()
        let app = try makeApp(in: dir, plist: ["CFBundleIdentifier": "com.bohemiancoding.sketch3", "CFBundleName": "Sketch"])
        XCTAssertEqual(TrashedAppLeftovers.readTrashedApp(at: app),
                       TrashedApp(bundleID: "com.bohemiancoding.sketch3", name: "Sketch"))
    }

    func testRejectsBadIDsAndFallsBackOnBadNames() throws {
        let dir = try TempDir()
        let bad = try makeApp(in: dir, name: "Bad.app", plist: ["CFBundleIdentifier": "../../etc"])
        XCTAssertNil(TrashedAppLeftovers.readTrashedApp(at: bad))
        let odd = try makeApp(in: dir, name: "Odd.app",
                              plist: ["CFBundleIdentifier": "com.vendor.odd", "CFBundleName": "Odd\nName"])
        XCTAssertEqual(TrashedAppLeftovers.readTrashedApp(at: odd)?.name, "Odd")
    }

    func testDoesNotFollowSymlinks() throws {
        let dir = try TempDir()
        let real = try makeApp(in: dir, name: "Real.app", plist: ["CFBundleIdentifier": "com.vendor.real"])
        // A symlinked .app.
        let linkedApp = URL(fileURLWithPath: dir.file("Linked.app"))
        try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: real)
        XCTAssertNil(TrashedAppLeftovers.readTrashedApp(at: linkedApp))
        // A real .app whose Info.plist is a symlink.
        let sneaky = URL(fileURLWithPath: dir.file("Sneaky.app/Contents"))
        try FileManager.default.createDirectory(at: sneaky, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sneaky.appendingPathComponent("Info.plist"),
                                                   withDestinationURL: real.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(TrashedAppLeftovers.readTrashedApp(at: URL(fileURLWithPath: dir.file("Sneaky.app"))))
    }

    func testNewAppsInTrash() {
        XCTAssertEqual(TrashWatcher.newApps(previous: ["Old.app"], current: ["Old.app", "B.app", "A.app"]),
                       ["A.app", "B.app"])
        XCTAssertEqual(TrashWatcher.newApps(previous: ["Old.app"], current: []), [])
    }
}

final class WhatsNewTests: XCTestCase {
    private let notes = [WhatsNew.Notes(version: "1.4.0", lines: ["One."])]

    func testShowsOnceAfterAnUpdate() {
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.0", isUpdatedVersion: true, fdaBannerShowing: false,
                                       lastShown: nil, notes: notes), .show(notes[0]))
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.0", isUpdatedVersion: true, fdaBannerShowing: false,
                                       lastShown: "1.4.0", notes: notes), .nothing)
    }

    func testNeverOnAFirstInstall() {
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.0", isUpdatedVersion: false, fdaBannerShowing: false,
                                       lastShown: nil, notes: notes), .markSeen("1.4.0"))
        // After that first install, an update to a bug-fix release doesn't show the same notes.
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.1", isUpdatedVersion: true, fdaBannerShowing: false,
                                       lastShown: "1.4.0", notes: notes), .nothing)
    }

    func testWaitsWhileTheFullDiskAccessBannerShows() {
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.0", isUpdatedVersion: true, fdaBannerShowing: true,
                                       lastShown: nil, notes: notes), .wait)
        // Next launch, Full Disk Access is fine.
        XCTAssertEqual(WhatsNew.decide(currentVersion: "1.4.0", isUpdatedVersion: true, fdaBannerShowing: false,
                                       lastShown: nil, notes: notes), .show(notes[0]))
    }

    func testNotesLookup() {
        XCTAssertEqual(WhatsNew.notes(for: "1.4.2", in: notes)?.version, "1.4.0")
        XCTAssertNil(WhatsNew.notes(for: "1.3.0", in: notes))
        XCTAssertNil(WhatsNew.notes(for: "1.5.0", in: notes))
        XCTAssertEqual(WhatsNew.decide(currentVersion: nil, isUpdatedVersion: true, fdaBannerShowing: false,
                                       lastShown: nil, notes: notes), .nothing)
    }

    func testBundledNotesAreTheSevenBoardLines() {
        XCTAssertEqual(WhatsNew.notes(for: "1.4.0")?.lines.count, 9)
        XCTAssertEqual(WhatsNew.changelogURL.absoluteString, "https://getfurl.app/changelog")
    }
}

import XCTest
@testable import Furl

final class RemovedAppsTests: XCTestCase {
    private func item(_ name: String, _ location: AppDataLocation = .caches, bytes: Int64 = 1_000_000,
                      strong: Bool = true) -> AppDataItem {
        let path = "/Users/me/Library/\(location.rawValue)/\(name)"
        return AppDataItem(id: path, path: path, name: name, location: location, sizeBytes: bytes,
                           modifiedDate: nil, isStrongMatch: strong)
    }

    private func group(_ key: String, sure: Bool, items names: [String]) -> OrphanedAppDataGroup {
        OrphanedAppDataGroup(id: key, appIdentifier: key, displayName: key,
                             items: names.map { item($0, strong: sure) })
    }

    // MARK: Sure vs possible

    func testFullAppIDWithNothingRelatedInstalledIsSure() {
        XCTAssertTrue(AppUninstallerService.isSureLeftover(key: "com.bohemiancoding.sketch3",
                                                           installedBundleIDs: ["com.tinyspeck.slackmacgap"]))
        XCTAssertTrue(AppUninstallerService.isSureLeftover(key: "zoom.us", installedBundleIDs: []))
    }

    func testPlainNamesAreGuesses() {
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "sketch", installedBundleIDs: []))
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "my app", installedBundleIDs: []))
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com..thing", installedBundleIDs: []))
    }

    func testHelpersAndSharedPartsAreGuesses() {
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com.electron.notion-helper", installedBundleIDs: []))
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com.vendor.app.shipit", installedBundleIDs: []))
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "org.sparkle-project.sparkle", installedBundleIDs: []))
    }

    func testSameMakerStillInstalledIsAGuess() {
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com.bohemiancoding.sketch3",
                                                            installedBundleIDs: ["com.bohemiancoding.sketchmirror"]))
    }

    // MARK: Select sure matches

    func testSelectSureMatchesNeverTicksAGuess() {
        let sure = group("com.bohemiancoding.sketch3", sure: true, items: ["a", "b"])
        let guess = group("com.electron.notion-helper", sure: false, items: ["c"])
        let ids = RemovedApps.sureItemIDs(in: [sure, guess])
        XCTAssertEqual(ids, Set(sure.items.map(\.id)))
        XCTAssertTrue(ids.isDisjoint(with: guess.items.map(\.id)))
    }

    func testMixedGroupIsAGuess() {
        let mixed = OrphanedAppDataGroup(id: "x.y", appIdentifier: "x.y", displayName: "x.y",
                                         items: [item("a"), item("b", strong: false)])
        XCTAssertFalse(mixed.isSureMatch)
        XCTAssertTrue(RemovedApps.sureItemIDs(in: [mixed]).isEmpty)
    }

    func testTickedSkipsFoldersThatAreGone() {
        let sure = group("zoom.us", sure: true, items: ["a"])
        XCTAssertTrue(RemovedApps.ticked(["/gone"], in: [sure]).isEmpty)
    }

    // MARK: Confirms

    func testOneAppListsFoldersAndSaysTrash() throws {
        let zoom = OrphanedAppDataGroup(id: "zoom.us", appIdentifier: "zoom.us", displayName: "Zoom",
                                        items: [item("zoom.us", .applicationSupport), item("us.zoom.xos", .caches)])
        let confirm = try XCTUnwrap(RemovedApps.confirm(for: [(zoom, zoom.items)], toTrash: true))
        XCTAssertEqual(confirm.title, "Move Zoom\u{2019}s data to the Trash?")
        XCTAssertEqual(confirm.message, "Zoom was removed. These 2 folders go to the Trash, so you can undo.")
        XCTAssertEqual(confirm.lines.map(\.name), ["Application Support/zoom.us", "Caches/us.zoom.xos"])
        XCTAssertTrue(confirm.button.hasPrefix("Move to Trash ("))
        XCTAssertEqual(confirm.paths.count, 2)
    }

    func testSeveralWithAGuessAddsTheCheckLine() throws {
        let sure = group("zoom.us", sure: true, items: ["a"])
        let guess = group("com.electron.notion-helper", sure: false, items: ["b"])
        let confirm = try XCTUnwrap(RemovedApps.confirm(for: [(sure, sure.items), (guess, guess.items)], toTrash: true))
        XCTAssertEqual(confirm.title, "Move data from 2 removed apps to the Trash?")
        XCTAssertTrue(confirm.message.hasPrefix("It all goes to the Trash, so you can undo."))
        XCTAssertTrue(confirm.message.contains("check that no app you still use needs it."))
        XCTAssertEqual(confirm.lines.map(\.name), ["zoom.us", "com.electron.notion-helper · guess"])
    }

    func testPermanentModeNeverSaysTrash() throws {
        let sure = group("zoom.us", sure: true, items: ["a"])
        let confirm = try XCTUnwrap(RemovedApps.confirm(for: [(sure, sure.items)], toTrash: false))
        XCTAssertFalse(confirm.title.contains("Trash"))
        XCTAssertFalse(confirm.message.contains("Trash"))
        XCTAssertTrue(confirm.message.contains("This folder is deleted for good"))
    }

    func testNothingTickedHasNoConfirm() {
        XCTAssertNil(RemovedApps.confirm(for: [], toTrash: true))
    }
    // MARK: Review fixes

    func testSelectSureMatchesSkipsFoldersThatMayHoldDocuments() {
        let items = [item("zoom.us", .caches), item("zoom.us", .applicationSupport),
                     item("us.zoom.xos.plist", .preferences), item("us.zoom.xos", .containers)]
        let zoom = OrphanedAppDataGroup(id: "zoom.us", appIdentifier: "zoom.us", displayName: "Zoom", items: items)
        XCTAssertEqual(RemovedApps.sureItemIDs(in: [zoom]), [items[0].id])
    }

    func testAutoTickDroppedWhenRescanMakesItAGuess() {
        let before = group("zoom.us", sure: true, items: ["a"])
        let after = group("zoom.us", sure: false, items: ["a"])
        let auto = RemovedApps.sureItemIDs(in: [before])
        XCTAssertEqual(RemovedApps.staleAutoTicks(auto, in: [after]), auto)
        XCTAssertTrue(RemovedApps.staleAutoTicks(auto, in: [before]).isEmpty)
    }

    func testInstalledAppNameMakesItAGuess() {
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com.vendor.sketch", installedBundleIDs: [],
                                                            installedAppNames: ["sketch"]))
        XCTAssertFalse(AppUninstallerService.isSureLeftover(key: "com.vendor.tableplus", installedBundleIDs: [],
                                                            installedAppNames: ["Table Plus"]))
        XCTAssertTrue(AppUninstallerService.isSureLeftover(key: "com.vendor.sketch", installedBundleIDs: [],
                                                           installedAppNames: ["slack"]))
    }

    func testSeveralAppsConfirmShowsFolderKinds() throws {
        let zoom = OrphanedAppDataGroup(id: "zoom.us", appIdentifier: "zoom.us", displayName: "Zoom",
                                        items: [item("a", .caches), item("b", .logs), item("c", .caches)])
        let other = group("com.x.y", sure: true, items: ["d"])
        let confirm = try XCTUnwrap(RemovedApps.confirm(for: [(zoom, zoom.items), (other, other.items)], toTrash: true))
        XCTAssertEqual(confirm.lines.first?.detail, "Caches, Logs")
        XCTAssertEqual(RemovedApps.folderKinds([item("a", .applicationSupport), item("b", .preferences)]),
                       "App Support, Settings")
        XCTAssertEqual(RemovedApps.tickedSummary(appCount: 1), "1 removed app ticked")
    }

    func testUninstallConfirmListsFoldersAndKeepsBothNotes() {
        let sure = item("com.tinyspeck.slackmacgap", .caches, bytes: 3_000)
        let loose = item("slack-helper", .applicationSupport, bytes: 2_000, strong: false)
        let app = InstalledAppItem(id: "/Applications/Slack.app", name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap",
                                   version: "4", bundlePath: "/Applications/Slack.app", appSizeBytes: 1_000,
                                   associatedData: [sure, loose], isRunning: true, isAppleApp: false)
        let confirm = RemovedApps.uninstall(app, data: [sure], toTrash: true)
        XCTAssertEqual(confirm.lines.map(\.name), ["Slack.app", "Caches/com.tinyspeck.slackmacgap"])
        XCTAssertEqual(confirm.paths, ["/Applications/Slack.app", sure.path])
        XCTAssertTrue(confirm.message.contains("is running and will be quit first"))
        XCTAssertTrue(confirm.message.contains("go to the Trash"))
        XCTAssertTrue(confirm.message.contains("Possible match"))
        XCTAssertEqual(confirm.totalBytes, 4_000)
    }
}

import XCTest
@testable import Furl

/// Dropping tray items a finished scan no longer lists, so they don't fail at clean time.
final class CleanupTrayReconcileTests: XCTestCase {
    private func item(_ source: TraySource, _ key: String) -> TrayItem {
        TrayItem(source: source, key: key, path: "/x/" + key, title: key, subtitle: "", bytes: 1, isPermanent: false)
    }

    private lazy var tray = [item(.apps, "data:old"), item(.apps, "app:kept"), item(.junk, "cache")]

    func testCompleteScanDropsItemsItNoLongerLists() {
        let result = CleanupTray.reconcile(tray, source: .apps, listed: ["app:kept"], completed: true, fullAccess: true)
        XCTAssertEqual(result.removed.map(\.key), ["data:old"])
        XCTAssertEqual(result.kept.map(\.key), ["app:kept", "cache"])
        XCTAssertTrue(result.unchecked.isEmpty)
    }

    func testOtherSectionsAreLeftAlone() {
        let result = CleanupTray.reconcile(tray, source: .junk, listed: [], completed: true, fullAccess: true)
        XCTAssertEqual(result.removed.map(\.key), ["cache"])
        XCTAssertEqual(result.kept.map(\.key), ["data:old", "app:kept"])
    }

    func testStoppedScanKeepsEverything() {
        let result = CleanupTray.reconcile(tray, source: .apps, listed: [], completed: false, fullAccess: true)
        XCTAssertEqual(result.kept, tray)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(result.unchecked.isEmpty)
    }

    func testScanWithoutFullDiskAccessKeepsAndFlags() {
        let result = CleanupTray.reconcile(tray, source: .apps, listed: ["app:kept"], completed: true, fullAccess: false)
        XCTAssertEqual(result.kept, tray)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.unchecked.map(\.key), ["data:old"])
    }

    func testEverythingListedChangesNothing() {
        let result = CleanupTray.reconcile(tray, source: .apps, listed: ["app:kept", "data:old"], completed: true, fullAccess: true)
        XCTAssertEqual(result, CleanupTray.Reconciled(kept: tray, removed: [], unchecked: []))
    }

    func testNotices() {
        XCTAssertEqual(CleanupTray.removedNotice([item(.apps, "a")], section: .apps),
                       "Removed 1 item that's no longer listed in Apps & Leftovers.")
        XCTAssertEqual(CleanupTray.removedNotice([item(.apps, "a"), item(.apps, "b")], section: .apps),
                       "Removed 2 items that are no longer listed in Apps & Leftovers.")
        XCTAssertEqual(CleanupTray.needsAccessMessage([item(.apps, "Foo")]),
                       "Kept Foo in the tray: Furl needs Full Disk Access to check it.")
    }
}

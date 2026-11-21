import XCTest
@testable import Furl

/// Closing the window keeps Furl in the menu bar by default, so the menu bar item and the
/// app-trashed notification keep working; an explicit choice in Settings still wins.
@MainActor
final class MenuBarDefaultsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "MenuBarDefaultsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testKeepsRunningInMenuBarByDefault() {
        let store = AutoSweepStore(defaults: freshDefaults())
        XCTAssertTrue(store.showMenuBarItem)
        XCTAssertTrue(store.keepRunningInMenuBar)
    }

    func testExplicitOffIsKept() {
        let d = freshDefaults()
        d.set(false, forKey: "menuBar.keepRunning")
        XCTAssertFalse(AutoSweepStore(defaults: d).keepRunningInMenuBar)
    }
}

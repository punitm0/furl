import XCTest
@testable import Furl

final class NeverScanTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @MainActor
    func testNeverOffersHomeVolumesOrLibrary() {
        XCTAssertFalse(AppState.canNeverScan("/"))
        XCTAssertFalse(AppState.canNeverScan(home))
        XCTAssertFalse(AppState.canNeverScan("/Users"))
        XCTAssertFalse(AppState.canNeverScan(home + "/Library"))
        XCTAssertFalse(AppState.canNeverScan("/Volumes"))
        XCTAssertFalse(AppState.canNeverScan("/Volumes/Samsung T7"))
        XCTAssertTrue(AppState.canNeverScan("/Volumes/Samsung T7/code"))
        XCTAssertTrue(AppState.canNeverScan(home + "/code/vendor"))
        XCTAssertTrue(AppState.canNeverScan(home + "/Library/Caches/com.example"))
        // Folders right inside home or ~/Library hold too much else.
        XCTAssertFalse(AppState.canNeverScan(home + "/Downloads"))
        XCTAssertFalse(AppState.canNeverScan(home + "/Documents"))
        XCTAssertFalse(AppState.canNeverScan(home + "/Library/Caches"))
        XCTAssertFalse(AppState.canNeverScan(home + "/Library/Logs"))
        XCTAssertTrue(AppState.canNeverScan(home + "/Downloads/old-project"))
    }

    func testNeverScanRootsCoverAutoSweepAndTidyCandidates() {
        let roots = [home + "/Library/Caches/Homebrew", home + "/Downloads/keep"]
        XCTAssertTrue(AppState.isExcluded(home + "/Library/Caches/Homebrew/downloads/x.tar.gz", by: roots))
        XCTAssertTrue(AppState.isExcluded(home + "/Downloads/keep", by: roots))
        XCTAssertFalse(AppState.isExcluded(home + "/Library/Caches/Homebrew2", by: roots))
        XCTAssertFalse(AppState.isExcluded(home + "/Downloads/installer.dmg", by: roots))
        XCTAssertFalse(AppState.isExcluded(home + "/anything", by: []))
    }

    @MainActor
    func testUndoPutsCopiesBackIntoCurrentGroups() {
        func file(_ name: String) -> DuplicateFile {
            DuplicateFile(id: "/d/" + name, path: "/d/" + name, name: name, modifiedDate: nil, privateBytes: 10)
        }
        // A rescan finished after the skip: group g now holds a and b only.
        let current = [DuplicateGroup(id: "g", sizeBytes: 10, files: [file("a"), file("b")])]
        let removed = [DuplicateGroup(id: "g", sizeBytes: 10, files: [file("c"), file("a")]),
                       DuplicateGroup(id: "h", sizeBytes: 10, files: [file("x"), file("y")]),
                       DuplicateGroup(id: "i", sizeBytes: 10, files: [file("lonely")])]
        let restored = AppState.restoring(removed, into: current)
        XCTAssertEqual(Set(restored.map(\.id)), ["g", "h"])
        XCTAssertEqual(restored.first { $0.id == "g" }?.files.map(\.name), ["a", "b", "c"])
    }

    @MainActor
    func testInsideMatchesWholeFolderNamesOnly() {
        XCTAssertTrue(AppState.isInside(home + "/code/vendor/node_modules", home + "/code/vendor"))
        XCTAssertTrue(AppState.isInside(home + "/code/vendor", home + "/code/vendor"))
        XCTAssertFalse(AppState.isInside(home + "/code/vendor2/node_modules", home + "/code/vendor"))
    }

    func testConfirmCopy() {
        let request = NeverScanRequest(folder: home + "/code/vendor", section: .junk, itemCount: 3)
        XCTAssertEqual(request.title, "Stop scanning ~/code/vendor?")
        XCTAssertEqual(request.message,
                       "Furl won’t look inside this folder again, and its 3 items leave Furl’s lists. Nothing is deleted.")
        let one = NeverScanRequest(folder: "/Volumes/Archive/old", section: .largeFiles, itemCount: 1)
        XCTAssertEqual(one.message,
                       "Furl won’t look inside this folder again, and its 1 item leaves Furl’s lists. Nothing is deleted.")
    }

    func testUnusedAfterDaysOnlyHidesGatedItems() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        func item(gated: Bool) -> JunkItem {
            JunkItem(id: "x", name: "web/node_modules", path: "/tmp/web/node_modules", category: .devArtifacts,
                     risk: .moderate, sizeBytes: 1, modifiedDate: tenDaysAgo, reason: "",
                     listedOnlyWhenUnused: gated)
        }
        XCTAssertTrue(item(gated: true).isListed(staleDays: 7, now: now))
        XCTAssertFalse(item(gated: true).isListed(staleDays: 30, now: now))
        XCTAssertTrue(item(gated: false).isListed(staleDays: 30, now: now))
    }

    func testReasonFollowsTheUserSettingNotTheScanFloor() {
        let now = Date()
        let item = JunkItem(id: "x", name: "web/node_modules", path: "/tmp/web/node_modules", category: .devArtifacts,
                            risk: .moderate, sizeBytes: 1, modifiedDate: now.addingTimeInterval(-10 * 86_400),
                            reason: "Unused for 10 days in web", projectName: "web")
        XCTAssertEqual(item.relabeled(staleDays: 30, now: now).reason, "Build/dependency folder in web (reinstallable)")
        XCTAssertEqual(item.relabeled(staleDays: 7, now: now).reason, "Unused for 10 days in web")
    }
}

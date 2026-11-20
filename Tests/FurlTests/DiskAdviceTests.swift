import XCTest
@testable import Furl

final class DiskAdviceTests: XCTestCase {
    private typealias E = DiskFindings.Entry
    private let gb: Int64 = 1_000_000_000

    func testAllSafeJunkIsClean() {
        let f = DiskFindings(entries: [
            E(kind: .safeJunk, path: "/u/Library/Developer/Xcode/DerivedData", bytes: 5 * gb, label: "Dev Build & Deps"),
        ])
        let a = f.advice(for: "/u/Library/Developer", category: .developer)
        XCTAssertEqual(a.action, .clean)
        XCTAssertEqual(a.section, .junk)
        XCTAssertEqual(a.foundBytes, 5 * gb)
        XCTAssertTrue(a.detail?.contains("cleanable") == true)
        XCTAssertTrue(a.detail?.contains("Dev Build & Deps") == true)
    }

    func testJunkNeedingALookIsReview() {
        let f = DiskFindings(entries: [
            E(kind: .safeJunk, path: "/u/Library/Caches/a", bytes: 3 * gb),
            E(kind: .checkJunk, path: "/u/Library/Caches/b", bytes: gb),
        ])
        XCTAssertEqual(f.advice(for: "/u/Library/Caches").action, .review)
    }

    func testBiggestFindingPicksTheSection() {
        let f = DiskFindings(entries: [
            E(kind: .worktree, path: "/u/code/app-wt", bytes: 9 * gb),
            E(kind: .safeJunk, path: "/u/code/web/node_modules", bytes: 4 * gb),
            E(kind: .largeFile, path: "/u/Movies/a.mov", bytes: 6 * gb),
        ])
        let code = f.advice(for: "/u/code")
        XCTAssertEqual(code.action, .review)
        XCTAssertEqual(code.section, .worktrees)
        XCTAssertEqual(code.detail?.hasPrefix("9"), true)
        XCTAssertTrue(code.detail?.contains("merged worktrees") == true)

        let movies = f.advice(for: "/u/Movies")
        XCTAssertEqual(movies.action, .pickFiles)
        XCTAssertEqual(movies.section, .largeFiles)
    }

    func testSiblingWithSharedPrefixIsNotCounted() {
        let f = DiskFindings(entries: [E(kind: .safeJunk, path: "/u/code-old/x", bytes: gb)])
        XCTAssertEqual(f.advice(for: "/u/code", category: .other).action, .open)
    }

    func testNothingFoundFallsBackByCategory() {
        let f = DiskFindings(entries: [])
        XCTAssertEqual(f.advice(for: "/u/Movies", category: .media).action, .pickFiles)
        let other = f.advice(for: "/u/stuff", category: .other)
        XCTAssertEqual(other.action, .open)
        XCTAssertNil(other.section)
        XCTAssertNil(other.detail)
        let dev = f.advice(for: "/u/code/web/node_modules", category: .developer)
        XCTAssertEqual(dev.action, .review)
        XCTAssertEqual(dev.section, .junk)
    }

    func testCategoryForPath() {
        XCTAssertEqual(DiskFindings.category(forPath: "/h/Library/Developer/CoreSimulator", home: "/h"), .developer)
        XCTAssertEqual(DiskFindings.category(forPath: "/h/code/web/node_modules", home: "/h"), .developer)
        XCTAssertEqual(DiskFindings.category(forPath: "/h/Pictures", home: "/h"), .media)
        XCTAssertEqual(DiskFindings.category(forPath: "/h/code", home: "/h"), .other)
        XCTAssertEqual(DiskFindings.category(forPath: "/Applications", home: "/h"), .other)
    }

    func testLegacySectionNamesOpenDisk() {
        XCTAssertEqual(SidebarSection(rawValue: "Space Map"), .disk)
        XCTAssertEqual(SidebarSection(rawValue: "Snapshots"), .disk)
        XCTAssertNil(SidebarSection(rawValue: "Nope"))
        for section in SidebarSection.allCases {
            XCTAssertEqual(SidebarSection(rawValue: section.rawValue), section)
        }
    }

    func testExploreGroupIsDiskHistoryFind() {
        XCTAssertEqual(SidebarGroup.explore.sections, [.disk, .activity, .find])
    }

    /// SimplerNav: Compress joins "Free up space", Processes gets "Running now", ⌘1–⌘8 unchanged.
    func testSimplerNavGroupsKeepShortcutOrder() {
        XCTAssertEqual(SidebarGroup.allCases, [.overview, .freeUpSpace, .runningNow, .explore])
        XCTAssertEqual(SidebarGroup.freeUpSpace.sections.last, .compress)
        XCTAssertEqual(SidebarGroup.runningNow.sections, [.processes])
        XCTAssertEqual(Array(SidebarSection.allCases.prefix(8)),
                       [.dashboard, .smartReview, .junk, .worktrees, .duplicates, .largeFiles, .apps, .compress])
    }

    // MARK: Hand-off selection

    private struct Item { let id: String; let path: String }

    /// Clean on a Disk row must only reach items at or under that folder, not siblings that
    /// share its name as a prefix, and not items ticked elsewhere.
    func testHandoffNarrowsSelectionToFolder() {
        let items = [
            Item(id: "a", path: "/u/code"),
            Item(id: "b", path: "/u/code/web/node_modules"),
            Item(id: "c", path: "/u/code-archive/old"),
            Item(id: "d", path: "/u/Library/Caches/x"),
            Item(id: "e", path: "/u/code/api/.build"),
        ]
        let ticked: Set<String> = ["a", "b", "c", "d"]
        let narrowed = DiskFindings.narrow(ticked, items, to: "/u/code", id: \.id, path: \.path)
        XCTAssertEqual(narrowed, ["a", "b"], "unticked e stays unticked; c and d are dropped")
        XCTAssertEqual(DiskFindings.narrow(ticked, items, to: "/u/code/", id: \.id, path: \.path), ["a", "b"])
        XCTAssertEqual(DiskFindings.narrow(ticked, items, to: "/u/Movies", id: \.id, path: \.path), [])
    }

    func testHiddenSelectionNote() {
        XCTAssertNil(hiddenSelectionNote(0))
        XCTAssertEqual(hiddenSelectionNote(1), "1 selected item isn't shown")
        XCTAssertEqual(hiddenSelectionNote(3), "3 selected items aren't shown")
    }

    /// The sorted lookup finds the folder itself and everything under it, and skips siblings
    /// that sort in between ("code-x", "code.x" come before "code/").
    func testEntriesUnderFolderUsesPrefix() {
        let f = DiskFindings(entries: [
            E(kind: .largeFile, path: "/u/code/z.bin", bytes: 1),
            E(kind: .largeFile, path: "/u/code-x/a", bytes: 1),
            E(kind: .largeFile, path: "/u/code", bytes: 1),
            E(kind: .largeFile, path: "/u/code.old/a", bytes: 1),
            E(kind: .largeFile, path: "/u/code/a/b", bytes: 1),
            E(kind: .largeFile, path: "/u/codex", bytes: 1),
            E(kind: .largeFile, path: "/u/Movies/a", bytes: 1),
        ])
        XCTAssertEqual(Set(f.entries(under: "/u/code").map(\.path)), ["/u/code", "/u/code/z.bin", "/u/code/a/b"])
        XCTAssertEqual(f.entries(under: "/u/nothing").count, 0)
        XCTAssertEqual(f.entries(under: "/u").count, 7)
    }
}

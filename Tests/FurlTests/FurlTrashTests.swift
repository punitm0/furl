import XCTest
@testable import Furl

/// "Empty Furl's items" deletes for good, so it may only ever touch an item that is still exactly
/// what Furl put in the Trash.
final class FurlTrashTests: XCTestCase {
    private var dir: TempDir!
    private var trash: String!
    private var folders: FurlTrash.Folders!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = try TempDir()
        trash = dir.file("Trash")
        try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        folders = FurlTrash.Folders(home: dir.path, uid: getuid(), testRoots: [trash])
    }

    override func tearDown() { dir = nil }

    // MARK: - Helpers

    @discardableResult
    private func put(_ name: String, _ contents: String = "hello") throws -> String {
        let path = (trash as NSString).appendingPathComponent(name)
        try contents.write(toFile: path, atomically: false, encoding: .utf8)
        return path
    }

    /// What Furl records right after moving an item to the Trash.
    private func record(_ path: String) -> TrashLedgerEntry {
        TrashLedgerEntry(originalPath: "/somewhere/\((path as NSString).lastPathComponent)", trashPath: path,
                         date: Date(), fileID: DeletionService.fileID(path),
                         bytes: FileSizeHelper.directorySize(at: URL(fileURLWithPath: path)),
                         stamp: CleanupStamp.read(path))
    }

    private func check(_ entry: TrashLedgerEntry, deep: Bool = true) -> FurlTrash.Check {
        FurlTrash.check(entry, deep: deep, folders: folders)
    }

    private func setModified(_ path: String, _ date: Date?) throws {
        guard let date else { return }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }

    // MARK: - Matching

    func testUnchangedItemMatches() throws {
        let entry = record(try put("cache.db"))
        XCTAssertEqual(check(entry), .matches)
        XCTAssertEqual(check(entry, deep: false), .matches)
    }

    func testAlreadyGoneIsSkipped() throws {
        let path = try put("cache.db")
        let entry = record(path)
        try fm.removeItem(atPath: path)
        XCTAssertEqual(check(entry), .gone)
    }

    func testRenamedIsSkipped() throws {
        let path = try put("cache.db")
        let entry = record(path)
        try fm.moveItem(atPath: path, toPath: (trash as NSString).appendingPathComponent("cache 2.db"))
        XCTAssertEqual(check(entry), .gone)
    }

    func testSameNameDifferentFileIsSkipped() throws {
        let path = try put("cache.db", "hello")
        let entry = record(path)
        try fm.removeItem(atPath: path)
        // Finder reuses Trash names: same name, same contents, same date, but another file.
        try put("cache.db", "hello")
        try setModified(path, entry.stamp?.modified)
        XCTAssertEqual(check(entry), .changed)
    }

    func testSizeChangedWithSameDateIsSkipped() throws {
        let path = try put("cache.db", "hello")
        let entry = record(path)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 1, count: 8192))
        try handle.close()
        try setModified(path, entry.stamp?.modified)
        XCTAssertEqual(check(entry), .changed)
    }

    func testDateChangedIsSkipped() throws {
        let path = try put("cache.db")
        let entry = record(path)
        try setModified(path, Date(timeIntervalSinceNow: -86_400))
        XCTAssertEqual(check(entry), .changed)
    }

    func testFolderChangedDeepInsideIsSkipped() throws {
        let folder = (trash as NSString).appendingPathComponent("DerivedData")
        let inner = (folder as NSString).appendingPathComponent("a/b")
        try fm.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try "x".write(toFile: (inner as NSString).appendingPathComponent("f"), atomically: false, encoding: .utf8)
        let entry = record(folder)
        XCTAssertEqual(check(entry), .matches)
        // The folder's own date doesn't change when something deep inside does; the size does.
        try String(repeating: "y", count: 50_000)
            .write(toFile: (inner as NSString).appendingPathComponent("g"), atomically: false, encoding: .utf8)
        XCTAssertEqual(check(entry, deep: false), .matches)
        XCTAssertEqual(check(entry), .changed)
    }

    func testReplacedBySymlinkIsSkipped() throws {
        let path = try put("cache.db")
        let entry = record(path)
        let elsewhere = dir.file("precious.db")
        try "hello".write(toFile: elsewhere, atomically: false, encoding: .utf8)
        try fm.removeItem(atPath: path)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: elsewhere)
        XCTAssertEqual(check(entry), .changed)
    }

    func testOldRecordWithoutStampIsNeverDeleted() throws {
        let path = try put("cache.db")
        let old = TrashLedgerEntry(originalPath: "/x/cache.db", trashPath: path, date: Date(),
                                   fileID: DeletionService.fileID(path), bytes: 5)
        XCTAssertEqual(check(old), .unconfirmable)
        let outcome = FurlTrash.empty([old], folders: folders)
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertTrue(exists(path))
    }

    func testPathOutsideTheTrashIsRefused() throws {
        let outside = dir.file("outside.db")
        try "hello".write(toFile: outside, atomically: false, encoding: .utf8)
        let entry = record(outside)
        XCTAssertEqual(check(entry), .unconfirmable)
        // Nested inside the Trash, or reached through "..", doesn't count either.
        let nested = (trash as NSString).appendingPathComponent("sub")
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let inner = (nested as NSString).appendingPathComponent("f")
        try "x".write(toFile: inner, atomically: false, encoding: .utf8)
        XCTAssertEqual(check(record(inner)), .unconfirmable)
        let dotted = TrashLedgerEntry(originalPath: "/x", trashPath: trash + "/../outside.db", date: Date(),
                                      fileID: entry.fileID, bytes: entry.bytes, stamp: entry.stamp)
        XCTAssertEqual(check(dotted), .unconfirmable)
        XCTAssertEqual(FurlTrash.empty([entry, dotted], folders: folders).deleted.count, 0)
        XCTAssertTrue(exists(outside))
    }

    func testTrashFolderThatIsASymlinkIsRefused() throws {
        let real = dir.file("Real")
        try fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = dir.file("LinkedTrash")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: real)
        let path = (link as NSString).appendingPathComponent("f")
        try "x".write(toFile: path, atomically: false, encoding: .utf8)
        let linked = FurlTrash.Folders(home: dir.path, uid: getuid(), testRoots: [link])
        XCTAssertEqual(FurlTrash.check(record(path), deep: true, folders: linked), .unconfirmable)
    }

    func testSystemFoldersOnlyAllowHomeTrashAndOwnVolumeTrash() {
        let system = FurlTrash.Folders(home: "/nonexistent-home", uid: 501)
        XCTAssertFalse(system.isTrashFolder("/nonexistent-home/Documents"))
        XCTAssertFalse(system.isTrashFolder("/Volumes/X/.Trashes/502"))
        XCTAssertFalse(system.isTrashFolder("/Volumes/X/.Trashes"))
        XCTAssertFalse(system.isTrashFolder("/Volumes/X/sub/.Trashes/501"))
        XCTAssertFalse(system.isTrashFolder("/private/tmp"))
    }

    // MARK: - Emptying

    func testEmptyDeletesOnlyMatchingItemsAndNeverTheUsersOwn() throws {
        let keep = try put("mine.txt", "the user's own")            // not recorded: never touched
        let ours = try put("cache.db")
        let changed = try put("edited.db", "v1")
        let gone = try put("gone.db")
        let entries = [record(ours), record(changed), record(gone)]
        try "v2 is longer".write(toFile: changed, atomically: false, encoding: .utf8)
        try fm.removeItem(atPath: gone)

        let outcome = FurlTrash.empty(entries, folders: folders)

        XCTAssertEqual(outcome.deleted.map(\.trashPath), [ours])
        XCTAssertEqual(outcome.bytes, entries[0].bytes)
        XCTAssertFalse(exists(ours))
        XCTAssertTrue(exists(changed))
        XCTAssertTrue(exists(keep))
        XCTAssertEqual(Set(outcome.skipped.map(\.entry.trashPath)), [changed, gone])
        XCTAssertEqual(outcome.skipped.first { $0.entry.trashPath == gone }?.check, .gone)
        XCTAssertEqual(outcome.skipped.first { $0.entry.trashPath == changed }?.check, .changed)
    }

    func testItemSwappedRightBeforeRemovalIsSkipped() throws {
        let path = try put("cache.db")
        let entry = record(path)
        let outcome = FurlTrash.empty([entry], folders: folders) { _ in
            // Something replaces it between the full check and the removal.
            try? self.fm.removeItem(atPath: path)
            try? "other".write(toFile: path, atomically: false, encoding: .utf8)
        }
        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertTrue(exists(path))
    }

    func testSymlinkIsRemovedButItsTargetIsKept() throws {
        let target = dir.file("target")
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "keep".write(toFile: (target as NSString).appendingPathComponent("f"), atomically: false, encoding: .utf8)
        let link = (trash as NSString).appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        let entry = record(link)
        XCTAssertEqual(entry.stamp?.kind, .symlink)

        let outcome = FurlTrash.empty([entry], folders: folders)
        XCTAssertEqual(outcome.deleted.count, 1)
        XCTAssertFalse(exists(link))
        XCTAssertTrue(exists((target as NSString).appendingPathComponent("f")))
    }

    func testFolderContainingSymlinkDoesNotFollowIt() throws {
        let target = dir.file("outside")
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        let precious = (target as NSString).appendingPathComponent("precious")
        try "keep".write(toFile: precious, atomically: false, encoding: .utf8)
        let folder = (trash as NSString).appendingPathComponent("node_modules")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("pkg"), withDestinationPath: target)

        let outcome = FurlTrash.empty([record(folder)], folders: folders)
        XCTAssertEqual(outcome.deleted.count, 1)
        XCTAssertFalse(exists(folder))
        XCTAssertTrue(exists(precious))
    }

    // MARK: - Confirm

    func testPlanCountsWhatNoLongerMatches() throws {
        let a = record(try put("a", "aaaa"))
        let b = record(try put("b", "bbbbbbbb"))
        let c = record(try put("c"))
        try fm.removeItem(atPath: c.trashPath)
        let legacy = TrashLedgerEntry(originalPath: "/x", trashPath: trash + "/legacy", date: Date(), bytes: 9)

        let plan = FurlTrashPlan.make([a, b, c, a, legacy], folders: folders)
        XCTAssertEqual(plan.total, 3)                      // duplicates and pre-1.4.0 records don't count
        XCTAssertEqual(plan.matched.map(\.trashPath), [a.trashPath, b.trashPath])
        XCTAssertEqual(plan.notMatchedCount, 1)
        XCTAssertTrue(plan.isPartial)
        XCTAssertEqual(plan.matchedBytes, (a.bytes ?? 0) + (b.bytes ?? 0))
    }

    func testConfirmTextSaysPermanentAndNamesTheSize() {
        let entry = TrashLedgerEntry(originalPath: "/x", trashPath: "/t/x", date: Date(), fileID: 1, bytes: 2_000_000,
                                     stamp: CleanupStamp(kind: .file, modified: nil))
        let full = DashboardView.emptyConfirmMessage(FurlTrashPlan(total: 1, matched: [entry]))
        XCTAssertTrue(full.contains("1 item, \(FileSizeHelper.formatBytes(2_000_000)), will be deleted for good"))
        XCTAssertTrue(full.contains("can’t be undone"))
        let partial = DashboardView.emptyConfirmMessage(FurlTrashPlan(total: 3, matched: [entry]))
        XCTAssertTrue(partial.hasPrefix("2 of 3 were put back, renamed or already emptied."))
        XCTAssertTrue(partial.contains("delete the 1 it can still match: \(FileSizeHelper.formatBytes(2_000_000)), for good"))
    }

    // MARK: - Record

    func testTrashingRecordsStampFileIDAndSize() throws {
        // A real move to the Trash, the way every cleanup does it, then straight back out again.
        let path = dir.file("furl-trash-test-\(UUID().uuidString).txt")
        try "hello".write(toFile: path, atomically: false, encoding: .utf8)
        let result = DeletionService.deletePaths([path], mode: .moveToTrash)
        let item = try XCTUnwrap(result.trashedItems.first)
        defer { try? fm.removeItem(atPath: item.trashPath) }
        XCTAssertNotNil(item.fileID)
        XCTAssertEqual(item.stamp?.kind, .file)
        XCTAssertNotNil(item.stamp?.modified)
        XCTAssertEqual(item.sizeBytes, FileSizeHelper.directorySize(at: URL(fileURLWithPath: item.trashPath)))
        let entry = TrashLedgerEntry(originalPath: item.originalPath, trashPath: item.trashPath, date: Date(),
                                     fileID: item.fileID, bytes: item.sizeBytes, stamp: item.stamp)
        XCTAssertEqual(FurlTrash.check(entry, deep: true), .matches)
    }
}

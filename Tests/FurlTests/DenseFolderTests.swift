import CoreServices
import XCTest
@testable import Furl

/// Huge flat folders (browser caches) keep a per-file table, so a file-level FSEvents change re-reads only
/// the files it names. Every patched index must equal a fresh walk, and anything a delta can't express
/// exactly must fall back to reading the folder.
final class DenseFolderTests: XCTestCase {
    private var root = ""
    private var flat: String { root + "/cache/Cache_Data" }
    private let fm = FileManager.default
    private var config: ScanEngine.Configuration {
        var config = ScanEngine.Configuration(root: root)
        config.denseMinFiles = 8
        return config
    }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "furl-dense-\(UUID().uuidString)"
        for i in 0..<40 { try makeFile("cache/Cache_Data/f_\(i)", bytes: 100 + i * 997) }
        try makeFile("cache/Cache_Data/big_0", bytes: 200_000) // kept as a file record (≥ 32 KB)
        try makeFile("cache/Cache_Data/index-dir/the-real-index", bytes: 3_000)
        try makeFile("cache/small/a", bytes: 10)
        try makeFile("cache/small/b", bytes: 20)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    // MARK: Building

    func testOnlyHugeSelfContainedFoldersGetATable() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        let flatID = try XCTUnwrap(index.dirID(forPath: flat))
        let table = try XCTUnwrap(index.denseEntries(ofDir: flatID))
        XCTAssertEqual(table.count, 41, "every file, however small")
        XCTAssertNil(index.denseEntries(ofDir: try XCTUnwrap(index.dirID(forPath: root + "/cache/small"))))
        XCTAssertNil(index.denseEntries(ofDir: try XCTUnwrap(index.dirID(forPath: flat + "/index-dir"))))
        let record = index.dirs[Int(flatID)]
        XCTAssertEqual(record.ownFiles, UInt64(table.count))
        XCTAssertEqual(record.ownReclaimable, table.reduce(0) { $0 + $1.reclaimableSize })
        XCTAssertEqual(record.ownLogical, table.reduce(0) { $0 + $1.logicalSize })

        // With the default threshold this small folder has none.
        let plain = try await ScanEngine.buildIndex(root: root)
        XCTAssertTrue(plain.denseEntries.isEmpty)
    }

    func testAHardLinkKeepsTheFolderFromGettingATable() async throws {
        try fm.linkItem(atPath: flat + "/f_1", toPath: root + "/cache/small/link")
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        XCTAssertNil(index.denseEntries(ofDir: try XCTUnwrap(index.dirID(forPath: flat))))
    }

    func testSaveAndLoadKeepsTables() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        let store = IndexStore(directory: URL(fileURLWithPath: root + "-store"))
        defer { try? fm.removeItem(atPath: root + "-store") }
        try store.save(index)
        let loaded = try XCTUnwrap(store.load(root: index.rootPath))
        XCTAssertEqual(table(loaded), table(index))
        XCTAssertFalse(table(loaded).isEmpty)

        // A crafted table count is rejected, not trusted. Header: 4 × UInt32, then dirCount, hiddenDirCount,
        // fileCount, nameBytes, denseCount (UInt64 each).
        let url = store.fileURL(forRoot: index.rootPath)
        let good = try Data(contentsOf: url)
        for value in [UInt64.max, UInt64(Int.max) / 64, 1] {
            var bad = good
            withUnsafeBytes(of: value.littleEndian) { bad.replaceSubrange(48..<56, with: $0) }
            try bad.write(to: url)
            XCTAssertNil(store.load(root: index.rootPath), "denseCount \(value)")
        }
    }

    // MARK: File-level patches

    func testChangedAddedAndDeletedFilesArePatchedExactly() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try makeFile("cache/Cache_Data/f_3", bytes: 50_000)   // grows past the keep size
        try makeFile("cache/Cache_Data/big_0", bytes: 1_000)  // shrinks below it
        try makeFile("cache/Cache_Data/new_1", bytes: 7_777)
        try fm.removeItem(atPath: flat + "/f_7")
        try fm.moveItem(atPath: flat + "/f_9", toPath: flat + "/todelete_f_9")
        let changed = ["f_3", "big_0", "new_1", "f_7", "f_9", "todelete_f_9"].map { flat + "/" + $0 }

        let (patched, kind, details) = try await apply(files: changed, to: index)
        XCTAssertEqual(kind, .incremental(shallow: 0, deep: 0), "no folder read")
        XCTAssertEqual(details.patchedFolders, [flat: changed.count])
        let fresh = try await ScanEngine.buildIndex(root: root, configuration: config)
        assertSame(patched, fresh)
        XCTAssertNotNil(patched.reclaimableSize(ofPath: flat + "/f_3"), "now kept")
        XCTAssertNil(patched.reclaimableSize(ofPath: flat + "/big_0"), "no longer kept")

        // A second round on the patched index, then a save/load in between.
        let store = IndexStore(directory: URL(fileURLWithPath: root + "-store"))
        defer { try? fm.removeItem(atPath: root + "-store") }
        try store.save(patched)
        let loaded = try XCTUnwrap(store.load(root: patched.rootPath))
        try fm.removeItem(atPath: flat + "/f_3")
        try makeFile("cache/Cache_Data/f_11", bytes: 1)
        let (again, _, _) = try await apply(files: [flat + "/f_3", flat + "/f_11"], to: loaded)
        assertSame(again, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testAFileNamedButUnchangedLeavesTotalsAlone() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        let (patched, _, details) = try await apply(files: [flat + "/f_2", flat + "/never-existed"], to: index)
        XCTAssertEqual(details.patchedFolders[flat], 2)
        assertSame(patched, index)
    }

    func testFilesInFoldersWithoutATableReadTheFolder() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try makeFile("cache/small/c", bytes: 5_000)
        let (patched, kind, details) = try await apply(files: [root + "/cache/small/c"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertTrue(details.patchedFolders.isEmpty)
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testANewSubFolderFallsBackToAFolderRead() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try makeFile("cache/Cache_Data/f_5", bytes: 9_000)
        try makeFile("cache/Cache_Data/newdir/x", bytes: 4_000)
        let (patched, kind, details) = try await apply(files: [flat + "/f_5", flat + "/newdir"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertTrue(details.patchedFolders.isEmpty)
        let fresh = try await ScanEngine.buildIndex(root: root, configuration: config)
        assertSame(patched, fresh)
        XCTAssertNotNil(patched.dirID(forPath: flat + "/newdir"))
    }

    func testAHardLinkFallsBackAndDropsTheTable() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        // Inside the folder: f_1's own size changes too (a link elsewhere has no event for its folder, with
        // folder-level events as well, so that gap is unchanged and not tested here).
        try fm.linkItem(atPath: flat + "/f_1", toPath: flat + "/linked")
        let (patched, kind, _) = try await apply(files: [flat + "/linked"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertNil(patched.denseEntries(ofDir: try XCTUnwrap(patched.dirID(forPath: flat))))
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testACloneFallsBackAndDropsTheTable() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        guard clonefile(flat + "/big_0", flat + "/clone_0", 0) == 0 else { throw XCTSkip("volume can't clone") }
        let (patched, kind, _) = try await apply(files: [flat + "/clone_0"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertNil(patched.denseEntries(ofDir: try XCTUnwrap(patched.dirID(forPath: flat))))
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testManyChangedFilesReadTheFolderInstead() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        let names = (0..<300).map { "burst_\($0)" }
        for name in names { try makeFile("cache/Cache_Data/" + name, bytes: 300) }
        let (patched, kind, details) = try await apply(files: names.map { flat + "/" + $0 }, to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertTrue(details.patchedFolders.isEmpty)
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testAFolderReadReplacesTheTable() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try makeFile("cache/Cache_Data/f_0", bytes: 12_345)
        let (patched, kind, _) = try await apply(shallow: [flat], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    func testDeletingTheFolderDropsItsTable() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try fm.removeItem(atPath: flat)
        let (patched, _, _) = try await apply(files: [flat + "/f_1"], shallow: [root + "/cache"], to: index)
        XCTAssertTrue(patched.denseEntries.isEmpty)
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    /// On case-insensitive APFS "f_3" still resolves after f_3 → F_3; it must not be counted twice.
    func testCaseOnlyRenameIsNotCountedTwice() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try fm.moveItem(atPath: flat + "/f_3", toPath: flat + "/F_3")
        let (patched, _, _) = try await apply(files: [flat + "/f_3", flat + "/F_3"], to: index)
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
    }

    /// Chromium resets a cache by renaming Cache_Data away, deleting it and creating a new one. The new
    /// folder must not inherit the old record, table or kept files just because the name matches.
    func testFolderReplacedUnderTheSameNameStartsFresh() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        try fm.moveItem(atPath: flat, toPath: root + "/cache/old_Cache_Data")
        try fm.removeItem(atPath: root + "/cache/old_Cache_Data")
        try makeFile("cache/Cache_Data/n_1", bytes: 500)
        // Folder events map to the parent; the file event is kept by path.
        let (patched, _, _) = try await apply(files: [flat + "/n_1"], shallow: [root + "/cache"], to: index)
        assertSame(patched, try await ScanEngine.buildIndex(root: root, configuration: config))
        XCTAssertEqual(patched.dirs[Int(try XCTUnwrap(patched.dirID(forPath: flat)))].ownFiles, 1)
    }

    /// The weekly full walk (`maxIndexAge`) must not be postponed by every incremental save.
    func testPatchesKeepTheFullWalkDate() async throws {
        let built = try await ScanEngine.buildIndex(root: root, configuration: config)
        let old = Date(timeIntervalSinceNow: -6 * 24 * 3600)
        let index = IndexBuilder(built).finish(eventID: built.eventID, fseventsUUID: built.fseventsUUID, configHash: built.configHash, builtAt: old)
        try makeFile("cache/Cache_Data/f_1", bytes: 4_321)
        try makeFile("cache/small/a", bytes: 99)
        let (patched, _, details) = try await apply(files: [flat + "/f_1", root + "/cache/small/a"], to: index)
        XCTAssertEqual(details.patchedFolders.count, 1)
        XCTAssertEqual(patched.builtAt, old)
    }

    /// 100 k file events (a build) must be grouped by folder, not resolved one by one.
    func testManyFileEventsAreGroupedByFolder() async throws {
        let index = try await ScanEngine.buildIndex(root: root, configuration: config)
        var changes = ChangeSet()
        for folder in 0..<200 { for file in 0..<500 { changes.files.insert(root + "/cache/small/gen\(folder)/f\(file)") } }
        let started = Date()
        let (updated, kind, _) = try await ScanEngine.applyReturningDetails(
            changes, to: index, newEventID: index.eventID, configuration: config, progress: nil
        )
        XCTAssertNotNil(updated)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0), "all resolve to cache/small")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "generous bound; ~0.1 s in release")
    }

    // MARK: Event mapping

    func testFileLevelEventsMapLikeFolderEvents() {
        func changes(_ path: String, _ flags: Int) -> ChangeSet {
            var set = ChangeSet()
            set.add(path: path, flags: FSEventStreamEventFlags(flags), id: 1, roots: ["/r"])
            return set
        }
        let file = kFSEventStreamEventFlagItemIsFile
        XCTAssertEqual(changes("/r/a/f", file | kFSEventStreamEventFlagItemModified).files, ["/r/a/f"])
        XCTAssertEqual(changes("/r/a/f", file | kFSEventStreamEventFlagItemCloned).shallow, ["/r/a"], "a clone is a folder change")
        XCTAssertEqual(changes("/r/a/d", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated).shallow, ["/r/a"])
        XCTAssertEqual(changes("/r/a/d", file | kFSEventStreamEventFlagItemIsDir).shallow, ["/r/a"], "file became a folder")
        XCTAssertEqual(changes("/r/a/l", kFSEventStreamEventFlagItemIsSymlink).shallow, ["/r/a"])
        XCTAssertEqual(changes("/r/a", 0).shallow, ["/r/a"], "folder-level event")
        XCTAssertEqual(changes("/r", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemInodeMetaMod).shallow, ["/r"])
        XCTAssertEqual(changes("/r/a", kFSEventStreamEventFlagMustScanSubDirs).deep, ["/r/a"])
        XCTAssertTrue(changes("/r/a/f", file).files.count == 1 && !changes("/r/a/f", file).isEmpty)
    }

    // MARK: Helpers

    private func makeFile(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(repeating: 7, count: bytes)))
    }

    private func apply(files: [String] = [], shallow: [String] = [], to index: FileIndex) async throws
        -> (FileIndex, ScanEngine.Report.Kind, ScanEngine.PatchDetails) {
        var changes = ChangeSet()
        changes.files = Set(files)
        changes.shallow = Set(shallow)
        let (updated, kind, details) = try await ScanEngine.applyReturningDetails(
            changes, to: index, newEventID: index.eventID, configuration: config, progress: nil
        )
        return (try XCTUnwrap(updated), kind, details)
    }

    /// Table entries by path with every field.
    private func table(_ index: FileIndex) -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for entry in index.denseEntries {
            result[index.path(ofDir: entry.dir) + "/" + index.name(entry.name)] = [
                Int64(entry.linkCount), entry.logicalSize, entry.allocatedSize, entry.privateSize, entry.modified,
            ]
        }
        return result
    }

    private func snapshot(_ index: FileIndex) -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for id in 0..<index.dirCount {
            let d = index.record(Int32(id))
            result[index.path(ofDir: Int32(id))] = [
                Int64(d.ownFiles), d.ownLogical, d.ownAllocated, d.ownReclaimable, d.ownNewestModified,
                Int64(d.totalFiles), Int64(d.totalDirs), d.totalLogical, d.totalAllocated, d.totalReclaimable,
                d.newestModified, Int64(d.flags.intersection([.incomplete, .unreadable]).rawValue), Int64(d.modeRaw),
            ]
        }
        return result
    }

    private func assertSame(_ a: FileIndex, _ b: FileIndex, file: StaticString = #filePath, line: UInt = #line) {
        let sa = snapshot(a), sb = snapshot(b)
        XCTAssertEqual(Set(sa.keys), Set(sb.keys), file: file, line: line)
        for (path, values) in sa where sb[path] != values {
            XCTFail("\(path): \(values) vs \(sb[path] ?? [])", file: file, line: line)
        }
        func kept(_ i: FileIndex) -> [String] {
            i.files.map { "\(i.path(of: $0)) \($0.logicalSize) \($0.allocatedSize) \($0.privateSize) \($0.modified)" }.sorted()
        }
        XCTAssertEqual(kept(a), kept(b), file: file, line: line)
        XCTAssertEqual(table(a), table(b), "per-file tables", file: file, line: line)
    }
}

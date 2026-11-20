import XCTest
@testable import Furl

/// Size-only folders keep hidden sub-folder records two levels deep, so an incremental update re-sizes a
/// small sub-tree instead of the whole folder. None of that may show through the public queries.
final class SizeOnlySubrecordTests: XCTestCase {
    private var root = ""
    private var nm: String { root + "/proj/node_modules" }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "furl-sizeonly-\(UUID().uuidString)"
        // node_modules = depth 0, a = 1, b = 2 (deepest kept), c = 3, d = 4.
        try makeFile("proj/package.json", bytes: 100)
        try makeFile("proj/big.bin", bytes: 64 * 1024)
        try makeFile("proj/node_modules/top.js", bytes: 1_000)
        try makeFile("proj/node_modules/a/a.js", bytes: 2_000)
        try makeFile("proj/node_modules/a/b/b.js", bytes: 3_000)
        try makeFile("proj/node_modules/a/b/c/c.js", bytes: 4_000)
        try makeFile("proj/node_modules/a/b/c/d/d.js", bytes: 5_000)
        try makeFile("proj/node_modules/a/b/c/d/e/e.js", bytes: 6_000)
        try makeFile("proj/node_modules/a/b2/x.js", bytes: 7_000)
        try makeFile("proj/node_modules/foo/node_modules/bar/index.js", bytes: 8_000)
        try makeFile("proj/node_modules/foo/node_modules/bar/lib/deep/more.js", bytes: 9_000)
        try fm.createDirectory(atPath: nm + "/a/b/c/empty", withIntermediateDirectories: true)
        // Unreadable folder 4 levels down: today it marks node_modules incomplete; it must still.
        try makeFile("proj/node_modules/a/b/c/locked/secret.js", bytes: 1_000)
        chmod(nm + "/a/b/c/locked", 0)
    }

    override func tearDownWithError() throws {
        chmod(nm + "/a/b/c/locked", 0o755)
        try? fm.removeItem(atPath: root)
    }

    // MARK: Totals and hiding

    func testTotalsMatchAFullCountAndRecordsStayHidden() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        let nmID = try XCTUnwrap(index.dirID(forPath: nm))
        let record = index.dirs[Int(nmID)]

        // Same totals the size-only folder had when its whole subtree was folded into it.
        let brute = bruteForce(nm)
        XCTAssertEqual(record.totalFiles, brute.files)
        XCTAssertEqual(record.totalDirs, brute.dirs)
        XCTAssertEqual(record.totalLogical, brute.logical)
        XCTAssertEqual(record.totalReclaimable, FileSizeHelper.directorySize(at: URL(fileURLWithPath: nm)))
        XCTAssertTrue(record.flags.contains(.incomplete), "the unreadable folder inside still marks it incomplete")
        XCTAssertTrue(index.dirs[Int(FileIndex.rootID)].flags.contains(.incomplete))

        // The hidden records exist (node_modules → a → b, …) but nothing public sees them.
        XCTAssertFalse(index.hiddenDirs.isEmpty)
        XCTAssertTrue(index.children(ofDir: nmID).isEmpty)
        XCTAssertTrue(index.files(inDir: nmID).isEmpty)
        XCTAssertNil(index.dirID(forPath: nm + "/a"))
        XCTAssertNil(index.dirID(forPath: nm + "/a/b"))
        XCTAssertNil(index.reclaimableSize(ofPath: nm + "/a"))
        XCTAssertEqual(index.directories(named: ["node_modules"]).map { index.path(ofDir: $0) }, [nm])
        XCTAssertTrue(index.directories(named: ["a", "b", "c", "bar"]).isEmpty)
        XCTAssertEqual(Set((0..<index.dirs.count).map { index.path(ofDir: Int32($0)) }), [root, root + "/proj", nm])
        XCTAssertFalse(index.largeFiles(minBytes: 0).contains { index.path(of: $0).hasPrefix(nm + "/") })
        XCTAssertEqual(ProjectRootDiscovery.discover(in: index), [root + "/proj"])

        // Visitors only see the visible folders.
        final class Counter: IndexVisitor { var dirs = 0; func visit(dir id: Int32, record: DirRecord, in index: FileIndex) { dirs += 1 } }
        let counter = Counter()
        index.accept([counter])
        XCTAssertEqual(counter.dirs, 3)

        // Kept to two levels below node_modules: c, d, e are folded into b.
        XCTAssertNotNil(hiddenID(index, nm + "/a/b"))
        XCTAssertNil(hiddenID(index, nm + "/a/b/c"))
        let b = index.record(try XCTUnwrap(hiddenID(index, nm + "/a/b")))
        XCTAssertEqual(b.totalFiles, bruteForce(nm + "/a/b").files)
        XCTAssertEqual(b.totalDirs, bruteForce(nm + "/a/b").dirs)
    }

    func testSaveAndLoadKeepsHiddenRecords() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        let store = IndexStore(directory: URL(fileURLWithPath: root + "-store"))
        defer { try? fm.removeItem(atPath: root + "-store") }
        try store.save(index)
        let loaded = try XCTUnwrap(store.load(root: index.rootPath))
        XCTAssertEqual(loaded.dirs.count, index.dirs.count)
        XCTAssertEqual(loaded.hiddenDirs.count, index.hiddenDirs.count)
        assertSame(loaded, index)
    }

    /// Snapshots add up `ownAllocated` per visible folder; a size-only folder's own stats no longer hold
    /// its subtree, so it must count its total instead.
    func testSnapshotCategoryTotalsCountWholeSizeOnlyFolders() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        let nmRecord = index.dirs[Int(try XCTUnwrap(index.dirID(forPath: nm)))]
        let disk = DiskUsageInfo(totalBytes: 1 << 40, availableBytes: 1 << 39, usedBytes: 1 << 39, volumeName: "Test")
        let snapshot = SnapshotBuilder.make(from: index, disk: disk)
        XCTAssertGreaterThan(nmRecord.totalAllocated, nmRecord.ownAllocated, "fixture has files below node_modules")
        XCTAssertEqual(snapshot.categoryTotal(.developer), nmRecord.totalAllocated)
        XCTAssertEqual(snapshot.categoryTotals.reduce(0, +), index.root.totalAllocated)
    }

    /// A damaged header must make `load` return nil, not trap on an overflowing size computation.
    func testCraftedCountsAreRejected() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        let store = IndexStore(directory: URL(fileURLWithPath: root + "-store"))
        defer { try? fm.removeItem(atPath: root + "-store") }
        try store.save(index)
        let url = store.fileURL(forRoot: index.rootPath)
        let good = try Data(contentsOf: url)
        // Header: magic, version, dirStride, fileStride (UInt32 each), then dirCount, hiddenDirCount,
        // fileCount, nameBytes (UInt64 each).
        for offset in [16, 24, 32, 40] {
            for value in [UInt64.max, UInt64(Int.max), UInt64(Int.max) / 64] {
                var bad = good
                withUnsafeBytes(of: value.littleEndian) { bad.replaceSubrange(offset..<offset + 8, with: $0) }
                try bad.write(to: url)
                XCTAssertNil(store.load(root: index.rootPath), "offset \(offset), value \(value)")
            }
        }
        try good.write(to: url)
        XCTAssertNotNil(store.load(root: index.rootPath))
    }

    // MARK: Incremental updates

    func testChangeThreeLevelsDownReSizesOnlyTheLeaf() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        try makeFile("proj/node_modules/a/b/c/c.js", bytes: 40_000)
        let (patched, kind, deep) = try await apply(shallow: [nm + "/a/b/c"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 0, deep: 1))
        XCTAssertEqual(deep, [nm + "/a/b"])
        assertSame(patched, try await ScanEngine.buildIndex(root: root))
    }

    func testChangeAtKeptLevelIsAShallowRead() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        try makeFile("proj/node_modules/a/a.js", bytes: 20_000)
        let (patched, kind, deep) = try await apply(shallow: [nm + "/a"], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 1, deep: 0))
        XCTAssertTrue(deep.isEmpty)
        assertSame(patched, try await ScanEngine.buildIndex(root: root))
    }

    func testAddingASubFolderMatchesAFreshWalk() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        try makeFile("proj/node_modules/a/new/x/y/z/n.js", bytes: 12_000)
        try makeFile("proj/node_modules/fresh/f.js", bytes: 500)
        let changed = [nm, nm + "/a", nm + "/a/new", nm + "/a/new/x", nm + "/a/new/x/y", nm + "/a/new/x/y/z", nm + "/fresh"]
        let (patched, kind, _) = try await apply(shallow: changed, to: index)
        XCTAssertEqual(kind, .incremental(shallow: 2, deep: 0))
        let fresh = try await ScanEngine.buildIndex(root: root)
        assertSame(patched, fresh)
        XCTAssertNotNil(hiddenID(patched, nm + "/a/new"))
        XCTAssertNil(hiddenID(patched, nm + "/a/new/x"), "re-pruned to two levels")
    }

    func testDeletingASubFolderMatchesAFreshWalk() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        try fm.removeItem(atPath: nm + "/a/b2")
        try fm.removeItem(atPath: nm + "/foo/node_modules/bar/lib")
        let (patched, _, _) = try await apply(shallow: [nm + "/a", nm + "/foo/node_modules/bar"], to: index)
        assertSame(patched, try await ScanEngine.buildIndex(root: root))
        XCTAssertNil(hiddenID(patched, nm + "/a/b2"))
    }

    func testDeepReWalkOfTheSizeOnlyFolderRePrunes() async throws {
        let index = try await ScanEngine.buildIndex(root: root)
        try makeFile("proj/node_modules/a/b/c/d/e/f/g.js", bytes: 3_000)
        let (patched, kind, deep) = try await apply(deep: [nm], to: index)
        XCTAssertEqual(kind, .incremental(shallow: 0, deep: 1))
        XCTAssertEqual(deep, [nm])
        assertSame(patched, try await ScanEngine.buildIndex(root: root))
    }

    // MARK: Helpers

    private func makeFile(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(repeating: 7, count: bytes)))
    }

    private func apply(shallow: [String] = [], deep: [String] = [], to index: FileIndex) async throws
        -> (FileIndex, ScanEngine.Report.Kind, [String]) {
        var changes = ChangeSet()
        changes.shallow = Set(shallow)
        changes.deep = Set(deep)
        let (updated, kind, deepPaths) = try await ScanEngine.applyReturningDeep(
            changes, to: index, newEventID: index.eventID, configuration: nil, progress: nil
        )
        return (try XCTUnwrap(updated), kind, deepPaths)
    }

    private func hiddenID(_ index: FileIndex, _ path: String) -> Int32? {
        (index.dirs.count..<index.dirCount).map(Int32.init).first { index.path(ofDir: $0) == path }
    }

    /// Every record (visible and hidden) by path, with the fields totals depend on.
    private func snapshot(_ index: FileIndex) -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        for id in 0..<index.dirCount {
            let d = index.record(Int32(id))
            result[index.path(ofDir: Int32(id)) + (id < index.dirs.count ? "" : " (hidden)")] = [
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
        XCTAssertEqual(a.files.map { a.path(of: $0) }.sorted(), b.files.map { b.path(of: $0) }.sorted(), file: file, line: line)
    }

    /// Independent count of what's under `path` (unreadable folders count as one folder, contents unknown).
    private func bruteForce(_ path: String) -> (files: UInt64, dirs: UInt64, logical: Int64) {
        var files: UInt64 = 0, dirs: UInt64 = 0, logical: Int64 = 0
        let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                       options: [], errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { dirs += 1 } else { files += 1; logical += Int64(values?.fileSize ?? 0) }
        }
        return (files, dirs, logical)
    }
}

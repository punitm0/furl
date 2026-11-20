// ScanBench — developer-only timing harness for Furl's scanners and the new ScanEngine.
// Build: swift build -c release --product ScanBench
// Run:   .build/release/ScanBench <command> [args]   (see `help`)
//
// It compiles the app's Services/ and Models/ through symlinks (Sources/ScanBench/Linked), so it times the
// exact code the app ships without editing the app target.

import Darwin
import Foundation

// MARK: - Helpers

func now() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

@discardableResult
func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Double) {
    let start = now()
    let value = try body()
    let elapsed = now() - start
    print(String(format: "  %-44@ %8.2f s", label as NSString, elapsed))
    return (value, elapsed)
}

func timeAsync<T>(_ label: String, _ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = now()
    let value = try await body()
    let elapsed = now() - start
    print(String(format: "  %-44@ %8.2f s", label as NSString, elapsed))
    return (value, elapsed)
}

func fmt(_ bytes: Int64) -> String { FileSizeHelper.formatBytes(bytes) }

let home = FileManager.default.homeDirectoryForCurrentUser.path

/// `sudo purge` flushes the unified buffer cache so the next run is "cold". Needs root; we just try.
func tryPurge() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    task.arguments = ["-n", "/usr/sbin/purge"]
    task.standardError = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    do { try task.run() } catch { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

func run(_ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func walk(_ root: String, width: Int = ParallelWalker.defaultWidth, progress: ScanProgress? = nil) async throws -> FileIndex {
    var config = ScanEngine.Configuration(root: root)
    config.width = width
    return try await ScanEngine.buildIndex(root: root, configuration: config, progress: progress)
}

// MARK: - Commands

/// Times every existing scanner as the app calls it.
func benchOld(passes: Int) async {
    let roots = WorktreeScanner.defaultSearchRoots()
    print("Project roots: \(roots)")
    for pass in 1...passes {
        print("\n== Old scanners, pass \(pass) ==")
        let (junk, _) = time("JunkScanner.scan") { JunkScanner.scan(projectRoots: roots, staleDays: 30) }
        print("     \(junk.count) items, \(fmt(junk.reduce(0) { $0 + $1.sizeBytes }))")
        let (large, _) = time("LargeFilesScanner.scan(100 MB)") { LargeFilesScanner.scan(minimumBytes: 100_000_000) }
        print("     \(large.count) files")
        let dupProgress = ScanProgress()
        let (dups, dupT) = time("DuplicateScanner.scan(1 MB)") {
            DuplicateScanner.scan(roots: DuplicateScanner.defaultRoots(), minimumBytes: 1_000_000, progress: dupProgress)
        }
        print("     \(dups.count) groups, \(dupProgress.items) entries listed (\(Int(Double(dupProgress.items) / dupT))/s incl. hashing)")
        let srProgress = ScanProgress()
        let (sr, srT) = time("SmartReviewScanner.scan") { SmartReviewScanner.scan(ignoredPaths: [], progress: srProgress) }
        print("     \(sr.count) items, \(srProgress.items) files considered (\(Int(Double(srProgress.items) / srT))/s)")
        let spProgress = ScanProgress()
        let (space, spT) = time("SpaceAnalyzer.scan(home)") { SpaceAnalyzer.scan(rootPath: home, progress: spProgress) }
        print("     \(fmt(space.sizeBytes)), \(space.itemCount) files, \(spProgress.items) entries (\(Int(Double(spProgress.items) / spT))/s)")
        let (wt, _) = time("WorktreeScanner.scan") { WorktreeScanner.scan(roots: roots) }
        print("     \(wt.count) worktrees")
        let (apps, _) = time("AppUninstallerService.scan") { AppUninstallerService.scan() }
        print("     \(apps.installedApps.count) apps, \(apps.orphanedGroups.count) orphan groups")
    }
}

/// Old `FileSizeHelper.directorySize` vs new walker on the same folders: time + byte totals.
func compare(paths: [String], width: Int) async throws {
    print("\n== directorySize (old) vs ScanEngine walk (new), width \(width) ==")
    print("| Folder | Files | Old time | New time | Speed-up | Old bytes | New bytes | Match |")
    print("|---|---:|---:|---:|---:|---:|---:|---|")
    for path in paths {
        // Warm both equally: run each twice, keep the second.
        _ = FileSizeHelper.directorySize(at: URL(fileURLWithPath: path))
        let t0 = now()
        let old = FileSizeHelper.directorySize(at: URL(fileURLWithPath: path))
        let oldT = now() - t0

        var config = ScanEngine.Configuration(root: path)
        config.width = width
        // Size the whole tree like directorySize does: nothing pruned, nothing skipped.
        config.policy.sizeOnlyNames = []
        config.policy.packagesAreSizeOnly = false
        _ = try await ScanEngine.buildIndex(root: path, configuration: config)
        let t1 = now()
        let index = try await ScanEngine.buildIndex(root: path, configuration: config)
        let newT = now() - t1
        let new = index.root.totalReclaimable
        let diff = abs(new - old)
        let match = diff == 0 ? "exact" : (Double(diff) / Double(max(old, 1)) < 0.001 ? "Δ \(diff) B" : "MISMATCH Δ \(diff) B")
        print(String(format: "| %@ | %llu | %.2f s | %.2f s | %.1f× | %lld | %lld | %@ |",
                     (path.replacingOccurrences(of: home, with: "~")) as NSString, index.root.totalFiles,
                     oldT, newT, oldT / max(newT, 0.0001), old, new, match as NSString))
    }
}

/// Builds a folder of APFS clones and hard links and checks the engine agrees with FileSizeHelper.
func cloneTest() async throws {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "scanbench-clones-\(getpid())"
    try? fm.removeItem(atPath: dir)
    try fm.createDirectory(atPath: dir + "/sub/deeper", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }

    // 8 MB original, 3 clones (one modified so it has private blocks), 2 hard links, small files, a symlink.
    let original = dir + "/original.bin"
    var bytes = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
    for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) }
    fm.createFile(atPath: original, contents: Data(bytes))
    _ = run(["cp", "-c", original, dir + "/clone1.bin"])
    _ = run(["cp", "-c", original, dir + "/sub/clone2.bin"])
    _ = run(["cp", "-c", original, dir + "/sub/deeper/clone3-modified.bin"])
    if let h = FileHandle(forWritingAtPath: dir + "/sub/deeper/clone3-modified.bin") {
        h.seek(toFileOffset: 0)
        h.write(Data(repeating: 0xAB, count: 1024 * 1024)) // 1 MB of private blocks
        try? h.close()
    }
    let linked = dir + "/linked.bin"
    fm.createFile(atPath: linked, contents: Data(repeating: 7, count: 2 * 1024 * 1024))
    try fm.linkItem(atPath: linked, toPath: dir + "/sub/hardlink-a.bin")
    try fm.linkItem(atPath: linked, toPath: dir + "/sub/deeper/hardlink-b.bin")
    for i in 0..<50 { fm.createFile(atPath: dir + "/sub/small\(i).txt", contents: Data(repeating: UInt8(i), count: 100 + i * 37)) }
    try fm.createSymbolicLink(atPath: dir + "/link-to-original", withDestinationPath: original)
    try fm.createDirectory(atPath: dir + "/Fake.app/Contents", withIntermediateDirectories: true)
    fm.createFile(atPath: dir + "/Fake.app/Contents/payload", contents: Data(repeating: 1, count: 300_000))
    sync()

    print("\n== Clone / hard-link test in \(dir) ==")
    print("| Path | FileSizeHelper.directorySize | ScanEngine reclaimable | Finder-style (allocated) | Match |")
    print("|---|---:|---:|---:|---|")
    let index = try await walk(dir)
    var allMatch = true
    for sub in ["", "/sub", "/sub/deeper", "/Fake.app"] {
        let path = dir + sub
        let old = FileSizeHelper.directorySize(at: URL(fileURLWithPath: path))
        let new = index.reclaimableSize(ofPath: path) ?? -1
        let alloc = index.dirID(forPath: path).map { index.dirs[Int($0)].totalAllocated } ?? -1
        allMatch = allMatch && old == new
        print("| \(sub.isEmpty ? "(root)" : sub) | \(old) | \(new) | \(alloc) | \(old == new ? "exact" : "MISMATCH") |")
    }
    // Per-file checks against FileSizeHelper.privateSize.
    for file in index.files {
        let path = index.path(of: file)
        let priv = FileSizeHelper.privateSize(atPath: path) ?? -1
        if priv != file.privateSize {
            allMatch = false
            print("  per-file mismatch \(path): getattrlist \(priv) vs bulk \(file.privateSize)")
        }
    }
    print(allMatch ? "  ✔ all totals and per-file private sizes match" : "  ✘ mismatches above")
}

/// Full walk at several widths to pick the default.
func widths(root: String, list: [Int]) async throws {
    print("\n== Width sweep on \(root) ==")
    _ = try await walk(root, width: 8) // warm
    for width in list {
        let t0 = now()
        let index = try await walk(root, width: width)
        let t = now() - t0
        print(String(format: "  width %2d: %.2f s  (%llu files, %llu dirs, %.0f files/s)", width, t,
                     index.root.totalFiles, index.root.totalDirs, Double(index.root.totalFiles) / t))
    }
}

/// One walk of home answering every feature, vs the old scanners.
func benchNew(root: String, width: Int, passes: Int) async throws {
    for pass in 1...passes {
        print("\n== ScanEngine full walk of \(root), width \(width), pass \(pass) ==")
        let progress = ScanProgress()
        let (index, t) = try await timeAsync("ScanEngine.buildIndex") { try await walk(root, width: width, progress: progress) }
        let r = index.root
        print("     \(r.totalFiles) files, \(r.totalDirs) dirs, \(Int(Double(r.totalFiles) / t)) files/s, \(progress.unreadable) unreadable")
        print("     allocated \(fmt(r.totalAllocated)), reclaimable \(fmt(r.totalReclaimable)), kept \(index.files.count) file records, \(index.dirs.count) dir records + \(index.hiddenDirs.count) hidden")
        let memory = index.dirCount * MemoryLayout<DirRecord>.stride + index.files.count * MemoryLayout<FileRecord>.stride + index.names.count
        print("     index size in memory ≈ \(fmt(Int64(memory)))")

        // Feature queries from the one index.
        let (large, _) = time("query: large files ≥ 100 MB") { index.largeFiles(minBytes: 100_000_000) }
        print("     \(large.count) files")
        let (buckets, _) = time("query: duplicate size buckets ≥ 1 MB") { index.sizeBuckets(minBytes: 1_000_000) }
        print("     \(buckets.count) buckets, \(buckets.values.reduce(0) { $0 + $1.count }) candidates")
        let (heavy, _) = time("query: node_modules/.venv/… folders") {
            index.directories(named: ["node_modules", ".venv", "venv", ".next", ".turbo", "__pycache__"])
        }
        print("     \(heavy.count) folders, \(fmt(heavy.reduce(0) { $0 + index.dirs[Int($1)].totalReclaimable }))")
        let (ds, _) = time("query: .DS_Store files") { index.files.filter { index.name($0.name) == ".DS_Store" } }
        print("     \(ds.count) files")

        let store = IndexStore(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "scanbench-store"))
        let (_, saveT) = time("IndexStore.save") { try? store.save(index) }
        let (loaded, loadT) = time("IndexStore.load") { store.load(root: index.rootPath) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: store.fileURL(forRoot: index.rootPath).path)[.size] as? Int64) ?? 0
        print("     on disk \(fmt(bytes)); reload ok: \(loaded?.root.totalReclaimable == r.totalReclaimable) (save \(String(format: "%.2f", saveT)) s, load \(String(format: "%.2f", loadT)) s)")
    }
}

/// Saves an index, changes files, then replays FSEvents and checks the patched index equals a fresh walk.
func incrementalTest(root: String) async throws {
    let fm = FileManager.default
    let store = IndexStore(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "scanbench-store"))
    store.remove(root: ScanEngine.normalizedRoot(root))
    print("\n== Incremental test on \(root) ==")
    let (_, firstReport) = try await ScanEngine.index(root: root, store: store)
    print("  first: \(firstReport.kind) in \(String(format: "%.2f", firstReport.duration)) s")
    if let saved = store.load(root: ScanEngine.normalizedRoot(root)) {
        let bytes = (try? fm.attributesOfItem(atPath: store.fileURL(forRoot: saved.rootPath).path)[.size] as? Int64) ?? 0
        print("  index: \(saved.dirs.count) dir records + \(saved.hiddenDirs.count) hidden, \(saved.files.count) file records, \(saved.denseEntries.count) table entries, on disk \(fmt(bytes)) (\(bytes) B)")
        var perDir: [Int32: Int] = [:]
        for entry in saved.denseEntries { perDir[entry.dir, default: 0] += 1 }
        for (dir, n) in perDir.sorted(by: { $0.value > $1.value }) {
            print("    table: \(n) files  \(saved.path(ofDir: dir).replacingOccurrences(of: home, with: "~"))")
        }
    }
    func line(_ r: ScanEngine.Report) -> String {
        "\(r.kind) in \(String(format: "%.3f", r.duration)) s (\(r.fsEvents) events, replay \(String(format: "%.2f", r.replayDuration)) s, \(r.patchedFiles) files re-read in \(r.patchedFolders) huge folders)"
    }
    // Rescans a minute apart: what the user sees on a repeat scan.
    for _ in 0..<3 {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        let (_, r) = try await ScanEngine.index(root: root, store: store)
        print("  rescan after 60 s: \(line(r))")
    }

    // Unchanged: replay with nothing to do.
    let (_, unchanged) = try await ScanEngine.index(root: root, store: store)
    print("  no-change rescan: \(unchanged.kind) in \(String(format: "%.3f", unchanged.duration)) s (\(unchanged.fsEvents) events)")

    // Make changes inside the root.
    let playground = root + "/.scanbench-incremental-\(getpid())"
    try fm.createDirectory(atPath: playground + "/a/b", withIntermediateDirectories: true)
    fm.createFile(atPath: playground + "/big.bin", contents: Data(repeating: 1, count: 3_000_000))
    fm.createFile(atPath: playground + "/a/b/mid.bin", contents: Data(repeating: 2, count: 700_000))
    try fm.createDirectory(atPath: playground + "/node_modules/pkg", withIntermediateDirectories: true)
    fm.createFile(atPath: playground + "/node_modules/pkg/index.js", contents: Data(repeating: 3, count: 50_000))
    defer { try? fm.removeItem(atPath: playground) }
    try await Task.sleep(nanoseconds: 1_500_000_000) // let fseventsd flush

    let (patched, report) = try await ScanEngine.index(root: root, store: store)
    print("  after changes: \(line(report))")
    print("  deep re-walks: \(report.deepPaths.prefix(15).map { $0.replacingOccurrences(of: home, with: "~") })")
    let fresh = try await walk(root)
    func describe(_ i: FileIndex) -> String { "files \(i.root.totalFiles), reclaimable \(i.root.totalReclaimable), kept \(i.files.count)" }
    let pg = patched.reclaimableSize(ofPath: playground) ?? -1
    let fg = fresh.reclaimableSize(ofPath: playground) ?? -1
    print("  patched: \(describe(patched)); playground \(pg)")
    print("  fresh:   \(describe(fresh)); playground \(fg)")
    print("  playground subtree matches: \(pg == fg ? "yes" : "NO")  (whole-root totals can differ by files changed by other apps between the two walks)")

    // Delete and replay again.
    try fm.removeItem(atPath: playground + "/a")
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let (afterDelete, report2) = try await ScanEngine.index(root: root, store: store)
    let fresh2 = try await walk(root)
    let p2 = afterDelete.reclaimableSize(ofPath: playground) ?? -1, f2 = fresh2.reclaimableSize(ofPath: playground) ?? -1
    print("  after delete: \(report2.kind) in \(String(format: "%.3f", report2.duration)) s; playground patched \(p2) vs fresh \(f2): \(p2 == f2 ? "match" : "MISMATCH"); a/ gone: \(afterDelete.dirID(forPath: playground + "/a") == nil)")

    // A busy size-only folder: 8×8×8 leaf folders, 20 files each, 4 levels below node_modules.
    let busy = playground + "/node_modules/big"
    for i in 0..<8 { for j in 0..<8 { for k in 0..<8 {
        let dir = "\(busy)/\(i)/\(j)/\(k)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in 0..<20 { fm.createFile(atPath: "\(dir)/f\(f).js", contents: Data(repeating: UInt8(f), count: 2_000)) }
    } } }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let (_, report3) = try await ScanEngine.index(root: root, store: store)
    print("  size-only tree added (10,240 files): \(report3.kind) in \(String(format: "%.3f", report3.duration)) s")
    fm.createFile(atPath: busy + "/3/4/5/f7.js", contents: Data(repeating: 9, count: 50_000))
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let (afterTouch, report4) = try await ScanEngine.index(root: root, store: store)
    let fresh4 = try await walk(root)
    let nm = playground + "/node_modules"
    let p4 = afterTouch.reclaimableSize(ofPath: nm) ?? -1, f4 = fresh4.reclaimableSize(ofPath: nm) ?? -1
    print("  file changed 4 levels inside node_modules: \(report4.kind) in \(String(format: "%.3f", report4.duration)) s; node_modules patched \(p4) vs fresh \(f4): \(p4 == f4 ? "match" : "MISMATCH")")
    print("    deep re-walks: \(report4.deepPaths.prefix(15).map { $0.replacingOccurrences(of: home, with: "~") })")

    // A huge flat folder like a browser cache: 5 000 small files, then change, add and delete a few.
    let flat = playground + "/Cache_Data"
    try fm.createDirectory(atPath: flat, withIntermediateDirectories: true)
    for i in 0..<5_000 { fm.createFile(atPath: "\(flat)/f_\(i)", contents: Data(repeating: UInt8(i % 251), count: 200 + i % 3_000)) }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let (withFlat, report5) = try await ScanEngine.index(root: root, store: store)
    let hasTable = withFlat.dirID(forPath: flat).flatMap { withFlat.denseEntries(ofDir: $0) }?.count ?? 0
    print("  flat folder added (5 000 files): \(line(report5)); table \(hasTable) files")
    fm.createFile(atPath: flat + "/f_10", contents: Data(repeating: 1, count: 90_000))
    fm.createFile(atPath: flat + "/new_1", contents: Data(repeating: 2, count: 1_234))
    try fm.removeItem(atPath: flat + "/f_20")
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let (afterFlat, report6) = try await ScanEngine.index(root: root, store: store)
    let fresh6 = try await walk(root)
    let p6 = afterFlat.reclaimableSize(ofPath: flat) ?? -1, f6 = fresh6.reclaimableSize(ofPath: flat) ?? -1
    let n6 = afterFlat.dirID(forPath: flat).map { afterFlat.dirs[Int($0)].ownFiles } ?? 0
    let fn6 = fresh6.dirID(forPath: flat).map { fresh6.dirs[Int($0)].ownFiles } ?? 0
    print("  3 files changed in it: \(line(report6)); patched \(p6) B / \(n6) files vs fresh \(f6) B / \(fn6) files: \(p6 == f6 && n6 == fn6 ? "match" : "MISMATCH")")

    // A build writing 100 k files into 1 000 folders: events must be grouped by folder.
    var storm = ChangeSet()
    for d in 0..<1_000 { for f in 0..<100 { storm.files.insert("\(playground)/a/gen\(d)/obj\(f).o") } }
    try fm.createDirectory(atPath: playground + "/a", withIntermediateDirectories: true)
    let t0 = now()
    let (_, stormKind) = try await ScanEngine.apply(storm, to: afterFlat, newEventID: afterFlat.eventID)
    print(String(format: "  100 000 file events in 1 000 new folders: %@ in %.3f s", "\(stormKind)", now() - t0))
}

func spotlight(minMB: Int64) async {
    print("\n== Spotlight fast path (approximate) ==")
    let (hits, _) = await timeAsync("SpotlightFastPath.largeFiles(≥ \(minMB) MB, home)") {
        await SpotlightFastPath.largeFiles(minBytes: minMB * 1_000_000, scopes: [home])
    }
    print("     \(hits.count) hits; top: \(hits.prefix(3).map { "\(($0.path as NSString).lastPathComponent) \(fmt($0.logicalSize))" })")
}

/// Validates the "only clones need a private-size lookup" shortcut and times EXT_FLAGS alone.
func extFlagsCheck(root: String) {
    BulkDirectoryReader.requestExtFlags = true
    let reader = BulkDirectoryReader()
    var stack = [root]
    var files = 0, flagged = 0, differs = 0, differsUnflagged = 0, linked = 0
    var unflaggedBytes: Int64 = 0
    var examples: [String] = []
    let t0 = now()
    while let dir = stack.popLast() {
        let prefix = dir == "/" ? "/" : dir + "/"
        reader.read(path: dir) { e, name in
            switch e.kind {
            case .directory: if !e.isMountPoint { stack.append(prefix + name.fileName) }
            case .file:
                files += 1
                if e.linkCount > 1 { linked += 1 }
                let mayShare = e.extFlags & 1 != 0
                if mayShare { flagged += 1 }
                if e.privateSize >= 0 && e.privateSize != e.allocatedSize {
                    differs += 1
                    if !mayShare {
                        differsUnflagged += 1
                        unflaggedBytes += e.allocatedSize - e.privateSize
                        if examples.count < 5 { examples.append("\(prefix)\(name.fileName) alloc \(e.allocatedSize) priv \(e.privateSize) flags \(e.extFlags)") }
                    }
                }
            default: break
            }
        }
    }
    print(String(format: "  %.2f s single-threaded", now() - t0))
    print("  files \(files), may-share flagged \(flagged), private≠allocated \(differs), of which NOT flagged \(differsUnflagged) (\(unflaggedBytes) B), hard-linked \(linked)")
    for e in examples { print("   e.g. \(e)") }
}

/// The migrated scanners as AppState now runs them: one shared index, each scanner answering from it.
func benchPhase2() async throws {
    let roots = WorktreeScanner.defaultSearchRoots()
    let store = IndexStore(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "scanbench-store"))
    store.remove(root: home)
    for pass in ["full walk (no saved index)", "incremental (saved index + FSEvents)"] {
        print("\n== Phase 2 scanners, \(pass) ==")
        let (result, _) = try await timeAsync("index: ScanEngine.index(home)") { try await ScanEngine.index(root: home, store: store) }
        let index = result.0
        print("     \(result.1.kind), replay \(String(format: "%.2f", result.1.replayDuration)) s, \(result.1.fsEvents) events")
        if !result.1.deepPaths.isEmpty { print("     deep: \(result.1.deepPaths.prefix(15).map { $0.replacingOccurrences(of: home, with: "~") })") }
        try await ScanIndexContext.$index.withValue(index) {
            let (junk, _) = time("JunkScanner.scan") { JunkScanner.scan(projectRoots: roots, staleDays: 30) }
            print("     \(junk.count) items, \(fmt(junk.reduce(0) { $0 + $1.sizeBytes }))")
            let (large, _) = time("LargeFilesScanner.scan(100 MB)") { LargeFilesScanner.scan(minimumBytes: 100_000_000) }
            print("     \(large.count) files")
            let (dups, _) = time("DuplicateScanner.scan(1 MB)") {
                DuplicateScanner.scan(roots: DuplicateScanner.defaultRoots(), minimumBytes: 1_000_000)
            }
            print("     \(dups.count) groups")
            let (space, _) = time("SpaceAnalyzer.scan(home)") { SpaceAnalyzer.scan(rootPath: home) }
            print("     \(fmt(space.sizeBytes)), \(space.itemCount) files")
            let (wt, _) = time("WorktreeScanner.scan (no gh)") { WorktreeScanner.scan(roots: roots) }
            print("     \(wt.count) worktrees")
            _ = try await Task.sleep(nanoseconds: 1)
        }
    }
}

/// Same scanners with and without the shared index, on the same machine state: do they agree?
func verifyPhase2() async throws {
    let roots = WorktreeScanner.defaultSearchRoots()
    let index = try await walk(home)
    func withIndex<T>(_ body: () -> T) -> T { ScanIndexContext.$index.withValue(index) { body() } }

    print("\n== Junk: index vs walk ==")
    let (jNew, _) = time("JunkScanner (index)") { withIndex { JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false) } }
    let (jOld, _) = time("JunkScanner (walk)") { JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false) }
    let newMap = Dictionary(jNew.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
    let oldMap = Dictionary(jOld.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
    print("     index \(jNew.count) items \(fmt(jNew.reduce(0) { $0 + $1.sizeBytes })), walk \(jOld.count) items \(fmt(jOld.reduce(0) { $0 + $1.sizeBytes }))")
    for path in Set(newMap.keys).union(oldMap.keys).sorted() {
        let a = newMap[path], b = oldMap[path]
        if a != b { print("     differs: \(path.replacingOccurrences(of: home, with: "~")) index \(a.map(fmt) ?? "—") walk \(b.map(fmt) ?? "—")") }
    }

    print("\n== Large files ≥ 50 MB: index vs walk ==")
    let lNew = withIndex { LargeFilesScanner.scan(minimumBytes: 50_000_000) }
    let lOld = LargeFilesScanner.scan(minimumBytes: 50_000_000)
    print("     index \(lNew.count), walk \(lOld.count); same set: \(Set(lNew.map(\.path)) == Set(lOld.map(\.path)))")
    for p in Set(lNew.map(\.path)).symmetricDifference(Set(lOld.map(\.path))).prefix(10) { print("     only in one: \(p)") }

    print("\n== Duplicates ≥ 1 MB: index vs walk ==")
    let dNew = withIndex { DuplicateScanner.scan(roots: DuplicateScanner.defaultRoots(), minimumBytes: 1_000_000) }
    let dOld = DuplicateScanner.scan(roots: DuplicateScanner.defaultRoots(), minimumBytes: 1_000_000)
    let setNew = Set(dNew.flatMap { $0.files.map(\.path) }), setOld = Set(dOld.flatMap { $0.files.map(\.path) })
    print("     index \(dNew.count) groups / \(setNew.count) files, walk \(dOld.count) / \(setOld.count); same files: \(setNew == setOld)")

    print("\n== Space Map of ~/Documents: index vs walk ==")
    let docs = home + "/Documents"
    let sNew = withIndex { SpaceAnalyzer.scan(rootPath: docs) }
    let (sOld, _) = time("SpaceAnalyzer (walk)") { SpaceAnalyzer.scan(rootPath: docs) }
    print("     index \(sNew.sizeBytes) B / \(sNew.itemCount) files, walk \(sOld.sizeBytes) B / \(sOld.itemCount) files")
    let topNew = Dictionary(sNew.children.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
    for child in sOld.children.prefix(8) {
        print("     \(child.name): walk \(fmt(child.sizeBytes)), index \(topNew[child.id].map(fmt) ?? "—")")
    }
}

/// Hand-picked default roots vs roots discovered from the index: worktrees and junk found by each.
func compareRoots() async throws {
    let (index, _) = try await timeAsync("index") { try await walk(home) }
    let (discovered, _) = time("ProjectRootDiscovery.discover") { ProjectRootDiscovery.discover(in: index) }
    let old = WorktreeScanner.defaultSearchRoots()
    print("  old roots: \(old.map { $0.replacingOccurrences(of: home, with: "~") })")
    print("  discovered: \(discovered.count) roots, e.g. \(discovered.prefix(12).map { $0.replacingOccurrences(of: home, with: "~") })")
    func run(_ label: String, _ roots: [String]) -> (Set<String>, Set<String>) {
        ScanIndexContext.$index.withValue(index) {
            let (wt, _) = time("WorktreeScanner (\(label))") { WorktreeScanner.scan(roots: roots) }
            let (junk, _) = time("JunkScanner no tools (\(label))") { JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false) }
            print("     \(wt.count) worktrees, \(junk.count) junk items (\(fmt(junk.reduce(0) { $0 + $1.sizeBytes }))), dev artifacts \(junk.filter { $0.category == .devArtifacts }.count), .DS_Store \(junk.filter { $0.category == .dsStore }.count)")
            return (Set(wt.map(\.worktreePath)), Set(junk.map(\.path)))
        }
    }
    let (wOld, jOld) = run("old roots", old)
    let (wNew, jNew) = run("discovered", discovered)
    print("  worktrees only with old roots: \(wOld.subtracting(wNew).sorted().map { $0.replacingOccurrences(of: home, with: "~") })")
    print("  worktrees only with discovered: \(wNew.subtracting(wOld).count)")
    print("  junk only with old roots: \(jOld.subtracting(jNew).sorted().map { $0.replacingOccurrences(of: home, with: "~") })")
    print("  junk only with discovered: \(jNew.subtracting(jOld).sorted().prefix(20).map { $0.replacingOccurrences(of: home, with: "~") })")
}

/// Cost of one change inside a size-only folder: re-sizing the whole folder (before hidden sub-records)
/// vs re-sizing one of its level-2 sub-folders (after). Warm cache: each walk runs twice, second one kept.
func sizeOnlyCost(paths: [String], width: Int) async throws {
    print("\n== Re-size cost inside size-only folders (warm) ==")
    print("| Folder | Files | Whole folder | Level-2 leaves | Median leaf | Slowest leaf |")
    print("|---|---:|---:|---:|---:|---:|")
    func timedWalk(_ path: String) async throws -> (Double, UInt64) {
        var config = ScanEngine.Configuration(root: path)
        config.width = width
        _ = try await ScanEngine.buildIndex(root: path, configuration: config)
        let t0 = now()
        let index = try await ScanEngine.buildIndex(root: path, configuration: config)
        return (now() - t0, index.root.totalFiles)
    }
    let fm = FileManager.default
    for path in paths {
        let (whole, files) = try await timedWalk(path)
        var leaves: [String] = []
        for a in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            let pa = path + "/" + a
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: pa, isDirectory: &isDir), isDir.boolValue else { continue }
            for b in (try? fm.contentsOfDirectory(atPath: pa)) ?? [] {
                let pb = pa + "/" + b
                if fm.fileExists(atPath: pb, isDirectory: &isDir), isDir.boolValue { leaves.append(pb) }
            }
        }
        var times: [Double] = []
        for leaf in leaves { times.append(try await timedWalk(leaf).0) }
        times.sort()
        let median = times.isEmpty ? 0 : times[times.count / 2]
        print(String(format: "| %@ | %llu | %.3f s | %d | %.4f s | %.3f s |",
                     path.replacingOccurrences(of: home, with: "~") as NSString, files, whole, leaves.count, median, times.last ?? 0))
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
func intArg(_ name: String, _ fallback: Int) -> Int {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) { return v }
    return fallback
}
let width = intArg("--width", ParallelWalker.defaultWidth)
let passes = intArg("--passes", 2)
let positional = args.dropFirst().filter { !$0.hasPrefix("--") && Int($0) == nil }

if args.contains("--no-private") {
    BulkDirectoryReader.requestPrivateSize = false
    print("Not requesting APFS private size (benchmark only).")
}
if args.contains("--purge") {
    print(tryPurge() ? "Purged file cache (cold run)." : "Could not purge (needs: sudo purge). Runs are warm-cache.")
}

switch command {
case "old":
    await benchOld(passes: passes)
case "new":
    try await benchNew(root: positional.first ?? home, width: width, passes: passes)
case "compare":
    try await compare(paths: Array(positional), width: width)
case "clones":
    try await cloneTest()
case "widths":
    try await widths(root: positional.first ?? home, list: [2, 4, 8, 12, 16, 24])
case "sizeonly":
    try await sizeOnlyCost(paths: Array(positional), width: width)
case "incremental":
    try await incrementalTest(root: positional.first ?? home)
case "phase2":
    try await benchPhase2()
case "roots":
    try await compareRoots()
case "verify":
    try await verifyPhase2()
case "extflags":
    extFlagsCheck(root: positional.first ?? home)
case "spotlight":
    await spotlight(minMB: Int64(intArg("--min-mb", 100)))
case "stream":
    streamCheck()
case "hotprobe":
    hotProbe(paths: Array(positional), waitSeconds: intArg("--wait", 60))
default:
    print("""
    ScanBench commands:
      old [--passes N]                     time every existing scanner (as AppState calls them)
      new [root] [--width W] [--passes N]  one ScanEngine walk + feature queries + save/load
      compare <folder>... [--width W]      FileSizeHelper.directorySize vs engine: time and bytes
      clones                               clone/hard-link accuracy test in a temp folder
      widths [root]                        sweep worker widths
      incremental [root]                   save → change files → FSEvents patch → compare with fresh walk
      sizeonly <folder>…                   re-size cost: whole size-only folder vs one level-2 sub-folder
      spotlight [--min-mb N]               Spotlight fast path
      stream                               time to first streamed result vs full scan, per scanner
      hotprobe <folder>… [--wait S]        re-read cost of huge flat folders; FSEvents folder vs file events
      --purge                              try `sudo -n purge` first (cold cache)
    """)
}

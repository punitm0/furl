import Foundation

/// `ScanBench stream`: for each scanner, how long until the first partial result arrives (what the
/// screen can show) versus how long the whole scan takes, and whether the streamed results add up
/// to the final ones. Runs without the shared index, i.e. the slow first-scan path.
final class EmitLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var first: Double?
    private(set) var batches = 0
    private(set) var items = 0
    let start = now()
    func note(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = now() - start }
        batches += 1
        items += count
    }
}

func streamCheck() {
    func report(_ label: String, _ log: EmitLog, total: Int) {
        let elapsed = now() - log.start
        let first = log.first.map { String(format: "%6.2f s", $0) } ?? "   none "
        let match = log.items == total ? "ok" : "MISMATCH (\(log.items) streamed)"
        print(String(format: "  %-24@ first %@   total %6.2f s   %4d batches   %5d results  %@",
                     label as NSString, first as NSString, elapsed, log.batches, total, match as NSString))
    }
    let roots = WorktreeScanner.defaultSearchRoots()
    print("Streaming check (no shared index; first-scan path):")
    do {
        let log = EmitLog()
        let r = JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false, progress: ScanProgress()) { log.note($0.count) }
        report("Caches & Junk", log, total: r.count)
    }
    do {
        let log = EmitLog()
        let r = LargeFilesScanner.scan(minimumBytes: 100_000_000, progress: ScanProgress()) { log.note($0.count) }
        report("Large Files", log, total: r.count)
    }
    do {
        let log = EmitLog()
        let r = DuplicateScanner.scan(roots: DuplicateScanner.defaultRoots(), minimumBytes: 1_000_000, progress: ScanProgress()) { log.note($0.count) }
        report("Duplicates", log, total: r.count)
    }
    do {
        let log = EmitLog()
        let r = WorktreeScanner.scan(roots: roots, progress: ScanProgress()) { log.note($0.count) }
        // The final list drops a worktree reached twice through overlapping roots; streaming merges dedupe the same way.
        report("Git Worktrees", log, total: r.count)
    }
    do {
        let log = EmitLog()
        var streamedApps = 0
        let r = AppUninstallerService.scan(progress: ScanProgress()) { log.note(0); streamedApps = $0.installedApps.count }
        print(String(format: "  %-24@ first %6.2f s   total %6.2f s   apps streamed %d of %d", "Apps & Leftovers" as NSString,
                     log.first ?? -1, now() - log.start, streamedApps, r.installedApps.count))
    }
    do {
        let log = EmitLog()
        let r = SmartReviewScanner.scan(ignoredPaths: [], progress: ScanProgress()) { log.note($0.count) }
        report("Smart Review", log, total: r.count)
    }
    do {
        let log = EmitLog()
        let r = SpaceAnalyzer.scan(rootPath: home, progress: ScanProgress()) { _ in log.note(1) }
        print(String(format: "  %-24@ first %6.2f s   total %6.2f s   top-level items streamed %d (map keeps %d)", "Space Map (walk)" as NSString,
                     log.first ?? -1, now() - log.start, log.items, r.children.count))
    }
}

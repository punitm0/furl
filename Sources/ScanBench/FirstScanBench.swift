import Foundation

/// `ScanBench firstscan`: the FirstScan board's "usable number in 20 seconds". Starts the home walk and,
/// alongside it, the junk scan's quick checks without the index (what `AppState.scanJunk` does on a
/// first scan), and prints when each quick check finished with the safe bytes so far. Then times the
/// old path for comparison: the safe number only appeared after the walk plus the index-based checks.
final class FirstScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var safe: Int64 = 0
    private(set) var steps: [(title: String, at: Double, safe: Int64)] = []
    let start: Double
    init(start: Double) { self.start = start }
    func add(_ items: [JunkItem]) {
        lock.lock(); defer { lock.unlock() }
        safe += items.filter { $0.risk == .safe && $0.command == nil }.reduce(0) { $0 + $1.sizeBytes }
    }
    func done(_ title: String) {
        lock.lock(); defer { lock.unlock() }
        steps.append((title, now() - start, safe))
    }
}

func benchFirstScan(width: Int) async throws {
    let roots = WorktreeScanner.defaultSearchRoots()
    print("\n== First scan: quick junk checks alongside the home walk (width \(width)) ==")
    let start = now()
    var config = ScanEngine.Configuration(root: home)
    config.width = width
    let walk = Task.detached(priority: .userInitiated) { () -> (FileIndex?, Double) in
        let index = try? await ScanEngine.buildIndex(root: home, configuration: config)
        return (index, now() - start)
    }
    let log = FirstScanLog(start: start)
    _ = await Task.detached(priority: .userInitiated) {
        JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false, pass: .quick,
                         emit: { log.add($0) }, stepDone: { log.done($0) })
    }.value
    for step in log.steps {
        print(String(format: "  %-44@ %8.2f s   safe so far %@", step.title as NSString, step.at, fmt(step.safe) as NSString))
    }
    let (index, walkTime) = await walk.value
    print(String(format: "  %-44@ %8.2f s", "home walk (ran alongside)" as NSString, walkTime))
    guard let index else { print("  walk failed"); return }

    print("\n  Before (1.3.0): the junk scan waited for the walk, then ran every check on the index")
    let restStart = now()
    let all = ScanIndexContext.$index.withValue(index) {
        JunkScanner.scan(projectRoots: roots, staleDays: 30, includeToolItems: false, pass: .all)
    }
    let restTime = now() - restStart
    let safeAll = all.filter { $0.risk == .safe && $0.command == nil }.reduce(Int64(0)) { $0 + $1.sizeBytes }
    print(String(format: "  %-44@ %8.2f s   (first safe number at ≈ %.2f s)", "index-based checks after the walk" as NSString,
                 restTime, walkTime + restTime))
    print("  safe total (all checks, before nesting): \(fmt(safeAll))")
}

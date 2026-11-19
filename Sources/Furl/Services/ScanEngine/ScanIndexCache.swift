import Foundation

/// The home-folder index the current scan should use. Scanners run inside
/// `ScanIndexContext.$index.withValue(index) { … }`, so `FileSizeHelper.directorySize` and the scanners can
/// answer from the index without new parameters threading through every call. Task-local, so it never leaks
/// into unrelated work (and is simply nil on threads spawned by `concurrentPerform`, which then fall back).
enum ScanIndexContext {
    @TaskLocal static var index: FileIndex?
}

/// One shared, coalesced home index for the whole app.
///
/// - Concurrent callers (Scan All starts five scans at once) share ONE walk.
/// - A later call patches the saved index from FSEvents (`ScanEngine.index`) — usually well under a second.
/// - Results younger than `reuseWindow` are returned as-is, so back-to-back scans don't even replay FSEvents.
actor ScanIndexCache {
    static let shared = ScanIndexCache()

    static var homePath: String { ScanEngine.normalizedRoot(FileManager.default.homeDirectoryForCurrentUser.path) }

    private var current: FileIndex?
    private var refreshedAt = Date.distantPast
    private var inFlight: Task<FileIndex?, Never>?
    private var walkProgress: ScanProgress?
    private let reuseWindow: TimeInterval = 3
    /// Called (off the main thread) with each freshly built or patched index — e.g. to save a snapshot.
    private var onRefresh: (@Sendable (FileIndex) -> Void)?

    func setOnRefresh(_ handler: @escaping @Sendable (FileIndex) -> Void) { onRefresh = handler }

    /// Returns a fresh home index, or nil if it couldn't be built (callers fall back to their own walk) or
    /// the caller's `progress` was cancelled while waiting. The shared walk itself is not cancelled by one
    /// caller; it keeps running for the others and is saved for next time.
    func homeIndex(progress: ScanProgress? = nil) async -> FileIndex? {
        if inFlight == nil {
            if let current, Date().timeIntervalSince(refreshedAt) < reuseWindow { return current }
            let walk = ScanProgress()
            walkProgress = walk
            inFlight = Task.detached(priority: .userInitiated) {
                try? await ScanEngine.index(root: ScanIndexCache.homePath, progress: walk).0
            }
        }
        guard let task = inFlight, let walk = walkProgress else { return current }

        // Mirror the shared walk's counters into the caller's progress until it finishes.
        let mirror: Task<Void, Never>? = progress.map { target in
            Task.detached {
                var copied = 0, unreadable = 0
                while !Task.isCancelled {
                    let items = walk.items
                    if items > copied { target.addItems(items - copied); copied = items }
                    while unreadable < walk.unreadable { target.addUnreadable(); unreadable += 1 }
                    target.setPhase(walk.phase)
                    if target.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        let outcome = await Self.wait(for: task, unlessStopped: progress)
        mirror?.cancel()
        guard case .finished(let result) = outcome else {
            // Stopped: return now (the walk can take minutes) and record the result when it lands.
            Task { let result = await task.value; self.settle(task, result: result) }
            return nil
        }
        settle(task, result: result)
        if progress?.isCancelled == true { return nil }
        return result
    }

    private func settle(_ task: Task<FileIndex?, Never>, result: FileIndex?) {
        guard inFlight == task else { return }
        inFlight = nil
        walkProgress = nil
        if let result {
            if current !== result, let onRefresh { Task.detached(priority: .utility) { onRefresh(result) } }
            current = result
            refreshedAt = Date()
        }
    }

    enum WaitOutcome: Sendable {
        case finished(FileIndex?)
        case stopped
    }

    /// Waits for the shared walk, or returns `.stopped` soon after `progress` is cancelled. Awaiting
    /// `task.value` alone can't be interrupted, so Stop did nothing until the whole walk had finished.
    static func wait(for task: Task<FileIndex?, Never>, unlessStopped progress: ScanProgress?,
                     pollInterval: UInt64 = 100_000_000) async -> WaitOutcome {
        guard let progress else { return .finished(await task.value) }
        if progress.isCancelled { return .stopped }
        let gate = ResumeOnce<WaitOutcome>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task.detached { gate.resume(.finished(await task.value)) }
            Task.detached {
                while !gate.isResumed {
                    if progress.isCancelled { gate.resume(.stopped); return }
                    try? await Task.sleep(nanoseconds: pollInterval)
                }
            }
        }
    }

    /// Forget the in-memory copy (e.g. after a big cleanup) so the next call replays FSEvents immediately.
    func markStale() {
        refreshedAt = .distantPast
    }
}

/// Resumes a continuation exactly once, whichever of several racers gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var resumed = false

    var isResumed: Bool { lock.withLock { resumed } }

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

// MARK: - Query helpers used by the migrated scanners

extension FileIndex {
    /// True when `path` lies inside this index's root.
    func covers(_ path: String) -> Bool {
        let p = ScanEngine.normalizedRoot(path)
        return p == rootPath || p.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    /// A per-directory flag propagated down the tree: a directory is excluded when its parent is, or when
    /// `exclude` says so. Parent ids are always smaller, so one forward pass suffices.
    func exclusionMask(_ exclude: (_ id: Int32, _ record: DirRecord) -> Bool) -> [Bool] {
        var mask = [Bool](repeating: false, count: dirs.count)
        for id in 0..<dirs.count {
            let parent = Int(dirs[id].parent)
            mask[id] = (parent >= 0 && mask[parent]) || exclude(Int32(id), dirs[id])
        }
        return mask
    }

    /// Mask of directories inside any of `roots` (each root's own subtree, root included).
    func inclusionMask(roots: [String]) -> [Bool] {
        let rootIDs = Set(roots.compactMap { dirID(forPath: $0) })
        var mask = [Bool](repeating: false, count: dirs.count)
        for id in 0..<dirs.count {
            let parent = Int(dirs[id].parent)
            mask[id] = rootIDs.contains(Int32(id)) || (parent >= 0 && mask[parent])
        }
        return mask
    }

    /// Directory name without building the full path.
    func dirName(_ id: Int32) -> String { name(dirs[Int(id)].name) }

    func modifiedDate(ofDir id: Int32) -> Date { Date(timeIntervalSince1970: TimeInterval(dirs[Int(id)].modified)) }
}

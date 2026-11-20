import Darwin
import Foundation

/// Walks a tree with a fixed number of worker threads, each reading whole directories with
/// `BulkDirectoryReader`. Produces (or updates) an `IndexBuilder`.
///
/// Why threads and not a task group: `getattrlistbulk` blocks in the kernel. Blocking Swift's cooperative pool
/// (one thread per core) would stall every other async task in the app for the length of the scan. The walk is
/// exposed as an `async` function and honours task cancellation, so callers still use structured concurrency.
struct ParallelWalker: Sendable {
    /// Directory to read. `existingChildren` makes the read shallow: sub-directories found there keep their
    /// old record (only their attributes refresh) and are not descended. Used by the incremental updater.
    struct Seed: Sendable {
        var id: Int32
        var path: String
        var mode: DirMode
        var existingChildren: [String: ExistingChild]?
    }

    /// A sub-directory the index already has. It is reused only if the folder found under that name is the
    /// same one (same file ID): a folder deleted and re-created under its old name — Chromium resetting its
    /// cache — is new, so its old subtree, table and kept files must not carry over.
    struct ExistingChild: Sendable {
        var id: Int32
        var fileID: UInt64
    }

    var width: Int = ParallelWalker.defaultWidth
    var policy: WalkPolicy = .default
    var retain: RetainRule = .default
    /// Indexed folders with at least this many files keep a per-file table (`FileIndex.denseEntries`), so a
    /// change FSEvents names costs one stat per file instead of a re-read. A re-read costs ~50–100 µs per
    /// file with APFS private size, so this is where one reaches ~0.3 s. Not part of the config fingerprint:
    /// tables are rebuilt or dropped on every read of a folder.
    var denseMinFiles = ParallelWalker.defaultDenseMinFiles

    static let defaultDenseMinFiles = 4096

    /// Tuned on an M2 Pro (12 cores): see docs/scan-benchmarks.md.
    static let defaultWidth = 8

    /// Full walk of `rootPath` into a fresh builder (not yet compacted).
    func walkTree(rootPath: String, progress: ScanProgress? = nil) async throws -> IndexBuilder {
        var builder = IndexBuilder(rootPath: rootPath)
        var root = DirRecord()
        var st = stat()
        if lstat(rootPath, &st) == 0 {
            root.fileID = UInt64(st.st_ino)
            root.modified = Int64(st.st_mtimespec.tv_sec)
            root.created = Int64(st.st_birthtimespec.tv_sec)
        }
        let rootName = (rootPath as NSString).lastPathComponent
        root.name = rootName.utf8CString.withUnsafeBytes { raw in
            builder.appendName(UnsafeRawBufferPointer(rebasing: raw.dropLast()))
        }
        builder.dirs.append(root)
        try await walk(seeds: [Seed(id: FileIndex.rootID, path: rootPath, mode: .indexed)], into: &builder, progress: progress)
        return builder
    }

    /// Reads every seed (deeply, unless it has `existingChildren`) and merges the results into `builder`:
    /// new directories are appended, seeds get fresh own-stats, new files are appended (unsorted).
    /// Returns the ids of `existingChildren` that were found again (the rest have disappeared).
    @discardableResult
    func walk(seeds: [Seed], into builder: inout IndexBuilder, progress: ScanProgress? = nil) async throws -> Set<Int32> {
        let shared = WalkState(nextDirID: Int32(builder.dirs.count), seeds: seeds, progress: progress)
        let workerCount = max(1, min(width, 64))
        let outputs = (0..<workerCount).map { _ in WorkerOutput() }
        let policy = self.policy
        let retain = self.retain
        let denseMinFiles = self.denseMinFiles

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for output in outputs {
                    group.enter()
                    let thread = Thread {
                        Self.workerLoop(shared: shared, output: output, policy: policy, retain: retain, denseMinFiles: denseMinFiles)
                        group.leave()
                    }
                    thread.qualityOfService = .userInitiated
                    thread.stackSize = 1 << 20
                    thread.start()
                }
                group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
            }
            if shared.isCancelled { throw CancellationError() }
        } onCancel: {
            shared.cancel()
        }

        // Merge worker outputs. Records hold worker-local name offsets; rebase them.
        var refreshed = Set<Int32>()
        let total = Int(shared.nextDirIDValue)
        if builder.dirs.count < total {
            builder.dirs.append(contentsOf: repeatElement(DirRecord(), count: total - builder.dirs.count))
        }
        // Pass 1: records. A directory's record comes from the worker that read its PARENT, its stats from the
        // worker that read the directory itself — so all records must land before any stats are applied.
        var bases: [UInt32] = []
        for output in outputs {
            let base = UInt32(builder.names.count)
            bases.append(base)
            builder.names.append(contentsOf: output.names)
            for (id, var record) in output.newDirs {
                record.name.offset += base
                builder.dirs[Int(id)] = record
            }
            for (id, update) in output.refreshedDirs {
                refreshed.insert(id)
                builder.dirs[Int(id)].modified = update.modified
                builder.dirs[Int(id)].created = update.created
                builder.dirs[Int(id)].fileID = update.fileID
            }
        }
        // Every folder read here gets a fresh table (or none); drop the old ones first.
        var read = Set<Int32>()
        for output in outputs { for (id, _) in output.stats { read.insert(id) } }
        if !builder.denseEntries.isEmpty { builder.denseEntries.removeAll { read.contains($0.dir) } }
        // Pass 2: own stats and kept files.
        for (output, base) in zip(outputs, bases) {
            for var entry in output.dense {
                entry.name.offset += base
                builder.denseEntries.append(entry)
            }
            for (id, stats) in output.stats {
                var d = builder.dirs[Int(id)]
                d.ownFiles = stats.files
                d.ownLogical = stats.logical
                d.ownAllocated = stats.allocated
                d.ownReclaimable = stats.reclaimable
                d.ownNewestModified = stats.newest
                d.totalDirs = 0 // recounted by compact()/recomputeTotals()
                d.foldedDirs = 0 // a deep re-read re-folds its subtree in compact()
                var flags = d.flags
                if stats.unreadable { flags.insert(.unreadable) } else { flags.remove(.unreadable) }
                flags.remove(.incomplete)
                flags.remove(.foldedIncomplete)
                d.flags = flags
                builder.dirs[Int(id)] = d
            }
            builder.files.reserveCapacity(builder.files.count + output.files.count)
            for var file in output.files {
                file.name.offset += base
                builder.files.append(file)
            }
        }
        return refreshed
    }

    // MARK: - Worker

    private struct OwnStats {
        var files: UInt64 = 0
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var reclaimable: Int64 = 0
        var newest: Int64 = 0
        var unreadable = false
    }

    private struct Refresh {
        var modified: Int64
        var created: Int64
        var fileID: UInt64
    }

    private struct PendingChild {
        var record: DirRecord
        var path: String
        var mode: DirMode
    }

    private final class WorkerOutput: @unchecked Sendable {
        var names: [UInt8] = []
        var newDirs: [(Int32, DirRecord)] = []
        var refreshedDirs: [(Int32, Refresh)] = []
        var stats: [(Int32, OwnStats)] = []
        var files: [FileRecord] = []
        var dense: [DenseEntry] = []
    }

    private static func workerLoop(shared: WalkState, output: WorkerOutput, policy: WalkPolicy, retain: RetainRule, denseMinFiles: Int) {
        let reader = BulkDirectoryReader()
        var pending: [PendingChild] = []
        // Every file of the folder being read, in case it turns out to be huge (names in `candidateNames`).
        var candidates: [DenseEntry] = []
        var candidateNames: [UInt8] = []
        while let item = shared.next() {
            pending.removeAll(keepingCapacity: true)
            candidates.removeAll(keepingCapacity: true)
            candidateNames.removeAll(keepingCapacity: true)
            var selfContained = true
            var stats = OwnStats()
            let isIndexed = item.mode == .indexed
            let parentPrefix = item.path == "/" ? "/" : item.path + "/"

            let result = reader.read(path: item.path) { entry, name in
                switch entry.kind {
                case .file:
                    stats.files += 1
                    stats.logical += entry.logicalSize
                    stats.allocated += entry.displaySize
                    stats.reclaimable += entry.reclaimableSize
                    if entry.modified > stats.newest { stats.newest = entry.modified }
                    if isIndexed && selfContained {
                        if DenseEntry.isSelfContained(entry) {
                            let ref = NameRef(offset: UInt32(candidateNames.count), length: UInt32(name.count))
                            candidateNames.append(contentsOf: name)
                            candidates.append(DenseEntry(dir: item.id, name: ref, entry: entry))
                        } else {
                            selfContained = false
                        }
                    }
                    if isIndexed && retain.keeps(entry, name: name) {
                        let ref = NameRef(offset: UInt32(output.names.count), length: UInt32(name.count))
                        output.names.append(contentsOf: name)
                        output.files.append(FileRecord(
                            dir: item.id, name: ref,
                            linkCount: entry.linkCount, bsdFlags: entry.bsdFlags, fileID: entry.fileID,
                            logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize,
                            privateSize: entry.privateSize,
                            modified: entry.modified, accessed: entry.accessed, created: entry.created
                        ))
                    }
                case .directory:
                    let childName = name.fileName
                    if let existing = item.existingChildren?[childName], existing.fileID == entry.fileID {
                        output.refreshedDirs.append((existing.id, Refresh(modified: entry.modified, created: entry.created, fileID: entry.fileID)))
                        return
                    }
                    let isPackage = PackageDetector.isPackage(name: name, finderFlags: entry.finderFlags)
                    let childPath = parentPrefix + childName
                    let mode = policy.classify(
                        name: childName, path: childPath, parentMode: item.mode,
                        isPackage: isPackage, isMountPoint: entry.isMountPoint
                    )
                    var record = DirRecord()
                    record.name = NameRef(offset: UInt32(output.names.count), length: UInt32(name.count))
                    output.names.append(contentsOf: name)
                    record.parent = item.id
                    record.mode = mode
                    record.fileID = entry.fileID
                    record.modified = entry.modified
                    record.created = entry.created
                    var flags: DirFlags = []
                    if isPackage { flags.insert(.package) }
                    if name.startsWithDot || entry.isHiddenFlag { flags.insert(.hidden) }
                    if entry.isMountPoint { flags.insert(.mountPoint) }
                    record.flags = flags
                    pending.append(PendingChild(record: record, path: childPath, mode: mode))
                case .symlink, .other:
                    break // like FileSizeHelper/FileManager-based scanners: links are not followed or counted
                }
            }

            switch result {
            case .success(let count):
                shared.progress?.addItems(count)
                // A partial listing would make later deltas wrong; the folder keeps the folder read instead.
                if selfContained && !reader.lastReadIncomplete && candidates.count >= denseMinFiles {
                    let base = UInt32(output.names.count)
                    output.names.append(contentsOf: candidateNames)
                    for var entry in candidates {
                        entry.name.offset += base
                        output.dense.append(entry)
                    }
                }
            case .failure:
                stats.unreadable = true
                shared.progress?.addUnreadable()
            }
            output.stats.append((item.id, stats))
            shared.finish(children: &pending, output: output)
        }
    }

    // MARK: - Shared work queue

    private final class WalkState: @unchecked Sendable {
        struct Item {
            var id: Int32
            var path: String
            var mode: DirMode
            var existingChildren: [String: ExistingChild]?
        }

        private let condition = NSCondition()
        private var stack: [Item]
        private var active = 0
        private var nextDirID: Int32
        private var cancelled = false
        let progress: ScanProgress?

        init(nextDirID: Int32, seeds: [Seed], progress: ScanProgress?) {
            self.nextDirID = nextDirID
            self.progress = progress
            self.stack = seeds.map { Item(id: $0.id, path: $0.path, mode: $0.mode, existingChildren: $0.existingChildren) }
        }

        var isCancelled: Bool {
            condition.lock(); defer { condition.unlock() }
            return cancelled
        }

        var nextDirIDValue: Int32 {
            condition.lock(); defer { condition.unlock() }
            return nextDirID
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }

        /// Blocks until there is work, or returns nil when the walk is finished or cancelled.
        func next() -> Item? {
            if progress?.isCancelled == true { cancel() }
            condition.lock()
            defer { condition.unlock() }
            while stack.isEmpty && active > 0 && !cancelled {
                condition.wait()
            }
            if cancelled || stack.isEmpty {
                condition.broadcast()
                return nil
            }
            active += 1
            return stack.removeLast()
        }

        /// Assigns ids to the directory's sub-directories, queues the ones to descend, marks the item done.
        func finish(children: inout [PendingChild], output: WorkerOutput) {
            condition.lock()
            for child in children {
                let id = nextDirID
                nextDirID += 1
                output.newDirs.append((id, child.record))
                if child.mode != .skipped {
                    stack.append(Item(id: id, path: child.path, mode: child.mode, existingChildren: nil))
                }
            }
            active -= 1
            if !children.isEmpty || active == 0 { condition.broadcast() }
            condition.unlock()
        }
    }
}

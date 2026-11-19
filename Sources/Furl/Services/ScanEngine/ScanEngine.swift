import Darwin
import Foundation

/// Entry point for the shared scan engine: one parallel bulk walk per root, persisted, then kept fresh with
/// FSEvents so later scans only re-read the directories that changed.
///
///     let (index, report) = try await ScanEngine.index(root: NSHomeDirectory(), progress: progress)
///     let big = index.largeFiles(minBytes: 100_000_000)
///     let nodeModules = index.directories(named: ["node_modules"]).map { index.dirs[Int($0)].totalReclaimable }
enum ScanEngine {
    struct Configuration: Sendable {
        var policy: WalkPolicy
        var retain: RetainRule = .default
        var width: Int = ParallelWalker.defaultWidth
        /// Older indexes are rebuilt from scratch even if FSEvents history is available.
        var maxIndexAge: TimeInterval = 7 * 24 * 3600
        /// More changed directories than this and a full walk is cheaper than patching.
        var maxIncrementalDirectories = 20_000

        init(root: String) { policy = .forRoot(root) }

        var fingerprint: UInt64 {
            var h = FNV1a()
            h.add(String(policy.fingerprint))
            h.add(String(retain.fingerprint))
            return h.value
        }

        var walker: ParallelWalker { ParallelWalker(width: width, policy: policy, retain: retain) }
    }

    struct Report: Sendable {
        enum Kind: Sendable, Equatable {
            case full(reason: String)
            case incremental(shallow: Int, deep: Int)
            case unchanged
        }
        var kind: Kind
        var duration: TimeInterval
        var fsEvents: Int = 0
        /// Time spent replaying FSEvents history (part of `duration`).
        var replayDuration: TimeInterval = 0
        /// Folders re-walked deeply in an incremental update (diagnostics).
        var deepPaths: [String] = []
    }

    // MARK: Full walk

    static func buildIndex(root: String, configuration: Configuration? = nil, progress: ScanProgress? = nil) async throws -> FileIndex {
        let config = configuration ?? Configuration(root: root)
        let rootPath = normalizedRoot(root)
        // Capture the event ID first: anything that changes while we walk is replayed next time.
        let eventID = FSEventsHistory.currentEventID()
        let uuid = FSEventsHistory.databaseUUID(forPath: rootPath)
        progress?.setPhase("Reading folders")
        var builder = try await config.walker.walkTree(rootPath: rootPath, progress: progress)
        progress?.setPhase("Adding up sizes")
        builder.compact()
        return builder.finish(eventID: eventID, fseventsUUID: uuid, configHash: config.fingerprint)
    }

    // MARK: Persistent + incremental

    /// Loads the saved index for `root` and patches it from FSEvents history, or walks from scratch when
    /// there's no usable index. Saves the result.
    static func index(
        root: String,
        configuration: Configuration? = nil,
        store: IndexStore = IndexStore(),
        progress: ScanProgress? = nil
    ) async throws -> (FileIndex, Report) {
        let config = configuration ?? Configuration(root: root)
        let rootPath = normalizedRoot(root)
        let started = Date()

        func full(_ reason: String) async throws -> (FileIndex, Report) {
            let index = try await buildIndex(root: rootPath, configuration: config, progress: progress)
            try? store.save(index)
            return (index, Report(kind: .full(reason: reason), duration: Date().timeIntervalSince(started)))
        }

        guard let saved = store.load(root: rootPath) else { return try await full("No saved index") }
        if saved.configHash != config.fingerprint { return try await full("Scan settings changed") }
        if saved.fseventsUUID.isEmpty || saved.fseventsUUID != FSEventsHistory.databaseUUID(forPath: rootPath) {
            return try await full("FSEvents database changed")
        }
        if Date().timeIntervalSince(saved.builtAt) > config.maxIndexAge { return try await full("Saved index is too old") }

        progress?.setPhase("Checking what changed")
        let replayFrom = FSEventsHistory.currentEventID()
        let replayStarted = Date()
        let changes = await FSEventsHistory.changes(since: saved.eventID, roots: [rootPath])
        let replayDuration = Date().timeIntervalSince(replayStarted)
        if changes.requiresFullRescan { return try await full(changes.fullRescanReason ?? "FSEvents asked for a full rescan") }

        let (updated, kind, deepPaths) = try await applyReturningDeep(changes, to: saved, newEventID: replayFrom, configuration: config, progress: progress)
        if kind == .unchanged {
            // Nothing to rescan, but remember that history up to now has been consumed.
            let refreshed = IndexBuilder(saved).finish(
                eventID: replayFrom, fseventsUUID: saved.fseventsUUID, configHash: saved.configHash, builtAt: saved.builtAt
            )
            try? store.save(refreshed)
            return (refreshed, Report(kind: .unchanged, duration: Date().timeIntervalSince(started), fsEvents: changes.eventCount, replayDuration: replayDuration))
        }
        guard let updated else { return try await full("Too many changes to patch") }
        try? store.save(updated)
        return (updated, Report(kind: kind, duration: Date().timeIntervalSince(started), fsEvents: changes.eventCount,
                                replayDuration: replayDuration, deepPaths: deepPaths))
    }

    /// Patches `index` with a change set (from history replay or a live `FSEventsCollector`).
    /// Returns nil when the changes are too broad and a full walk should be done instead.
    static func apply(
        _ changes: ChangeSet,
        to index: FileIndex,
        newEventID: UInt64,
        configuration: Configuration? = nil,
        progress: ScanProgress? = nil
    ) async throws -> (FileIndex?, Report.Kind) {
        let (updated, kind, _) = try await applyReturningDeep(changes, to: index, newEventID: newEventID, configuration: configuration, progress: progress)
        return (updated, kind)
    }

    private static func applyReturningDeep(
        _ changes: ChangeSet,
        to index: FileIndex,
        newEventID: UInt64,
        configuration: Configuration?,
        progress: ScanProgress?
    ) async throws -> (FileIndex?, Report.Kind, [String]) {
        let config = configuration ?? Configuration(root: index.rootPath)
        if changes.requiresFullRescan { return (nil, .full(reason: changes.fullRescanReason ?? ""), []) }

        // FSEvents reports real paths; translate them back to the root as the index spells it.
        let rootPath = index.rootPath
        let realRoot = realPath(rootPath) ?? rootPath
        func translate(_ path: String) -> String? {
            for base in Set([realRoot, rootPath]) {
                if path == base { return rootPath }
                let prefix = base == "/" ? "/" : base + "/"
                if path.hasPrefix(prefix) { return (rootPath == "/" ? "" : rootPath) + "/" + path.dropFirst(prefix.count) }
            }
            return nil
        }

        // Resolve every changed path to the directory that must be re-read.
        var deep = Set<Int32>()
        var shallow = Set<Int32>()
        for (path, isDeep) in changes.deep.map({ ($0, true) }) + changes.shallow.map({ ($0, false) }) {
            guard let local = translate(path) else { continue }
            switch target(for: local, in: index) {
            case .ignore: continue
            case .deep(let id): deep.insert(id)
            case .exact(let id): if isDeep { deep.insert(id) } else { shallow.insert(id) }
            case .ancestor(let id): shallow.insert(id)
            }
        }
        if deep.isEmpty && shallow.isEmpty { return (index, .unchanged, []) }
        if deep.contains(FileIndex.rootID) || deep.count + shallow.count > config.maxIncrementalDirectories {
            return (nil, .full(reason: "Changes too broad"), [])
        }

        // Drop targets already covered by a deep rescan of an ancestor.
        func coveredByDeep(_ id: Int32) -> Bool {
            var cursor = index.dirs[Int(id)].parent
            while cursor >= 0 {
                if deep.contains(cursor) { return true }
                cursor = index.dirs[Int(cursor)].parent
            }
            return false
        }
        deep = deep.filter { !coveredByDeep($0) }
        shallow = shallow.filter { !deep.contains($0) && !coveredByDeep($0) }

        var builder = IndexBuilder(index)
        var dead = [Bool](repeating: false, count: index.dirs.count)
        func killSubtree(_ id: Int32, includingSelf: Bool) {
            if includingSelf { dead[Int(id)] = true }
            for child in index.children(ofDir: id) { killSubtree(child, includingSelf: true) }
        }

        var dropFilesOf = Set<Int32>()
        var seeds: [ParallelWalker.Seed] = []
        var shallowChildren: [Int32: [String: Int32]] = [:]
        for id in deep.sorted() {
            let path = index.path(ofDir: id)
            killSubtree(id, includingSelf: false)
            dropFilesOf.insert(id)
            guard directoryExists(path) else { killSubtree(id, includingSelf: true); continue }
            seeds.append(.init(id: id, path: path, mode: index.dirs[Int(id)].mode))
        }
        for id in shallow.sorted() {
            let path = index.path(ofDir: id)
            dropFilesOf.insert(id)
            guard directoryExists(path) else { killSubtree(id, includingSelf: true); continue }
            var existing: [String: Int32] = [:]
            for child in index.children(ofDir: id) { existing[index.name(index.dirs[Int(child)].name)] = child }
            shallowChildren[id] = existing
            seeds.append(.init(id: id, path: path, mode: index.dirs[Int(id)].mode, existingChildren: existing))
        }
        builder.files.removeAll { dropFilesOf.contains($0.dir) || dead[Int($0.dir)] }

        progress?.setPhase("Updating \(seeds.count) changed folder\(seeds.count == 1 ? "" : "s")")
        let refreshed = try await config.walker.walk(seeds: seeds, into: &builder, progress: progress)

        // Sub-directories that a shallow re-read didn't find any more are gone.
        for (_, existing) in shallowChildren {
            for (_, child) in existing where !refreshed.contains(child) { killSubtree(child, includingSelf: true) }
        }
        dead.append(contentsOf: repeatElement(false, count: builder.dirs.count - dead.count))
        builder.compact(dead: dead)
        let updated = builder.finish(eventID: newEventID, fseventsUUID: index.fseventsUUID, configHash: index.configHash)
        return (updated, .incremental(shallow: shallow.count, deep: deep.count), deep.sorted().map { index.path(ofDir: $0) })
    }

    // MARK: Helpers

    private enum Target {
        case ignore
        /// Inside a sizeOnly folder (whose contents aren't kept): re-size that folder.
        case deep(Int32)
        case exact(Int32)
        /// Path isn't in the index (new folder): re-read the nearest known ancestor, which discovers it.
        case ancestor(Int32)
    }

    private static func target(for path: String, in index: FileIndex) -> Target {
        let rootPath = index.rootPath
        var cursor = FileIndex.rootID
        if path != rootPath {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard path.hasPrefix(prefix) else { return .ignore }
            for component in path.dropFirst(prefix.count).split(separator: "/") {
                let record = index.dirs[Int(cursor)]
                if record.mode == .skipped { return .ignore }
                if record.mode == .sizeOnly { return .deep(cursor) }
                guard let next = index.children(ofDir: cursor).first(where: { index.name(index.dirs[Int($0)].name) == component }) else {
                    return .ancestor(cursor)
                }
                cursor = next
            }
        }
        switch index.dirs[Int(cursor)].mode {
        case .skipped: return .ignore
        case .sizeOnly: return .deep(cursor)
        case .indexed: return .exact(cursor)
        }
    }

    static func normalizedRoot(_ root: String) -> String {
        var path = (root as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

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

        /// See `ParallelWalker.denseMinFiles`.
        var denseMinFiles = ParallelWalker.defaultDenseMinFiles

        var walker: ParallelWalker {
            var walker = ParallelWalker(width: width, policy: policy, retain: retain)
            walker.denseMinFiles = denseMinFiles
            return walker
        }
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
        /// Huge folders updated file by file, and how many files were re-read for them (diagnostics).
        var patchedFolders = 0
        var patchedFiles = 0
    }

    /// What an incremental update did, beyond its `Report.Kind` (diagnostics and tests).
    struct PatchDetails: Sendable, Equatable {
        var deepPaths: [String] = []
        /// Folders updated from their per-file table, by path, with the number of files re-read.
        var patchedFolders: [String: Int] = [:]
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

        let (updated, kind, details) = try await applyReturningDetails(changes, to: saved, newEventID: replayFrom, configuration: config, progress: progress)
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
                                replayDuration: replayDuration, deepPaths: details.deepPaths,
                                patchedFolders: details.patchedFolders.count,
                                patchedFiles: details.patchedFolders.values.reduce(0, +)))
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

    /// `apply`, plus the folders re-walked deeply (internal so tests can check them).
    static func applyReturningDeep(
        _ changes: ChangeSet,
        to index: FileIndex,
        newEventID: UInt64,
        configuration: Configuration?,
        progress: ScanProgress?
    ) async throws -> (FileIndex?, Report.Kind, [String]) {
        let (updated, kind, details) = try await applyReturningDetails(
            changes, to: index, newEventID: newEventID, configuration: configuration, progress: progress
        )
        return (updated, kind, details.deepPaths)
    }

    /// `apply`, plus what was re-read and how (internal so tests can check it).
    static func applyReturningDetails(
        _ changes: ChangeSet,
        to index: FileIndex,
        newEventID: UInt64,
        configuration: Configuration?,
        progress: ScanProgress?
    ) async throws -> (FileIndex?, Report.Kind, PatchDetails) {
        let config = configuration ?? Configuration(root: index.rootPath)
        if changes.requiresFullRescan { return (nil, .full(reason: changes.fullRescanReason ?? ""), PatchDetails()) }

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

        // Group file events by folder first: a build can write 100 k files into a few hundred folders, and
        // each folder is resolved once.
        var filesByFolder: [String: [String]] = [:]
        for path in changes.files {
            let ns = path as NSString
            filesByFolder[ns.deletingLastPathComponent, default: []].append(ns.lastPathComponent)
        }

        // Resolve every changed folder to the directory that must be re-read. A changed file in a folder with
        // a per-file table is re-read alone; anywhere else it is a change of its folder, as with a
        // folder-level stream.
        var fileTargets: [Int32: Set<String>] = [:]
        var deep = Set<Int32>()
        var shallow = Set<Int32>()
        func tooBroad() -> Bool { deep.count + shallow.count + fileTargets.count > config.maxIncrementalDirectories }
        for (path, isDeep) in changes.deep.map({ ($0, true) }) + changes.shallow.map({ ($0, false) }) {
            guard let local = translate(path) else { continue }
            switch target(for: local, in: index) {
            case .ignore: continue
            case .deep(let id): deep.insert(id)
            case .exact(let id): if isDeep { deep.insert(id) } else { shallow.insert(id) }
            case .ancestor(let id): shallow.insert(id)
            }
            if tooBroad() { return (nil, .full(reason: "Changes too broad"), PatchDetails()) }
        }
        for (folder, names) in filesByFolder {
            guard let local = translate(folder) else { continue }
            switch target(for: local, in: index) {
            case .ignore: continue
            case .deep(let id): deep.insert(id)
            case .exact(let id):
                if index.denseEntries(ofDir: id) != nil { fileTargets[id, default: []].formUnion(names) } else { shallow.insert(id) }
            case .ancestor(let id): shallow.insert(id)
            }
            if tooBroad() { return (nil, .full(reason: "Changes too broad"), PatchDetails()) }
        }
        // Many changed files: one folder read is cheaper than a stat each (and a bulk read is ~100× faster
        // per file than single stats).
        for (id, names) in fileTargets where names.count > max(256, (index.denseEntries(ofDir: id)?.count ?? 0) / 16) {
            fileTargets[id] = nil
            shallow.insert(id)
        }
        if deep.isEmpty && shallow.isEmpty && fileTargets.isEmpty { return (index, .unchanged, PatchDetails()) }
        if deep.contains(FileIndex.rootID) || deep.count + shallow.count + fileTargets.count > config.maxIncrementalDirectories {
            return (nil, .full(reason: "Changes too broad"), PatchDetails())
        }

        // Drop targets already covered by a deep rescan of an ancestor.
        func coveredByDeep(_ id: Int32) -> Bool {
            var cursor = index.record(id).parent
            while cursor >= 0 {
                if deep.contains(cursor) { return true }
                cursor = index.record(cursor).parent
            }
            return false
        }
        deep = deep.filter { !coveredByDeep($0) }
        shallow = shallow.filter { !deep.contains($0) && !coveredByDeep($0) }

        // Re-read each named file. Anything a delta can't express exactly (a new sub-folder, a hard link, a
        // clone, an unreadable file) turns the patch into a re-read of the whole folder.
        var filePatches: [Int32: [String: BulkEntry?]] = [:]
        let statReader = BulkDirectoryReader(bufferSize: 4096)
        for (id, names) in fileTargets.sorted(by: { $0.key < $1.key }) {
            if shallow.contains(id) || deep.contains(id) || coveredByDeep(id) { continue }
            try Task.checkCancellation()
            let dirPath = index.path(ofDir: id)
            var results: [String: BulkEntry?] = [:]
            var exact = true
            for name in names {
                switch statReader.readItem(path: (dirPath == "/" ? "" : dirPath) + "/" + name) {
                case .missing:
                    results[name] = .some(nil)
                case .found(let entry) where entry.kind == .file && DenseEntry.isSelfContained(entry):
                    results[name] = entry
                case .found(let entry) where entry.kind == .symlink || entry.kind == .other:
                    results[name] = .some(nil) // not counted, like in a folder read
                case .found, .failed, .differentName:
                    // .differentName: the table can't tell which spelling is current; a read can.
                    exact = false
                }
                if !exact { break }
            }
            if exact { filePatches[id] = results } else { shallow.insert(id) }
        }

        var builder = IndexBuilder(index)
        // Ids here are combined ones (visible + hidden), matching `IndexBuilder(index)`.
        var dead = [Bool](repeating: false, count: index.dirCount)
        func killSubtree(_ id: Int32, includingSelf: Bool) {
            if includingSelf { dead[Int(id)] = true }
            for child in index.allChildren(ofDir: id) { killSubtree(child, includingSelf: true) }
        }

        var dropFilesOf = Set<Int32>()
        var seeds: [ParallelWalker.Seed] = []
        var shallowChildren: [Int32: [String: ParallelWalker.ExistingChild]] = [:]
        for id in deep.sorted() {
            let path = index.path(ofDir: id)
            killSubtree(id, includingSelf: false)
            dropFilesOf.insert(id)
            guard directoryExists(path) else { killSubtree(id, includingSelf: true); continue }
            seeds.append(.init(id: id, path: path, mode: index.record(id).mode))
        }
        for id in shallow.sorted() {
            let path = index.path(ofDir: id)
            dropFilesOf.insert(id)
            guard directoryExists(path) else { killSubtree(id, includingSelf: true); continue }
            var existing: [String: ParallelWalker.ExistingChild] = [:]
            for child in index.allChildren(ofDir: id) {
                let record = index.record(child)
                existing[index.name(record.name)] = .init(id: child, fileID: record.fileID)
            }
            shallowChildren[id] = existing
            seeds.append(.init(id: id, path: path, mode: index.record(id).mode, existingChildren: existing))
        }
        builder.files.removeAll { dropFilesOf.contains($0.dir) || dead[Int($0.dir)] }
        if !filePatches.isEmpty { applyFilePatches(filePatches, to: &builder, retain: config.retain) }

        progress?.setPhase("Updating \(seeds.count) changed folder\(seeds.count == 1 ? "" : "s")")
        let refreshed = seeds.isEmpty ? [] : try await config.walker.walk(seeds: seeds, into: &builder, progress: progress)

        // Sub-directories that a shallow re-read didn't find any more (or found replaced) are gone.
        for (_, existing) in shallowChildren {
            for (_, child) in existing where !refreshed.contains(child.id) { killSubtree(child.id, includingSelf: true) }
        }
        dead.append(contentsOf: repeatElement(false, count: builder.dirs.count - dead.count))
        builder.compact(dead: dead)
        // builtAt stays the date of the last full walk, so `maxIndexAge` forces a fresh walk every week even
        // when the user rescans daily; any drift a patch can't see heals then.
        let updated = builder.finish(
            eventID: newEventID, fseventsUUID: index.fseventsUUID, configHash: index.configHash, builtAt: index.builtAt
        )
        var details = PatchDetails(deepPaths: deep.sorted().map { index.path(ofDir: $0) })
        for (id, results) in filePatches { details.patchedFolders[index.path(ofDir: id)] = results.count }
        return (updated, .incremental(shallow: shallow.count, deep: deep.count), details)
    }

    /// Applies re-read files (nil = gone or not counted) to folders with a per-file table: updates the table
    /// and the kept file records, then re-adds the folder's own stats from the table, exactly as a read would.
    private static func applyFilePatches(_ patches: [Int32: [String: BulkEntry?]], to builder: inout IndexBuilder, retain: RetainRule) {
        let names = builder.names
        func nameString(_ ref: NameRef) -> String {
            names.withUnsafeBufferPointer {
                String(decoding: UnsafeBufferPointer(rebasing: $0[Int(ref.offset)..<Int(ref.offset + ref.length)]), as: UTF8.self)
            }
        }
        // Kept records of the named files are replaced below.
        builder.files.removeAll { file in
            guard let results = patches[file.dir] else { return false }
            return results[nameString(file.name)] != nil
        }
        var table: [Int32: [DenseEntry]] = [:]
        builder.denseEntries.removeAll { entry in
            guard let results = patches[entry.dir] else { return false }
            if results[nameString(entry.name)] == nil { table[entry.dir, default: []].append(entry) }
            return true
        }
        for (id, results) in patches.sorted(by: { $0.key < $1.key }) {
            var entries = table[id] ?? []
            for (name, found) in results.sorted(by: { $0.key < $1.key }) {
                guard let entry = found else { continue }
                let ref = Array(name.utf8).withUnsafeBytes { bytes -> NameRef in
                    if retain.keeps(entry, name: bytes) {
                        let ref = builder.appendName(bytes)
                        builder.files.append(FileRecord(
                            dir: id, name: ref,
                            linkCount: entry.linkCount, bsdFlags: entry.bsdFlags, fileID: entry.fileID,
                            logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize,
                            privateSize: entry.privateSize,
                            modified: entry.modified, accessed: entry.accessed, created: entry.created
                        ))
                        return ref
                    }
                    return builder.appendName(bytes)
                }
                entries.append(DenseEntry(dir: id, name: ref, entry: entry))
            }
            var d = builder.dirs[Int(id)]
            d.ownFiles = UInt64(entries.count)
            d.ownLogical = entries.reduce(0) { $0 + $1.logicalSize }
            d.ownAllocated = entries.reduce(0) { $0 + $1.displaySize }
            d.ownReclaimable = entries.reduce(0) { $0 + $1.reclaimableSize }
            d.ownNewestModified = entries.reduce(0) { max($0, $1.modified) }
            builder.dirs[Int(id)] = d
            builder.denseEntries.append(contentsOf: entries)
        }
    }

    // MARK: Helpers

    private enum Target {
        case ignore
        /// At or below the deepest kept record of a sizeOnly folder (whose contents aren't kept): re-size it.
        case deep(Int32)
        case exact(Int32)
        /// Path isn't in the index (new folder): re-read the nearest known ancestor, which discovers it.
        case ancestor(Int32)
    }

    /// Follows the path through visible and hidden records. Inside a sizeOnly folder the kept levels above
    /// `IndexBuilder.sizeOnlyKeptDepth` are re-read shallowly like indexed folders; the deepest kept level
    /// holds its whole subtree folded in, so a change at or below it re-sizes just that record.
    private static func target(for path: String, in index: FileIndex) -> Target {
        let rootPath = index.rootPath
        let leafDepth = IndexBuilder.sizeOnlyKeptDepth
        var cursor = FileIndex.rootID
        var depth = -1 // levels below the outermost sizeOnly folder on the path, -1 outside one
        if path != rootPath {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard path.hasPrefix(prefix) else { return .ignore }
            for component in path.dropFirst(prefix.count).split(separator: "/") {
                let record = index.record(cursor)
                if record.mode == .skipped { return .ignore }
                if depth >= leafDepth { return .deep(cursor) }
                guard let next = index.allChildren(ofDir: cursor).first(where: { index.name(index.record($0).name) == component }) else {
                    return .ancestor(cursor)
                }
                cursor = next
                if depth >= 0 { depth += 1 } else if index.record(cursor).mode == .sizeOnly { depth = 0 }
            }
        }
        switch index.record(cursor).mode {
        case .skipped: return .ignore
        case .sizeOnly: return depth >= leafDepth ? .deep(cursor) : .exact(cursor)
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

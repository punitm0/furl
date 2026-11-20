import Foundation

// MARK: - Records (plain old data, so the index can be written to disk as raw bytes)

/// Reference into `FileIndex.names` (UTF-8 bytes, no terminator).
struct NameRef: Equatable, Sendable {
    var offset: UInt32
    var length: UInt32
}

/// How the walker treats a directory.
enum DirMode: UInt8, Sendable {
    /// Children are walked and large-enough files are kept in the index.
    case indexed = 0
    /// Walked for its size only (packages, node_modules, .git, …): shown as one item, contents not kept.
    case sizeOnly = 1
    /// Not entered at all (other volumes, excluded paths). Its size is unknown (0).
    case skipped = 2
}

struct DirFlags: OptionSet, Sendable {
    let rawValue: UInt16
    static let package = DirFlags(rawValue: 1 << 0)
    static let hidden = DirFlags(rawValue: 1 << 1)
    static let unreadable = DirFlags(rawValue: 1 << 2)
    static let mountPoint = DirFlags(rawValue: 1 << 3)
    /// Some descendant could not be read, so totals are a lower bound.
    static let incomplete = DirFlags(rawValue: 1 << 4)
    /// Internal: a sub-folder pruned into this record (see `DirRecord.foldedDirs`) could not be read.
    /// `incomplete` is re-derived from it on every `recomputeTotals`.
    static let foldedIncomplete = DirFlags(rawValue: 1 << 5)
}

struct DirRecord: Sendable {
    /// Index of the parent directory, -1 for the root. Always smaller than this record's own index.
    var parent: Int32 = -1
    var name = NameRef(offset: 0, length: 0)
    var modeRaw: UInt8 = DirMode.indexed.rawValue
    var _pad: UInt8 = 0
    var flagsRaw: UInt16 = 0
    /// Sub-folders pruned into this record by `IndexBuilder.compact` (their files are in the own stats).
    var foldedDirs: UInt32 = 0
    var fileID: UInt64 = 0
    var modified: Int64 = 0
    var created: Int64 = 0

    // Files directly inside this directory (for the deepest kept record in a sizeOnly folder: its whole
    // subtree, folded in). A visible sizeOnly folder's sub-folders are hidden records, so outside the
    // engine use its total* fields: own* covers only its direct files.
    var ownFiles: UInt64 = 0
    var ownLogical: Int64 = 0
    var ownAllocated: Int64 = 0
    var ownReclaimable: Int64 = 0
    var ownNewestModified: Int64 = 0

    // Whole subtree (filled by `FileIndex.recomputeTotals`).
    var totalFiles: UInt64 = 0
    var totalDirs: UInt64 = 0
    var totalLogical: Int64 = 0
    /// Finder-style size (clones and hard links counted in full) — what Space Map shows.
    var totalAllocated: Int64 = 0
    /// What deleting the folder frees — identical to `FileSizeHelper.directorySize`.
    var totalReclaimable: Int64 = 0
    var newestModified: Int64 = 0

    var mode: DirMode {
        get { DirMode(rawValue: modeRaw) ?? .indexed }
        set { modeRaw = newValue.rawValue }
    }
    var flags: DirFlags {
        get { DirFlags(rawValue: flagsRaw) }
        set { flagsRaw = newValue.rawValue }
    }
}

struct FileRecord: Sendable {
    var dir: Int32 = 0
    var name = NameRef(offset: 0, length: 0)
    var linkCount: UInt32 = 1
    var bsdFlags: UInt32 = 0
    var fileID: UInt64 = 0
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    /// -1 when the volume doesn't report APFS private size.
    var privateSize: Int64 = -1
    var modified: Int64 = 0
    var accessed: Int64 = 0
    var created: Int64 = 0

    var reclaimableSize: Int64 {
        if linkCount > 1 { return 0 }
        if privateSize >= 0 { return privateSize }
        return allocatedSize > 0 ? allocatedSize : logicalSize
    }
    var displaySize: Int64 { allocatedSize > 0 ? allocatedSize : logicalSize }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
    var accessedDate: Date { Date(timeIntervalSince1970: TimeInterval(accessed)) }
    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
}

/// One regular file of a huge flat folder (see `FileIndex.denseEntries`). Every file is kept, however small,
/// so a change FSEvents names can be applied as a delta instead of re-reading the whole folder.
struct DenseEntry: Sendable {
    var dir: Int32 = 0
    var name = NameRef(offset: 0, length: 0)
    var linkCount: UInt32 = 1
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    /// -1 when the volume doesn't report APFS private size.
    var privateSize: Int64 = -1
    var modified: Int64 = 0

    init(dir: Int32, name: NameRef, entry: BulkEntry) {
        self.dir = dir
        self.name = name
        linkCount = entry.linkCount
        logicalSize = entry.logicalSize
        allocatedSize = entry.allocatedSize
        privateSize = entry.privateSize
        modified = entry.modified
    }

    /// Same rules as `BulkEntry`, so own stats summed from these equal a fresh read.
    var reclaimableSize: Int64 {
        if linkCount > 1 { return 0 }
        if privateSize >= 0 { return privateSize }
        return allocatedSize > 0 ? allocatedSize : logicalSize
    }
    var displaySize: Int64 { allocatedSize > 0 ? allocatedSize : logicalSize }

    /// A file whose blocks are its own: not hard-linked and no APFS clone sharing. Only folders made of such
    /// files get a table, because a change to one of them can't change another file's size behind our back
    /// (deleting a clone or a hard link does, without an event for the other file).
    static func isSelfContained(_ entry: BulkEntry) -> Bool {
        entry.linkCount <= 1 && (entry.privateSize < 0 || entry.privateSize == entry.allocatedSize)
    }
}

// MARK: - Index

/// The result of one walk: every directory under `rootPath` with its aggregates, plus the files the
/// `RetainRule` asked to keep. Paths are interned as a parent-pointer tree; build them on demand.
///
/// Immutable and `Sendable`; the incremental updater produces a new index rather than mutating one.
///
/// Inside a sizeOnly folder the index also keeps sub-folder records down to
/// `IndexBuilder.sizeOnlyKeptDepth` levels, so a change deep inside `.git` or `.build` re-sizes one small
/// sub-tree instead of the whole folder. Those records live in `hiddenDirs`, which only the incremental
/// updater reads: `dirs` and every query still show a sizeOnly folder as a single leaf.
final class FileIndex: Sendable {
    static let rootID: Int32 = 0

    let rootPath: String
    /// Every visible directory; ids 0..<dirs.count.
    let dirs: [DirRecord]
    /// Sub-folders of sizeOnly folders; ids dirs.count..<dirCount. Parent ids use the same combined
    /// numbering and are always smaller than the record's own id.
    let hiddenDirs: [DirRecord]
    /// Sorted by `dir`, so a directory's files are contiguous (see `files(inDir:)`).
    let files: [FileRecord]
    let names: [UInt8]
    /// Every file of each huge flat indexed folder (at least `ParallelWalker.denseMinFiles` files, all
    /// self-contained), sorted by `dir`. Only the incremental updater reads them: with file-level FSEvents it
    /// re-reads just the files that changed and re-adds the folder's own stats from this table.
    let denseEntries: [DenseEntry]
    /// FSEvents event ID taken just *before* the walk started; replaying from here catches changes made during it.
    let eventID: UInt64
    /// FSEvents database UUID for the root's volume; if it changes, stored event IDs are meaningless.
    let fseventsUUID: String
    let builtAt: Date
    /// Fingerprint of the WalkPolicy + RetainRule that built it (a different config needs a full walk).
    let configHash: UInt64

    private let fileStart: [Int32]
    private let childDirs: [[Int32]]
    /// Hidden children of visible sizeOnly folders, keyed by the folder's id.
    private let hiddenRootChildren: [Int32: [Int32]]
    /// Children of hidden records, indexed by `id - dirs.count`.
    private let hiddenChildDirs: [[Int32]]
    /// Range of `denseEntries` per folder that has a table.
    private let denseRanges: [Int32: Range<Int>]

    init(
        rootPath: String, dirs: [DirRecord], hiddenDirs: [DirRecord] = [], files: [FileRecord], names: [UInt8],
        denseEntries: [DenseEntry] = [],
        eventID: UInt64, fseventsUUID: String, builtAt: Date, configHash: UInt64
    ) {
        self.rootPath = rootPath
        self.dirs = dirs
        self.hiddenDirs = hiddenDirs
        self.files = files
        self.names = names
        self.denseEntries = denseEntries
        var ranges: [Int32: Range<Int>] = [:]
        var lo = 0
        while lo < denseEntries.count {
            let dir = denseEntries[lo].dir
            var hi = lo + 1
            while hi < denseEntries.count && denseEntries[hi].dir == dir { hi += 1 }
            ranges[dir] = lo..<hi
            lo = hi
        }
        self.denseRanges = ranges
        self.eventID = eventID
        self.fseventsUUID = fseventsUUID
        self.builtAt = builtAt
        self.configHash = configHash

        // files are sorted by dir: start[d]..<start[d + 1] is directory d's run.
        var start = [Int32](repeating: 0, count: dirs.count + 1)
        var cursor = 0
        for d in 0...dirs.count {
            while cursor < files.count && Int(files[cursor].dir) < d { cursor += 1 }
            start[d] = Int32(cursor)
        }
        self.fileStart = start

        var children = [[Int32]](repeating: [], count: dirs.count)
        for (id, dir) in dirs.enumerated() where dir.parent >= 0 {
            children[Int(dir.parent)].append(Int32(id))
        }
        self.childDirs = children

        let visible = dirs.count
        var rootChildren: [Int32: [Int32]] = [:]
        var hiddenChildren = [[Int32]](repeating: [], count: hiddenDirs.count)
        for (offset, dir) in hiddenDirs.enumerated() {
            let id = Int32(visible + offset)
            if Int(dir.parent) < visible {
                rootChildren[dir.parent, default: []].append(id)
            } else {
                hiddenChildren[Int(dir.parent) - visible].append(id)
            }
        }
        self.hiddenRootChildren = rootChildren
        self.hiddenChildDirs = hiddenChildren
    }

    // MARK: Navigation

    var root: DirRecord { dirs[Int(Self.rootID)] }

    func name(_ ref: NameRef) -> String {
        names.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(rebasing: buf[Int(ref.offset)..<Int(ref.offset + ref.length)]), as: UTF8.self)
        }
    }

    func name(ofDir id: Int32) -> String { id == Self.rootID ? (rootPath as NSString).lastPathComponent : name(record(id).name) }

    /// Also accepts hidden ids (the incremental updater builds paths for them).
    func path(ofDir id: Int32) -> String {
        if id == Self.rootID { return rootPath }
        var components: [String] = []
        var cursor = id
        while cursor > Self.rootID {
            let d = record(cursor)
            components.append(name(d.name))
            cursor = d.parent
        }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + components.reversed().joined(separator: "/")
    }

    func path(of file: FileRecord) -> String {
        let dirPath = path(ofDir: file.dir)
        return (dirPath == "/" ? "" : dirPath) + "/" + name(file.name)
    }

    func children(ofDir id: Int32) -> [Int32] { childDirs[Int(id)] }

    // MARK: Internal records (incremental updater only)

    /// Visible plus hidden directory records.
    var dirCount: Int { dirs.count + hiddenDirs.count }

    /// A visible or hidden record by combined id.
    func record(_ id: Int32) -> DirRecord {
        Int(id) < dirs.count ? dirs[Int(id)] : hiddenDirs[Int(id) - dirs.count]
    }

    /// Visible children plus, for sizeOnly folders and their kept sub-folders, the hidden ones.
    func allChildren(ofDir id: Int32) -> [Int32] {
        if Int(id) >= dirs.count { return hiddenChildDirs[Int(id) - dirs.count] }
        guard let hidden = hiddenRootChildren[id] else { return childDirs[Int(id)] }
        return childDirs[Int(id)] + hidden
    }

    /// The per-file table of a huge flat folder, or nil when the folder has none.
    func denseEntries(ofDir id: Int32) -> ArraySlice<DenseEntry>? {
        guard let range = denseRanges[id] else { return nil }
        return denseEntries[range]
    }

    func files(inDir id: Int32) -> ArraySlice<FileRecord> {
        let lo = Int(fileStart[Int(id)]), hi = Int(fileStart[Int(id) + 1])
        guard hi > lo else { return [] }
        return files[lo..<hi]
    }

    /// Directory id for an absolute path inside the index, or nil (outside the root, a file, or pruned
    /// because it sits inside a sizeOnly folder).
    func dirID(forPath path: String) -> Int32? {
        let standardized = (path as NSString).standardizingPath
        if standardized == rootPath { return Self.rootID }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard standardized.hasPrefix(prefix) else { return nil }
        var cursor = Self.rootID
        for component in standardized.dropFirst(prefix.count).split(separator: "/") {
            guard let next = childDirs[Int(cursor)].first(where: { name(dirs[Int($0)].name) == component }) else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Clone- and hard-link-aware reclaimable bytes for a folder or kept file — the drop-in replacement
    /// for `FileSizeHelper.directorySize` when the path is covered by this index. Nil when it isn't.
    func reclaimableSize(ofPath path: String) -> Int64? {
        if let id = dirID(forPath: path) {
            let d = dirs[Int(id)]
            return d.mode == .skipped ? nil : d.totalReclaimable
        }
        let parent = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent
        guard let dirID = dirID(forPath: parent) else { return nil }
        return files(inDir: dirID).first(where: { name($0.name) == leaf })?.reclaimableSize
    }

    func isInside(_ id: Int32, _ ancestor: Int32) -> Bool {
        var cursor = id
        while cursor >= 0 {
            if cursor == ancestor { return true }
            cursor = dirs[Int(cursor)].parent
        }
        return false
    }

    // MARK: Queries used by the scanners

    /// Directories with the given name (e.g. "node_modules") — each one is a single, already-sized item.
    func directories(named wanted: Set<String>) -> [Int32] {
        var result: [Int32] = []
        for id in 1..<dirs.count where wanted.contains(name(dirs[id].name)) {
            result.append(Int32(id))
        }
        return result
    }

    /// Kept files at least `minBytes` (Finder size), largest first. `include` can filter by directory.
    func largeFiles(minBytes: Int64, include: ((Int32) -> Bool)? = nil) -> [FileRecord] {
        files.filter { $0.displaySize >= minBytes && (include?($0.dir) ?? true) }
            .sorted { $0.displaySize > $1.displaySize }
    }

    /// Same-length groups for duplicate detection; hard links to one inode count once.
    func sizeBuckets(minBytes: Int64, include: ((Int32) -> Bool)? = nil) -> [Int64: [FileRecord]] {
        var seen = Set<UInt64>()
        var buckets: [Int64: [FileRecord]] = [:]
        for file in files where file.logicalSize >= minBytes && (include?(file.dir) ?? true) {
            if file.linkCount > 1 && !seen.insert(file.fileID).inserted { continue }
            buckets[file.logicalSize, default: []].append(file)
        }
        return buckets.filter { $0.value.count > 1 }
    }

    // MARK: Visitors

    /// Visits every directory, then every kept file, in one pass. Lets several features share one index.
    func accept(_ visitors: [any IndexVisitor]) {
        for id in 0..<dirs.count {
            for visitor in visitors { visitor.visit(dir: Int32(id), record: dirs[id], in: self) }
        }
        for file in files {
            for visitor in visitors { visitor.visit(file: file, in: self) }
        }
    }
}

/// Plug-in over a finished index (Large Files, Smart Review, Junk rules, …).
protocol IndexVisitor: AnyObject {
    func visit(dir id: Int32, record: DirRecord, in index: FileIndex)
    func visit(file: FileRecord, in index: FileIndex)
}

extension IndexVisitor {
    func visit(dir id: Int32, record: DirRecord, in index: FileIndex) {}
    func visit(file: FileRecord, in index: FileIndex) {}
}

// MARK: - Building

/// Mutable form used while walking and merging. Produces a `FileIndex` via `finish`.
struct IndexBuilder {
    /// How many levels of sub-folders a sizeOnly folder keeps as (hidden) records. The deepest kept level
    /// folds its whole subtree into its own stats, the way the sizeOnly folder itself did before.
    static let sizeOnlyKeptDepth = 2

    var rootPath: String
    /// Visible and hidden records in one array (combined ids, as in `FileIndex.record(_:)`).
    var dirs: [DirRecord]
    var files: [FileRecord]
    var names: [UInt8]
    /// Unsorted while walking and patching; `compact` sorts it by dir.
    var denseEntries: [DenseEntry]
    /// `dirs[..<visibleCount]` are the visible records; set by `compact`, which `finish` relies on.
    private(set) var visibleCount: Int?

    init(rootPath: String) {
        self.rootPath = rootPath
        self.dirs = []
        self.files = []
        self.names = []
        self.denseEntries = []
    }

    init(_ index: FileIndex) {
        rootPath = index.rootPath
        dirs = index.dirs + index.hiddenDirs
        files = index.files
        names = index.names
        denseEntries = index.denseEntries
        visibleCount = index.dirs.count
    }

    mutating func appendName(_ bytes: UnsafeRawBufferPointer) -> NameRef {
        let ref = NameRef(offset: UInt32(names.count), length: UInt32(bytes.count))
        names.append(contentsOf: bytes)
        return ref
    }

    /// Drops dead directories (and their files), prunes sizeOnly folders to `sizeOnlyKeptDepth` levels of
    /// sub-folders (deeper ones fold into the deepest kept one), puts visible records before hidden ones,
    /// rebuilds the name table and recomputes totals.
    mutating func compact(dead: [Bool]? = nil) {
        let count = dirs.count
        var keep = [Bool](repeating: true, count: count)
        var remap = [Int32](repeating: -1, count: count)
        // Levels below the outermost sizeOnly ancestor: 0 for that folder itself, -1 outside sizeOnly folders.
        var depth = [Int32](repeating: -1, count: count)
        for id in 0..<count {
            let parent = Int(dirs[id].parent)
            if let dead, dead[id] { keep[id] = false; continue }
            guard parent >= 0 else { continue }
            // Parent ids are always smaller, so the parent's verdict is final by now.
            if depth[parent] >= 0 {
                depth[id] = depth[parent] + 1
            } else if dirs[id].mode == .sizeOnly {
                depth[id] = 0
            }
            if !keep[parent] || depth[id] > Int32(Self.sizeOnlyKeptDepth) { keep[id] = false }
        }
        // Fold pruned sizeOnly descendants into their deepest kept ancestor before dropping them.
        for id in stride(from: count - 1, through: 1, by: -1) where !keep[id] {
            if let dead, dead[id] { continue }
            let parent = Int(dirs[id].parent)
            guard parent >= 0, !(dead?[parent] ?? false) else { continue }
            dirs[parent].ownFiles += dirs[id].ownFiles
            dirs[parent].ownLogical += dirs[id].ownLogical
            dirs[parent].ownAllocated += dirs[id].ownAllocated
            dirs[parent].ownReclaimable += dirs[id].ownReclaimable
            dirs[parent].ownNewestModified = max(dirs[parent].ownNewestModified, dirs[id].ownNewestModified)
            if dirs[id].flags.contains(.unreadable) || dirs[id].flags.contains(.foldedIncomplete) {
                dirs[parent].flags.insert(.foldedIncomplete)
            }
            dirs[parent].foldedDirs += 1 + dirs[id].foldedDirs
        }

        var newNames: [UInt8] = []
        newNames.reserveCapacity(names.count)
        func copyName(_ ref: NameRef) -> NameRef {
            let out = NameRef(offset: UInt32(newNames.count), length: ref.length)
            newNames.append(contentsOf: names[Int(ref.offset)..<Int(ref.offset + ref.length)])
            return out
        }

        // Visible records first, then hidden ones (anything below a sizeOnly folder). Both passes keep the
        // original order, so parents still come before their children.
        var newDirs: [DirRecord] = []
        newDirs.reserveCapacity(count)
        for hidden in [false, true] {
            for id in 0..<count where keep[id] && (depth[id] > 0) == hidden {
                var record = dirs[id]
                remap[id] = Int32(newDirs.count)
                record.parent = record.parent >= 0 ? remap[Int(record.parent)] : -1
                record.name = copyName(record.name)
                newDirs.append(record)
            }
            if !hidden { visibleCount = newDirs.count }
        }

        var newFiles: [FileRecord] = []
        newFiles.reserveCapacity(files.count)
        for var file in files {
            let mapped = remap[Int(file.dir)]
            guard mapped >= 0, dirs[Int(file.dir)].mode == .indexed else { continue }
            file.dir = mapped
            file.name = copyName(file.name)
            newFiles.append(file)
        }
        newFiles.sort { $0.dir < $1.dir }

        var newDense: [DenseEntry] = []
        newDense.reserveCapacity(denseEntries.count)
        for var entry in denseEntries {
            let mapped = remap[Int(entry.dir)]
            guard mapped >= 0, dirs[Int(entry.dir)].mode == .indexed else { continue }
            entry.dir = mapped
            entry.name = copyName(entry.name)
            newDense.append(entry)
        }
        newDense.sort { $0.dir < $1.dir }

        dirs = newDirs
        files = newFiles
        names = newNames
        denseEntries = newDense
        recomputeTotals()
    }

    /// Bottom-up aggregation; relies on parent index < child index.
    mutating func recomputeTotals() {
        for id in 0..<dirs.count {
            let d = dirs[id]
            dirs[id].totalFiles = d.ownFiles
            dirs[id].totalLogical = d.ownLogical
            dirs[id].totalAllocated = d.ownAllocated
            dirs[id].totalReclaimable = d.ownReclaimable
            dirs[id].newestModified = d.ownNewestModified
            // Folded sub-folders (from compact()) count here; kept ones are added below.
            dirs[id].totalDirs = UInt64(d.foldedDirs)
            if d.flags.contains(.foldedIncomplete) { dirs[id].flags.insert(.incomplete) } else { dirs[id].flags.remove(.incomplete) }
        }
        for id in stride(from: dirs.count - 1, through: 1, by: -1) {
            let child = dirs[id]
            let parent = Int(child.parent)
            guard parent >= 0 else { continue }
            dirs[parent].totalFiles += child.totalFiles
            dirs[parent].totalDirs += 1 + child.totalDirs
            dirs[parent].totalLogical += child.totalLogical
            dirs[parent].totalAllocated += child.totalAllocated
            dirs[parent].totalReclaimable += child.totalReclaimable
            dirs[parent].newestModified = max(dirs[parent].newestModified, child.newestModified)
            if child.flags.contains(.unreadable) || child.flags.contains(.incomplete) {
                dirs[parent].flags.insert(.incomplete)
            }
        }
    }

    /// Call after `compact` whenever directories were added, so visible records come first.
    func finish(eventID: UInt64, fseventsUUID: String, configHash: UInt64, builtAt: Date = Date()) -> FileIndex {
        let visible = min(visibleCount ?? dirs.count, dirs.count)
        return FileIndex(
            rootPath: rootPath, dirs: Array(dirs[..<visible]), hiddenDirs: Array(dirs[visible...]), files: files, names: names,
            denseEntries: denseEntries,
            eventID: eventID, fseventsUUID: fseventsUUID, builtAt: builtAt, configHash: configHash
        )
    }
}

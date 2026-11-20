import Foundation

/// What a folder's bytes are, for "what grew" by category. Raw values are stored on disk; append only.
enum SnapshotCategory: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case other = 0
    case developer
    case caches
    case aiModels
    case docker
    case media
    case documents
    case downloads
    case appData
    case trash

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .other: return "Other"
        case .developer: return "Developer"
        case .caches: return "Caches & logs"
        case .aiModels: return "AI models"
        case .docker: return "Docker"
        case .media: return "Media"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .appData: return "App data"
        case .trash: return "Trash"
        }
    }

    /// Folders (relative to home) that start a category. The most specific match wins; children inherit.
    static let pathRules: [String: SnapshotCategory] = [
        "Library/Developer": .developer,
        "Library/Caches": .caches,
        "Library/Logs": .caches,
        ".cache": .caches,
        ".npm": .caches,
        ".yarn": .caches,
        ".pnpm-store": .caches,
        ".gradle": .caches,
        ".m2": .caches,
        ".cargo/registry": .caches,
        "go/pkg/mod": .caches,
        "Library/Caches/Homebrew": .caches,
        ".ollama": .aiModels,
        ".cache/huggingface": .aiModels,
        ".cache/lm-studio": .aiModels,
        ".lmstudio": .aiModels,
        "Library/Application Support/LM Studio": .aiModels,
        ".docker": .docker,
        "Library/Containers/com.docker.docker": .docker,
        "Library/Group Containers/group.com.docker": .docker,
        "Movies": .media,
        "Music": .media,
        "Pictures": .media,
        "Documents": .documents,
        "Desktop": .documents,
        "Downloads": .downloads,
        "Library/Application Support": .appData,
        "Library/Containers": .appData,
        "Library/Group Containers": .appData,
        "Library/Mail": .appData,
        "Library/Messages": .appData,
        ".Trash": .trash,
    ]

    /// Folder names that are build output or dependencies wherever they appear.
    static let nameRules: [String: SnapshotCategory] = [
        "node_modules": .developer, ".venv": .developer, "DerivedData": .developer, ".build": .developer,
        "Pods": .developer, "__pycache__": .developer, ".next": .developer, ".git": .developer,
        ".turbo": .developer, ".parcel-cache": .developer,
    ]
}

/// A compact record of folder sizes at one moment, built from the shared home index.
///
/// Folders are a parent-pointer tree (entry 0 is the root). Every folder down to `alwaysDepth` is kept,
/// deeper ones only while they are at least `minFolderBytes`, so a missing deep folder was under that size.
struct DiskSnapshot: Codable, Sendable {
    var version = 1
    var date: Date
    var rootPath: String
    var volumeUsed: Int64
    var volumeTotal: Int64
    var names: [String]
    var parents: [Int32]
    /// Finder-style allocated bytes of the whole folder (what Space Map shows).
    var sizes: [Int64]
    var cats: [UInt8]
    /// Bytes per `SnapshotCategory.rawValue`, every byte under the root counted once.
    var categoryTotals: [Int64]

    static let alwaysDepth = 2
    static let maxDepth = 8
    static let minFolderBytes: Int64 = 10_000_000

    var total: Int64 { sizes.first ?? 0 }

    /// Relative path ("Library/Caches") for every entry; the root is "".
    func relativePaths() -> [String] {
        var paths = [String](repeating: "", count: names.count)
        for i in 1..<max(1, names.count) {
            let p = Int(parents[i])
            paths[i] = p <= 0 ? names[i] : paths[p] + "/" + names[i]
        }
        return paths
    }

    func categoryTotal(_ c: SnapshotCategory) -> Int64 {
        Int(c.rawValue) < categoryTotals.count ? categoryTotals[Int(c.rawValue)] : 0
    }
}

/// Lightweight per-snapshot facts kept in the manifest, so lists, charts and the Dashboard hint never
/// decompress a snapshot.
struct SnapshotSummary: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var date: Date
    var total: Int64
    var volumeUsed: Int64
    var volumeTotal: Int64
    var folderCount: Int
}

// MARK: - Building

enum SnapshotBuilder {
    static func make(from index: FileIndex, disk: DiskUsageInfo, date: Date = Date()) -> DiskSnapshot {
        let n = index.dirs.count
        var depth = [UInt8](repeating: 0, count: n)
        var cat = [UInt8](repeating: SnapshotCategory.other.rawValue, count: n)
        var slot = [Int32](repeating: -1, count: n)
        var ruleByID: [Int32: SnapshotCategory] = [:]
        let base = index.rootPath == "/" ? "" : index.rootPath
        for (rel, c) in SnapshotCategory.pathRules {
            if let id = index.dirID(forPath: base + "/" + rel) { ruleByID[id] = c }
        }
        var totals = [Int64](repeating: 0, count: SnapshotCategory.allCases.count)
        var names: [String] = [], parents: [Int32] = [], sizes: [Int64] = [], cats: [UInt8] = []

        for id in 0..<n {
            let d = index.dirs[id]
            let p = Int(d.parent)
            if id > 0 {
                depth[id] = depth[p] == 255 ? 255 : depth[p] + 1
                cat[id] = cat[p]
            }
            if let c = ruleByID[Int32(id)] {
                cat[id] = c.rawValue
            } else if id > 0, let c = SnapshotCategory.nameRules[index.dirName(Int32(id))] {
                cat[id] = c.rawValue
            }
            // A size-only folder's own stats are only its direct files (its sub-folders are hidden records
            // that `dirs` doesn't list), so count its whole total here.
            totals[Int(cat[id])] += d.mode == .sizeOnly ? d.totalAllocated : d.ownAllocated

            guard d.mode != .skipped else { continue }
            let level = Int(depth[id])
            let keep = id == 0 || (slot[p] >= 0 && (level <= DiskSnapshot.alwaysDepth
                || (level <= DiskSnapshot.maxDepth && d.totalAllocated >= DiskSnapshot.minFolderBytes)))
            guard keep else { continue }
            slot[id] = Int32(names.count)
            names.append(id == 0 ? "" : index.dirName(Int32(id)))
            parents.append(id == 0 ? -1 : slot[p])
            sizes.append(d.totalAllocated)
            cats.append(cat[id])
        }
        return DiskSnapshot(
            date: date, rootPath: index.rootPath, volumeUsed: disk.usedBytes, volumeTotal: disk.totalBytes,
            names: names, parents: parents, sizes: sizes, cats: cats, categoryTotals: totals
        )
    }
}

// MARK: - Differences

struct FolderChange: Identifiable, Sendable, Hashable {
    /// Relative to the root ("Library/Caches").
    let path: String
    let oldSize: Int64
    let newSize: Int64
    let category: SnapshotCategory
    /// Didn't exist in the older snapshot (only certain for shallow folders, which are always recorded).
    let isNew: Bool
    let isGone: Bool
    let hasChildren: Bool

    var id: String { path }
    var delta: Int64 { newSize - oldSize }
    var name: String { (path as NSString).lastPathComponent }
}

struct CategoryChange: Identifiable, Sendable {
    let category: SnapshotCategory
    let oldSize: Int64
    let newSize: Int64
    var id: UInt8 { category.rawValue }
    var delta: Int64 { newSize - oldSize }
}

/// The difference between two snapshots, built once (a dictionary per side) and then queried cheaply.
struct SnapshotDiff: Sendable {
    let old: SnapshotSummary
    let new: SnapshotSummary
    let rootPath: String
    private let oldSizes: [String: Int64]
    private let newSizes: [String: Int64]
    private let newCats: [String: UInt8]
    private let oldCats: [String: UInt8]
    private let kids: [String: [String]]
    let categories: [CategoryChange]

    init(old o: DiskSnapshot, oldSummary: SnapshotSummary, new n: DiskSnapshot, newSummary: SnapshotSummary) {
        old = oldSummary
        new = newSummary
        rootPath = n.rootPath
        var oldSizes: [String: Int64] = [:], newSizes: [String: Int64] = [:]
        var oldCats: [String: UInt8] = [:], newCats: [String: UInt8] = [:]
        var kids: [String: Set<String>] = [:]
        for (snap, isNew) in [(o, false), (n, true)] {
            let paths = snap.relativePaths()
            for i in paths.indices {
                if isNew { newSizes[paths[i]] = snap.sizes[i]; newCats[paths[i]] = snap.cats[i] }
                else { oldSizes[paths[i]] = snap.sizes[i]; oldCats[paths[i]] = snap.cats[i] }
                if i > 0 { kids[paths[max(0, Int(snap.parents[i]))], default: []].insert(paths[i]) }
            }
        }
        self.oldSizes = oldSizes
        self.newSizes = newSizes
        self.oldCats = oldCats
        self.newCats = newCats
        self.kids = kids.mapValues { Array($0) }
        categories = SnapshotCategory.allCases.map {
            CategoryChange(category: $0, oldSize: o.categoryTotal($0), newSize: n.categoryTotal($0))
        }
    }

    var net: Int64 { new.total - old.total }

    /// Sum of growth / shrinkage across top-level folders.
    var grew: Int64 { children(of: "").map(\.delta).filter { $0 > 0 }.reduce(0, +) }
    var shrank: Int64 { children(of: "").map(\.delta).filter { $0 < 0 }.reduce(0, +) }

    func change(_ path: String) -> FolderChange {
        let o = oldSizes[path], n = newSizes[path]
        let depth = path.isEmpty ? 0 : path.split(separator: "/").count
        let cat = SnapshotCategory(rawValue: newCats[path] ?? oldCats[path] ?? 0) ?? .other
        return FolderChange(
            path: path, oldSize: o ?? 0, newSize: n ?? 0, category: cat,
            isNew: o == nil && depth <= DiskSnapshot.alwaysDepth,
            isGone: n == nil && depth <= DiskSnapshot.alwaysDepth,
            hasChildren: !(kids[path]?.isEmpty ?? true)
        )
    }

    /// Children of a folder, biggest change first.
    func children(of path: String, minDelta: Int64 = 1) -> [FolderChange] {
        (kids[path] ?? []).map(change).filter { abs($0.delta) >= minDelta }
            .sorted { abs($0.delta) > abs($1.delta) }
    }

    /// The folders that explain the change, biggest first: a folder whose change is mostly carried by a few
    /// significant children is replaced by them, so "~/Library" becomes "~/Library/Developer/…/DerivedData".
    func hotspots(minDelta: Int64 = 25_000_000, limit: Int = 30) -> [FolderChange] {
        func explain(_ c: FolderChange) -> [FolderChange] {
            let sig = children(of: c.path, minDelta: minDelta)
            let sameSign = sig.filter { ($0.delta > 0) == (c.delta > 0) }.map(\.delta).reduce(0, +)
            if !sig.isEmpty && abs(sameSign) * 10 >= abs(c.delta) * 6 {
                return sig.flatMap(explain)
            }
            return [c]
        }
        return children(of: "", minDelta: minDelta).flatMap(explain)
            .sorted { abs($0.delta) > abs($1.delta) }
            .prefix(limit).map { $0 }
    }

    func hotspots(in category: SnapshotCategory) -> [FolderChange] {
        hotspots(minDelta: 10_000_000, limit: 200).filter { $0.category == category }.prefix(8).map { $0 }
    }

    func absolutePath(_ rel: String) -> String { rel.isEmpty ? rootPath : rootPath + "/" + rel }
}

extension DiskSnapshot {
    /// Biggest folders right now (first-run state): the same "explain" walk, by size instead of change.
    func biggestFolders(limit: Int = 8) -> [(path: String, size: Int64)] {
        let paths = relativePaths()
        var kids = [[Int]](repeating: [], count: names.count)
        for i in 1..<max(1, names.count) { kids[Int(parents[i])].append(i) }
        var result: [(String, Int64)] = []
        func walk(_ i: Int) {
            let sorted = kids[i].sorted { sizes[$0] > sizes[$1] }
            if let top = sorted.first, sizes[top] * 10 >= sizes[i] * 7, !kids[top].isEmpty { walk(top); return }
            result.append((paths[i], sizes[i]))
        }
        for i in kids[0].sorted(by: { sizes[$0] > sizes[$1] }).prefix(limit) { walk(i) }
        return result.sorted { $0.1 > $1.1 }.map { (path: $0.0, size: $0.1) }
    }
}

import Foundation

/// What a Disk row offers for one folder: the action chip, where it leads, and the line under the
/// path. Built from the other sections' scan results, so it never claims more than they found.
struct DiskAdvice: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Everything found here is safe to clean (primary chip).
        case clean
        /// Found something that needs a look first.
        case review
        /// Large files: the user picks.
        case pickFiles
        /// Nothing found: look at the folder itself.
        case open

        var title: String {
            switch self {
            case .clean: return "Clean"
            case .review: return "Review"
            case .pickFiles: return "Pick files"
            case .open: return "Open"
            }
        }
    }

    var action: Action
    /// The section the chip opens, filtered to this folder; nil opens the folder in the Inspector.
    var section: SidebarSection?
    /// "18.2 GB cleanable · Package & Tool Caches"; nil when nothing was found.
    var detail: String?
    var foundBytes: Int64
}

/// The scan results Disk rows look through. Plain values, so the rules can be tested on their own.
struct DiskFindings: Sendable {
    struct Entry: Sendable {
        enum Kind: Sendable { case safeJunk, checkJunk, worktree, duplicate, leftover, largeFile }
        var kind: Kind
        var path: String
        var bytes: Int64
        /// Junk category name, for the detail line.
        var label: String?
    }

    /// Sorted by the path's UTF-8 bytes, so everything under a folder sits in one run.
    private(set) var entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    @MainActor
    init(state: AppState) {
        var list: [Entry] = []
        for item in state.junkItems {
            list.append(Entry(kind: item.risk == .safe ? .safeJunk : .checkJunk, path: item.path,
                              bytes: item.sizeBytes, label: item.category.rawValue))
        }
        for wt in state.worktrees where wt.canAutoSelect {
            list.append(Entry(kind: .worktree, path: wt.worktreePath, bytes: wt.sizeBytes))
        }
        for group in state.duplicateGroups {
            // Every copy but one can go; the one kept is the first, as Duplicates keeps it.
            for file in group.files.dropFirst() {
                list.append(Entry(kind: .duplicate, path: file.path, bytes: file.privateBytes))
            }
        }
        for group in state.orphanedGroups {
            for item in group.items {
                list.append(Entry(kind: .leftover, path: item.path, bytes: item.sizeBytes))
            }
        }
        for file in state.largeFiles {
            list.append(Entry(kind: .largeFile, path: file.path, bytes: file.sizeBytes))
        }
        self.init(entries: list)
    }

    /// Entries at or under `folder`, by binary search: the folder itself and "folder/…" all sort
    /// between "folder" and "folder0" ('0' follows '/'), so only that run is checked.
    func entries(under folder: String) -> [Entry] {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let lo = firstIndex(notBefore: base)
        let hi = firstIndex(notBefore: base + "0")
        guard lo < hi else { return [] }
        return entries[lo..<hi].filter { Self.contains(base, $0.path) }
    }

    private func firstIndex(notBefore key: String) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].path.utf8.lexicographicallyPrecedes(key.utf8) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func contains(_ folder: String, _ path: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }

    /// The ids in `selection` whose item is `folder` or inside it (a path prefix, so
    /// `~/code-archive` is not under `~/code`).
    static func narrow<Item>(_ selection: Set<String>, _ items: [Item], to folder: String,
                             id: (Item) -> String, path: (Item) -> String) -> Set<String> {
        Set(items.filter { selection.contains(id($0)) && contains(folder, path($0)) }.map(id))
    }

    /// The snapshot category a folder falls in (the most specific path rule above it), for the
    /// bar colour and the fallback action.
    static func category(forPath path: String, home: String = ScanIndexCache.homePath) -> SnapshotCategory {
        guard contains(home, path), path.count > home.count else { return .other }
        var rel = String(path.dropFirst(home.count + 1))
        while true {
            if let c = SnapshotCategory.pathRules[rel] { return c }
            if let name = rel.split(separator: "/").last, let c = SnapshotCategory.nameRules[String(name)] { return c }
            guard let slash = rel.lastIndex(of: "/") else { return .other }
            rel = String(rel[..<slash])
        }
    }

    /// Advice for a folder. With nothing found under it, documents and media still lead to Large
    /// Files (the user picks), developer folders to Caches & Junk; anything else opens in the Inspector.
    func advice(for folder: String, category: SnapshotCategory? = nil) -> DiskAdvice {
        var bytes: [Entry.Kind: Int64] = [:]
        var counts: [Entry.Kind: Int] = [:]
        var junkLabels: [String: Int64] = [:]
        for e in entries(under: folder) where e.bytes > 0 {
            bytes[e.kind, default: 0] += e.bytes
            counts[e.kind, default: 0] += 1
            if let label = e.label { junkLabels[label, default: 0] += e.bytes }
        }
        let junk = (bytes[.safeJunk] ?? 0) + (bytes[.checkJunk] ?? 0)
        let all: [(Group, Int64)] = [
            (Group.junk, junk),
            (Group.worktree, bytes[.worktree] ?? 0),
            (Group.duplicate, bytes[.duplicate] ?? 0),
            (Group.leftover, bytes[.leftover] ?? 0),
            (Group.largeFile, bytes[.largeFile] ?? 0),
        ]
        let groups = all.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }

        guard let top = groups.first else {
            switch category ?? Self.category(forPath: folder) {
            case .media, .documents, .downloads:
                return DiskAdvice(action: .pickFiles, section: .largeFiles, detail: nil, foundBytes: 0)
            case .developer, .caches, .aiModels:
                // Build output and caches are what Caches & Junk looks for; it shows whether any is safe.
                return DiskAdvice(action: .review, section: .junk, detail: nil, foundBytes: 0)
            default:
                return DiskAdvice(action: .open, section: nil, detail: nil, foundBytes: 0)
            }
        }

        let action: DiskAdvice.Action
        let section: SidebarSection
        switch top.0 {
        case .junk:
            action = (bytes[.checkJunk] ?? 0) == 0 ? .clean : .review
            section = .junk
        case .worktree: action = .review; section = .worktrees
        case .duplicate: action = .review; section = .duplicates
        case .leftover: action = .review; section = .apps
        case .largeFile: action = .pickFiles; section = .largeFiles
        }

        func phrase(_ group: Group, _ amount: Int64) -> String {
            let size = FileSizeHelper.formatBytes(amount)
            switch group {
            case .junk: return "\(size) cleanable"
            case .worktree: return "\(size) in merged worktrees"
            case .duplicate: return "\(size) in duplicate copies"
            case .leftover: return "\(size) in leftovers of deleted apps"
            case .largeFile:
                let n = counts[.largeFile] ?? 0
                return "\(n) large file\(n == 1 ? "" : "s"), \(size)"
            }
        }

        var parts = groups.prefix(2).map { phrase($0.0, $0.1) }
        if groups.count == 1, top.0 == .junk {
            let names = junkLabels.sorted { $0.value > $1.value }.prefix(2).map(\.key)
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        return DiskAdvice(action: action, section: section, detail: parts.joined(separator: " · "),
                          foundBytes: groups.reduce(0) { $0 + $1.1 })
    }

    private enum Group { case junk, worktree, duplicate, leftover, largeFile }
}

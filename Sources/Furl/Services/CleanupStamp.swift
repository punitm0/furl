import Foundation

// MARK: - On-disk stamps

/// What one path looked like on disk: its kind and modification date (and, where it matters, its size).
/// Read with the same API the scanners use for `modifiedDate` (URL resource values), so a scanner's
/// date compares exactly. Every delete path re-checks its items against these right before removing.
struct CleanupStamp: Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Hashable, Codable { case file, directory, symlink }
    let kind: Kind
    let modified: Date?
    /// Logical size in bytes. Only recorded where the size is part of what was found (duplicates);
    /// nil means the size isn't compared.
    var size: Int64? = nil

    init(kind: Kind, modified: Date?, size: Int64? = nil) {
        self.kind = kind
        self.modified = modified
        self.size = size
    }

    // Stored as seconds since the reference date: the exact value `Date` holds, so a stamp saved in
    // a JSON file (whose date strategy may drop fractions) still compares exactly after a relaunch.
    private enum CodingKeys: String, CodingKey { case kind, modified, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        modified = try c.decodeIfPresent(Double.self, forKey: .modified).map(Date.init(timeIntervalSinceReferenceDate:))
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(modified?.timeIntervalSinceReferenceDate, forKey: .modified)
        try c.encodeIfPresent(size, forKey: .size)
    }

    /// nil when nothing is at `path` any more.
    static func read(_ path: String, includeSize: Bool = false) -> CleanupStamp? {
        // A fresh URL each time: URL caches resource values per instance.
        let url = URL(fileURLWithPath: path)
        var keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        if includeSize { keys.insert(.fileSizeKey) }
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let kind: Kind = values.isSymbolicLink == true ? .symlink : (values.isDirectory == true ? .directory : .file)
        let size = includeSize ? values.fileSize.map(Int64.init) : nil
        return CleanupStamp(kind: kind, modified: values.contentModificationDate, size: size)
    }

    static func read(_ paths: [String]) -> [String: CleanupStamp] {
        var stamps: [String: CleanupStamp] = [:]
        for path in paths where stamps[path] == nil {
            if let stamp = read(path) { stamps[path] = stamp }
        }
        return stamps
    }

    /// Stamps for junk items. A single-path item keeps the modification date the scanner saw
    /// while scanning, so a change made between that moment and now still counts as a change.
    /// Command-based items (docker, simctl) have no file and get no stamp.
    static func read(junk items: [JunkItem]) -> [String: CleanupStamp] {
        var stamps: [String: CleanupStamp] = [:]
        for item in items where item.command == nil {
            let paths = [item.path] + item.extraPaths
            for path in paths where stamps[path] == nil {
                guard let now = read(path) else { continue }
                if paths.count == 1, let scanned = item.modifiedDate {
                    stamps[path] = CleanupStamp(kind: now.kind, modified: scanned)
                } else {
                    stamps[path] = now
                }
            }
        }
        return stamps
    }

    /// Stamps for duplicate copies: kind, modification date and size. A copy whose size no longer
    /// matches its group's size gets no stamp, so the re-check skips it.
    static func read(duplicates groups: [DuplicateGroup]) -> [String: CleanupStamp] {
        var stamps: [String: CleanupStamp] = [:]
        for group in groups {
            for file in group.files where stamps[file.path] == nil {
                guard let now = read(file.path, includeSize: true), now.size == group.sizeBytes else { continue }
                stamps[file.path] = now
            }
        }
        return stamps
    }

    /// Whether `path` still looks the way this stamp recorded it. With `checkModified` false only the
    /// kind (and size, if recorded) are compared.
    func matches(_ path: String, checkModified: Bool = true) -> Bool {
        guard let now = Self.read(path, includeSize: size != nil) else { return false }
        guard now.kind == kind, now.size == size else { return false }
        return !checkModified || now.modified == modified
    }
}

// MARK: - Re-check before removing

/// One thing about to be removed and every path that goes with it. It passes the re-check only if
/// every path still matches what the scan recorded.
struct CleanupItem: Sendable {
    /// The item's own path (what counts and toasts refer to).
    let path: String
    /// `path` first, then anything removed together with it (e.g. an Ollama model's blobs).
    let allPaths: [String]
    /// A Git worktree that must still have no uncommitted changes.
    var requireCleanWorktree = false
    /// A Git worktree whose HEAD must still start with this commit (the scan's short hash).
    var worktreeCommit: String? = nil
    /// Browser caches are skipped while the browser that owns them runs: cache folder dates don't
    /// change while the browser writes into their subfolders, so the stamp alone can't tell.
    var isBrowserCache = false
    /// false only for data an app may rewrite when Furl quits it for an uninstall (see `uninstallApp`).
    var checkModified = true

    init(path: String, allPaths: [String]? = nil) {
        self.path = path
        self.allPaths = allPaths ?? [path]
    }
}

enum CleanupRecheck {
    /// The last check before anything moves. An item passes only if every one of its paths still
    /// matches its stamp (exists, same kind, same modification date, same size where recorded) and
    /// its extra conditions hold. A path without a recorded stamp fails: never guess.
    static func verify(_ items: [CleanupItem], stamps: [String: CleanupStamp]) -> (verified: [CleanupItem], skipped: [CleanupItem]) {
        var verified: [CleanupItem] = []
        var skipped: [CleanupItem] = []
        for item in items {
            if passes(item, stamps: stamps) { verified.append(item) } else { skipped.append(item) }
        }
        return (verified, skipped)
    }

    static func passes(_ item: CleanupItem, stamps: [String: CleanupStamp]) -> Bool {
        let unchanged = item.allPaths.allSatisfy { path in
            guard let expected = stamps[path] else { return false }
            return expected.matches(path, checkModified: item.checkModified)
        }
        guard unchanged else { return false }
        if item.isBrowserCache, JunkScanner.browserIsRunning(forCachePath: item.path) { return false }
        if item.requireCleanWorktree, !worktreeIsClean(item.path) { return false }
        if let commit = item.worktreeCommit, !worktreeHead(item.path, startsWith: commit) { return false }
        return true
    }

    /// Same test the worktree scanner uses: if git can't prove it's clean, it isn't.
    static func worktreeIsClean(_ path: String) -> Bool {
        guard let status = ShellRunner.gitStatusPorcelain(in: path, timeout: 30) else { return false }
        return status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The worktree's HEAD is still the commit the scan saw (no new commits since).
    static func worktreeHead(_ path: String, startsWith commit: String) -> Bool {
        let head = ShellRunner.git(["rev-parse", "HEAD"], in: path, timeout: 30)
        let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.exitCode == 0 && !sha.isEmpty && sha.hasPrefix(commit)
    }
}

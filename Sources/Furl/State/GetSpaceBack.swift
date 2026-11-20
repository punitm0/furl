import AppKit

/// The Overview's "Get space back" panel (GetSpaceBack board): one safe number, three steps
/// (smallest risk first) and the result after cleaning.

/// What the Overview's one-click clean did, for the "You got back…" state.
struct SafeCleanSummary: Equatable {
    let run: AutoSweepRun
    let freedBytes: Int64
    let itemCount: Int
    let diskBefore: Disk
    let biggestWin: (name: String, bytes: Int64)?

    struct Disk: Equatable {
        let totalBytes: Int64
        let usedBytes: Int64
        let availableBytes: Int64
    }

    /// The space comes back once the Trash is emptied; the board shows the fullness it leads to.
    var percentBefore: Int { Self.percent(diskBefore.usedBytes, of: diskBefore.totalBytes) }
    var percentAfter: Int { Self.percent(max(0, diskBefore.usedBytes - freedBytes), of: diskBefore.totalBytes) }
    var freeAfter: Int64 { diskBefore.availableBytes + freedBytes }

    static func percent(_ used: Int64, of total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(used) / Double(total) * 100).rounded())
    }

    static func == (a: Self, b: Self) -> Bool {
        a.run.id == b.run.id && a.freedBytes == b.freedBytes && a.itemCount == b.itemCount
            && a.diskBefore == b.diskBefore && a.biggestWin?.name == b.biggestWin?.name
            && a.biggestWin?.bytes == b.biggestWin?.bytes
    }

    /// The item name that freed most, summed across items with that name (e.g. node_modules ×42).
    static func biggestWin(trashed: [TrashLedgerEntry], names: [String: String], sizes: [String: Int64]) -> (name: String, bytes: Int64)? {
        var byName: [String: Int64] = [:]
        for entry in trashed {
            guard let name = names[entry.originalPath] else { continue }
            byName[name, default: 0] += entry.bytes ?? sizes[entry.originalPath] ?? 0
        }
        return byName.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            .map { ($0.key, $0.value) }
    }
}

/// The three steps under the big number. Each step's bytes leave out anything an earlier step
/// already counts, so "→ X GB free after this" can be added up as you go.
struct SpaceSteps: Equatable {
    var safeBytes: Int64 = 0
    var worktreeBytes: Int64 = 0
    var worktreeCount = 0
    var duplicateBytes: Int64 = 0
    var duplicateCount = 0
    var leftoverBytes: Int64 = 0
    var leftoverCount = 0
    var largeFileBytes: Int64 = 0
    var largeFileCount = 0

    var quickLookBytes: Int64 { worktreeBytes + duplicateBytes + leftoverBytes }

    /// "Your call": large files not changed in this long.
    static let largeFileAge: TimeInterval = 365 * 86_400

    static func make(plan: AppState.SafeCleanupPlan, worktrees: [WorktreeItem], duplicates: [DuplicateGroup],
                     leftovers: [OrphanedAppDataGroup], largeFiles: [LargeFileItem], now: Date = Date()) -> SpaceSteps {
        var steps = SpaceSteps(safeBytes: plan.bytes)
        var counted = Set(plan.paths)
        let safeSizes = plan.paths.map { ($0, plan.itemBytes[$0] ?? 0) }

        // Quick look: merged worktrees (Permanent, so never "safe"), duplicate copies, app leftovers.
        for tree in worktrees where tree.canAutoSelect && !isInside(tree.worktreePath, counted) {
            // Safe items inside the worktree are already in step one.
            let nested = safeSizes.filter { isInside($0.0, [tree.worktreePath]) }.reduce(Int64(0)) { $0 + $1.1 }
            steps.worktreeBytes += max(0, tree.sizeBytes - nested)
            steps.worktreeCount += 1
            counted.insert(tree.worktreePath)
        }
        var leftoverPaths: [String] = []
        for item in leftovers.flatMap(\.items) where !isInside(item.path, counted) {
            steps.leftoverBytes += item.sizeBytes
            steps.leftoverCount += 1
            leftoverPaths.append(item.path)
        }
        counted.formUnion(leftoverPaths)
        var duplicatePaths = Set<String>()
        for group in duplicates {
            guard let sample = group.files.last, !isInside(sample.path, counted) else { continue }
            steps.duplicateBytes += group.reclaimableBytes
            steps.duplicateCount += max(0, group.files.count - 1)
            duplicatePaths.formUnion(group.files.map(\.path))
        }

        // Your call: large files nobody has changed in a year, not already counted above.
        let cutoff = now.addingTimeInterval(-largeFileAge)
        for file in largeFiles {
            guard let modified = file.modifiedDate, modified <= cutoff,
                  !duplicatePaths.contains(file.path), !isInside(file.path, counted) else { continue }
            steps.largeFileBytes += file.sizeBytes
            steps.largeFileCount += 1
        }
        return steps
    }

    /// `path` is one of `roots` or inside one.
    static func isInside(_ path: String, _ roots: Set<String>) -> Bool {
        guard !roots.isEmpty else { return false }
        var url = URL(fileURLWithPath: path)
        while url.path != "/" && !url.path.isEmpty {
            if roots.contains(url.path) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }
}

extension AppState {
    var spaceSteps: SpaceSteps {
        SpaceSteps.make(plan: safeCleanupPlan, worktrees: worktrees, duplicates: duplicateGroups,
                        leftovers: orphanedGroups, largeFiles: largeFiles)
    }

    /// The Overview's "Move X to Trash": the same path as the menu bar's "Clean safe items" (always the
    /// Trash, re-checked on disk right before moving, one History entry, one Undo), limited to the
    /// items the button showed.
    func cleanSafeNow(store: AutoSweepStore, confirmedPaths: [String]) async {
        let disk = diskUsage
        var names: [String: String] = [:]
        var sizes: [String: Int64] = [:]
        let confirmed = Set(confirmedPaths)
        for item in junkItems where confirmed.contains(item.path) {
            names[item.path] = Self.friendlyName(item)
            sizes[item.path] = item.sizeBytes
        }
        guard let run = await cleanSafeItems(store: store, trigger: .overview, confirmedPaths: confirmedPaths),
              run.totalItems > 0 else { return }
        lastSafeClean = SafeCleanSummary(
            run: run,
            freedBytes: run.totalBytes,
            itemCount: run.totalItems,
            diskBefore: .init(totalBytes: disk.totalBytes, usedBytes: disk.usedBytes, availableBytes: disk.availableBytes),
            biggestWin: SafeCleanSummary.biggestWin(trashed: run.trashed, names: names, sizes: sizes)
        )
    }

    /// "Biggest win: Xcode caches": a cache folder named after a bundle id ("com.example.App") reads
    /// as that app's caches, or as its category when the app isn't installed.
    static func friendlyName(_ item: JunkItem) -> String {
        let name = item.name
        let parts = name.split(separator: ".")
        guard parts.count >= 3, !name.contains(" "), !name.contains("/") else { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name),
           let app = FileManager.default.displayName(atPath: url.path).split(separator: ".").first {
            return "\(app) caches"
        }
        return item.category.rawValue
    }

    /// Undo on the "You got back…" state: puts that cleanup's items back. The state (and its Undo)
    /// stays until History shows the run as undone, so a failed or refused undo can be tried again.
    func undoSafeClean(store: AutoSweepStore) async {
        await undoSafeClean { run in
            let current = store.history.first { $0.id == run.id } ?? run
            await self.undoAutoSweepRun(current, store: store)
            return store.history.first { $0.id == run.id }?.undone ?? false
        }
    }

    /// `undo` puts a run back and says whether History now shows it as undone.
    func undoSafeClean(using undo: (AutoSweepRun) async -> Bool) async {
        guard let summary = lastSafeClean, !isCleaning else { return }
        if await undo(summary.run), lastSafeClean?.run.id == summary.run.id {
            lastSafeClean = nil
        }
    }

    /// Bytes of Furl's own items still in the Trash (the Trash ledger); the user's own items aren't counted.
    func furlTrashBytes(store: AutoSweepStore) -> Int64 {
        store.ledger.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
    }

    /// "Empty Furl's items…": permanently removes only what Furl itself moved to the Trash. The caller
    /// confirms first; the user's own Trash items are never touched.
    func emptyFurlTrashItems(store: AutoSweepStore) async {
        guard !isCleaning else { return }
        store.pruneLedger()
        let entries = store.ledger
        guard !entries.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.permanentlyRemove(entries)
        }.value
        store.removeFromLedger(outcome.removed)
        let count = entries.filter { outcome.removed.contains($0.trashPath) }.count
        recordFreed(outcome.bytes, items: count, category: .trash)
        if outcome.bytes > 0 || count > 0 {
            ActivityLog.shared.recordEmptyTrash(bytes: outcome.bytes, count: count)
            // Those items are gone for good now.
            lastUndo = nil
            lastSafeClean = nil
            statusBanner = "Emptied Furl’s items from the Trash (\(FileSizeHelper.formatBytes(outcome.bytes)) freed)."
        }
        if !outcome.errors.isEmpty {
            errorBanner = outcome.errors.joined(separator: "\n")
        }
        ActivityLog.shared.refreshRestorable()
        refreshDiskInfo()
    }
}

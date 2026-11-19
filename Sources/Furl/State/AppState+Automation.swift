import Combine
import Foundation

/// Menu bar "Clean safe items", Auto-Sweep jobs and undo. Everything here moves items to the
/// Trash (never deletes outright), regardless of the main window's deletion mode, and records
/// a History entry that can be undone. The only permanent removal is the "Empty Trash items
/// older than N days" rule, which only touches items Furl itself put in the Trash.
extension AppState {

    // MARK: - Safe items (what the app already auto-selects)

    struct SafeCleanupPlan: Equatable {
        /// One path per item (what the counts in the UI refer to).
        var paths: [String] = []
        var bytes: Int64 = 0
        var junkCount = 0
        var worktreeCount = 0
        /// Every path that goes to the Trash with an item: its own path first, then `extraPaths`.
        var itemPaths: [String: [String]] = [:]
        var worktreePaths: Set<String> = []
        /// Browser caches: skipped at clean time while their browser runs.
        var browserCachePaths: Set<String> = []
        var isEmpty: Bool { paths.isEmpty }
    }

    /// Scan results older than this are rescanned before "Clean safe items" moves anything.
    static let safeCleanupMaxResultAge: TimeInterval = 10 * 60

    /// Junk with risk `.safe` plus merged worktrees passing `canAutoSelect` — the same items the
    /// Junk and Worktrees sections pre-select. Items nested inside another item count once.
    /// Tool-cleaned junk (docker, simctl) has no file to move, so it's never part of this.
    var safeCleanupPlan: SafeCleanupPlan {
        var entries: [(path: String, extra: [String], bytes: Int64, isWorktree: Bool, isBrowser: Bool)] = []
        entries += worktrees.filter(\.canAutoSelect).map { ($0.worktreePath, [], $0.sizeBytes, true, false) }
        entries += junkItems.filter { $0.risk == .safe && $0.command == nil }
            .map { ($0.path, $0.extraPaths, $0.sizeBytes, false, $0.category == .browserCaches) }
        var plan = SafeCleanupPlan()
        for entry in Self.removingNested(entries, path: \.path) {
            plan.paths.append(entry.path)
            plan.itemPaths[entry.path] = [entry.path] + entry.extra
            plan.bytes += entry.bytes
            if entry.isBrowser { plan.browserCachePaths.insert(entry.path) }
            if entry.isWorktree {
                plan.worktreeCount += 1
                plan.worktreePaths.insert(entry.path)
            } else {
                plan.junkCount += 1
            }
        }
        return plan
    }

    var hasScannedForSafeCleanup: Bool { hasScannedJunk && hasScannedWorktrees }

    /// Runs the junk and worktree scans the menu bar needs, if they haven't run yet.
    func prepareSafeCleanup() async {
        let needJunk = !hasScannedJunk && !isScanningJunk
        let needWorktrees = !hasScannedWorktrees && !isScanningWorktrees
        async let jk: Void = needJunk ? scanJunk() : ()
        async let wt: Void = needWorktrees ? scanWorktrees() : ()
        _ = await (jk, wt)
    }

    /// "Clean safe items" from the menu bar or a low-disk notification. The caller confirms first and
    /// passes the item paths of the plan it showed (`confirmedPaths`), so a scan that lands while the
    /// confirmation is up can't add items the user never saw.
    ///
    /// Scan results can be old. If the junk or worktree results are older than
    /// `safeCleanupMaxResultAge` they're rescanned first, and only items that were in the plan the
    /// user confirmed *and* are still safe after the rescan are cleaned (new finds wait for the
    /// next time the user sees them). Every item is then re-checked on disk right before it moves
    /// (`CleanupRecheck`): it must still exist, be the same kind (file, folder, link) and carry the
    /// modification date the scan saw; merged worktrees must also still have no uncommitted changes,
    /// and browser caches are left alone while their browser runs. Anything that fails is skipped,
    /// and the banner and History count only what actually went to the Trash.
    @discardableResult
    func cleanSafeItems(store: AutoSweepStore, trigger: AutoSweepRun.Trigger,
                        confirmedPaths: [String]) async -> AutoSweepRun? {
        guard !confirmedPaths.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        safeCleanNote = nil
        // "Checking…" covers the rescan of stale results and the on-disk re-check; "Cleaning…" the move.
        setSafeCleanPhase(.checking)
        defer {
            isCleaning = false
            setSafeCleanPhase(nil)
        }

        await refreshSafeCleanupScans(maxAge: Self.safeCleanupMaxResultAge)

        let current = safeCleanupPlan
        let confirmedSet = Set(confirmedPaths)
        let items = current.paths.filter { confirmedSet.contains($0) }.map { path in
            var item = CleanupItem(path: path, allPaths: current.itemPaths[path] ?? [path])
            item.requireCleanWorktree = current.worktreePaths.contains(path)
            item.isBrowserCache = current.browserCachePaths.contains(path)
            return item
        }
        let stamps = cleanupStamps.junk.merging(cleanupStamps.worktrees) { a, _ in a }
        let check = await Task.detached(priority: .userInitiated) {
            CleanupRecheck.verify(items, stamps: stamps)
        }.value

        setSafeCleanPhase(.cleaning)
        let result = await Self.moveToTrash(check.verified.flatMap(\.allPaths), expected: stamps)

        // Count items, not paths: an item with extra paths is one item. An item counts as removed
        // once any of its paths actually went to the Trash.
        let trashedPaths = Set(result.trashedItems.map(\.originalPath))
        let removed = check.verified.filter { $0.allPaths.contains(where: trashedPaths.contains) }
        let removedWorktrees = removed.filter(\.requireCleanWorktree).count
        let removedJunk = removed.count - removedWorktrees

        // Items dropped by the rescan never reach the check, and an item can still fail the
        // per-path check right before it moves; count both as skipped too.
        let lateSkipped = Set(result.skippedPaths)
        let skippedCount = check.skipped.count + (confirmedSet.count - items.count)
            + check.verified.filter { $0.allPaths.contains(where: lateSkipped.contains) }.count
        if skippedCount > 0 {
            // Shown in the toast and the History row (design copy, see `skippedSentence`).
            NSLog("Furl: Clean safe items skipped %ld item(s) that changed since the scan", skippedCount)
        }

        junkItems.removeAll { $0.command == nil && !Self.pathExists($0.path) }
        selectedJunkIDs.formIntersection(Set(junkItems.map(\.id)))
        worktrees.removeAll { $0.canAutoSelect && !Self.pathExists($0.worktreePath) }
        selectedWorktreeIDs.formIntersection(Set(worktrees.map(\.id)))
        refreshDiskInfo()

        // Nothing moved and nothing failed: no History entry for a cleanup that didn't happen.
        guard !removed.isEmpty || !result.errors.isEmpty else {
            if skippedCount > 0 {
                showNothingCleaned(rescan: [.junk, .worktrees])
                safeCleanNote = Self.nothingCleanedText
            }
            return nil
        }

        let run = AutoSweepRun(
            date: Date(),
            trigger: trigger,
            parts: [AutoSweepRunPart(
                rule: .safeClean,
                itemCount: removed.count,
                bytes: result.reclaimedBytes,
                detail: "\(removedJunk) cache/junk item(s), \(removedWorktrees) merged worktree(s)"
            )],
            trashed: Self.ledgerEntries(result),
            errors: result.errors,
            skippedCount: skippedCount > 0 ? skippedCount : nil
        )
        store.record(run, countsAsAutoSweep: false)

        if !removed.isEmpty {
            statusBanner = Self.withSkipped("Moved \(removed.count) safe item(s) to the Trash (\(FileSizeHelper.formatBytes(result.reclaimedBytes))). Undo from Settings › Automation.", skippedCount)
        }
        if !result.errors.isEmpty {
            errorBanner = result.errors.joined(separator: "\n")
        }
        return run
    }

    /// Every other user-triggered delete path logs items it left alone because they changed since
    /// the scan (or, for browser caches, because the browser is open) through here. The user sees them
    /// in the toast and History (`skippedSentence`, `showNothingCleaned`).
    func noteSkippedSinceScan(_ count: Int, in context: String) {
        guard count > 0 else { return }
        NSLog("Furl: %@ skipped %ld item(s) that changed since the scan", context, count)
    }

    /// Rescans junk and worktrees when their results are older than `maxAge` (0 = always), and
    /// waits until results newer than this call are in. A scan already running counts: its
    /// results land after this call started.
    func refreshSafeCleanupScans(maxAge: TimeInterval) async {
        let start = Date()
        func isStale(_ date: Date?) -> Bool {
            guard let date else { return true }
            return maxAge <= 0 || start.timeIntervalSince(date) > maxAge
        }
        async let jk: Void = isStale(cleanupStamps.junkDate) ? waitForFreshScan(junk: true, after: start) : ()
        async let wt: Void = isStale(cleanupStamps.worktreesDate) ? waitForFreshScan(junk: false, after: start) : ()
        _ = await (jk, wt)
    }

    /// Junk (`junk: true`) or worktrees: returns once that scan has finished after `start`.
    private func waitForFreshScan(junk: Bool, after start: Date) async {
        while ((junk ? cleanupStamps.junkDate : cleanupStamps.worktreesDate) ?? .distantPast) < start {
            if junk ? isScanningJunk : isScanningWorktrees {
                // Starting a scan now would only queue a rescan and return; wait for the running one.
                try? await Task.sleep(for: .milliseconds(200))
            } else if junk {
                await scanJunk()
            } else {
                await scanWorktrees()
            }
        }
    }

    // MARK: - Auto-Sweep jobs

    /// The scheduled job: caches and stale dependency folders not used in N days.
    func runScheduledAutoSweep(store: AutoSweepStore, trigger: AutoSweepRun.Trigger) async -> AutoSweepRun {
        let roots = projectRoots
        let days = store.cachesUnusedDays
        // Always a fresh scan right before cleaning, then the same on-disk re-check as
        // "Clean safe items": anything that changed while the sweep was deciding is left alone.
        let (verified, stamps) = await Task.detached(priority: .utility) {
            let candidates = Self.removingNested(Self.autoSweepCacheCandidates(roots: roots, unusedDays: days), path: \.path)
            let items = candidates.map { CleanupItem(path: $0.path, allPaths: [$0.path] + $0.extraPaths) }
            let stamps = CleanupStamp.read(junk: candidates)
            return (CleanupRecheck.verify(items, stamps: stamps).verified, stamps)
        }.value
        let result = await Self.moveToTrash(verified.flatMap(\.allPaths), expected: stamps)
        let run = AutoSweepRun(
            date: Date(),
            trigger: trigger,
            parts: [AutoSweepRunPart(rule: .caches, itemCount: result.succeededCount, bytes: result.reclaimedBytes,
                                     detail: "Not used in \(days) days")],
            trashed: Self.ledgerEntries(result),
            errors: result.errors
        )
        afterAutoSweep()
        return run
    }

    /// Daily chores: expire Furl's own Trash items, tidy Downloads, plus the manager's hooks.
    func runDailyAutoSweep(store: AutoSweepStore, trigger: AutoSweepRun.Trigger) async -> AutoSweepRun {
        var parts: [AutoSweepRunPart] = []
        var trashed: [TrashLedgerEntry] = []
        var errors: [String] = []
        var skipped = 0

        if store.stopProcessesEnabled, let hook = store.stopLeftoverProcesses,
           let part = await hook(store.stopProcessesAfterHours) {
            parts.append(part)
        }

        if store.expireTrashEnabled {
            store.pruneLedger()
            let expired = store.expiredLedgerEntries(olderThanDays: store.expireTrashDays)
            if !expired.isEmpty {
                let outcome = await Task.detached(priority: .utility) {
                    Self.permanentlyRemove(expired)
                }.value
                store.removeFromLedger(outcome.removed)
                parts.append(AutoSweepRunPart(rule: .expireTrash, itemCount: outcome.removed.count, bytes: outcome.bytes,
                                              detail: "In the Trash for over \(store.expireTrashDays) days"))
                errors += outcome.errors
                recordFreed(outcome.bytes, items: outcome.removed.count, category: .trash, promptSupport: false)
            }
        }

        if store.tidyDownloadsEnabled {
            let candidates = await Task.detached(priority: .utility) { DownloadsTidier.candidates() }.value
            if !candidates.isEmpty {
                // Each candidate carries how it looked when its age (and, for archives, the unzipped
                // folder) was judged; one that changed since is left alone.
                var stamps: [String: CleanupStamp] = [:]
                for candidate in candidates { if let stamp = candidate.stamp { stamps[candidate.path] = stamp } }
                // An archive whose unzipped folder is gone is the only copy now: keep it.
                let movable = candidates.filter { $0.extractedFolder.map(Self.pathExists) ?? true }
                let result = await Self.moveToTrash(movable.map(\.path), expected: stamps)
                skipped += result.skippedPaths.count + candidates.count - movable.count
                noteSkippedSinceScan(skipped, in: "Auto-Sweep Downloads tidy")
                parts.append(AutoSweepRunPart(rule: .downloads, itemCount: result.succeededCount, bytes: result.reclaimedBytes,
                                              detail: "Old installers, unfinished downloads, already-unzipped archives"))
                trashed += Self.ledgerEntries(result)
                errors += result.errors
            }
        }

        if store.compressEnabled, let hook = store.compressColdFolders,
           let part = await hook(store.compressUnusedDays) {
            parts.append(part)
        }

        afterAutoSweep()
        return AutoSweepRun(date: Date(), trigger: trigger, parts: parts, trashed: trashed, errors: errors,
                            skippedCount: skipped > 0 ? skipped : nil)
    }

    /// Puts a run's items back where they were.
    func undoAutoSweepRun(_ run: AutoSweepRun, store: AutoSweepStore) async {
        guard run.canUndo, !isCleaning else { return }
        isCleaning = true
        let items = run.trashed.map(\.asTrashedItem)
        let outcome = await Task.detached(priority: .userInitiated) {
            DeletionService.restore(items)
        }.value
        isCleaning = false
        // The run is undone only once every item came back; otherwise it keeps the rest for another try.
        let back = Set(outcome.restoredItems.map(\.trashPath))
        store.markRestored(run.id, remaining: run.trashed.filter { !back.contains($0.trashPath) && $0.isStillOurs })
        ActivityLog.shared.refreshRestorable()
        if outcome.restored > 0 {
            statusBanner = "Restored \(outcome.restored) item(s) from the Trash."
        }
        if !outcome.errors.isEmpty {
            errorBanner = outcome.errors.joined(separator: "\n")
        }
        refreshDiskInfo()
        if hasScannedJunk { await scanJunk() }
        if hasScannedWorktrees { await scanWorktrees() }
    }

    // MARK: - Ledger feed

    /// Every cleanup in the main window that goes to the Trash publishes an UndoRecord; remember
    /// those paths so Trash expiry only ever touches Furl's own items.
    func observeTrashForLedger(store: AutoSweepStore) -> AnyCancellable {
        trashLedgerStore = store
        return $lastUndo
            .compactMap { $0 }
            .sink { [weak store] record in
                store?.recordTrashed(record.items, date: record.date)
            }
    }

    // MARK: - Helpers

    private func afterAutoSweep() {
        // Command items (docker://, simctl://) have no file; only test real paths.
        junkItems.removeAll { $0.command == nil && !Self.pathExists($0.path) }
        selectedJunkIDs.formIntersection(Set(junkItems.map(\.id)))
        refreshDiskInfo()
    }

    nonisolated static func pathExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Always the Trash. `expected` re-checks each path against its stamp right before it moves.
    nonisolated static func moveToTrash(_ paths: [String], expected: [String: CleanupStamp]) async -> CleanupResult {
        guard !paths.isEmpty else {
            return CleanupResult(succeededCount: 0, failedCount: 0, reclaimedBytes: 0, errors: [])
        }
        return await Task.detached(priority: .userInitiated) {
            DeletionService.deletePaths(paths, mode: .moveToTrash, expected: expected)
        }.value
    }

    nonisolated static func ledgerEntries(_ result: CleanupResult) -> [TrashLedgerEntry] {
        let now = Date()
        return result.trashedItems.map {
            TrashLedgerEntry(originalPath: $0.originalPath, trashPath: $0.trashPath, date: now, fileID: $0.fileID, bytes: $0.sizeBytes)
        }
    }

    /// Shortest paths first; anything inside an already-kept path is dropped.
    nonisolated static func removingNested<T>(_ items: [T], path: (T) -> String) -> [T] {
        let sorted = items.sorted { path($0).count < path($1).count }
        var kept: [T] = []
        var keptPaths = Set<String>()
        for item in sorted {
            var url = URL(fileURLWithPath: path(item)).deletingLastPathComponent()
            var nested = false
            while url.path != "/" && !url.path.isEmpty {
                if keptPaths.contains(url.path) { nested = true; break }
                url.deleteLastPathComponent()
            }
            guard !nested, !keptPaths.contains(path(item)) else { continue }
            keptPaths.insert(path(item))
            kept.append(item)
        }
        return kept
    }

    /// Caches (package, app, logs, .DS_Store) the scanner rates `.safe`, plus build output and
    /// dependency folders (node_modules, .venv) untouched for `unusedDays`. Never installers.
    nonisolated static func autoSweepCacheCandidates(roots: [String], unusedDays: Int) -> [JunkItem] {
        let cutoff = Date().addingTimeInterval(-Double(unusedDays) * 86_400)
        let dependencyNames: Set<String> = ["node_modules", ".venv", "venv"]
        var activityCache: [String: Date] = [:]
        return JunkScanner.scan(projectRoots: roots, staleDays: unusedDays, includeToolItems: false).filter { item in
            switch item.category {
            case .devArtifacts:
                guard let modified = item.modifiedDate, modified <= cutoff else { return false }
                let name = URL(fileURLWithPath: item.path).lastPathComponent
                guard item.risk == .safe || dependencyNames.contains(name) else { return false }
                // A folder's own date only changes when its top-level entries change, so a
                // node_modules in a project used every day can look months old. Judge by the
                // project around it instead.
                let project = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
                let lastActivity = activityCache[project] ?? projectLastActivity(project)
                activityCache[project] = lastActivity
                return lastActivity <= cutoff
            case .packageCaches, .systemCaches, .logsAndCrash, .dsStore:
                return item.risk == .safe
            case .installers:
                return false
            case .browserCaches, .mailAttachments:
                // Browser caches span several folders and a browser may open between scan and sweep;
                // Mail attachments need review. Both are cleaned by hand only.
                return false
            case .aiModels, .docker, .simulators:
                // Big, slow to get back, and need their own tools to remove: always ask first.
                return false
            }
        }
    }

    /// Newest modification date among the project's own files (a bounded walk that skips
    /// dependency, build and VCS folders). Returns `.distantFuture` when unsure, so callers skip.
    nonisolated static func projectLastActivity(_ project: String, maxEntries: Int = 20_000) -> Date {
        let skip: Set<String> = ["node_modules", ".venv", "venv", ".git", "build", "dist", ".next", "target",
                                 "DerivedData", ".build", "Pods", ".gradle", "__pycache__", ".turbo", ".cache"]
        let root = URL(fileURLWithPath: project)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants]) else {
            return .distantFuture
        }
        var newest = Date.distantPast
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen > maxEntries { return .distantFuture }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if let date = values?.contentModificationDate, date > newest { newest = date }
        }
        return newest
    }

    nonisolated static func permanentlyRemove(_ entries: [TrashLedgerEntry]) -> (removed: Set<String>, bytes: Int64, errors: [String]) {
        let fm = FileManager.default
        let trashRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL.path
        var removed = Set<String>()
        var bytes: Int64 = 0
        var errors: [String] = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry.trashPath).standardizedFileURL
            // Only ever delete things that are still in a Trash folder.
            let inVolumeTrash = url.path.hasPrefix("/Volumes/") && url.pathComponents.count > 3 && url.pathComponents[3] == ".Trashes"
            guard url.path.hasPrefix(trashRoot + "/") || inVolumeTrash else { continue }
            guard pathExists(url.path), entry.isStillOurs else {
                // Already gone, or something else now has that name: forget it, touch nothing.
                removed.insert(entry.trashPath)
                continue
            }
            let size = FileSizeHelper.directorySize(at: url)
            do {
                try fm.removeItem(at: url)
                removed.insert(entry.trashPath)
                bytes += size
            } catch {
                errors.append("\(url.lastPathComponent): couldn't remove from the Trash (\(error.localizedDescription))")
            }
        }
        return (removed, bytes, errors)
    }
}

// MARK: - Stamp book

/// `CleanupStamp`s (Services/CleanupStamp.swift) from the latest scan of each area, and when each
/// scan finished. Every user-triggered delete re-checks its items against these before removing.
struct CleanupStampBook {
    var junk: [String: CleanupStamp] = [:]
    var junkDate: Date?
    var worktrees: [String: CleanupStamp] = [:]
    var worktreesDate: Date?
    var largeFiles: [String: CleanupStamp] = [:]
    /// Includes each copy's size, which must still match its group.
    var duplicates: [String: CleanupStamp] = [:]
    var smartReview: [String: CleanupStamp] = [:]
    /// App bundles, their data folders and orphaned leftovers.
    var apps: [String: CleanupStamp] = [:]
    var spaceMap: [String: CleanupStamp] = [:]
}

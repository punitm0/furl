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
        /// Every path that goes to the Trash with an item: its own path first, then `extraPaths`.
        var itemPaths: [String: [String]] = [:]
        var itemBytes: [String: Int64] = [:]
        /// Browser caches: skipped at clean time while their browser runs.
        var browserCachePaths: Set<String> = []
        var isEmpty: Bool { paths.isEmpty }
    }

    /// Scan results older than this are rescanned before "Clean safe items" moves anything.
    static let safeCleanupMaxResultAge: TimeInterval = 10 * 60

    /// "Safe now" (GetSpaceBack board): the one number the Overview, the menu bar, the low-disk alert
    /// and Shortcuts show, and exactly what their button moves to the Trash. Only caches and junk the
    /// scanner rates Safe, that are still ticked in Caches & Junk, that have a file to move (never Docker
    /// or Simulator items, which can't go to the Trash) and that aren't protected. Browser caches count
    /// only while their browser is closed, since the clean skips them otherwise. Worktrees, duplicates,
    /// leftovers and large files are never part of it: they need a look first. Items nested inside
    /// another item count once. `AppState.safeCleanupPlan` holds the current one.
    nonisolated static func safeCleanupPlan(junk: [JunkItem], ticked: Set<String>,
                                            isProtected: (String) -> Bool = DeletionService.isProtected,
                                            isBrowserRunning: (String) -> Bool = { _ in false }) -> SafeCleanupPlan {
        let safe = junk.filter { item in
            item.risk == .safe && !item.isPermanent && ticked.contains(item.id)
                && !isProtected(item.path) && !item.extraPaths.contains(where: isProtected)
                && !(item.category == .browserCaches && isBrowserRunning(item.path))
        }
        var plan = SafeCleanupPlan()
        for item in removingNested(safe, path: \.path) {
            plan.paths.append(item.path)
            plan.itemPaths[item.path] = [item.path] + item.extraPaths
            plan.itemBytes[item.path] = item.sizeBytes
            plan.bytes += item.sizeBytes
            plan.junkCount += 1
            if item.category == .browserCaches { plan.browserCachePaths.insert(item.path) }
        }
        return plan
    }

    var hasScannedForSafeCleanup: Bool { hasScannedJunk }

    /// Runs the junk scan the menu bar needs, if it hasn't run yet.
    func prepareSafeCleanup() async {
        if !hasScannedJunk && !isScanningJunk { await scanJunk() }
    }

    /// The safe plan from a settled scan no older than `safeCleanupMaxResultAge`: waits for a scan
    /// that's running and rescans stale results. For anything that shows the number without the
    /// Overview in front of it (low-disk alert and notification, Shortcuts).
    func freshSafeCleanupPlan() async -> SafeCleanupPlan {
        await refreshSafeCleanupScans(maxAge: Self.safeCleanupMaxResultAge)
        return safeCleanupPlan
    }

    /// A safe clean needs something confirmed and no other cleanup running (a second click, the menu
    /// bar and the Overview at once, or the tray): only one ever runs.
    func canStartSafeClean(confirmedPaths: [String]) -> Bool {
        !confirmedPaths.isEmpty && !isCleaning
    }

    /// What a safe clean may move: items in the plan right now (Safe and ticked after any rescan) that
    /// the user confirmed and didn't untick while it was checking.
    nonisolated static func safeCleanTargets(plan: SafeCleanupPlan, confirmed: Set<String>,
                                             vetoed: Set<String>) -> [CleanupItem] {
        plan.paths.filter { confirmed.contains($0) && !vetoed.contains($0) }.map { path in
            var item = CleanupItem(path: path, allPaths: plan.itemPaths[path] ?? [path])
            item.isBrowserCache = plan.browserCachePaths.contains(path)
            return item
        }
    }

    /// "Clean safe items" from the Overview, the menu bar or a low-disk notification. The caller confirms first and
    /// passes the item paths of the plan it showed (`confirmedPaths`), so a scan that lands while the
    /// confirmation is up can't add items the user never saw, and an item the user unticks while it's
    /// checking stays put. Returns nil without doing anything while another cleanup runs.
    ///
    /// Scan results can be old. If the junk results are older than
    /// `safeCleanupMaxResultAge` they're rescanned first, and only items that were in the plan the
    /// user confirmed *and* are still safe after the rescan are cleaned (new finds wait for the
    /// next time the user sees them). Every item is then re-checked on disk right before it moves
    /// (`CleanupRecheck`): it must still exist, be the same kind (file, folder, link) and carry the
    /// modification date the scan saw, and browser caches are left alone while their browser runs. Anything that fails is skipped,
    /// and the banner and History count only what actually went to the Trash.
    @discardableResult
    func cleanSafeItems(store: AutoSweepStore, trigger: AutoSweepRun.Trigger,
                        confirmedPaths: [String]) async -> AutoSweepRun? {
        guard canStartSafeClean(confirmedPaths: confirmedPaths) else { return nil }
        isCleaning = true
        safeCleanNote = nil
        trackSafeCleanVetoes(true)
        // "Checking…" covers the rescan of stale results and the on-disk re-check; "Cleaning…" the move.
        setSafeCleanPhase(.checking)
        defer {
            isCleaning = false
            trackSafeCleanVetoes(false)
            setSafeCleanPhase(nil)
        }

        await refreshSafeCleanupScans(maxAge: Self.safeCleanupMaxResultAge)
        // Cancelled mid-rescan: the list may be half filled, so move nothing.
        guard !Task.isCancelled, !isScanningJunk else { return nil }

        let confirmedSet = Set(confirmedPaths)
        let items = Self.safeCleanTargets(plan: safeCleanupPlan, confirmed: confirmedSet,
                                          vetoed: safeCleanVetoes ?? [])
        // From here on the list is fixed; later unticks no longer apply.
        trackSafeCleanVetoes(false)
        let stamps = cleanupStamps.junk
        let check = await Task.detached(priority: .userInitiated) {
            CleanupRecheck.verify(items, stamps: stamps)
        }.value

        setSafeCleanPhase(.cleaning)
        let result = await Self.moveToTrash(check.verified.flatMap(\.allPaths), expected: stamps)

        // Count items, not paths: an item with extra paths is one item. An item counts as removed
        // once any of its paths actually went to the Trash.
        let trashedPaths = Set(result.trashedItems.map(\.originalPath))
        let removed = check.verified.filter { $0.allPaths.contains(where: trashedPaths.contains) }

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
        refreshDiskInfo()

        // Nothing moved and nothing failed: no History entry for a cleanup that didn't happen.
        guard !removed.isEmpty || !result.errors.isEmpty else {
            if skippedCount > 0 {
                showNothingCleaned(rescan: [.junk])
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
                detail: "\(removed.count) cache/junk item(s)"
            )],
            trashed: Self.ledgerEntries(result),
            errors: result.errors,
            skippedCount: skippedCount > 0 ? skippedCount : nil
        )
        store.record(run, countsAsAutoSweep: false)

        // The Overview shows its own "Freed…" banner with Undo (GetSpaceBack board).
        if !removed.isEmpty && trigger != .overview {
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

    /// Rescans junk when its results are older than `maxAge` (0 = always), and waits until results
    /// newer than this call are in. A scan already running is waited for, whatever the age of the
    /// last one: while it streams, the junk list is only partly filled.
    func refreshSafeCleanupScans(maxAge: TimeInterval) async {
        let start = Date()
        func isStale(_ date: Date?) -> Bool {
            guard let date else { return true }
            return maxAge <= 0 || start.timeIntervalSince(date) > maxAge
        }
        if isStale(cleanupStamps.junkDate) || isScanningJunk { await waitForFreshScan(after: start) }
    }

    /// Returns once a junk scan has finished after `start`, or when the task is cancelled.
    private func waitForFreshScan(after start: Date) async {
        while (cleanupStamps.junkDate ?? .distantPast) < start && !Task.isCancelled {
            if isScanningJunk {
                // Starting a scan now would only queue a rescan and return; wait for the running one.
                try? await Task.sleep(for: .milliseconds(200))
            } else {
                await scanJunk()
            }
        }
    }

    // MARK: - Auto-Sweep jobs

    /// The scheduled job: caches and stale dependency folders not used in N days.
    func runScheduledAutoSweep(store: AutoSweepStore, trigger: AutoSweepRun.Trigger,
                               skipping skips: Set<String> = []) async -> AutoSweepRun {
        let roots = projectRoots
        let days = store.cachesUnusedDays
        let excluded = excludedScanRoots
        // Always a fresh scan right before cleaning, then the same on-disk re-check as
        // "Clean safe items": anything that changed while the sweep was deciding is left alone.
        let (verified, stamps) = await Task.detached(priority: .utility) {
            let candidates = Self.removingNested(Self.autoSweepCacheCandidates(roots: roots, unusedDays: days), path: \.path)
                .filter { !Self.isExcluded($0.path, by: excluded) && !skips.contains($0.path) }
            let items = candidates.map { CleanupItem(path: $0.path, allPaths: [$0.path] + $0.extraPaths) }
            let stamps = CleanupStamp.read(junk: candidates)
            return (CleanupRecheck.verify(items, stamps: stamps).verified, stamps)
        }.value
        let result = await Self.moveToTrash(verified.flatMap(\.allPaths), expected: stamps)
        let parts = [AutoSweepRunPart(rule: .caches, itemCount: result.succeededCount, bytes: result.reclaimedBytes,
                                      detail: "Not used in \(days) days")]
        let run = AutoSweepRun(
            date: Date(),
            trigger: trigger,
            parts: parts,
            trashed: Self.ledgerEntries(result),
            errors: result.errors,
            why: trigger == .scheduled ? AutoSweepWhy.text(parts: parts, frequency: store.frequency, approved: false,
                                                           processHours: store.stopProcessesAfterHours) : nil
        )
        afterAutoSweep()
        return run
    }

    /// Daily chores: expire Furl's own Trash items, tidy Downloads, plus the manager's hooks.
    func runDailyAutoSweep(store: AutoSweepStore, trigger: AutoSweepRun.Trigger,
                           skipping skips: Set<String> = []) async -> AutoSweepRun {
        var parts: [AutoSweepRunPart] = []
        var trashed: [TrashLedgerEntry] = []
        var errors: [String] = []
        var skipped = 0

        if store.stopProcessesEnabled, let hook = store.stopLeftoverProcesses,
           let part = await hook(store.stopProcessesAfterHours, await processIDs(store: store, skipping: skips)) {
            parts.append(part)
        }

        if store.expireTrashEnabled {
            store.pruneLedger()
            let expired = store.expiredLedgerEntries(olderThanDays: store.expireTrashDays)
                .filter { !skips.contains($0.trashPath) }
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
            let excluded = excludedScanRoots
            let candidates = await Task.detached(priority: .utility) {
                DownloadsTidier.candidates().filter { !Self.isExcluded($0.path, by: excluded) }
            }.value
                .filter { !skips.contains($0.path) }
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
                            skippedCount: skipped > 0 ? skipped : nil,
                            why: trigger == .scheduled ? AutoSweepWhy.text(parts: parts, frequency: store.frequency, approved: false,
                                                                           processHours: store.stopProcessesAfterHours) : nil)
    }

    /// Leftovers to stop when some were unticked in See list: the due ones minus those. Nil = all due.
    private func processIDs(store: AutoSweepStore, skipping skips: Set<String>) async -> Set<String>? {
        guard !skips.isEmpty, let preview = store.previewLeftoverProcesses else { return nil }
        return Set(await preview(store.stopProcessesAfterHours).map(\.path)).subtracting(skips)
    }

    // MARK: - Preview and Ask first

    /// What a run would do right now, without touching anything: the next-run preview in Settings
    /// and the menu bar, and the list an Ask first notification asks about.
    func previewAutoSweep(store: AutoSweepStore, scheduled: Bool, daily: Bool) async -> AutoSweepPreview {
        var items: [AutoSweepPreview.Item] = []
        var stamps: [String: CleanupStamp] = [:]

        if scheduled && store.cachesEnabled {
            let roots = projectRoots
            let days = store.cachesUnusedDays
            let found = await Task.detached(priority: .utility) { () -> ([AutoSweepPreview.Item], [String: CleanupStamp]) in
                let candidates = Self.removingNested(Self.autoSweepCacheCandidates(roots: roots, unusedDays: days), path: \.path)
                    .filter { !DeletionService.isProtected($0.path) }
                let stamps = CleanupStamp.read(junk: candidates)
                let items = candidates.map { item in
                    let isDependency = URL(fileURLWithPath: item.path).lastPathComponent == "node_modules"
                    let folder = Self.shortPath(URL(fileURLWithPath: item.path).deletingLastPathComponent().path)
                    var detail = isDependency ? folder : Self.shortPath(item.path)
                    if isDependency, let modified = item.modifiedDate {
                        let days = max(1, Int(Date().timeIntervalSince(modified) / 86_400))
                        detail += " · not used for \(days) days"
                    }
                    let name = isDependency ? URL(fileURLWithPath: folder).lastPathComponent + "/node_modules" : item.name
                    let isDevArtifact = item.category == .devArtifacts
                    return AutoSweepPreview.Item(kind: isDependency ? .dependency : .cache, path: item.path,
                                                 extraPaths: item.extraPaths, name: name, bytes: item.sizeBytes,
                                                 detail: detail,
                                                 project: isDevArtifact ? URL(fileURLWithPath: item.path).deletingLastPathComponent().path : nil,
                                                 modified: isDevArtifact ? item.modifiedDate : nil)
                }
                return (items, stamps)
            }.value
            items += found.0
            stamps.merge(found.1) { a, _ in a }
        }

        if daily {
            if store.stopProcessesEnabled, let hook = store.previewLeftoverProcesses {
                items += await hook(store.stopProcessesAfterHours)
            }
            if store.expireTrashEnabled {
                store.pruneLedger()
                items += store.expiredLedgerEntries(olderThanDays: store.expireTrashDays).map { entry in
                    AutoSweepPreview.Item(kind: .trash, path: entry.trashPath,
                                          name: URL(fileURLWithPath: entry.originalPath).lastPathComponent,
                                          bytes: entry.bytes ?? 0, ledgerEntry: entry,
                                          detail: Self.shortPath(URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent().path))
                }
            }
            if store.tidyDownloadsEnabled {
                let found = await Task.detached(priority: .utility) { () -> [(AutoSweepPreview.Item, CleanupStamp)] in
                    // Each keeps the stamp from when its age was judged; one without a stamp is never offered.
                    DownloadsTidier.candidates().compactMap { candidate in
                        guard let stamp = candidate.stamp else { return nil }
                        let item = AutoSweepPreview.Item(kind: .download, path: candidate.path,
                                                         name: URL(fileURLWithPath: candidate.path).lastPathComponent,
                                                         bytes: FileSizeHelper.directorySize(at: URL(fileURLWithPath: candidate.path)),
                                                         extractedFolder: candidate.extractedFolder,
                                                         detail: candidate.reason)
                        return (item, stamp)
                    }
                }.value
                for (item, stamp) in found {
                    items.append(item)
                    stamps[item.path] = stamp
                }
            }
        }
        return AutoSweepPreview(date: Date(), scheduled: scheduled, daily: daily, items: items, stamps: stamps)
    }

    /// "~/code/web" for paths in the home folder.
    nonisolated static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Ask first: runs exactly what the user approved. Every file moves to the Trash only if it still
    /// matches how it looked in the preview; anything that changed, or that a rule no longer allows,
    /// is left alone. The Trash expiry removes only ledger entries Furl still tracks and still owns.
    func runApprovedAutoSweep(_ approved: AutoSweepPreview, store: AutoSweepStore) async -> AutoSweepRun {
        var parts: [AutoSweepRunPart] = []
        var trashed: [TrashLedgerEntry] = []
        var errors: [String] = []
        let stamps = approved.stamps

        // The ask may be days old: judge every item again by today's rules (a project used since,
        // a rule switched off or made stricter). What no longer passes is left alone.
        let rules = store.rules
        let checked = await Task.detached(priority: .userInitiated) {
            AutoSweepApproval.filter(approved, rules: rules, now: Date(), projectActivity: { Self.projectLastActivity($0) })
        }.value
        let preview = checked.preview
        var skipped = checked.dropped

        let cacheItems = preview.items.filter { $0.kind == .cache || $0.kind == .dependency }
        if !cacheItems.isEmpty {
            let items = cacheItems.filter { !DeletionService.isProtected($0.path) }
                .map { CleanupItem(path: $0.path, allPaths: [$0.path] + $0.extraPaths) }
            let verified = await Task.detached(priority: .userInitiated) {
                CleanupRecheck.verify(items, stamps: stamps).verified
            }.value
            let result = await Self.moveToTrash(verified.flatMap(\.allPaths), expected: stamps)
            skipped += cacheItems.count - verified.count + result.skippedPaths.count
            parts.append(AutoSweepRunPart(rule: .caches, itemCount: result.succeededCount, bytes: result.reclaimedBytes,
                                          detail: "Not used in \(store.cachesUnusedDays) days"))
            trashed += Self.ledgerEntries(result)
            errors += result.errors
        }

        let processIDs = Set(preview.items(.process).map(\.path))
        if !processIDs.isEmpty, let hook = store.stopLeftoverProcesses,
           let part = await hook(store.stopProcessesAfterHours, processIDs) {
            parts.append(part)
        }

        let trashItems = preview.items(.trash).compactMap(\.ledgerEntry)
        if !trashItems.isEmpty {
            store.pruneLedger()
            let tracked = Set(store.ledger.map(\.trashPath))
            let entries = trashItems.filter { tracked.contains($0.trashPath) }
            let outcome = await Task.detached(priority: .userInitiated) { Self.permanentlyRemove(entries) }.value
            store.removeFromLedger(outcome.removed)
            parts.append(AutoSweepRunPart(rule: .expireTrash, itemCount: outcome.removed.count, bytes: outcome.bytes,
                                          detail: "In the Trash for over \(store.expireTrashDays) days"))
            errors += outcome.errors
            recordFreed(outcome.bytes, items: outcome.removed.count, category: .trash, promptSupport: false)
        }

        let downloads = preview.items(.download)
        if !downloads.isEmpty {
            // An archive whose unzipped folder is gone is the only copy now: keep it.
            let movable = downloads.filter { $0.extractedFolder.map(Self.pathExists) ?? true }
                .filter { !DeletionService.isProtected($0.path) }
            let result = await Self.moveToTrash(movable.map(\.path), expected: stamps)
            skipped += result.skippedPaths.count + downloads.count - movable.count
            parts.append(AutoSweepRunPart(rule: .downloads, itemCount: result.succeededCount, bytes: result.reclaimedBytes,
                                          detail: "Old installers, unfinished downloads, already-unzipped archives"))
            trashed += Self.ledgerEntries(result)
            errors += result.errors
        }

        noteSkippedSinceScan(skipped, in: "Auto-Sweep (Ask first)")
        afterAutoSweep()
        return AutoSweepRun(date: Date(), trigger: .scheduled, parts: parts, trashed: trashed, errors: errors,
                            skippedCount: skipped > 0 ? skipped : nil,
                            why: AutoSweepWhy.text(parts: parts, frequency: store.frequency, approved: true,
                                                   processHours: store.stopProcessesAfterHours),
                            approved: true)
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

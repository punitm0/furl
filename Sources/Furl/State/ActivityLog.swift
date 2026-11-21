import Combine
import Foundation

/// Where a cleaned item went in the Trash (Codable twin of `TrashedItem`).
struct ActivityTrashedItem: Codable, Hashable, Sendable {
    let originalPath: String
    let trashPath: String
    /// Inode in the Trash (same scheme as `TrashLedgerEntry.fileID`): Finder reuses Trash names, so
    /// Undo only restores a match. Optional so older activity.json files still decode; an item saved
    /// without one (and without a size) can't be confirmed and isn't offered for Undo.
    var fileID: UInt64?
    var sizeBytes: Int64?
    /// See `TrashedItem.stamp`. Optional so older activity.json files still decode.
    var stamp: CleanupStamp?

    init(_ item: TrashedItem) {
        originalPath = item.originalPath
        trashPath = item.trashPath
        fileID = item.fileID
        sizeBytes = item.sizeBytes > 0 ? item.sizeBytes : nil
        stamp = item.stamp
    }

    var asTrashedItem: TrashedItem {
        TrashedItem(originalPath: originalPath, trashPath: trashPath, sizeBytes: sizeBytes ?? 0, fileID: fileID, stamp: stamp)
    }
}

/// A file Compress, Shrink or Format replaced (Codable twin of `CompressUndoRecord`), so Undo
/// still works after the screen's results are dismissed or Furl is relaunched.
struct ActivityReplacedItem: Codable, Hashable, Sendable {
    let originalPath: String
    let trashPath: String?
    let newPath: String
    /// See `CompressUndoRecord`. Optional so older activity.json files still decode; a record saved
    /// without them can't be confirmed, so Undo leaves it alone.
    var trashFileID: UInt64?
    var newStamp: CleanupStamp?

    init(_ record: CompressUndoRecord) {
        originalPath = record.originalPath
        trashPath = record.trashPath
        newPath = record.newPath
        trashFileID = record.trashFileID
        newStamp = record.newStamp
    }

    var asUndoRecord: CompressUndoRecord {
        CompressUndoRecord(originalPath: originalPath, trashPath: trashPath, newPath: newPath,
                           trashFileID: trashFileID, newStamp: newStamp)
    }

    /// The original is still the item Furl put in the Trash.
    var originalStillInTrash: Bool {
        guard let trashPath, let trashFileID else { return false }
        return DeletionService.fileID(trashPath) == trashFileID
    }
}

/// One thing Furl did, recorded by the main window, the tray, Processes, Compress, Shrink and Format.
/// Auto-Sweep runs keep their own History (`AutoSweepStore.history`) and are merged in for display.
struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cleanup
        case tray
        case processes
        case compress
        case emptyTrash
        /// Lossy Shrink (Compress screen). Originals are always kept in the Trash.
        case shrink
        /// Format suggestions (e.g. PNG → HEIC). Originals are kept in the Trash.
        case format
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var title: String
    var detail: String
    /// `SidebarSection.rawValue`s touched (for rescans after Undo).
    var sections: [String] = []
    var itemCount: Int
    /// Disk space cleaned: moved to the Trash or deleted. Empty-Trash entries keep their bytes here
    /// too but don't count toward the headline (those bytes were counted when they were cleaned).
    var diskBytes: Int64 = 0
    var memoryBytes: Int64 = 0
    var compressBytes: Int64 = 0
    /// Bytes removed for good (permanent mode, worktrees, Docker/Simulator commands).
    var permanentBytes: Int64 = 0
    var trashed: [ActivityTrashedItem] = []
    var automatic = false
    var undone = false
    /// Matches `CompressRunResult.startedAt`. Only used for entries saved before `replaced` existed.
    var compressRunStart: Date?
    /// What was touched, for entries whose items didn't go to the Trash (worktree folders, stopped
    /// processes, ended sessions, replaced files). Optional so older activity.json files still decode.
    var items: [String]?
    /// Compress / Shrink / Format: originals in the Trash and their replacements, so Undo can swap them back.
    var replaced: [ActivityReplacedItem]?
    /// Compress / Shrink: the StatsLedger event holding this run's savings, reversed when it's undone here.
    var statsEventID: UUID?
    /// Items left alone because they changed since the scan (History shows "N left alone: …").
    var skippedCount: Int?

    /// True when this entry's Undo puts originals back over replacements (Compress, Shrink, Format).
    var isReplacement: Bool { kind == .compress || kind == .shrink || kind == .format }
}

/// Timeline of everything Furl did. Stored in ~/Library/Application Support/Furl/activity.json;
/// it never leaves the Mac.
@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published private(set) var entries: [ActivityEntry] = []
    /// Entries whose Trash items are still there (refreshed when the Activity screen appears).
    @Published private(set) var restorableIDs: Set<UUID> = []
    /// Auto-Sweep runs whose Trash items are all gone (emptied), so their Undo would do nothing.
    @Published private(set) var goneRunIDs: Set<UUID> = []
    @Published private(set) var isUndoing = false

    /// Set while Auto-Sweep stops processes: its run records them in AutoSweep History instead.
    var suppressProcessStops = false

    private var batch: ActivityEntry?
    private var connected = false
    /// The entry for each store's `lastRun`, so an Undo pressed on that screen marks it, and an Undo
    /// pressed here goes through the store (keeping its results card and StatsLedger in sync).
    private var liveRunEntry: [ActivityEntry.Kind: UUID] = [:]
    /// Bumped whenever `restorableIDs` changes here, so a slower `refreshRestorable` pass that started
    /// before the change can't overwrite it with its older snapshot.
    private var restorableGeneration = 0
    private let maxEntries = 500

    private init() {
        entries = Self.load() ?? []
    }

    // MARK: - Wiring

    /// Compress, Shrink and Format have completion hooks; connect them once at launch.
    func connect(compress: CompressStore) {
        guard !connected else { return }
        connected = true

        let previousRun = compress.onRunCompleted
        compress.onRunCompleted = { [weak self] run in
            previousRun?(run)
            self?.recordCompress(run)
            self?.recordOriginalsInTrash(run.undoRecords)
        }
        let previousUndo = compress.onUndoCompleted
        compress.onUndoCompleted = { [weak self] restored, notRestored in
            previousUndo?(restored, notRestored)
            self?.liveRunUndone(.compress, restored: restored, notRestored: notRestored)
        }

        let shrink = compress.shrink
        let previousShrinkRun = shrink.onRunCompleted
        shrink.onRunCompleted = { [weak self] run in
            previousShrinkRun?(run)
            self?.recordShrink(run)
            self?.recordOriginalsInTrash(run.undoRecords)
        }
        let previousShrinkUndo = shrink.onUndoCompleted
        shrink.onUndoCompleted = { [weak self] restored, notRestored in
            previousShrinkUndo?(restored, notRestored)
            self?.liveRunUndone(.shrink, restored: restored, notRestored: notRestored)
        }

        let formats = shrink.formats
        let previousFormatRun = formats.onRunCompleted
        formats.onRunCompleted = { [weak self] run in
            previousFormatRun?(run)
            self?.recordFormat(run)
            self?.recordOriginalsInTrash(run.undoRecords)
        }
        let previousFormatUndo = formats.onUndoCompleted
        formats.onUndoCompleted = { [weak self] restored, notRestored in
            previousFormatUndo?(restored, notRestored)
            self?.liveRunUndone(.format, restored: restored, notRestored: notRestored)
        }
    }

    /// Compress, Shrink and Format keep originals in the Trash. They're Furl's items too, so "Empty
    /// Furl's items" can free them (TrashEmpty board). Read now, right after the run, off the main thread.
    private func recordOriginalsInTrash(_ records: [CompressUndoRecord]) {
        let moved = records.compactMap { record -> (original: String, trash: String, fileID: UInt64)? in
            guard let trash = record.trashPath, let fileID = record.trashFileID else { return nil }
            return (record.originalPath, trash, fileID)
        }
        guard !moved.isEmpty else { return }
        Task {
            let items = await Task.detached(priority: .utility) {
                moved.compactMap { item -> TrashedItem? in
                    guard DeletionService.fileID(item.trash) == item.fileID,
                          let stamp = CleanupStamp.read(item.trash) else { return nil }
                    let size = FileSizeHelper.directorySize(at: URL(fileURLWithPath: item.trash))
                    return TrashedItem(originalPath: item.original, trashPath: item.trash, sizeBytes: size,
                                       fileID: item.fileID, stamp: stamp)
                }
            }.value
            AppServices.autoSweep.recordTrashed(items)
        }
    }

    /// The store's own Undo ran (on its screen, or from here). The entry is undone only when every
    /// original came back; otherwise it keeps just the records that didn't, so Undo here can retry them.
    private func liveRunUndone(_ kind: ActivityEntry.Kind, restored: Int, notRestored: [CompressUndoRecord]) {
        guard let id = liveRunEntry.removeValue(forKey: kind), restored > 0 else { return }
        applyReplacementUndo(entryID: id, notRestored: notRestored)
    }

    /// Marks a Compress / Shrink / Format entry after some originals came back.
    private func applyReplacementUndo(entryID id: UUID, notRestored: [CompressUndoRecord]) {
        if notRestored.isEmpty {
            mutate { $0.id == id } change: { $0.undone = true }
            setRestorable(id, false)
        } else {
            mutate { $0.id == id } change: { $0.replaced = notRestored.map(ActivityReplacedItem.init) }
            refreshRestorable()
        }
    }

    private func setRestorable(_ id: UUID, _ restorable: Bool) {
        restorableGeneration += 1
        if restorable { restorableIDs.insert(id) } else { restorableIDs.remove(id) }
    }

    // MARK: - Recording

    /// Called from `AppState.applyDeletionResult` for every main-window cleanup.
    func recordCleanup(section: SidebarSection, label: String, result: CleanupResult, mode: DeletionMode, skipped: Int = 0) {
        guard result.succeededCount > 0 else { return }
        let permanent = mode == .permanent ? result.reclaimedBytes : 0
        let verb = mode == .moveToTrash ? "moved to the Trash" : "deleted"
        add(ActivityEntry(
            date: Date(),
            kind: .cleanup,
            title: section.rawValue,
            detail: "\(result.succeededCount) \(label) \(verb)",
            sections: [section.rawValue],
            itemCount: result.succeededCount,
            diskBytes: result.reclaimedBytes,
            permanentBytes: permanent,
            trashed: result.trashedItems.map(ActivityTrashedItem.init),
            skippedCount: skipped > 0 ? skipped : nil
        ))
    }

    /// Items cleaned for good although the mode was Move to Trash (worktrees, Docker/Simulator commands).
    /// For junk this adjusts the entry `recordCleanup` just made instead of adding one.
    func recordPermanent(section: SidebarSection, count: Int, bytes: Int64, detail: String, items: [String] = [],
                         skipped: Int = 0) {
        guard count > 0 else { return }
        if section == .junk {
            if var open = batch, open.sections.contains(section.rawValue) {
                open.permanentBytes += bytes
                batch = open
                return
            }
            if let index = entries.firstIndex(where: { $0.kind == .cleanup && $0.title == section.rawValue }),
               Date().timeIntervalSince(entries[index].date) < 5 {
                entries[index].permanentBytes += bytes
                save()
                return
            }
        }
        add(ActivityEntry(
            date: Date(),
            kind: .cleanup,
            title: section.rawValue,
            detail: detail,
            sections: [section.rawValue],
            itemCount: count,
            diskBytes: bytes,
            permanentBytes: bytes,
            items: items.isEmpty ? nil : items,
            skippedCount: skipped > 0 ? skipped : nil
        ))
    }

    /// No Undo: a stopped process can't be brought back. `names` are the leftovers' display names.
    func recordProcessStop(count: Int, bytes: UInt64, automatic: Bool, names: [String] = []) {
        guard count > 0, !suppressProcessStops else { return }
        add(ActivityEntry(
            date: Date(),
            kind: .processes,
            title: "Processes & Sessions",
            detail: (automatic ? "Auto-stopped " : "Stopped ") + (count == 1 ? "1 leftover process" : "\(count) leftover processes"),
            itemCount: count,
            memoryBytes: Int64(clamping: bytes),
            automatic: automatic,
            items: names.isEmpty ? nil : names
        ))
    }

    /// An agent session ended from Processes (by the user, by Force Quit, or by auto-end). No Undo;
    /// the agent can be resumed from its own transcript. `detail` reuses the Processes banner's wording.
    func recordSessionEnd(label: String, detail: String, automatic: Bool) {
        add(ActivityEntry(
            date: Date(),
            kind: .processes,
            title: "Processes & Sessions",
            detail: detail,
            itemCount: 1,
            automatic: automatic,
            items: [label]
        ))
    }

    func recordCompress(_ run: CompressRunResult) {
        let compressed = run.count(.compressed)
        // The store's `lastRun` is now this run; an older entry must no longer take the live path.
        guard compressed > 0 else { liveRunEntry[.compress] = nil; return }
        let records = run.undoRecords
        let entry = ActivityEntry(
            date: run.finishedAt,
            kind: .compress,
            title: "Compress",
            detail: "\(compressed) item\(compressed == 1 ? "" : "s") compressed losslessly",
            itemCount: compressed,
            compressBytes: run.savedBytes,
            compressRunStart: run.startedAt,
            items: run.items.filter { $0.status == .compressed }.map(\.path),
            replaced: records.map(ActivityReplacedItem.init),
            statsEventID: StatsLedger.shared.recordRun(category: .compress, startedAt: run.startedAt,
                                                       savedBytes: run.savedBytes, files: compressed)
        )
        liveRunEntry[.compress] = entry.id
        insert(entry)
    }

    func recordShrink(_ run: ShrinkRunResult) {
        let shrunk = run.items.filter { $0.status == .shrunk }
        guard !shrunk.isEmpty else { liveRunEntry[.shrink] = nil; return }
        let entry = ActivityEntry(
            date: run.finishedAt,
            kind: .shrink,
            title: "Shrink",
            detail: "\(shrunk.count) item\(shrunk.count == 1 ? "" : "s") shrunk, originals kept in the Trash",
            itemCount: shrunk.count,
            compressBytes: run.savedBytes,
            compressRunStart: run.startedAt,
            items: shrunk.map(\.path),
            replaced: run.undoRecords.map(ActivityReplacedItem.init),
            statsEventID: StatsLedger.shared.recordRun(category: .shrink, startedAt: run.startedAt,
                                                       savedBytes: run.savedBytes, files: shrunk.count)
        )
        liveRunEntry[.shrink] = entry.id
        insert(entry)
    }

    func recordFormat(_ run: FormatRunResult) {
        let converted = run.items.filter { $0.status == .shrunk }
        guard !converted.isEmpty else { liveRunEntry[.format] = nil; return }
        let entry = ActivityEntry(
            date: Date(),
            kind: .format,
            title: "Format conversion",
            detail: "\(converted.count) file\(converted.count == 1 ? "" : "s") converted, originals kept in the Trash",
            itemCount: converted.count,
            compressBytes: run.savedBytes,
            items: converted.map(\.path),
            replaced: run.undoRecords.map(ActivityReplacedItem.init)
        )
        liveRunEntry[.format] = entry.id
        insert(entry)
    }

    func recordEmptyTrash(bytes: Int64, count: Int) {
        add(ActivityEntry(
            date: Date(),
            kind: .emptyTrash,
            title: "Emptied the Trash",
            detail: count > 0 ? "\(count) item\(count == 1 ? "" : "s") removed for good" : "Removed for good",
            itemCount: count,
            diskBytes: bytes,
            permanentBytes: bytes
        ))
        // Nothing Furl put in the Trash can come back now.
        restorableGeneration += 1
        restorableIDs = []
        goneRunIDs = Set(AppServices.autoSweep.history.filter { !$0.trashed.isEmpty }.map(\.id))
    }

    /// "Empty Furl's items" (TrashEmpty board): Permanent, never undoable. Only Furl's own items went,
    /// so other entries' Undo is re-checked rather than switched off.
    func recordEmptyFurlTrash(bytes: Int64, count: Int, skipped: Int) {
        add(ActivityEntry(
            date: Date(),
            kind: .emptyTrash,
            title: "Emptied Furl’s items from the Trash",
            detail: "\(count) item\(count == 1 ? "" : "s") deleted for good",
            itemCount: count,
            diskBytes: bytes,
            permanentBytes: bytes,
            skippedCount: skipped > 0 ? skipped : nil
        ))
        refreshRestorable()
    }

    /// The tray runs several sections' cleanups; they become one entry.
    func beginBatch(title: String) {
        batch = ActivityEntry(date: Date(), kind: .tray, title: title, detail: "", itemCount: 0)
    }

    func endBatch() {
        guard var entry = batch else { return }
        batch = nil
        guard entry.itemCount > 0 else { return }
        let names = entry.sections.compactMap { SidebarSection(rawValue: $0)?.rawValue }
        entry.detail = "\(entry.itemCount) item\(entry.itemCount == 1 ? "" : "s") from " + names.joined(separator: ", ")
        entry.date = Date()
        insert(entry)
    }

    private func add(_ entry: ActivityEntry) {
        if var open = batch {
            open.itemCount += entry.itemCount
            open.diskBytes += entry.diskBytes
            open.permanentBytes += entry.permanentBytes
            open.trashed += entry.trashed
            if let skipped = entry.skippedCount { open.skippedCount = (open.skippedCount ?? 0) + skipped }
            for section in entry.sections where !open.sections.contains(section) {
                open.sections.append(section)
            }
            batch = open
            return
        }
        insert(entry)
    }

    private func insert(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        if Self.hasTrashItems(entry) { setRestorable(entry.id, true) }
        save()
    }

    // MARK: - Undo

    /// These items came back from the Trash (the banner's Undo, ⌥⌘Z, or Undo here). Each entry holding
    /// them drops them; an entry is undone once none of its items are left, otherwise it stays
    /// restorable with only the items that didn't come back.
    func markRestored(trashed items: [TrashedItem]) {
        let paths = Set(items.map(\.trashPath))
        guard !paths.isEmpty else { return }
        var emptied: [UUID] = []
        mutate { entry in entry.trashed.contains { paths.contains($0.trashPath) } } change: { entry in
            let remaining = entry.trashed.filter { !paths.contains($0.trashPath) }
            if remaining.isEmpty {
                // Keep the list as it was: the row still describes what the cleanup did.
                entry.undone = true
                emptied.append(entry.id)
            } else {
                entry.trashed = remaining
            }
        }
        for id in emptied { setRestorable(id, false) }
    }

    func canUndo(_ entry: ActivityEntry, compress: CompressStore) -> Bool {
        guard !entry.undone else { return false }
        switch entry.kind {
        case .cleanup, .tray, .shrink, .format:
            return restorableIDs.contains(entry.id)
        case .compress:
            if entry.replaced != nil { return restorableIDs.contains(entry.id) }
            // Saved before `replaced` existed: only the run still on the Compress screen can be undone.
            return entry.compressRunStart != nil && compress.lastRun?.startedAt == entry.compressRunStart
                && compress.lastRun?.undoRecords.contains { $0.trashPath != nil } == true
        case .processes, .emptyTrash:
            return false
        }
    }

    /// Auto-Sweep runs keep their own Undo; this hides it once the Trash that held their items was emptied.
    func canUndo(_ run: AutoSweepRun) -> Bool {
        run.canUndo && !goneRunIDs.contains(run.id)
    }

    func undo(_ entry: ActivityEntry, state: AppState, compress: CompressStore) async {
        guard canUndo(entry, compress: compress), !isUndoing, !state.isCleaning else { return }
        isUndoing = true
        defer { isUndoing = false }

        switch entry.kind {
        case .compress, .shrink, .format:
            await undoReplacement(entry, state: state, compress: compress)
        case .cleanup, .tray:
            let items = entry.trashed.map(\.asTrashedItem)
            let trashPaths = Set(items.map(\.trashPath))
            // The latest cleanup goes through AppState so its banner and ⌥⌘Z stay in sync.
            // Compare Trash paths only: History doesn't keep the sizes that `TrashedItem` hashes.
            if let last = state.lastUndo, Set(last.items.map(\.trashPath)) == trashPaths {
                await state.undoLastCleanup()
                return
            }
            // Restoring these makes the banner's Undo stale if it covers any of them.
            if let last = state.lastUndo, last.items.contains(where: { trashPaths.contains($0.trashPath) }) {
                state.lastUndo = nil
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                DeletionService.restore(items)
            }.value
            markRestored(trashed: outcome.restoredItems)
            // What didn't come back stays on the entry; recheck whether any of it is still in the Trash.
            refreshRestorable()
            if outcome.restored > 0 { state.statusBanner = "Restored \(outcome.restored) item(s) from the Trash." }
            if !outcome.errors.isEmpty { state.errorBanner = outcome.errors.joined(separator: "\n") }
            state.refreshDiskInfo()
            await state.rescanAfterRestore(sections: entry.sections.compactMap(SidebarSection.init(rawValue:)))
        case .processes, .emptyTrash:
            break
        }
    }

    /// Puts Compress / Shrink / Format originals back from the Trash (replacements go to the Trash).
    ///
    /// The run still on its screen goes through its store, whose hooks mark this entry
    /// (`liveRunUndone`) and reverse its StatsLedger savings. Any other run swaps back from the saved
    /// records here and reverses its savings itself, through the event id the entry kept; `reverse` is
    /// a no-op for an event already reversed, so the two paths never count twice.
    private func undoReplacement(_ entry: ActivityEntry, state: AppState, compress: CompressStore) async {
        // Live only while the store still holds this entry's run (an empty later run clears it).
        let isLive = liveRunEntry[entry.kind] == entry.id && {
            switch entry.kind {
            case .compress: return compress.lastRun != nil && compress.lastRun?.startedAt == entry.compressRunStart
            case .shrink: return compress.shrink.lastRun != nil && compress.shrink.lastRun?.startedAt == entry.compressRunStart
            case .format: return compress.shrink.formats.lastRun != nil
            default: return false
            }
        }()
        let outcome: (restored: Int, errors: [String])
        if entry.kind == .compress, entry.replaced == nil {
            // Saved before `replaced` existed; `canUndo` already checked it's the Compress screen's run.
            outcome = await compress.undoLastRun()
        } else if isLive, entry.kind == .compress {
            outcome = await compress.undoLastRun()
        } else if isLive, entry.kind == .shrink {
            outcome = await compress.shrink.undoLastRun()
        } else if isLive, entry.kind == .format {
            outcome = await compress.shrink.formats.undoLastRun()
        } else {
            // An older run, or one whose results card was dismissed: swap back from the saved records.
            if liveRunEntry[entry.kind] == entry.id { liveRunEntry[entry.kind] = nil }
            let records = (entry.replaced ?? []).map(\.asUndoRecord)
            let each = await Task.detached(priority: .userInitiated) { CompressionService.undoEach(records) }.value
            let restored = each.filter { $0.error == nil }.count
            outcome = (restored, each.compactMap(\.error))
            if restored > 0 {
                applyReplacementUndo(entryID: entry.id, notRestored: each.filter { $0.error != nil }.map(\.record))
                reverseSavings(of: entry)
            }
        }
        if outcome.restored > 0 {
            state.statusBanner = "Restored \(outcome.restored) original(s) from the Trash."
        } else {
            // Nothing came back (originals no longer in the Trash): recheck so the button goes away.
            refreshRestorable()
        }
        if !outcome.errors.isEmpty { state.errorBanner = outcome.errors.joined(separator: "\n") }
        state.refreshDiskInfo()
    }

    /// Takes a Compress / Shrink run's savings back out of StatsLedger. Format runs never added any.
    private func reverseSavings(of entry: ActivityEntry) {
        let category: StatsEvent.Category
        switch entry.kind {
        case .compress: category = .compress
        case .shrink: category = .shrink
        default: return
        }
        let ledger = StatsLedger.shared
        if let id = entry.statsEventID ?? ledger.legacyRunEvent(category: category, savedBytes: entry.compressBytes,
                                                                 files: entry.itemCount, finishedAt: entry.date) {
            ledger.reverse(id)
        }
    }

    /// Whether any of this entry's originals were put in the Trash (so Undo has something to restore).
    private nonisolated static func hasTrashItems(_ entry: ActivityEntry) -> Bool {
        !entry.trashed.isEmpty || (entry.replaced ?? []).contains { $0.trashPath != nil }
    }

    /// Whether at least one of this entry's items is still the very item Furl put in the Trash
    /// (matching inode; see `DeletionService.isStillInTrash`).
    private nonisolated static func hasRestorableItem(_ entry: ActivityEntry) -> Bool {
        entry.trashed.contains { DeletionService.isStillInTrash($0.asTrashedItem) }
            || (entry.replaced ?? []).contains(where: \.originalStillInTrash)
    }

    /// Checks which entries (and Auto-Sweep runs) still have their items in the Trash.
    func refreshRestorable() {
        let candidates = entries.filter { !$0.undone && Self.hasTrashItems($0) }
        let runs = AppServices.autoSweep.history.filter(\.canUndo)
        restorableGeneration += 1
        let generation = restorableGeneration
        Task {
            let (ids, gone) = await Task.detached(priority: .utility) { () -> (Set<UUID>, Set<UUID>) in
                let ids = Set(candidates.filter(Self.hasRestorableItem).map(\.id))
                let gone = Set(runs.filter { run in
                    !run.trashed.contains { DeletionService.isStillInTrash($0.asTrashedItem) }
                }.map(\.id))
                return (ids, gone)
            }.value
            // Something changed (or a newer refresh started) while this one ran: its snapshot is stale.
            guard generation == self.restorableGeneration else { return }
            self.restorableIDs = ids
            self.goneRunIDs = gone
        }
    }

    func clear() {
        entries = []
        restorableGeneration += 1
        restorableIDs = []
        save()
    }

    private func mutate(where match: (ActivityEntry) -> Bool, change: (inout ActivityEntry) -> Void) {
        var changed = false
        for index in entries.indices where match(entries[index]) {
            change(&entries[index])
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        AutoSweepStore.supportDirectory.appendingPathComponent("activity.json")
    }

    private static func load() -> [ActivityEntry]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([ActivityEntry].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

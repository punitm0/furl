import Foundation

/// Sections that can add items to the cleanup tray.
enum TraySource: String, Codable, CaseIterable, Sendable {
    case smartReview, junk, worktrees, duplicates, largeFiles, apps

    var section: SidebarSection {
        switch self {
        case .smartReview: return .smartReview
        case .junk: return .junk
        case .worktrees: return .worktrees
        case .duplicates: return .duplicates
        case .largeFiles: return .largeFiles
        case .apps: return .apps
        }
    }
}

/// One thing waiting in the tray. `key` is the item's id in its section, so the clean can hand it
/// back to that section's own cleanup.
struct TrayItem: Codable, Identifiable, Hashable, Sendable {
    let source: TraySource
    let key: String
    /// The path checked for existence. Docker/Simulator items use a pseudo path ("docker://…").
    let path: String
    let title: String
    let subtitle: String
    let bytes: Int64
    /// Removed for good even in Move to Trash mode (worktrees, Docker/Simulator commands).
    let isPermanent: Bool
    var included = true
    var addedAt = Date()
    /// Duplicates: the other copies. The item is dropped once it's the only copy left.
    var siblings: [String] = []
    /// Apps: data folders removed together with the app.
    var extraPaths: [String] = []
    /// Junk rated other than Safe: shows the Check first chip. Optional so trays saved before it still load.
    var checkFirst: Bool? = nil

    var id: String { source.rawValue + "|" + key }
    var isPseudoPath: Bool { path.contains("://") }
    var isAppBundle: Bool { source == .apps && key.hasPrefix("app:") }
}

/// Items from any section, cleaned in one go. Persisted at
/// ~/Library/Application Support/Furl/cleanup-tray.json.
@MainActor
final class CleanupTray: ObservableObject {
    static let shared = CleanupTray()

    @Published private(set) var items: [TrayItem] = [] {
        didSet {
            save()
            // A flag belongs to an item in the tray; drop it when the item leaves.
            let ids = Set(items.map(\.id))
            if !needsAccessIDs.isSubset(of: ids) { needsAccessIDs.formIntersection(ids) }
        }
    }
    @Published var isPresented = false
    @Published private(set) var isCleaning = false
    @Published private(set) var phase = ""
    /// Shown in the tray after adding: "3 added · 1 skipped (system folder)".
    @Published var notice: String?
    /// Items a scan without Full Disk Access didn't list. Kept, since that scan saw less than usual.
    @Published private(set) var needsAccessIDs: Set<String> = []

    private init() {
        items = Self.load() ?? []
    }

    // MARK: - Contents

    var includedItems: [TrayItem] { items.filter(\.included) }

    /// Running total without double counting items nested inside other tray items.
    var includedBytes: Int64 { Self.nestedAwareTotal(includedItems) }
    var totalBytes: Int64 { Self.nestedAwareTotal(items) }

    var sourceCount: Int { Set(items.map(\.source)).count }

    func contains(_ source: TraySource, key: String) -> Bool {
        items.contains { $0.source == source && $0.key == key }
    }

    func items(from source: TraySource) -> [TrayItem] {
        items.filter { $0.source == source }
    }

    // MARK: - Adding & removing

    /// Adds items, skipping protected system paths and anything already in the tray.
    @discardableResult
    func add(_ new: [TrayItem], open: Bool = true) -> Int {
        var added = 0
        var protected = 0
        var known = Set(items.map(\.id))
        var next = items
        for item in new {
            if !item.isPseudoPath && DeletionService.isProtected(item.path) {
                protected += 1
                continue
            }
            guard known.insert(item.id).inserted else { continue }
            needsAccessIDs.remove(item.id)
            next.append(item)
            added += 1
        }
        items = next
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) item\(added == 1 ? "" : "s")") }
        if protected > 0 { parts.append("\(protected) system item\(protected == 1 ? "" : "s") can't be added") }
        if added == 0 && protected == 0 && !new.isEmpty { parts.append("Already in the tray") }
        notice = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if open && !new.isEmpty { isPresented = true }
        return added
    }

    func setIncluded(_ id: String, _ included: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].included = included
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    func removeAll() {
        items = []
        notice = nil
    }

    /// Drops items whose files are gone (cleaned elsewhere, moved, or deleted by hand).
    func pruneMissing(state: AppState) {
        let junkScanSettled = state.hasScannedJunk && !state.isScanningJunk
        let junkIDs = Set(state.junkItems.map(\.id))
        let kept = items.filter { item in
            if item.isPseudoPath {
                return !junkScanSettled || junkIDs.contains(item.key)
            }
            guard Self.exists(item.path) else { return false }
            if item.source == .duplicates, !item.siblings.isEmpty {
                // Never clean the last copy of a file.
                return item.siblings.contains(where: Self.exists)
            }
            return true
        }
        if kept.count != items.count { items = kept }
    }

    // MARK: - Reconcile with a scan

    struct Reconciled: Equatable {
        /// What stays in the tray (includes `unchecked`).
        var kept: [TrayItem]
        /// Items the finished scan no longer lists. Only taken off the tray; nothing is deleted.
        var removed: [TrayItem]
        /// Not listed, but the scan ran without Full Disk Access, so they stay and get flagged.
        var unchecked: [TrayItem]
    }

    /// A tray item is a copy of a section's item, and the clean can only act on what the section lists.
    /// After a complete scan, items the new list lacks are dropped here instead of failing at clean time.
    /// A stopped scan proves nothing; a scan without Full Disk Access saw less, so its items are kept.
    nonisolated static func reconcile(
        _ items: [TrayItem], source: TraySource, listed: Set<String>, completed: Bool, fullAccess: Bool
    ) -> Reconciled {
        guard completed else { return Reconciled(kept: items, removed: [], unchecked: []) }
        let missing = items.filter { $0.source == source && !listed.contains($0.key) }
        guard !missing.isEmpty else { return Reconciled(kept: items, removed: [], unchecked: []) }
        if !fullAccess { return Reconciled(kept: items, removed: [], unchecked: missing) }
        let gone = Set(missing.map(\.id))
        return Reconciled(kept: items.filter { !gone.contains($0.id) }, removed: missing, unchecked: [])
    }

    /// Called when a section's scan ends. `listed` holds the keys tray items of `source` use.
    func reconcile(_ source: TraySource, listed: Set<String>, completed: Bool) {
        // A section's cleanup rescans while the tray cleans; `clean` settles the tray itself afterwards.
        guard !isCleaning, completed, items.contains(where: { $0.source == source }) else { return }
        FullDiskAccess.shared.refresh()
        let result = Self.reconcile(items, source: source, listed: listed, completed: completed,
                                    fullAccess: FullDiskAccess.shared.isGranted)
        // This section's flags now reflect this scan only.
        needsAccessIDs.subtract(items(from: source).map(\.id))
        needsAccessIDs.formUnion(result.unchecked.map(\.id))
        if !result.removed.isEmpty {
            items = result.kept
            notice = Self.removedNotice(result.removed, section: source.section)
        }
    }

    nonisolated static func removedNotice(_ removed: [TrayItem], section: SidebarSection) -> String {
        let n = removed.count
        return n == 1 ? "Removed 1 item that's no longer listed in \(section.rawValue)."
                      : "Removed \(n) items that are no longer listed in \(section.rawValue)."
    }

    /// Clean-time warning for items kept because Furl couldn't check them without Full Disk Access.
    nonisolated static func needsAccessMessage(_ items: [TrayItem]) -> String {
        if items.count == 1, let item = items.first {
            return "Kept \(item.title) in the tray: Furl needs Full Disk Access to check it."
        }
        return "Kept \(items.count) items in the tray: Furl needs Full Disk Access to check them."
    }

    // MARK: - Clean

    /// Hands each section its own items and runs that section's cleanup, so the Trash, permanent-item
    /// and keep-one-copy rules stay exactly as they are. The Trash parts become one Undo.
    func clean(state: AppState) async {
        guard !isCleaning, !state.isCleaning else { return }
        pruneMissing(state: state)
        let batch = includedItems
        guard !batch.isEmpty else { return }
        // Counted before any section runs: its cleanup may rescan and change the tray mid-clean.
        let beforeIDs = Set(items.map(\.id))
        isCleaning = true
        defer {
            isCleaning = false
            phase = ""
        }

        let log = ActivityLog.shared
        log.beginBatch(title: "Cleanup tray")
        var undoItems: [TrashedItem] = []
        var undoBytes: Int64 = 0
        var undoSections: [SidebarSection] = []
        var errors: [String] = []
        // Items whose section no longer lists them: left on disk, taken off the tray.
        var unmatched: [TrayItem] = []
        // Items a section left alone because they changed since its scan.
        var skipped = 0

        func capture(since before: UndoRecord?) {
            skipped += state.lastSkippedCount
            state.setLastSkipped(0)
            if let record = state.lastUndo, record.date != before?.date || record.items != before?.items {
                undoItems += record.items
                undoBytes += record.bytes
                if !undoSections.contains(record.section) { undoSections.append(record.section) }
            }
            if let error = state.errorBanner {
                errors.append(error)
                state.errorBanner = nil
            }
        }

        let grouped = Dictionary(grouping: batch, by: \.source)
        for source in TraySource.allCases {
            guard let group = grouped[source], !group.isEmpty else { continue }
            phase = "Checking \(source.section.rawValue)…"
            await ensureScanned(source, state: state)
            phase = "Cleaning \(source.section.rawValue)…"
            let keys = Set(group.map(\.key))
            let before = state.lastUndo
            state.setLastSkipped(0)

            switch source {
            case .junk:
                let matched = keys.intersection(state.junkItems.map(\.id))
                unmatched += group.filter { !matched.contains($0.key) }
                guard !matched.isEmpty else { continue }
                let saved = state.selectedJunkIDs
                state.selectedJunkIDs = matched
                await state.cleanSelectedJunk()
                state.selectedJunkIDs = saved.intersection(state.junkItems.map(\.id))
            case .largeFiles:
                let matched = keys.intersection(state.largeFiles.map(\.id))
                unmatched += group.filter { !matched.contains($0.key) }
                guard !matched.isEmpty else { continue }
                let saved = state.selectedLargeFileIDs
                state.selectedLargeFileIDs = matched
                await state.cleanSelectedLargeFiles()
                state.selectedLargeFileIDs = saved.intersection(state.largeFiles.map(\.id))
            case .duplicates:
                let all = Set(state.duplicateGroups.flatMap { $0.files.map(\.id) })
                let matched = keys.intersection(all)
                unmatched += group.filter { !matched.contains($0.key) }
                guard !matched.isEmpty else { continue }
                let saved = state.selectedDuplicateIDs
                state.selectedDuplicateIDs = matched
                await state.cleanSelectedDuplicates()
                state.selectedDuplicateIDs = saved.intersection(state.duplicateGroups.flatMap { $0.files.map(\.id) })
            case .smartReview:
                let matched = keys.intersection(state.smartItems.map(\.id))
                unmatched += group.filter { !matched.contains($0.key) }
                guard !matched.isEmpty else { continue }
                let saved = state.selectedSmartIDs
                state.selectedSmartIDs = matched
                await state.cleanSelectedSmartItems()
                state.selectedSmartIDs = saved.intersection(state.smartItems.map(\.id))
            case .worktrees:
                let matched = keys.intersection(state.worktrees.map(\.id))
                unmatched += group.filter { !matched.contains($0.key) }
                guard !matched.isEmpty else { continue }
                let saved = state.selectedWorktreeIDs
                state.selectedWorktreeIDs = matched
                await state.cleanSelectedWorktrees()
                state.selectedWorktreeIDs = saved.intersection(state.worktrees.map(\.id))
            case .apps:
                for item in group where item.isAppBundle {
                    guard let app = state.installedApps.first(where: { "app:" + $0.id == item.key }) else {
                        unmatched.append(item)
                        continue
                    }
                    let data = item.extraPaths.filter(Self.exists)
                    let appBefore = state.lastUndo
                    await state.uninstallApp(app, includeDataPaths: data)
                    capture(since: appBefore)
                }
                let dataKeys = Set(group.filter { !$0.isAppBundle }.map(\.key))
                if !dataKeys.isEmpty {
                    let leftovers = state.orphanedGroups.flatMap(\.items).filter { dataKeys.contains("data:" + $0.id) }
                    let found = Set(leftovers.map { "data:" + $0.id })
                    unmatched += group.filter { !$0.isAppBundle && !found.contains($0.key) }
                    if !leftovers.isEmpty {
                        let dataBefore = state.lastUndo
                        await state.clearOrphanedItems(leftovers, label: "leftover item(s)")
                        capture(since: dataBefore)
                    }
                }
                continue
            }
            capture(since: before)
        }

        log.endBatch()

        pruneMissing(state: state)
        let cleanedCount = beforeIDs.subtracting(items.map(\.id)).count

        if !undoItems.isEmpty, let first = undoSections.first {
            state.lastUndo = UndoRecord(
                label: "tray item(s)",
                items: undoItems,
                bytes: undoBytes,
                section: first,
                date: Date(),
                extraSections: Array(undoSections.dropFirst())
            )
        }
        if cleanedCount > 0 {
            let verb = state.deletionMode == .moveToTrash ? "Cleaned" : "Deleted"
            state.statusBanner = AppState.withSkipped("\(verb) \(cleanedCount) tray item\(cleanedCount == 1 ? "" : "s").", skipped)
        } else if skipped > 0, errors.isEmpty, unmatched.isEmpty {
            state.showNothingCleaned(rescan: Array(Set(batch.map(\.source.section))))
        }
        var rescan: [SidebarSection] = []
        if !unmatched.isEmpty {
            // Last line of defence: `reconcile` normally drops these when the scan ends, so this only
            // catches a list that changed between scan and clean.
            FullDiskAccess.shared.refresh()
            if FullDiskAccess.shared.isGranted {
                // Nothing on disk is touched here. Dropping them stops the same warning on every clean;
                // a rescan lists them again if they're still there.
                let stale = Set(unmatched.map(\.id))
                items.removeAll { stale.contains($0.id) }
                errors.append(Self.unmatchedMessage(unmatched))
                rescan = Self.sections(of: unmatched)
            } else {
                // The scan saw less than usual: keep them until Full Disk Access is back on.
                needsAccessIDs.formUnion(unmatched.map(\.id))
                errors.append(Self.needsAccessMessage(unmatched))
            }
        }
        if !errors.isEmpty {
            state.showError(errors.joined(separator: "\n"), rescan: rescan)
        }
        notice = nil
    }

    /// The section's list must be current before its cleanup can find the tray's items.
    private func ensureScanned(_ source: TraySource, state: AppState) async {
        func waitWhile(_ busy: () -> Bool) async {
            while busy() { try? await Task.sleep(for: .milliseconds(200)) }
        }
        switch source {
        case .junk:
            await waitWhile { state.isScanningJunk }
            if !state.hasScannedJunk { await state.scanJunk() }
        case .worktrees:
            await waitWhile { state.isScanningWorktrees }
            if !state.hasScannedWorktrees { await state.scanWorktrees() }
        case .largeFiles:
            await waitWhile { state.isScanningLargeFiles }
            if !state.hasScannedLargeFiles { await state.scanLargeFiles() }
        case .duplicates:
            await waitWhile { state.isScanningDuplicates }
            if !state.hasScannedDuplicates { await state.scanDuplicates() }
        case .apps:
            await waitWhile { state.isScanningApps }
            if !state.hasScannedApps { await state.scanApps() }
        case .smartReview:
            await waitWhile { state.isScanningSmart }
            if !state.hasScannedSmart { await state.scanSmartReview() }
        }
    }

    // MARK: - Labels

    /// The tray's main button. "Move to Trash" only when everything included really goes there.
    nonisolated static func primaryTitle(
        hasItems: Bool, includedCount: Int, permanentCount: Int, bytes: Int64, mode: DeletionMode
    ) -> String {
        if !hasItems { return mode == .permanent ? "Delete" : "Move to Trash" }
        let size = FileSizeHelper.formatBytes(bytes)
        if mode == .permanent { return "Delete \(size)" }
        if includedCount > 0 && permanentCount == includedCount { return "Remove \(size)" }
        if permanentCount > 0 { return "Clean \(size)" }
        return "Move \(size) to Trash"
    }

    /// Sections in tray order, each once.
    nonisolated static func sections(of items: [TrayItem]) -> [SidebarSection] {
        let present = Set(items.map(\.source))
        return TraySource.allCases.filter(present.contains).map(\.section)
    }

    /// Warning after a clean for items their section no longer lists. They were taken off the tray.
    nonisolated static func unmatchedMessage(_ items: [TrayItem]) -> String {
        let names = sections(of: items).map(\.rawValue)
        let sectionText = names.count <= 2
            ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
        if items.count == 1, let item = items.first {
            return "Took \(item.title) off the tray: \(sectionText) doesn't list it anymore, so Furl didn't touch it. Rescan to check it."
        }
        let verb = names.count == 1 ? "doesn't" : "don't"
        return "Took \(items.count) items off the tray that \(sectionText) \(verb) list anymore. Furl didn't touch them. Rescan to check them."
    }

    /// The part of worktree branch names that every worktree row shares up to a "/", such as
    /// "claude/". Rows drop it so the part that tells them apart stays visible.
    nonisolated static func sharedBranchPrefix(_ items: [TrayItem]) -> String {
        let titles = items.filter { $0.source == .worktrees }.map(\.title)
        guard titles.count > 1, var prefix = titles.first else { return "" }
        for title in titles.dropFirst() {
            prefix = String(prefix.commonPrefix(with: title))
            if prefix.isEmpty { return "" }
        }
        guard let slash = prefix.lastIndex(of: "/") else { return "" }
        let shared = String(prefix[...slash])
        // Keep the full name if dropping the prefix would leave a row empty.
        return titles.contains { $0.count == shared.count } ? "" : shared
    }

    /// The title a row shows: worktree branches without the shared prefix.
    nonisolated static func displayTitle(_ item: TrayItem, sharedPrefix: String) -> String {
        guard item.source == .worktrees, !sharedPrefix.isEmpty, item.title.hasPrefix(sharedPrefix) else { return item.title }
        return String(item.title.dropFirst(sharedPrefix.count))
    }

    // MARK: - Helpers

    nonisolated static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    nonisolated static func nestedAwareTotal(_ items: [TrayItem]) -> Int64 {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var counted: [String] = []
        var total: Int64 = 0
        for item in sorted {
            if !item.isPseudoPath, counted.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") }) { continue }
            if !item.isPseudoPath { counted.append(item.path) }
            total += item.bytes
        }
        return total
    }

    private static var fileURL: URL {
        AutoSweepStore.supportDirectory.appendingPathComponent("cleanup-tray.json")
    }

    private static func load() -> [TrayItem]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([TrayItem].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Building tray items from each section

extension TrayItem {
    static func junk(_ item: JunkItem) -> TrayItem {
        TrayItem(source: .junk, key: item.id, path: item.path, title: item.name,
                 subtitle: item.category.rawValue, bytes: item.sizeBytes, isPermanent: item.isPermanent,
                 checkFirst: item.risk.tier == .checkFirst)
    }

    static func worktree(_ item: WorktreeItem) -> TrayItem {
        TrayItem(source: .worktrees, key: item.id, path: item.worktreePath, title: item.branchName,
                 subtitle: item.repoName, bytes: item.sizeBytes, isPermanent: true)
    }

    static func largeFile(_ item: LargeFileItem) -> TrayItem {
        TrayItem(source: .largeFiles, key: item.id, path: item.path, title: item.name,
                 subtitle: Self.parentFolder(item.path), bytes: item.sizeBytes, isPermanent: false)
    }

    static func duplicate(_ file: DuplicateFile, in group: DuplicateGroup) -> TrayItem {
        TrayItem(source: .duplicates, key: file.id, path: file.path, title: file.name,
                 subtitle: Self.parentFolder(file.path), bytes: file.privateBytes, isPermanent: false,
                 siblings: group.files.filter { $0.id != file.id }.map(\.path))
    }

    static func smart(_ item: SmartReviewItem) -> TrayItem {
        TrayItem(source: .smartReview, key: item.id, path: item.path, title: item.name,
                 subtitle: Self.parentFolder(item.path), bytes: item.sizeBytes, isPermanent: false)
    }

    static func app(_ app: InstalledAppItem, dataPaths: [String]) -> TrayItem {
        let data = app.associatedData.filter { dataPaths.contains($0.path) }
        let bytes = app.appSizeBytes + data.reduce(0) { $0 + $1.sizeBytes }
        let subtitle = data.isEmpty ? "App" : "App + \(data.count) data item\(data.count == 1 ? "" : "s")"
        return TrayItem(source: .apps, key: "app:" + app.id, path: app.bundlePath, title: app.name,
                        subtitle: subtitle, bytes: bytes, isPermanent: false, extraPaths: data.map(\.path))
    }

    static func leftover(_ item: AppDataItem, appName: String) -> TrayItem {
        TrayItem(source: .apps, key: "data:" + item.id, path: item.path, title: item.name,
                 subtitle: "Leftover from \(appName)", bytes: item.sizeBytes, isPermanent: false)
    }

    private static func parentFolder(_ path: String) -> String {
        (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Overview hero

extension TrayItem {
    /// Everything the Overview hero total counts, for "Review items first". Ticked the way each section
    /// pre-selects: Safe junk and mergeable worktrees. Review-rated or permanent junk, app leftovers and
    /// duplicate copies are listed unticked. Leftovers are a guess (a Library entry no installed app
    /// claims), and the Leftovers screen never pre-selects them either.
    /// Like `AppState.totalReclaimableBytes`, an item inside a ticked item is left out: it goes with it.
    /// The Trash's size is part of the hero total too, but it isn't an item the tray can hold.
    static func reclaimable(
        junk: [JunkItem],
        worktrees: [WorktreeItem],
        leftovers: [OrphanedAppDataGroup],
        duplicates: [DuplicateGroup]
    ) -> [TrayItem] {
        var candidates: [TrayItem] = []
        candidates += worktrees.filter(\.canAutoSelect).map { TrayItem.worktree($0) }
        candidates += junk.map { item in
            var tray = TrayItem.junk(item)
            tray.included = item.risk == .safe && !item.isPermanent
            return tray
        }
        candidates += leftovers.flatMap { group in
            group.items.map { item in
                var tray = TrayItem.leftover(item, appName: group.displayName)
                tray.included = false
                return tray
            }
        }

        // Shortest paths first, so a parent is seen before anything inside it. The same folder can be
        // both junk and an app leftover (a tool's cache): it's listed once, ticked only if junk ticks it.
        candidates.sort { ($0.path.count, $0.included ? 0 : 1) < ($1.path.count, $1.included ? 0 : 1) }
        var ticked: [String] = []
        var listed = Set<String>()
        func insideTicked(_ path: String) -> Bool {
            ticked.contains { path.hasPrefix($0 + "/") }
        }
        var result: [TrayItem] = []
        for item in candidates {
            if !item.isPseudoPath {
                if insideTicked(item.path) || !listed.insert(item.path).inserted { continue }
                if item.included { ticked.append(item.path) }
            }
            result.append(item)
        }

        // Duplicates: every copy but the one that costs least to keep, matching `reclaimableBytes`.
        for group in duplicates {
            guard let minimum = group.files.map(\.privateBytes).min(),
                  let keeper = DuplicateKeepRule.oldest.keeper(in: group.files.filter { $0.privateBytes == minimum })
            else { continue }
            for file in group.files where file.id != keeper.id && !insideTicked(file.path) && !listed.contains(file.path) {
                var tray = TrayItem.duplicate(file, in: group)
                tray.included = false
                result.append(tray)
            }
        }
        return result
    }
}

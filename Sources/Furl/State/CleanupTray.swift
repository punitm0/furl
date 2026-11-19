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
        didSet { save() }
    }
    @Published var isPresented = false
    @Published private(set) var isCleaning = false
    @Published private(set) var phase = ""
    /// Shown in the tray after adding: "3 added · 1 skipped (system folder)".
    @Published var notice: String?

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

    // MARK: - Clean

    /// Hands each section its own items and runs that section's cleanup, so the Trash, permanent-item
    /// and keep-one-copy rules stay exactly as they are. The Trash parts become one Undo.
    func clean(state: AppState) async {
        guard !isCleaning, !state.isCleaning else { return }
        pruneMissing(state: state)
        let batch = includedItems
        guard !batch.isEmpty else { return }
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
        var unmatched = 0
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
                unmatched += keys.count - matched.count
                guard !matched.isEmpty else { continue }
                let saved = state.selectedJunkIDs
                state.selectedJunkIDs = matched
                await state.cleanSelectedJunk()
                state.selectedJunkIDs = saved.intersection(state.junkItems.map(\.id))
            case .largeFiles:
                let matched = keys.intersection(state.largeFiles.map(\.id))
                unmatched += keys.count - matched.count
                guard !matched.isEmpty else { continue }
                let saved = state.selectedLargeFileIDs
                state.selectedLargeFileIDs = matched
                await state.cleanSelectedLargeFiles()
                state.selectedLargeFileIDs = saved.intersection(state.largeFiles.map(\.id))
            case .duplicates:
                let all = Set(state.duplicateGroups.flatMap { $0.files.map(\.id) })
                let matched = keys.intersection(all)
                unmatched += keys.count - matched.count
                guard !matched.isEmpty else { continue }
                let saved = state.selectedDuplicateIDs
                state.selectedDuplicateIDs = matched
                await state.cleanSelectedDuplicates()
                state.selectedDuplicateIDs = saved.intersection(state.duplicateGroups.flatMap { $0.files.map(\.id) })
            case .smartReview:
                let matched = keys.intersection(state.smartItems.map(\.id))
                unmatched += keys.count - matched.count
                guard !matched.isEmpty else { continue }
                let saved = state.selectedSmartIDs
                state.selectedSmartIDs = matched
                await state.cleanSelectedSmartItems()
                state.selectedSmartIDs = saved.intersection(state.smartItems.map(\.id))
            case .worktrees:
                let matched = keys.intersection(state.worktrees.map(\.id))
                unmatched += keys.count - matched.count
                guard !matched.isEmpty else { continue }
                let saved = state.selectedWorktreeIDs
                state.selectedWorktreeIDs = matched
                await state.cleanSelectedWorktrees(force: false, deleteLocalBranch: false)
                state.selectedWorktreeIDs = saved.intersection(state.worktrees.map(\.id))
            case .apps:
                for item in group where item.isAppBundle {
                    guard let app = state.installedApps.first(where: { "app:" + $0.id == item.key }) else {
                        unmatched += 1
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
                    unmatched += dataKeys.count - leftovers.count
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

        let beforeCount = items.count
        pruneMissing(state: state)
        let cleanedCount = max(0, beforeCount - items.count)

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
        } else if skipped > 0, errors.isEmpty, unmatched == 0 {
            state.showNothingCleaned(rescan: Array(Set(batch.map(\.source.section))))
        }
        if unmatched > 0 {
            errors.append("\(unmatched) tray item(s) are no longer listed by their section, so they were left in place. Rescan that section to check them.")
        }
        if !errors.isEmpty {
            state.errorBanner = errors.joined(separator: "\n")
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

    // MARK: - Helpers

    nonisolated static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    nonisolated static func nestedAwareTotal(_ items: [TrayItem]) -> Int64 {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var counted: [String] = []
        var total: Int64 = 0
        for item in sorted {
            if !item.isPseudoPath, counted.contains(where: { item.path.hasPrefix($0 + "/") }) { continue }
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
                 subtitle: item.category.rawValue, bytes: item.sizeBytes, isPermanent: item.isPermanent)
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

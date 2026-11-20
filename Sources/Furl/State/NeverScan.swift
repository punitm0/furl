import Foundation

/// "Don't scan here…" on a row (SettingsMoved board): one confirm, then the folder joins
/// Settings › Scanning › Never scan and its rows leave the lists. Nothing is deleted.
struct NeverScanRequest: Identifiable, Equatable {
    let folder: String
    let section: SidebarSection
    /// Rows across Furl's lists that leave them.
    let itemCount: Int

    var id: String { folder }
    var displayPath: String { NeverScanRequest.abbreviate(folder) }

    var title: String { "Stop scanning \(displayPath)?" }
    var message: String {
        let items = itemCount == 1 ? "its 1 item leaves" : "its \(itemCount) items leave"
        return "Furl won’t look inside this folder again, and \(items) Furl’s lists. Nothing is deleted."
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The Undo button on a toast that isn't a cleanup.
struct BannerUndo {
    let help: String
    let perform: @MainActor () -> Void
}

extension AppState {
    /// The lowest "unused after" choice; junk scans use it so the toolbar can re-filter without a rescan.
    static let staleDaysScanFloor = 7
    static let staleDaysChoices = [7, 14, 30, 60, 90, 180]

    /// The toolbar choices, plus a saved value from the old Settings stepper that isn't one of them.
    var staleDaysOptions: [Int] {
        Array(Set(Self.staleDaysChoices + [staleDaysThreshold])).sorted()
    }

    /// Moves junk between the list and `heldBackJunk` when the days change; below what was scanned, rescans.
    func applyStaleDaysChange() {
        guard let scanned = junkScannedStaleDays else {
            if isScanningJunk { pendingRescans.insert(.junk) }
            return
        }
        guard staleDaysThreshold >= scanned else {
            Task { await scanJunk() }
            return
        }
        let days = staleDaysThreshold
        let pool = (junkItems + heldBackJunk).map { $0.relabeled(staleDays: days) }
        junkItems = pool.filter { $0.isListed(staleDays: days) }.sorted { $0.sizeBytes > $1.sizeBytes }
        heldBackJunk = pool.filter { !$0.isListed(staleDays: days) }
        selectedJunkIDs.formIntersection(junkItems.map(\.id))
    }

    // MARK: Which folder "here" is

    /// The folder "Don't scan here…" skips for a junk row, or nil when there's none narrow enough to offer.
    /// A file (a .DS_Store, an archive) or a build folder inside a project skips the folder around it,
    /// so the whole project goes; any other folder (a cache, a log folder) skips itself.
    /// Touches the disk, so call it from the menu action, not while drawing the row.
    func neverScanFolder(forJunk item: JunkItem) -> String? {
        guard item.command == nil else { return nil }
        let inProject = projectRoots.contains { item.path.hasPrefix($0 + "/") }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
        if (inProject && (item.category == .devArtifacts || item.category == .dsStore)) || !exists || !isDirectory.boolValue {
            return neverScanFolder(forFile: item.path)
        }
        return canNeverScan(item.path) ? item.path : nil
    }

    /// The folder holding a file, if it's narrow enough to stop scanning.
    func neverScanFolder(forFile path: String) -> String? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        return canNeverScan(parent) ? parent : nil
    }

    /// Like `canNeverScan(_:)`, and never a folder the user added under "Also scan".
    func canNeverScan(_ folder: String) -> Bool {
        Self.canNeverScan(folder) && !extraScanRoots.contains(folder)
    }

    /// Never offer the home folder or anything above it, a volume, ~/Library, or a folder directly
    /// inside home or ~/Library (~/Downloads, ~/Documents, ~/Library/Caches…): one click would
    /// quietly empty whole lists.
    nonisolated static func canNeverScan(_ folder: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if folder == "/" || folder == home || home.hasPrefix(folder + "/") { return false }
        let library = home + "/Library"
        let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path
        if folder == library || parent == home || parent == library { return false }
        let parts = folder.split(separator: "/")
        if parts.first == "Volumes" && parts.count <= 2 { return false }
        return true
    }

    // MARK: Asking and doing

    /// Opens the confirm for skipping `folder`, counting the rows across Furl's lists that would leave.
    func requestNeverScan(folder: String, from section: SidebarSection) {
        guard !isExcluded(folder) else { return }
        pendingNeverScan = NeverScanRequest(folder: folder, section: section,
                                            itemCount: listedPaths.filter { Self.isInside($0, folder) }.count)
    }

    /// "Don't scan here…" on a junk row: works out the folder when chosen, not while drawing.
    func requestNeverScan(forJunk item: JunkItem) {
        guard let folder = neverScanFolder(forJunk: item) else {
            statusBanner = "Furl can’t skip this one. The folder around it holds too much else."
            return
        }
        requestNeverScan(folder: folder, from: .junk)
    }

    /// Adds `folder` to Never scan, takes its rows off every list, and shows the toast with Undo.
    /// No rescan: the lists are updated here, so unticked rows stay unticked.
    func neverScan(_ folder: String, from section: SidebarSection) {
        let folder = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard !isExcluded(folder) else { return }
        let inside: (String) -> Bool = { Self.isInside($0, folder) }

        let removedJunk = junkItems.filter { inside($0.path) }
        let removedHeld = heldBackJunk.filter { inside($0.path) }
        let removedLarge = allLargeFiles.filter { inside($0.path) }
        let removedWorktrees = worktrees.filter { inside($0.worktreePath) }
        var removedDuplicates: [DuplicateGroup] = []
        duplicateGroups = duplicateGroups.compactMap { group in
            let gone = group.files.filter { inside($0.path) }
            guard !gone.isEmpty else { return group }
            removedDuplicates.append(DuplicateGroup(id: group.id, sizeBytes: group.sizeBytes, files: gone))
            var kept = group
            kept.files.removeAll { inside($0.path) }
            if kept.files.count > 1 { return kept }
            // The last copy left alone isn't a duplicate any more; it comes back with Undo.
            removedDuplicates[removedDuplicates.count - 1].files += kept.files
            return nil
        }
        let removedDuplicateIDs = Set(removedDuplicates.flatMap { $0.files.map(\.id) })
        let ticked = (
            junk: selectedJunkIDs.intersection(removedJunk.map(\.id)),
            large: selectedLargeFileIDs.intersection(removedLarge.map(\.id)),
            duplicates: selectedDuplicateIDs.intersection(removedDuplicateIDs),
            worktrees: selectedWorktreeIDs.intersection(removedWorktrees.map(\.id))
        )

        junkItems.removeAll { inside($0.path) }
        heldBackJunk.removeAll { inside($0.path) }
        selectedJunkIDs.subtract(ticked.junk)
        allLargeFiles.removeAll { inside($0.path) }
        largeFiles.removeAll { inside($0.path) }
        selectedLargeFileIDs.subtract(ticked.large)
        selectedDuplicateIDs.subtract(removedDuplicateIDs)
        worktrees.removeAll { inside($0.worktreePath) }
        selectedWorktreeIDs.subtract(ticked.worktrees)

        excludedScanRootSources[folder] = section.rawValue
        skipNextRootRescan = true
        addExcludedScanRoot(path: folder)

        statusBanner = "Furl won’t scan \(NeverScanRequest.abbreviate(folder))."
        bannerUndo = BannerUndo(help: "Scan this folder again") { [weak self] in
            guard let self else { return }
            self.skipNextRootRescan = true
            self.removeExcludedScanRoot(folder)
            self.junkItems = Self.merging(self.junkItems, removedJunk).sorted { $0.sizeBytes > $1.sizeBytes }
            self.heldBackJunk = Self.merging(self.heldBackJunk, removedHeld)
            self.allLargeFiles = Self.merging(self.allLargeFiles, removedLarge)
            self.largeFiles = self.allLargeFiles.filter { $0.sizeBytes > self.largeFileThresholdMB * 1_000_000 }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            self.worktrees = Self.merging(self.worktrees, removedWorktrees)
            self.duplicateGroups = Self.restoring(removedDuplicates, into: self.duplicateGroups)
            // Ticks come back only for rows that are listed again.
            self.selectedJunkIDs.formUnion(ticked.junk.intersection(self.junkItems.map(\.id)))
            self.selectedLargeFileIDs.formUnion(ticked.large.intersection(self.largeFiles.map(\.id)))
            self.selectedWorktreeIDs.formUnion(ticked.worktrees.intersection(self.worktrees.map(\.id)))
            self.selectedDuplicateIDs.formUnion(
                ticked.duplicates.intersection(self.duplicateGroups.flatMap { $0.files.map(\.id) }))
            self.statusBanner = nil
        }
    }

    /// Paths of every row on the lists "Don't scan here…" can empty.
    private var listedPaths: [String] {
        junkItems.map(\.path) + largeFiles.map(\.path) + worktrees.map(\.worktreePath)
            + duplicateGroups.flatMap { $0.files.map(\.path) }
    }

    /// `current` plus whichever of `removed` it doesn't already hold (a rescan may have listed them again).
    static func merging<T: Identifiable>(_ current: [T], _ removed: [T]) -> [T] {
        let shown = Set(current.map(\.id))
        return current + removed.filter { !shown.contains($0.id) }
    }

    /// Puts removed copies back into the current groups by group id; a group that's gone comes back whole.
    static func restoring(_ removed: [DuplicateGroup], into current: [DuplicateGroup]) -> [DuplicateGroup] {
        var groups = current
        for group in removed {
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                groups[index].files = merging(groups[index].files, group.files)
            } else if group.files.count > 1 {
                groups.append(group)
            }
        }
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    nonisolated static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// Whether `path` sits in one of the Never scan folders `roots`. Also used off the main actor
    /// (Auto-Sweep, Downloads tidy), so it takes the roots instead of reading them.
    nonisolated static func isExcluded(_ path: String, by roots: [String]) -> Bool {
        roots.contains { isInside(path, $0) }
    }
}

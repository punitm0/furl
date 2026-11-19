import Combine
import Foundation

/// The Inspector side panel (one per window) and the Find screen's shared state.
/// Any row can open the Inspector with `InspectorStore.shared.show(_:)` or `show(path:)`.
@MainActor
final class InspectorStore: ObservableObject {
    static let shared = InspectorStore()

    /// Item shown in the Inspector; nil hides the panel.
    @Published var current: InspectorItem?
    /// Paths the user chose to ignore. They're dropped from every scan's results and from Find.
    @Published private(set) var ignoredPaths: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignoredPaths).sorted(), forKey: Self.ignoredKey) }
    }
    /// Bumped by ⌘F so the Find field takes focus even when Find is already showing.
    @Published private(set) var focusRequest = 0
    @Published private(set) var isRemoving = false

    private static let ignoredKey = "inspectorIgnoredPaths"
    private var cancellables: Set<AnyCancellable> = []
    private weak var state: AppState?

    private init() {
        ignoredPaths = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    // MARK: Find

    func requestFind(state: AppState) {
        state.selectedSection = .find
        focusRequest += 1
    }

    /// Every current scan result as an Inspector item, biggest first. Ignored paths are left out.
    func catalog(_ state: AppState) -> [InspectorItem] {
        var items: [InspectorItem] = []
        items += state.junkItems.map(InspectorItem.init(junk:))
        items += state.worktrees.map(InspectorItem.init(worktree:))
        items += state.largeFiles.map { InspectorItem(largeFile: $0, thresholdMB: state.largeFileThresholdMB) }
        for group in state.duplicateGroups {
            items += group.files.map { InspectorItem(duplicate: $0, group: group) }
        }
        for group in state.orphanedGroups {
            items += group.items.map { InspectorItem(leftover: $0, group: group) }
        }
        items += state.installedApps.map(InspectorItem.init(app:))
        items += state.smartItems.map(InspectorItem.init(smart:))
        let ignored = ignoredPaths
        return items
            .filter { !ignored.contains($0.path) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Showing

    func show(_ item: InspectorItem) {
        current = item
    }

    func close() {
        current = nil
    }

    /// Opens the Inspector for whatever scan result lives at `path`, or for the plain file if no scan found it.
    func show(path: String, state: AppState) {
        if let match = catalog(state).first(where: { $0.path == path }) {
            current = match
        } else {
            current = Self.plainItem(path: path)
        }
    }

    /// The item as it is in the latest results (sizes and status change after rescans).
    func refreshed(_ item: InspectorItem, state: AppState) -> InspectorItem? {
        if item.id.hasPrefix("plain:") { return item }
        return catalog(state).first { $0.id == item.id }
    }

    private static func plainItem(path: String) -> InspectorItem {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let url = URL(fileURLWithPath: path)
        return InspectorItem(
            id: "plain:\(path)", source: .largeFile, sourceID: path,
            name: url.lastPathComponent, path: path, sizeBytes: 0,
            modifiedDate: FileSizeHelper.modifiedDate(at: url), lastUsedDate: nil,
            kind: isDir.boolValue ? "Folder" : "File",
            whyFlagged: "Not flagged. No scan lists this item right now.",
            safety: .review,
            safetyNote: "Furl has no opinion about it. Remove it from Finder if you're sure.",
            rebuild: "Unknown.",
            isPermanent: false, isOnDisk: true, canRemove: false, searchExtras: ""
        )
    }

    // MARK: Actions

    /// Removes the item through the section that found it, so the usual Trash, undo and result
    /// pruning apply. The section's own selection is put back afterwards.
    func remove(_ item: InspectorItem, state: AppState) async {
        guard item.canRemove, !isRemoving, !state.isCleaning else { return }
        isRemoving = true
        defer { isRemoving = false }

        switch item.source {
        case .junk:
            let prior = state.selectedJunkIDs
            state.selectedJunkIDs = [item.sourceID]
            await state.cleanSelectedJunk()
            state.selectedJunkIDs = prior.subtracting([item.sourceID]).intersection(state.junkItems.map(\.id))
        case .worktree:
            let prior = state.selectedWorktreeIDs
            state.selectedWorktreeIDs = [item.sourceID]
            await state.cleanSelectedWorktrees(force: false, deleteLocalBranch: false)
            state.selectedWorktreeIDs = prior.subtracting([item.sourceID]).intersection(state.worktrees.map(\.id))
        case .largeFile:
            let prior = state.selectedLargeFileIDs
            state.selectedLargeFileIDs = [item.sourceID]
            await state.cleanSelectedLargeFiles()
            state.selectedLargeFileIDs = prior.subtracting([item.sourceID]).intersection(state.largeFiles.map(\.id))
        case .duplicate:
            let prior = state.selectedDuplicateIDs
            state.selectedDuplicateIDs = [item.sourceID]
            await state.cleanSelectedDuplicates()
            let remaining = Set(state.duplicateGroups.flatMap { $0.files.map(\.id) })
            state.selectedDuplicateIDs = prior.subtracting([item.sourceID]).intersection(remaining)
        case .leftover:
            guard let data = state.orphanedGroups.flatMap(\.items).first(where: { $0.id == item.sourceID }) else { break }
            await state.clearOrphanedItems([data], label: "leftover item")
        case .app:
            guard let app = state.installedApps.first(where: { $0.id == item.sourceID }) else { break }
            let dataPaths = app.associatedData.filter(\.isStrongMatch).map(\.path)
            await state.uninstallApp(app, includeDataPaths: dataPaths)
        case .smartReview:
            let prior = state.selectedSmartIDs
            state.selectedSmartIDs = [item.sourceID]
            await state.cleanSelectedSmartItems()
            state.selectedSmartIDs = prior.subtracting([item.sourceID]).intersection(state.smartItems.map(\.id))
        }

        if current?.id == item.id {
            current = refreshed(item, state: state)
        }
    }

    /// Hides the item from Find and from its section, now and after future scans.
    func ignore(_ item: InspectorItem, state: AppState) {
        guard item.isOnDisk || item.source == .junk else { return }
        ignoredPaths.insert(item.path)
        applyIgnored(to: state)
        if current?.id == item.id { current = nil }
        state.statusBanner = "Ignoring \(item.name). Restore it from Find."
    }

    func restoreIgnored() {
        ignoredPaths = []
        state?.statusBanner = "Ignored items will show up again after the next scan."
    }

    // MARK: Keeping ignored items out of results

    /// Filters ignored paths out of scan results whenever they change. Call once at launch.
    func connect(to state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        let triggers: [AnyPublisher<Void, Never>] = [
            state.$junkItems.map { _ in () }.eraseToAnyPublisher(),
            state.$worktrees.map { _ in () }.eraseToAnyPublisher(),
            state.$largeFiles.map { _ in () }.eraseToAnyPublisher(),
            state.$duplicateGroups.map { _ in () }.eraseToAnyPublisher(),
            state.$orphanedGroups.map { _ in () }.eraseToAnyPublisher(),
            state.$installedApps.map { _ in () }.eraseToAnyPublisher(),
            state.$smartItems.map { _ in () }.eraseToAnyPublisher()
        ]
        // @Published fires before the new value is stored, so apply on the next main-queue turn.
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state] in
                guard let self, let state else { return }
                MainActor.assumeIsolated { self.applyIgnored(to: state) }
            }
            .store(in: &cancellables)
    }

    /// Drops ignored paths from the in-memory results. Only assigns when something changes,
    /// so the publishers above don't loop.
    private func applyIgnored(to state: AppState) {
        let ignored = ignoredPaths
        guard !ignored.isEmpty else { return }

        if state.junkItems.contains(where: { ignored.contains($0.path) }) {
            state.junkItems.removeAll { ignored.contains($0.path) }
            state.selectedJunkIDs.formIntersection(state.junkItems.map(\.id))
        }
        if state.worktrees.contains(where: { ignored.contains($0.worktreePath) }) {
            state.worktrees.removeAll { ignored.contains($0.worktreePath) }
            state.selectedWorktreeIDs.formIntersection(state.worktrees.map(\.id))
        }
        if state.largeFiles.contains(where: { ignored.contains($0.path) }) {
            state.largeFiles.removeAll { ignored.contains($0.path) }
            state.selectedLargeFileIDs.formIntersection(state.largeFiles.map(\.id))
        }
        if state.duplicateGroups.contains(where: { $0.files.contains { ignored.contains($0.path) } }) {
            state.duplicateGroups = state.duplicateGroups.compactMap { group in
                var updated = group
                updated.files = group.files.filter { !ignored.contains($0.path) }
                return updated.files.count > 1 ? updated : nil
            }
            state.selectedDuplicateIDs.formIntersection(state.duplicateGroups.flatMap { $0.files.map(\.id) })
        }
        if state.orphanedGroups.contains(where: { $0.items.contains { ignored.contains($0.path) } }) {
            state.orphanedGroups = state.orphanedGroups.compactMap { group in
                let remaining = group.items.filter { !ignored.contains($0.path) }
                guard !remaining.isEmpty else { return nil }
                return OrphanedAppDataGroup(id: group.id, appIdentifier: group.appIdentifier, displayName: group.displayName, items: remaining)
            }
        }
        if state.installedApps.contains(where: { ignored.contains($0.bundlePath) }) {
            state.installedApps.removeAll { ignored.contains($0.bundlePath) }
        }
        if state.smartItems.contains(where: { ignored.contains($0.path) }) {
            state.smartItems.removeAll { ignored.contains($0.path) }
            state.selectedSmartIDs.formIntersection(state.smartItems.map(\.id))
        }
    }
}

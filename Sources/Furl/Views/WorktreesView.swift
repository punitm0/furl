import AppKit
import SwiftUI

@MainActor
private final class WorktreesViewModel: ObservableObject {
    @Published var showOnlyCleanable = false
    @Published var searchText = ""
    /// The row whose "Remove anyway…" is checking its changes (spinner on that button).
    @Published var checkingID: String?
}

/// WorktreesSimple board: four toolbar controls, dirty rows that can't be ticked, and the risky
/// choices (branch deletion, losing changes) moved into the confirms where they happen.
struct WorktreesView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = WorktreesViewModel()
    @Environment(\.openSettings) private var openSettings

    private var displayedWorktrees: [WorktreeItem] {
        state.worktrees.filter { item in
            let matchesFilter = !vm.showOnlyCleanable || item.mergeStatus.isSafeToClean
            let matchesSearch = vm.searchText.isEmpty
                || item.repoName.localizedCaseInsensitiveContains(vm.searchText)
                || item.branchName.localizedCaseInsensitiveContains(vm.searchText)
                || item.worktreePath.localizedCaseInsensitiveContains(vm.searchText)
            return matchesFilter && matchesSearch
        }
    }

    private var groupedByRepo: [(repo: String, items: [WorktreeItem])] {
        let groups = Dictionary(grouping: displayedWorktrees, by: \.repoPath)
        return groups
            .map { (repo: $0.key, items: $0.value.sorted { lhs, rhs in
                // Main worktree first, then cleanable, then by size.
                if (lhs.mergeStatus == .main) != (rhs.mergeStatus == .main) { return lhs.mergeStatus == .main }
                if lhs.canAutoSelect != rhs.canAutoSelect { return lhs.canAutoSelect }
                return lhs.sizeBytes > rhs.sizeBytes
            }) }
            .sorted { lhs, rhs in
                lhs.items.reduce(0) { $0 + $1.sizeBytes } > rhs.items.reduce(0) { $0 + $1.sizeBytes }
            }
    }

    /// Ticked items that a bulk remove takes. A worktree with changes never counts, even if ticked.
    private var effectiveSelection: [WorktreeItem] {
        state.worktrees.filter { state.selectedWorktreeIDs.contains($0.id) && $0.isBulkSelectable }
    }

    /// Selected worktrees the search or "cleanable only" filter hides; Remove still removes them.
    private var hiddenSelectedCount: Int {
        let shown = Set(displayedWorktrees.map(\.id))
        return effectiveSelection.filter { !shown.contains($0.id) }.count
    }

    private var selectedSizeBytes: Int64 {
        effectiveSelection.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Git Worktrees", subtitle: "Worktrees whose branches are already merged.") {
                HeaderSearchField(text: $vm.searchText, prompt: "Filter by repo, branch or path")
            }
            toolbarBar

            LiveScanStripSlot(status: state.liveScans[.worktrees], onStop: { state.stopScan(.worktrees) },
                              onRescan: { Task { await state.scanWorktrees() } })

            if state.isScanningWorktrees && state.worktrees.isEmpty {
                ScanningPlaceholder(message: "Scanning Git repositories & worktrees…",
                                    status: state.liveScans[.worktrees])
            } else if !state.hasScannedWorktrees && !state.isScanningWorktrees {
                EmptyStatePlaceholder(
                    systemImage: "arrow.triangle.branch",
                    title: "Find Merged Worktrees",
                    message: "Scan your project folders for Git worktrees whose branches are already merged.",
                    buttonTitle: "Scan"
                ) {
                    Task { await state.scanWorktrees() }
                }
            } else if state.worktrees.isEmpty {
                // WorktreesSimple board: "Nothing to show" points to Settings › Scanning.
                EmptyStatePlaceholder(
                    systemImage: "checkmark.circle",
                    title: "No extra worktrees",
                    message: Self.emptyMessage(folderCount: state.projectRoots.count),
                    buttonTitle: "Open Scanning Settings",
                    buttonKind: .secondary
                ) {
                    SettingsTab.select(.folders)
                    AppWindows.activateForWindow()
                    openSettings()
                }
            } else if displayedWorktrees.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "No matches",
                    message: "Try clearing the search or the Merged only filter."
                )
            } else {
                // WhySafe board: the legend line sits at the top of the list. Removing a worktree skips
                // the Trash, so this list explains Permanent instead of "comes back by itself".
                RiskLegend(tiers: [.checkFirst, .permanent])
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, 14)
                List {
                    ForEach(groupedByRepo, id: \.repo) { group in
                        Section {
                            ForEach(group.items) { item in
                                worktreeRow(item)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkSecondary)
                                Text(URL(fileURLWithPath: group.repo).lastPathComponent)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.ink)
                                Text(group.repo.abbreviatingWithTildeInPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Self.worktreeCount(group.items.count))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .cardList()

                if effectiveSelection.isEmpty && !mergedSelection.isEmpty {
                    nothingTickedBar
                } else {
                    SelectionActionBar(
                        selectedCount: effectiveSelection.count,
                        totalCount: displayedWorktrees.filter(\.isBulkSelectable).count,
                        selectedBytes: selectedSizeBytes,
                        actionTitle: "Remove",
                        isBusy: state.isCleaning,
                        note: hiddenSelectionNote(hiddenSelectedCount),
                        // The tray removes without force, so uncommitted worktrees stay here.
                        onAddToTray: { CleanupTray.shared.add(effectiveSelection.filter { !$0.isDirty }.map(TrayItem.worktree)) },
                        onSelectAll: {
                            state.selectedWorktreeIDs.formUnion(displayedWorktrees.filter(\.isBulkSelectable).map(\.id))
                        },
                        onSelectNone: { state.selectedWorktreeIDs.removeAll() },
                        onAction: confirmRemoveSelected
                    )
                }
            }
        }
        .navigationTitle("Git Worktrees")
        // A Disk row's Clean / Review / Pick files opens this section filtered to its folder.
        .onAppear { if let filter = state.takeHandoffFilter(for: .worktrees) { vm.searchText = filter } }
        .cleanSlateScreen()
    }

    // MARK: - Confirms

    private func confirmRemoveSelected() {
        let items = effectiveSelection
        guard !items.isEmpty, !state.isCleaning else { return }
        guard let choice = WorktreeConfirm.remove(items, hiddenNote: hiddenSelectionNote(hiddenSelectedCount)) else { return }
        Task { await state.cleanSelectedWorktrees(deleteMergedBranches: choice.deleteMergedBranches) }
    }

    /// "Remove anyway…": reads the changes now, lists them in a second confirm, and passes exactly
    /// that list on, so the removal stops if anything changed in between.
    private func removeAnyway(_ item: WorktreeItem) {
        guard vm.checkingID == nil, !state.isCleaning else { return }
        vm.checkingID = item.id
        Task {
            let snapshot = await AppState.worktreeChanges(item)
            vm.checkingID = nil
            guard let snapshot, !snapshot.changes.isEmpty || item.losesCommitsIfRemoved else {
                WorktreeConfirm.cannotList(item, readable: snapshot != nil)
                await state.scanWorktrees()
                return
            }
            guard WorktreeConfirm.removeAnyway(item, changes: snapshot.changes) else { return }
            await state.removeWorktreeAnyway(item, confirmed: snapshot)
        }
    }

    static func emptyMessage(folderCount: Int) -> String {
        let folders = folderCount == 1 ? "1 project folder" : "\(folderCount) project folders"
        return "Furl looked in \(folders). To add more, go to Settings › Scanning."
    }

    static func worktreeCount(_ count: Int) -> String {
        "\(count) worktree\(count == 1 ? "" : "s")"
    }

    // MARK: - Toolbar

    private var toolbarBar: some View {
        // One row when it fits; on a narrow page (cleanup tray open) the buttons drop under the filter.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                mergedOnlyToggle
                Spacer(minLength: 12)
                toolbarActions
            }
            VStack(alignment: .leading, spacing: 8) {
                mergedOnlyToggle
                HStack(spacing: 12) { toolbarActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var mergedOnlyToggle: some View {
        Toggle("Merged only", isOn: $vm.showOnlyCleanable)
            .toggleStyle(.furlCheckbox)
            .fixedSize()
    }

    /// What "Select merged (N)" ticks.
    private var mergedSelection: [WorktreeItem] { AppState.mergedWorktreeSelection(state.worktrees) }

    @ViewBuilder private var toolbarActions: some View {
        // WorktreesShortcuts board: nothing starts ticked, so this is the primary toolbar button.
        Button(Self.selectMergedTitle(count: mergedSelection.count)) {
            state.selectedWorktreeIDs = Set(mergedSelection.map(\.id))
        }
        .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
        .help("Tick merged worktrees with nothing uncommitted")
        .disabled(mergedSelection.isEmpty)

        Button("Clean up missing folders") {
            Task { await state.pruneAllWorktrees() }
        }
        .buttonStyle(ToolbarButtonStyle())
        .help("Tell git to forget worktrees whose folder is gone. Nothing on disk is deleted.")
        .disabled(state.worktrees.isEmpty || state.isScanningWorktrees)

        if state.isScanningWorktrees {
            // SmallItemsStates: 12 pt spinner, 6 pt gap, "Refreshing…" in caption inkSecondary.
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Refreshing…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
        }

        Button {
            Task { await state.scanWorktrees() }
        } label: {
            Label("Rescan", systemImage: "arrow.clockwise")
        }
        .buttonStyle(ToolbarButtonStyle())
        .disabled(state.isScanningWorktrees)
    }

    nonisolated static func selectMergedTitle(count: Int) -> String {
        count > 0 ? "Select merged (\(count))" : "Select merged"
    }

    /// The bottom bar while nothing is ticked (WorktreesShortcuts board).
    nonisolated static func nothingTickedText(count: Int, bytes: Int64) -> String {
        let trees = count == 1 ? "the 1 merged, clean worktree" : "the \(count) merged, clean worktrees"
        let them = count == 1 ? "it" : "them"
        return "ticks \(trees) (\(FileSizeHelper.formatBytes(bytes))). Removing \(them) is permanent."
    }

    private var nothingTickedBar: some View {
        let merged = mergedSelection
        let bytes = merged.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
            (Text("Nothing is ticked. ").foregroundStyle(Theme.inkSecondary)
                + Text("Select merged").fontWeight(.semibold).foregroundStyle(Theme.ink)
                + Text(" " + Self.nothingTickedText(count: merged.count, bytes: bytes)).foregroundStyle(Theme.inkSecondary))
                .font(Theme.body)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove…") {}
                .buttonStyle(SweepButtonStyle(kind: .primary))
                .disabled(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    private func worktreeRow(_ item: WorktreeItem) -> some View {
        let isMain = item.mergeStatus == .main

        return HStack(spacing: 12) {
            if isMain {
                Color.clear.frame(width: 14, height: 14)
            } else {
                SelectionCheckbox(id: item.id, selection: $state.selectedWorktreeIDs, disabled: !item.isBulkSelectable)
                    .help(Self.untickableReason(item) ?? "")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: isMain ? "house" : "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                    Text(Self.displayName(item))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.head)
                    ForEach(Self.badges(item), id: \.text) { badge in
                        WorktreeBadge(badge: badge)
                    }
                }

                Text(Self.subtitle(item))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.lastCommitDate.map { "\(item.commitHash) · \($0.formatted(date: .long, time: .shortened))" } ?? item.commitHash)
            }

            Spacer(minLength: 8)

            if item.canRemoveAnyway {
                Button {
                    removeAnyway(item)
                } label: {
                    HStack(spacing: 6) {
                        if vm.checkingID == item.id { ProgressView().controlSize(.mini) }
                        Text("Remove anyway…")
                    }
                }
                .buttonStyle(ToolbarButtonStyle())
                .disabled(vm.checkingID != nil || state.isCleaning)
                .help("Lists the changed files first. Removing deletes them for good.")
            }

            HStack(spacing: 6) {
                ForEach(WhySafe.worktreeChips(item), id: \.self) { tier in
                    RiskChip(tier: tier, help: tier == .permanent
                             ? "git worktree remove deletes the folder for good. It can't go to the Trash." : nil)
                }
                WhyButton(explanation: WhySafe.worktree(item),
                          action: item.isPrunable ? nil : WhyAction(title: "Open in Finder") {
                              DeletionService.revealInFinder(item.worktreePath)
                          })
            }

            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .opacity(isMain ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .pathContextMenu(item.worktreePath, allowOpen: false)
    }

    /// The branch, or for a worktree with no branch its folder name (git would only say "HEAD").
    /// Control and bidirectional characters are escaped: names come from repos Furl doesn't trust.
    static func displayName(_ item: WorktreeItem) -> String {
        WorktreeChange.displaySafe(item.mergeStatus == .detached
            ? URL(fileURLWithPath: item.worktreePath).lastPathComponent : item.branchName)
    }

    static func untickableReason(_ item: WorktreeItem) -> String? {
        guard !item.isBulkSelectable, item.mergeStatus != .main else { return nil }
        if item.isDirty { return "Has changes that aren’t committed, so it can’t be ticked. Use Remove anyway… on this row." }
        return "Its latest commits aren’t on any branch, so it can’t be ticked. Use Remove anyway… on this row."
    }

    /// "~/code/web-app-router · yesterday": the path, then when it was last committed to.
    static func subtitle(_ item: WorktreeItem) -> String {
        var parts = [item.worktreePath.abbreviatingWithTildeInPath]
        if item.mergeStatus == .main, !item.commitHash.isEmpty { parts.append(item.commitHash) }
        if let date = item.lastCommitDate { parts.append(date.relativeDescription) }
        return parts.joined(separator: " · ")
    }

    /// WorktreesSimple board's names table: Merged, Merged (squash), Not merged, No branch,
    /// "3 changed files", Locked, Folder missing, Main worktree.
    static func badges(_ item: WorktreeItem) -> [WorktreeBadge.Model] {
        var badges: [WorktreeBadge.Model] = []
        switch item.mergeStatus {
        case .main: badges.append(.init(text: "Main worktree", style: .neutral))
        case .merged: badges.append(.init(text: "Merged", style: .merged))
        case .squashMerged: badges.append(.init(text: "Merged (squash)", style: .merged,
                                                 help: "Merged as one combined commit."))
        case .unmerged: badges.append(.init(text: "Not merged", style: .unmerged))
        case .detached: badges.append(.init(text: "No branch", style: .warning,
                                             help: "The worktree isn’t on a branch. Never selected for you."))
        }
        if item.isPrunable {
            badges.append(.init(text: "Folder missing", style: .warning,
                                help: "The folder is gone. Clean up missing folders tells git to forget it."))
        } else if item.isDirty {
            if let count = item.changedFileCount, count > 0 {
                badges.append(.init(text: count == 1 ? "1 changed file" : "\(count) changed files", style: .changes,
                                    help: "Changes that aren’t committed. Only Remove anyway… on this row removes it."))
            } else {
                badges.append(.init(text: "Couldn’t check changes", style: .changes,
                                    help: "Git couldn’t list this worktree’s changes safely, so Furl won’t remove it. Look at it in Finder."))
            }
        }
        if item.isLocked { badges.append(.init(text: "Locked", style: .neutral)) }
        return badges
    }
}

/// Status pill on a worktree row: 10.5 pt semibold, padding 1 × 6, radius 5 (WorktreesSimple board).
struct WorktreeBadge: View {
    enum Style { case merged, unmerged, changes, warning, neutral }

    struct Model: Hashable {
        let text: String
        let style: Style
        var help: String? = nil
    }

    let badge: Model

    var body: some View {
        Text(badge.text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(badge.help ?? badge.text)
    }

    private var foreground: Color {
        switch badge.style {
        case .merged: return Theme.sweepDeep
        case .unmerged: return Theme.memory
        case .changes: return Theme.danger
        case .warning: return Theme.warning
        case .neutral: return Theme.inkSecondary
        }
    }

    private var background: Color {
        switch badge.style {
        case .merged: return Theme.mintTint
        case .unmerged: return Theme.surfaceSubtle
        case .changes: return Theme.dangerTint
        case .warning: return Theme.warningTint
        case .neutral: return Theme.accentGray.bg
        }
    }
}

// MARK: - Confirms

/// The two worktree confirms, as standard caution alerts (app icon with the yellow badge).
@MainActor
enum WorktreeConfirm {
    struct RemoveChoice {
        /// "Also delete the N merged branches": unticked unless the user ticks it.
        var deleteMergedBranches = false
    }

    /// "Remove 4 worktrees?" Returns nil on Cancel.
    /// `hiddenNote` says when the search hides some of the ticked rows (a Disk hand-off); they're still listed.
    static func remove(_ items: [WorktreeItem], hiddenNote: String? = nil) -> RemoveChoice? {
        let count = items.count
        let bytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let branches = items.filter(\.hasDeletableMergedBranch).count
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove \(WorktreesView.worktreeCount(count))?"
        let folders = count == 1 ? "this folder" : "these \(count) folders"
        let they = count == 1 ? "It doesn’t" : "They don’t"
        var info = "Deletes \(folders) for good, including files git ignores, like .env. \(they) go to the Trash. Commits stay in each repository."
        if let hiddenNote { info += "\n\n\(hiddenNote), but they’re listed below and included." }
        alert.informativeText = info
        alert.accessoryView = listView(items.map { (WorktreesView.displayName($0), FileSizeHelper.formatBytes($0.sizeBytes)) })
        if branches > 0 {
            alert.showsSuppressionButton = true
            let noun = branches == 1 ? "the merged branch" : "the \(branches) merged branches"
            alert.suppressionButton?.title = "Also delete \(noun). Branches that aren’t merged are always kept."
            alert.suppressionButton?.state = .off
        }
        let title = count == 1 ? "Remove 1 Worktree" : "Remove \(count) Worktrees"
        addButtons(to: alert, destructive: "\(title) (\(FileSizeHelper.formatBytes(bytes)))")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return RemoveChoice(deleteMergedBranches: branches > 0 && alert.suppressionButton?.state == .on)
    }

    /// "Lose 3 changed files?" The second confirm for one row with changes, or with commits that
    /// aren't on any branch.
    static func removeAnyway(_ item: WorktreeItem, changes: [WorktreeChange]) -> Bool {
        let name = WorktreesView.displayName(item)
        let count = changes.count
        let alert = NSAlert()
        alert.alertStyle = .critical
        var text: [String] = []
        let action: String
        if count > 0 {
            alert.messageText = count == 1 ? "Lose 1 changed file?" : "Lose \(count) changed files?"
            let has = count == 1 ? "1 file with changes that isn’t committed" : "\(count) files with changes that aren’t committed"
            let them = count == 1 ? "it" : "them"
            text.append("\(name) has \(has). Removing it deletes \(them) for good. They aren’t in the Trash or in git.")
            if item.losesCommitsIfRemoved { text.append("Its latest commits aren’t on any branch, so they’re lost too.") }
            action = count == 1 ? "Remove and Lose 1 File" : "Remove and Lose \(count) Files"
        } else {
            alert.messageText = "Lose commits that aren’t on a branch?"
            text.append("\(name) isn’t on a branch, and its latest commits aren’t on any branch either. Removing it can lose them for good.")
            action = "Remove and Lose Commits"
        }
        // The list shows what git tracks; ignored files go too and aren't listed.
        text.append("Files git ignores, like .env, are deleted too.")
        alert.informativeText = text.joined(separator: " ")
        alert.accessoryView = listView(changes.map { (WorktreeChange.displaySafe($0.path), $0.kind.rawValue) },
                                       finderPath: item.worktreePath)
        addButtons(to: alert, destructive: action)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Git couldn't list the changes (or they're gone): nothing to confirm, so nothing is removed.
    static func cannotList(_ item: WorktreeItem, readable: Bool) {
        let name = WorktreesView.displayName(item)
        let alert = NSAlert()
        alert.alertStyle = .informational
        if !readable {
            alert.messageText = "Furl can’t list the changes in \(name)"
            alert.informativeText = "Git couldn’t check this worktree safely, so Furl won’t remove it. Look at it in Finder, or remove it with git yourself."
        } else {
            alert.messageText = "\(name) has no changes now"
            alert.informativeText = "Furl will scan again. If it’s merged, you can tick it and remove it as usual."
        }
        alert.addButton(withTitle: "OK")
        if !readable, !item.isPrunable { alert.addButton(withTitle: "Show in Finder") }
        if alert.runModal() == .alertSecondButtonReturn {
            DeletionService.revealInFinder(item.worktreePath)
        }
    }

    /// The red action first, Cancel second; Cancel is the default (Return), as the board draws it.
    private static func addButtons(to alert: NSAlert, destructive: String) {
        let action = alert.addButton(withTitle: destructive)
        action.hasDestructiveAction = true
        action.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
    }

    /// At most this many rows; the rest become "and N more".
    static let maxListedRows = 8

    private static func listView(_ rows: [(String, String)], finderPath: String? = nil) -> NSView {
        let host = NSHostingView(rootView: ConfirmList(rows: rows, finderPath: finderPath))
        host.frame.size = NSSize(width: 238, height: 10)
        host.frame.size.height = host.fittingSize.height
        return host
    }
}

/// The monospaced list inside a confirm: name on the left, size or change on the right.
private struct ConfirmList: View {
    let rows: [(String, String)]
    let finderPath: String?

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.prefix(WorktreeConfirm.maxListedRows).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(row.1).fixedSize()
                    }
                }
                if rows.count > WorktreeConfirm.maxListedRows {
                    Text("and \(rows.count - WorktreeConfirm.maxListedRows) more")
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let finderPath {
                Button("Show in Finder") { DeletionService.revealInFinder(finderPath) }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(width: 238)
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}

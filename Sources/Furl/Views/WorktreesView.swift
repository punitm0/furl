import SwiftUI

@MainActor
private final class WorktreesViewModel: ObservableObject {
    @Published var showOnlyCleanable = false
    @Published var deleteLocalBranch = true
    @Published var forceRemove = false
    @Published var showConfirmDialog = false
    @Published var searchText = ""
}

struct WorktreesView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = WorktreesViewModel()

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

    private func isSelectable(_ item: WorktreeItem) -> Bool {
        item.mergeStatus != .main && (!item.isDirty || vm.forceRemove)
    }

    /// Selected items that will actually be removed with the current options.
    private var effectiveSelection: [WorktreeItem] {
        state.worktrees.filter { state.selectedWorktreeIDs.contains($0.id) && isSelectable($0) }
    }

    private var selectedSizeBytes: Int64 {
        effectiveSelection.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Git Worktrees", subtitle: "Worktrees whose branches are already merged, including squash merges.") {
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
                    message: "Scan your project folders for Git worktrees whose branches are already merged (including squash merges).",
                    buttonTitle: "Scan Worktrees"
                ) {
                    Task { await state.scanWorktrees() }
                }
            } else if displayedWorktrees.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: state.worktrees.isEmpty ? "No Extra Worktrees" : "No Matches",
                    message: state.worktrees.isEmpty
                        ? "None of your repositories have additional worktrees. Add more scan folders on the Overview page if needed."
                        : "Try clearing the search or the Merged Only filter."
                )
            } else {
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
                                Text(group.repo)
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

                SelectionActionBar(
                    selectedCount: effectiveSelection.count,
                    totalCount: displayedWorktrees.filter(isSelectable).count,
                    selectedBytes: selectedSizeBytes,
                    actionTitle: "Remove",
                    isBusy: state.isCleaning,
                    // The tray removes without force, so uncommitted worktrees stay here.
                    onAddToTray: { CleanupTray.shared.add(effectiveSelection.filter { !$0.isDirty }.map(TrayItem.worktree)) },
                    onSelectAll: {
                        state.selectedWorktreeIDs.formUnion(displayedWorktrees.filter(isSelectable).map(\.id))
                    },
                    onSelectNone: { state.selectedWorktreeIDs.removeAll() },
                    onAction: { vm.showConfirmDialog = true }
                )
            }
        }
        .navigationTitle("Git Worktrees")
        .cleanSlateScreen()
        .confirmationDialog(
            "Remove \(Self.worktreeCount(effectiveSelection.count))?",
            isPresented: $vm.showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("Remove Worktrees (\(FileSizeHelper.formatBytes(selectedSizeBytes)))", role: .destructive) {
                Task {
                    await state.cleanSelectedWorktrees(force: vm.forceRemove, deleteLocalBranch: vm.deleteLocalBranch)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        var parts = ["Runs git worktree remove for each selected worktree. This deletes the worktree folder permanently (it does not go to the Trash)."]
        if vm.deleteLocalBranch {
            parts.append("Local branches of merged worktrees will also be deleted. Branches with unmerged commits are kept.")
        }
        let dirty = effectiveSelection.filter(\.isDirty).count
        if dirty > 0 {
            parts.append("⚠️ \(Self.worktreeCount(dirty)) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost.")
        }
        let unmerged = effectiveSelection.filter { !$0.mergeStatus.isSafeToClean }.count
        if unmerged > 0 {
            parts.append("⚠️ \(Self.worktreeCount(unmerged)) \(unmerged == 1 ? "is" : "are") not merged.")
        }
        return parts.joined(separator: "\n\n")
    }

    private static func worktreeCount(_ count: Int) -> String {
        "\(count) worktree\(count == 1 ? "" : "s")"
    }

    private var toolbarBar: some View {
        // One row when it fits; on a narrow page (cleanup tray open) the actions drop under the
        // options, then the options stack. Labels never wrap mid-phrase.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolbarOptions
                Spacer(minLength: 12)
                toolbarActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { toolbarOptions }
                HStack(spacing: 12) { toolbarActions }
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) { toolbarOptions }
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

    @ViewBuilder private var toolbarOptions: some View {
        Toggle("Merged only", isOn: $vm.showOnlyCleanable)
            .toggleStyle(.furlCheckbox)
            .fixedSize()

        Toggle("Delete local branch", isOn: $vm.deleteLocalBranch)
            .toggleStyle(.furlCheckbox)
            .fixedSize()
            .help("Also run git branch -d (or -D for squash merges) after removing the worktree")

        Toggle("Allow dirty worktrees", isOn: $vm.forceRemove)
            .toggleStyle(.furlCheckbox)
            .fixedSize()
            .help("Use --force so worktrees with uncommitted changes can be removed")
    }

    @ViewBuilder private var toolbarActions: some View {
        Button("Select Safe") {
            state.selectedWorktreeIDs = Set(state.worktrees.filter(\.canAutoSelect).map(\.id))
        }
        .fontWeight(.medium)
        .help("Select merged, clean, unlocked worktrees")
        .disabled(state.worktrees.isEmpty)

        Button("Prune Stale") {
            Task { await state.pruneAllWorktrees() }
        }
        .fontWeight(.medium)
        .help("Run `git worktree prune` to drop metadata for worktrees whose folders are gone")
        .disabled(state.worktrees.isEmpty)

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

    private func worktreeRow(_ item: WorktreeItem) -> some View {
        let isMain = item.mergeStatus == .main

        return HStack(spacing: 12) {
            SelectionCheckbox(id: item.id, selection: $state.selectedWorktreeIDs, disabled: !isSelectable(item))
                .help(isMain ? "The main worktree can't be removed" : (item.isDirty && !vm.forceRemove ? "Has uncommitted changes, or Furl couldn't check it. Look at it in Finder before forcing removal." : ""))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: isMain ? "house" : "arrow.triangle.branch")
                        .foregroundStyle(Theme.inkSecondary)
                    Text(item.branchName)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    statusBadge(for: item.mergeStatus)
                    if item.pointsAtBaseTip {
                        BadgeView(text: "No new commits", color: Theme.inkSecondary, help: "This branch points at the same commit as \(item.baseBranch). It may be a fresh branch you haven't worked on yet, so it isn't auto-selected.")
                    }
                    if item.isDirty {
                        BadgeView(text: "Uncommitted changes", color: Theme.danger)
                    }
                    if item.isLocked {
                        BadgeView(text: "Locked", color: Theme.inkSecondary)
                    }
                    if item.isPrunable {
                        BadgeView(text: "Folder missing", color: Theme.warning, help: "Git still tracks this worktree but its folder is gone. Prune Stale cleans it up.")
                    }
                }

                HStack(spacing: 6) {
                    Text(item.worktreePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("•")
                    Text("base \(item.baseBranch)")
                    Text("•")
                    Text(item.commitHash)
                        .font(.system(size: 11, design: .monospaced))
                    if let date = item.lastCommitDate {
                        Text("•")
                        Text(date.relativeDescription)
                            .help(date.formatted(date: .long, time: .shortened))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
            }

            Spacer()

            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, 4)
        .opacity(isMain ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .pathContextMenu(item.worktreePath, allowOpen: false)
    }

    private func statusBadge(for status: WorktreeMergeStatus) -> some View {
        let color: Color
        let help: String
        switch status {
        case .merged:
            color = Theme.sweep
            help = "Branch is fully merged into the base branch"
        case .squashMerged:
            color = Theme.chartPalette[3]
            help = "Changes were squash- or rebase-merged into the base branch"
        case .unmerged:
            color = Theme.memory
            help = "Branch has commits not in the base branch"
        case .detached:
            color = Theme.warning
            help = "Worktree is on a detached HEAD"
        case .main:
            color = Theme.inkSecondary
            help = "Primary checkout of this repository"
        }
        return BadgeView(text: status.rawValue, color: color, help: help)
    }
}

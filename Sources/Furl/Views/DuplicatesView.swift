import AppKit
import SwiftUI

@MainActor
private final class DuplicatesViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var showConfirmDialog = false
    @Published var showFolders = false
}

struct DuplicatesView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = DuplicatesViewModel()

    private var filteredGroups: [DuplicateGroup] {
        guard !vm.searchText.isEmpty else { return state.duplicateGroups }
        return state.duplicateGroups.filter { group in
            group.files.contains {
                $0.name.localizedCaseInsensitiveContains(vm.searchText)
                    || $0.path.localizedCaseInsensitiveContains(vm.searchText)
            }
        }
    }

    private var selectedFiles: [(file: DuplicateFile, size: Int64)] {
        state.duplicateGroups.flatMap { group in
            group.files.filter { state.selectedDuplicateIDs.contains($0.id) }.map { ($0, $0.privateBytes) }
        }
    }

    private var selectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    private var groupsWithEveryCopySelected: Int {
        state.duplicateGroups.filter { group in
            group.files.allSatisfy { state.selectedDuplicateIDs.contains($0.id) }
        }.count
    }

    private var totalFileCount: Int {
        state.duplicateGroups.reduce(0) { $0 + $1.files.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Duplicates", subtitle: "Identical files. Keep one copy and clear the rest; APFS clones free nothing.") {
                HeaderSearchField(text: $vm.searchText, prompt: "Filter by file name or path")
            }
            toolbarBar
            if vm.showFolders {
                foldersPanel
            }

            LiveScanStripSlot(status: state.liveScans[.duplicates], onStop: { state.stopScan(.duplicates) },
                              onRescan: { Task { await state.scanDuplicates() } })

            if state.isScanningDuplicates && state.duplicateGroups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(state.duplicatePhase.isEmpty ? "Looking for duplicates…" : state.duplicatePhase + "…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("Nothing found yet · \(state.duplicateScannedCount.formatted()) items checked")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.inkTertiary)
                    ScanStripBar(fraction: state.liveScans[.duplicates]?.fraction)
                        .frame(width: 220)
                        .clipShape(Capsule())
                    CancelRunButton(title: "Stop scan", compact: true) { state.cancelDuplicateScan() }
                    Text("Esc stops")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !state.hasScannedDuplicates && !state.isScanningDuplicates {
                EmptyStatePlaceholder(
                    systemImage: "doc.on.doc",
                    title: "Find Duplicate Files",
                    message: "Finds files that are exact copies of each other (compared by content, not name) in your Desktop, Documents, Downloads and media folders.",
                    buttonTitle: "Find Duplicates"
                ) {
                    Task { await state.scanDuplicates() }
                }
            } else if filteredGroups.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: state.duplicateGroups.isEmpty ? "No Duplicates" : "No Matches",
                    message: state.duplicateGroups.isEmpty
                        ? "No duplicate files over \(FileSizeHelper.formatBytes(state.duplicateMinimumBytes)) were found in the scanned folders."
                        : "Try a different search."
                )
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        groupSection(group)
                    }
                }
                .listStyle(.inset)
                .cardList()

                SelectionActionBar(
                    selectedCount: selectedFiles.count,
                    totalCount: totalFileCount,
                    selectedBytes: selectedBytes,
                    actionTitle: state.deletionMode == .moveToTrash ? "Move to Trash" : "Delete",
                    actionKind: state.deletionMode == .permanent ? .danger : .primary,
                    isBusy: state.isCleaning || state.isScanningDuplicates,
                    onAddToTray: {
                        let ids = Set(selectedFiles.map(\.file.id))
                        CleanupTray.shared.add(state.duplicateGroups.flatMap { group in
                            group.files.filter { ids.contains($0.id) }.map { TrayItem.duplicate($0, in: group) }
                        })
                    },
                    onSelectAll: { state.autoSelectDuplicates(keeping: .oldest) },
                    onSelectNone: { state.selectedDuplicateIDs.removeAll() },
                    onAction: { vm.showConfirmDialog = true }
                )
            }
        }
        .navigationTitle("Duplicates")
        .cleanSlateScreen()
        .confirmationDialog(
            "Remove \(selectedFiles.count) duplicate file\(selectedFiles.count == 1 ? "" : "s")?",
            isPresented: $vm.showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(selectedBytes)))", role: .destructive) {
                Task { await state.cleanSelectedDuplicates() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        var text = state.deletionMode == .moveToTrash
            ? "The selected copies go to the Trash, and you can undo right after."
            : "The selected copies will be permanently deleted."
        if groupsWithEveryCopySelected > 0 {
            text += "\n\nEvery copy is selected in \(groupsWithEveryCopySelected) group\(groupsWithEveryCopySelected == 1 ? "" : "s"); Furl will keep the oldest copy of each."
        }
        return text
    }

    private var toolbarBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(DuplicateKeepRule.allCases) { rule in
                    Button(rule.rawValue) { state.autoSelectDuplicates(keeping: rule) }
                }
            } label: {
                ToolbarChipLabel(title: "Auto-Select", systemImage: "wand.and.stars", weight: .medium)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(state.duplicateGroups.isEmpty)
            .help("Select every copy except the one to keep in each group")

            SweepMenuPicker(label: "Min size", options: [Int64(0), 1, 10, 100],
                            selection: $state.duplicateMinimumMB,
                            title: { $0 == 0 ? "100 KB" : "\($0) MB" })

            Button {
                vm.showFolders.toggle()
            } label: {
                Label("\(state.duplicateRoots.count) Folders", systemImage: vm.showFolders ? "chevron.up" : "folder")
            }

            Spacer()

            if state.isScanningDuplicates && !state.duplicateGroups.isEmpty {
                ProgressView().controlSize(.small)
                Text("Rescanning…").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }

            Button {
                Task { await state.scanDuplicates() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(state.isScanningDuplicates)
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var foldersPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.duplicateRoots, id: \.self) { root in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sweep)
                    Text(root.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        state.removeDuplicateRoot(root)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(height: 22)
            }
            HStack(spacing: 8) {
                Button {
                    state.addDuplicateRoot()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button("Reset") {
                    state.duplicateRoots = DuplicateScanner.defaultRoots()
                }
                Spacer()
                Text("Hidden files, app bundles, Photos libraries and dev folders (node_modules, .git) are skipped.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            ForEach(group.files) { file in
                fileRow(file, in: group)
            }
        } header: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files.first?.path ?? ""))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(group.files.first?.name ?? "")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(group.files.count) copies × \(FileSizeHelper.formatBytes(group.sizeBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("\(FileSizeHelper.formatBytes(group.reclaimableBytes)) reclaimable")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.sweep)
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        let isOldest = DuplicateKeepRule.oldest.keeper(in: group.files)?.id == file.id
        return HStack(spacing: 12) {
            SelectionCheckbox(id: file.id, selection: $state.selectedDuplicateIDs)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.name != group.files.first?.name {
                        Text(file.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    if isOldest {
                        BadgeView(text: "Oldest", color: Theme.memory, help: "Probably the original copy")
                    }
                    if file.isClone {
                        BadgeView(text: "Clone", color: Theme.inkSecondary, help: "This copy shares its storage with another file (APFS clone), so removing it frees almost nothing.")
                    }
                }
                if let date = file.modifiedDate {
                    Text("modified \(date.relativeDescription)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                        .help(date.formatted(date: .long, time: .shortened))
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            DeletionService.revealInFinder(file.path)
        }
        .pathContextMenu(file.path)
    }
}

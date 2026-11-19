import AppKit
import SwiftUI

@MainActor
private final class LargeFilesViewModel: ObservableObject {
    @Published var selectedKind: LargeFileKind = .all
    @Published var sortOrder: SortOrder = .sizeDescending
    @Published var searchText = ""
    @Published var showConfirmDialog = false
}

struct LargeFilesView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = LargeFilesViewModel()

    private var filteredFiles: [LargeFileItem] {
        state.largeFiles
            .filter { item in
                (vm.selectedKind == .all || item.kind == vm.selectedKind)
                    && (vm.searchText.isEmpty
                        || item.name.localizedCaseInsensitiveContains(vm.searchText)
                        || item.path.localizedCaseInsensitiveContains(vm.searchText))
            }
            .sorted { lhs, rhs in
                vm.sortOrder.areInIncreasingOrder(
                    lhsSize: lhs.sizeBytes, rhsSize: rhs.sizeBytes,
                    lhsName: lhs.name, rhsName: rhs.name,
                    lhsDate: lhs.modifiedDate, rhsDate: rhs.modifiedDate
                )
            }
    }

    private var selectedFiles: [LargeFileItem] {
        state.largeFiles.filter { state.selectedLargeFileIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    private var thresholdLabel: String {
        FileSizeHelper.formatBytes(state.largeFileThresholdMB * 1_000_000)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Large Files", subtitle: "The biggest files in your home folder. Nothing here is selected for you.") {
                HeaderSearchField(text: $vm.searchText, prompt: "Filter by name or path")
            }
            toolbarBar

            LiveScanStripSlot(status: state.liveScans[.largeFiles], onStop: { state.stopScan(.largeFiles) },
                              onRescan: { Task { await state.scanLargeFiles() } })

            if state.isScanningLargeFiles && state.largeFiles.isEmpty {
                ScanningPlaceholder(message: "Scanning your home folder for files over \(thresholdLabel)…",
                                    status: state.liveScans[.largeFiles])
            } else if !state.hasScannedLargeFiles && !state.isScanningLargeFiles {
                EmptyStatePlaceholder(
                    systemImage: "doc",
                    title: "Find Large Files",
                    message: "Scan your home folder (excluding ~/Library) for files over \(thresholdLabel).",
                    buttonTitle: "Scan Large Files"
                ) {
                    Task { await state.scanLargeFiles() }
                }
            } else if filteredFiles.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: state.largeFiles.isEmpty ? "No Large Files" : "No Matches",
                    message: state.largeFiles.isEmpty
                        ? "No files over \(thresholdLabel) were found in your home folder."
                        : "Try a different type or search."
                )
            } else {
                List {
                    ForEach(filteredFiles) { file in
                        fileRow(file)
                    }
                }
                .listStyle(.inset)
                .cardList()

                SelectionActionBar(
                    selectedCount: selectedFiles.count,
                    totalCount: state.largeFiles.count,
                    selectedBytes: selectedBytes,
                    actionTitle: state.deletionMode == .moveToTrash ? "Move to Trash" : "Delete",
                    actionKind: state.deletionMode == .permanent ? .danger : .primary,
                    isBusy: state.isCleaning,
                    onAddToTray: { CleanupTray.shared.add(selectedFiles.map(TrayItem.largeFile)) },
                    onSelectAll: { state.selectedLargeFileIDs.formUnion(filteredFiles.map(\.id)) },
                    onSelectNone: { state.selectedLargeFileIDs.removeAll() },
                    onAction: { vm.showConfirmDialog = true }
                )
            }
        }
        .navigationTitle("Large Files")
        .cleanSlateScreen()
        .confirmationDialog(
            "Remove \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s")?",
            isPresented: $vm.showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(selectedBytes)))", role: .destructive) {
                Task { await state.cleanSelectedLargeFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.deletionMode == .moveToTrash
                 ? "Files will be moved to the Trash."
                 : "Files will be permanently deleted and can't be recovered.")
        }
    }

    private var toolbarBar: some View {
        HStack(spacing: 12) {
            SweepMenuPicker(label: "Type", options: LargeFileKind.allCases, selection: $vm.selectedKind, title: \.rawValue)

            SweepMenuPicker(label: "Min size", options: [Int64(50), 100, 250, 500, 1000, 5000],
                            selection: $state.largeFileThresholdMB,
                            title: { $0 >= 1000 ? "\($0 / 1000) GB" : "\($0) MB" })
            .help("Raising the size filters current results; lowering it rescans")

            SweepMenuPicker(label: "Sort", options: SortOrder.allCases, selection: $vm.sortOrder, title: \.rawValue)

            Spacer()

            Button {
                Task { await state.scanLargeFiles() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(state.isScanningLargeFiles)
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func fileRow(_ file: LargeFileItem) -> some View {
        HStack(spacing: 12) {
            SelectionCheckbox(id: file.id, selection: $state.selectedLargeFileIDs)

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    BadgeView(text: file.kind.rawValue, color: Theme.accentTeal.fg)
                }
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let date = file.modifiedDate {
                        Text("•")
                        Text("modified \(date.relativeDescription)")
                            .help(date.formatted(date: .long, time: .shortened))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
            }

            Spacer()

            Text(FileSizeHelper.formatBytes(file.sizeBytes))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            DeletionService.revealInFinder(file.path)
        }
        .pathContextMenu(file.path)
    }
}

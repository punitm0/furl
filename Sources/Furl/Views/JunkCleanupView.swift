import SwiftUI

@MainActor
private final class JunkViewModel: ObservableObject {
    @Published var selectedCategory: JunkCategory? = nil
    @Published var searchText = ""
    @Published var sortOrder: SortOrder = .sizeDescending
    @Published var showConfirmDialog = false
}

struct JunkCleanupView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = JunkViewModel()

    private var filteredItems: [JunkItem] {
        state.junkItems
            .filter { item in
                let matchesCategory = vm.selectedCategory == nil || item.category == vm.selectedCategory
                let matchesSearch = vm.searchText.isEmpty
                    || item.name.localizedCaseInsensitiveContains(vm.searchText)
                    || item.path.localizedCaseInsensitiveContains(vm.searchText)
                return matchesCategory && matchesSearch
            }
            .sorted { lhs, rhs in
                vm.sortOrder.areInIncreasingOrder(
                    lhsSize: lhs.sizeBytes, rhsSize: rhs.sizeBytes,
                    lhsName: lhs.name, rhsName: rhs.name,
                    lhsDate: lhs.modifiedDate, rhsDate: rhs.modifiedDate
                )
            }
    }

    private var selectedItems: [JunkItem] {
        state.junkItems.filter { state.selectedJunkIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Ticked items the category or search filter hides; Clean still removes them.
    private var hiddenSelectedCount: Int {
        let shown = Set(filteredItems.map(\.id))
        return selectedItems.filter { !shown.contains($0.id) }.count
    }

    private func categoryBytes(_ category: JunkCategory?) -> Int64 {
        state.junkItems
            .filter { category == nil || $0.category == category }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Categories present in the current results, in `JunkCategory.allCases` order, so
    /// categories added later show up automatically.
    private var presentCategories: [JunkCategory] {
        JunkCategory.allCases.filter { cat in state.junkItems.contains { $0.category == cat } }
    }

    private func color(for category: JunkCategory) -> Color {
        // Fixed slots so no two categories share a colour (chartPalette, ChartColors decision v45).
        let index: Int
        switch category {
        case .devArtifacts: index = 0
        case .packageCaches: index = 1
        case .systemCaches: index = 2
        case .logsAndCrash: index = 3
        case .installers: index = 4
        case .dsStore: index = 5
        case .aiModels: index = 11
        case .docker: index = 7
        case .browserCaches: index = 8
        case .mailAttachments: index = 9
        case .simulators: index = 10
        }
        return Theme.chartPalette[index]
    }

    private var headerSubtitle: String {
        if (state.hasScannedJunk || state.isScanningJunk) && !state.junkItems.isEmpty {
            let soFar = state.isScanningJunk ? " so far" : ""
            return "\(FileSizeHelper.formatBytes(categoryBytes(nil))) found\(soFar). It rebuilds itself when needed."
        }
        return "Rebuilds itself when a tool needs it again."
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Caches & Junk", subtitle: headerSubtitle) {
                HeaderSearchField(text: $vm.searchText, prompt: "Filter by name or path")
                sortMenu
                // SettingsMoved board: the rule sits where its effect shows; changing it re-filters, no rescan.
                SweepMenuPicker(label: "Dependencies count as unused after", options: state.staleDaysOptions,
                                selection: $state.staleDaysThreshold,
                                title: { "\($0) days" })
                    .fixedSize()
                    .help("Small node_modules and .venv folders, and archives in Downloads, show once untouched this long")
                Button("Select Safe") {
                    state.selectedJunkIDs = Set(filteredItems.filter { $0.risk == .safe }.map(\.id))
                }
                .buttonStyle(ToolbarButtonStyle())
                .fixedSize()
                .help("Select only items marked Safe in the current view")
                .disabled(state.junkItems.isEmpty)
                // JunkStates: while scanning, Rescan gives way to a small spinner and "Scanning…".
                if state.isScanningJunk {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Scanning…")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .fixedSize()
                } else {
                    Button {
                        Task { await state.scanJunk() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ToolbarButtonStyle())
                    .fixedSize()
                }
            }

            LimitedResultsLine(screen: .junk, hasResults: state.hasScannedJunk)

            LiveScanStripSlot(status: state.liveScans[.junk], onStop: { state.stopScan(.junk) },
                              onRescan: { Task { await state.scanJunk() } })

            if state.isScanningJunk && state.junkItems.isEmpty {
                ScanningPlaceholder(message: "Scanning developer caches, logs, and unwanted files…",
                                    status: state.liveScans[.junk])
            } else if !state.hasScannedJunk && !state.isScanningJunk {
                EmptyStatePlaceholder(
                    systemImage: SidebarSection.junk.systemImage,
                    title: "Clean Up Caches & Junk",
                    message: "Find stale node_modules, build output, package manager caches, logs and old installers.",
                    buttonTitle: "Scan Caches & Junk"
                ) {
                    Task { await state.scanJunk() }
                }
            } else if state.junkItems.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: "All Clean",
                    message: "Nothing worth cleaning was found."
                )
            } else {
                categoryBar
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, 18)

                if filteredItems.isEmpty {
                    EmptyStatePlaceholder(
                        systemImage: "magnifyingglass",
                        title: "No Matches",
                        message: "Try a different category or search."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            // WhySafe board: the legend line sits at the top of the list.
                            RiskLegend()
                            ForEach(presentCategories, id: \.self) { cat in
                                let items = filteredItems.filter { $0.category == cat }
                                if !items.isEmpty {
                                    categoryCard(cat, items: items)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Space.page)
                        .padding(.vertical, 14)
                    }
                }

                SelectionActionBar(
                    selectedCount: selectedItems.count,
                    totalCount: state.junkItems.count,
                    selectedBytes: selectedBytes,
                    actionTitle: state.deletionMode == .moveToTrash ? "Clean" : "Delete",
                    actionKind: state.deletionMode == .permanent ? .danger : .primary,
                    isBusy: state.isCleaning,
                    note: hiddenSelectionNote(hiddenSelectedCount) ?? "Only Safe items are selected for you",
                    onAddToTray: { CleanupTray.shared.add(selectedItems.map(TrayItem.junk)) },
                    showsShortcutHint: false,
                    onSelectAll: { state.selectedJunkIDs.formUnion(filteredItems.map(\.id)) },
                    onSelectNone: { state.selectedJunkIDs.removeAll() },
                    onAction: { vm.showConfirmDialog = true }
                )
            }
        }
        .navigationTitle("Caches & Junk")
        // A Disk row's Clean / Review / Pick files opens this section filtered to its folder.
        .onAppear { if let filter = state.takeHandoffFilter(for: .junk) { vm.searchText = filter } }
        .cleanSlateScreen()
        .confirmationDialog(
            "Clean \(selectedItems.count) item\(selectedItems.count == 1 ? "" : "s")?",
            isPresented: $vm.showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(selectedBytes)))", role: .destructive) {
                Task { await state.cleanSelectedJunk() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        var text = state.deletionMode == .moveToTrash
            ? "Items will be moved to the Trash so you can recover them if needed."
            : "Items will be permanently deleted from disk."
        let permanent = selectedItems.filter(\.isPermanent).count
        if state.deletionMode == .moveToTrash && permanent > 0 {
            text += "\n\n\(permanent) selected item\(permanent == 1 ? "" : "s") (Docker or simulators) can't go to the Trash and will be removed permanently."
        }
        let risky = selectedItems.filter { $0.risk != .safe }.count
        if risky > 0 {
            text += "\n\n\(risky) selected item\(risky == 1 ? " is" : "s are") marked Check first. Double-check \(risky == 1 ? "it" : "them") first."
        }
        if let hidden = hiddenSelectionNote(hiddenSelectedCount) {
            text += "\n\n\(hidden), but \(hiddenSelectedCount == 1 ? "it's" : "they're") included."
        }
        return text
    }

    // MARK: - Stacked category bar

    private var categoryBar: some View {
        let total = Double(max(categoryBytes(nil), 1))
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let gaps = CGFloat(max(presentCategories.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(presentCategories, id: \.self) { cat in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(color(for: cat))
                            .opacity(vm.selectedCategory == nil || vm.selectedCategory == cat ? 1 : 0.3)
                            .frame(width: max(2, (geo.size.width - gaps) * Double(categoryBytes(cat)) / total))
                            .help("\(cat.rawValue): \(FileSizeHelper.formatBytes(categoryBytes(cat)))")
                    }
                }
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentCategories.map { "\($0.rawValue) \(FileSizeHelper.formatBytes(categoryBytes($0)))" }.joined(separator: ", "))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(
                        title: "All",
                        detail: FileSizeHelper.formatBytes(categoryBytes(nil)),
                        isActive: vm.selectedCategory == nil
                    ) { vm.selectedCategory = nil }
                    ForEach(presentCategories, id: \.self) { cat in
                        FilterChip(
                            title: cat.rawValue,
                            detail: FileSizeHelper.formatBytes(categoryBytes(cat)),
                            swatch: color(for: cat),
                            isActive: vm.selectedCategory == cat
                        ) {
                            vm.selectedCategory = vm.selectedCategory == cat ? nil : cat
                        }
                    }
                }
            }
        }
    }

    // MARK: - Grouped cards

    private func categoryCard(_ cat: JunkCategory, items: [JunkItem]) -> some View {
        let ids = Set(items.map(\.id))
        let selectedCount = ids.intersection(state.selectedJunkIDs).count
        let groupBytes = items.reduce(0) { $0 + $1.sizeBytes }
        let largest = Double(max(items.map(\.sizeBytes).max() ?? 1, 1))

        return GroupCard {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { selectedCount == ids.count },
                    set: { on in
                        if on { state.selectedJunkIDs.formUnion(ids) } else { state.selectedJunkIDs.subtract(ids) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.furlCheckbox)
                .help("Select every item in \(cat.rawValue)")
                Image(systemName: cat.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color(for: cat))
                    .frame(width: 16)
                Text(cat.rawValue)
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("\(items.count) item\(items.count == 1 ? "" : "s")\(selectedCount > 0 && selectedCount < ids.count ? " · \(selectedCount) selected" : "")")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(FileSizeHelper.formatBytes(groupBytes))
                    .font(Theme.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
        } content: {
            ForEach(items) { item in
                junkRow(item, barColor: color(for: cat), fraction: Double(item.sizeBytes) / largest)
            }
        }
    }

    private func junkRow(_ item: JunkItem, barColor: Color, fraction: Double) -> some View {
        GroupRow {
            HStack(spacing: 10) {
                SelectionCheckbox(id: item.id, selection: $state.selectedJunkIDs)
                Color.clear.frame(width: 16, height: 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(Theme.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(item.reason)
                        if let date = item.modifiedDate {
                            Text("· modified \(date.relativeDescription)")
                        }
                    }
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    Text(item.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.inkSecondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    RiskChip(tier: item.risk.tier)
                    if item.isPermanent {
                        RiskChip(tier: .permanent,
                                 help: "Removed with its own tool (Docker or Xcode). It can't go to the Trash or be undone.")
                    }
                    WhyButton(explanation: WhySafe.junk(item, deletionMode: state.deletionMode),
                              action: skipAction(for: item))
                }

                MeterBar(fraction: fraction, color: barColor)
                    .frame(width: 160)

                Text(FileSizeHelper.formatBytes(item.sizeBytes))
                    .font(Theme.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            DeletionService.revealInFinder(item.path)
        }
        .pathContextMenu(item.path, allowOpen: false,
                         dontScan: item.command == nil ? { state.requestNeverScan(forJunk: item) } : nil)
    }

    /// JunkStates: 28pt icon-only chip (arrow.up.arrow.down + chevron), surface fill, control border.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $vm.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.controlBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort items within each group")
        .accessibilityLabel("Sort: \(vm.sortOrder.rawValue)")
    }

    /// "Always skip …": adds the folder to Settings › Scanning › Never scan, with Undo on the toast.
    /// Tool-removed items (Docker, simulators) have no folder to skip.
    private func skipAction(for item: JunkItem) -> WhyAction? {
        guard item.command == nil, state.canNeverScan(item.path) else { return nil }
        return WhyAction(title: "Always skip \(item.name)") {
            state.neverScan(item.path, from: .junk)
        }
    }
}

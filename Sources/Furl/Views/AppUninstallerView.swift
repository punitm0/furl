import SwiftUI

@MainActor
private final class AppUninstallerViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case footprint = "Footprint"
        case unused = "Unused 90+ days"
        case orphaned = "Leftovers"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Total size"
        case lastUsed = "Last used"
        case name = "Name"
        var id: String { rawValue }
    }

    @Published var mode: Mode = .footprint
    @Published var searchText = ""
    @Published var selectedAppID: String?
    @Published var selectedDataIDs = Set<String>()
    @Published var appToUninstall: InstalledAppItem?
    @Published var appToClearCaches: InstalledAppItem?
    @Published var orphanedGroupToClear: OrphanedAppDataGroup?
    @Published var confirmClearAllOrphans = false
    @Published var confirmClearSelectedOrphans = false
    @Published var selectedOrphanItemIDs = Set<String>()
    @Published var expandedOrphanGroupIDs = Set<String>()
    @Published var sortOrder: SortOrder = .size
}

struct AppUninstallerView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = AppUninstallerViewModel()

    private var filteredApps: [InstalledAppItem] {
        let matches = state.installedApps.filter { app in
            (vm.mode != .unused || app.isUnused90Days)
                && (vm.searchText.isEmpty
                    || app.name.localizedCaseInsensitiveContains(vm.searchText)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(vm.searchText))
        }
        switch vm.sortOrder {
        case .size:
            return matches.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
        case .name:
            return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            // Least recently used first; apps macOS has no date for go last.
            return matches.sorted { a, b in
                switch (a.lastOpenedDate, b.lastOpenedDate) {
                case let (x?, y?): return x == y ? a.totalSizeBytes > b.totalSizeBytes : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.totalSizeBytes > b.totalSizeBytes
                }
            }
        }
    }

    private var unusedCount: Int {
        state.installedApps.filter(\.isUnused90Days).count
    }

    private var selectedOrphanItems: [AppDataItem] {
        state.orphanedGroups.flatMap(\.items).filter { vm.selectedOrphanItemIDs.contains($0.id) }
    }

    private var selectedOrphanBytes: Int64 {
        selectedOrphanItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var filteredOrphans: [OrphanedAppDataGroup] {
        state.orphanedGroups.filter { group in
            vm.searchText.isEmpty
                || group.displayName.localizedCaseInsensitiveContains(vm.searchText)
                || group.appIdentifier.localizedCaseInsensitiveContains(vm.searchText)
        }
    }

    private var selectedApp: InstalledAppItem? {
        filteredApps.first { $0.id == vm.selectedAppID } ?? filteredApps.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Apps & Leftovers", subtitle: "Each app's full footprint — the app plus its caches, data and settings in ~/Library.") {
                HeaderSearchField(text: $vm.searchText, prompt: "Search apps or bundle IDs")
            }
            toolbarBar

            LiveScanStripSlot(status: state.liveScans[.apps], onStop: { state.stopScan(.apps) },
                              onRescan: { Task { await state.scanApps() } })

            if state.isScanningApps && state.installedApps.isEmpty && state.orphanedGroups.isEmpty {
                ScanningPlaceholder(message: "Measuring installed apps and their ~/Library data…",
                                    status: state.liveScans[.apps])
            } else if !state.hasScannedApps && !state.isScanningApps {
                EmptyStatePlaceholder(
                    systemImage: "square.stack.3d.up",
                    title: "See What Each App Really Takes",
                    message: "Scan /Applications and ~/Applications to see each app's caches, data and settings, clear what's rebuildable, or uninstall apps with their leftovers.",
                    buttonTitle: "Scan Apps"
                ) {
                    Task { await state.scanApps() }
                }
            } else {
                switch vm.mode {
                case .footprint, .unused:
                    installedAppsContent
                case .orphaned:
                    orphanedDataContent
                }
            }
        }
        .navigationTitle("Apps & Leftovers")
        .cleanSlateScreen()
        .confirmationDialog(
            "Uninstall \(vm.appToUninstall?.name ?? "App")?",
            isPresented: Binding(
                get: { vm.appToUninstall != nil },
                set: { if !$0 { vm.appToUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = vm.appToUninstall {
                let dataItems = app.associatedData.filter { vm.selectedDataIDs.contains($0.id) }
                let dataPaths = dataItems.map(\.path)
                let total = app.appSizeBytes + dataItems.reduce(0) { $0 + $1.sizeBytes }

                if !dataPaths.isEmpty {
                    Button("Uninstall App + \(dataPaths.count) Data Item(s) (\(FileSizeHelper.formatBytes(total)))", role: .destructive) {
                        uninstall(app, dataPaths: dataPaths)
                    }
                }
                Button("Uninstall App Only (\(FileSizeHelper.formatBytes(app.appSizeBytes)))", role: .destructive) {
                    uninstall(app, dataPaths: [])
                }
                Button("Cancel", role: .cancel) {
                    vm.appToUninstall = nil
                }
            }
        } message: {
            if let app = vm.appToUninstall {
                let destination = state.deletionMode == .moveToTrash ? "moved to the Trash, so you can undo" : "deleted permanently"
                Text(app.isRunning
                     ? "\(app.name) is running and will be quit first. Everything is \(destination)."
                     : "Folders marked \u{201C}Possible match\u{201D} aren't included unless you tick them. Everything is \(destination).")
            }
        }
        .confirmationDialog(
            "Clear caches and logs for \(vm.appToClearCaches?.name ?? "")?",
            isPresented: Binding(
                get: { vm.appToClearCaches != nil },
                set: { if !$0 { vm.appToClearCaches = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = vm.appToClearCaches {
                Button("\(state.deletionMode.rawValue) \(app.rebuildableItems.count) Item(s) (\(FileSizeHelper.formatBytes(app.rebuildableBytes)))") {
                    let paths = AppFootprintSafety.sanitize(app.rebuildableItems.map(\.path))
                    let items = app.rebuildableItems.filter { paths.contains($0.path) }
                    vm.appToClearCaches = nil
                    Task { await state.clearOrphanedItems(items, label: "cache & log item(s) for \(app.name)") }
                }
                Button("Cancel", role: .cancel) { vm.appToClearCaches = nil }
            }
        } message: {
            if let app = vm.appToClearCaches {
                Text("\(app.name) rebuilds these as it needs them; it may be a little slower the first time."
                     + (app.isRunning ? " It's running now — quitting it first is safest." : ""))
            }
        }
        .confirmationDialog(
            "Clear data for \(vm.orphanedGroupToClear?.displayName ?? "")?",
            isPresented: Binding(
                get: { vm.orphanedGroupToClear != nil },
                set: { if !$0 { vm.orphanedGroupToClear = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let group = vm.orphanedGroupToClear {
                Button("Clear \(group.items.count) \(group.items.count == 1 ? "Item" : "Items") (\(FileSizeHelper.formatBytes(group.totalSizeBytes)))", role: .destructive) {
                    Task {
                        await state.clearOrphanedGroup(group)
                        vm.orphanedGroupToClear = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    vm.orphanedGroupToClear = nil
                }
            }
        }
        .confirmationDialog(
            "Clear \(selectedOrphanItems.count) selected leftover \(selectedOrphanItems.count == 1 ? "item" : "items")?",
            isPresented: $vm.confirmClearSelectedOrphans,
            titleVisibility: .visible
        ) {
            Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(selectedOrphanBytes)))", role: .destructive) {
                let items = selectedOrphanItems
                vm.selectedOrphanItemIDs.removeAll()
                Task { await state.clearOrphanedItems(items, label: "leftover item(s)") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Make sure these really belong to apps you've removed. Some apps keep data in ~/Library under a different name.")
        }
        .confirmationDialog(
            "Clear all \(state.orphanedGroups.count) orphaned app data groups?",
            isPresented: $vm.confirmClearAllOrphans,
            titleVisibility: .visible
        ) {
            Button("Clear All (\(FileSizeHelper.formatBytes(state.totalOrphanedAppDataBytes)))", role: .destructive) {
                vm.selectedOrphanItemIDs.removeAll()
                Task { await state.clearAllOrphanedData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leftover detection is heuristic. Review the list first — some apps keep data under names that don't match their bundle.")
        }
    }

    private func uninstall(_ app: InstalledAppItem, dataPaths: [String]) {
        vm.appToUninstall = nil
        guard app.allowsFootprintActions, AppFootprintSafety.isAllowed(app.bundlePath) else {
            ErrorLog.shared.redact(app.name)
            state.errorBanner = "\(app.name) is outside /Applications or managed by macOS, so it can't be removed here."
            return
        }
        // Only ~/Library app-data paths, and no folder that's already inside another one being removed.
        let paths = AppFootprintSafety.sanitize(dataPaths)
        Task { await state.uninstallApp(app, includeDataPaths: paths) }
    }

    private func tabTitle(_ mode: AppUninstallerViewModel.Mode) -> String {
        guard state.hasScannedApps else { return mode.rawValue }
        switch mode {
        case .footprint: return mode.rawValue
        case .unused: return "\(mode.rawValue) · \(unusedCount)"
        case .orphaned: return "\(mode.rawValue) · \(state.orphanedGroups.count)"
        }
    }

    /// One row when it fits; otherwise the Leftovers actions drop to a second row instead of
    /// pushing the window wider than it is (which blanked the whole split view).
    private var toolbarBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolbarTabs
                Spacer(minLength: 12)
                toolbarActions(spacing: 12)
                toolbarRescan
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    toolbarTabs
                    Spacer(minLength: 8)
                    toolbarRescan
                }
                toolbarActionsRow
            }
            // Narrower still (the cleanup tray open beside a small window): the tabs get their own
            // row, so the bar never overflows both edges of the page.
            VStack(alignment: .leading, spacing: 8) {
                pillTabs
                HStack(spacing: 8) {
                    sortPicker
                    Spacer(minLength: 8)
                    toolbarRescan
                }
                toolbarActionsRow
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var toolbarTabs: some View {
        HStack(spacing: 12) {
            pillTabs
            sortPicker
        }
    }

    private var pillTabs: some View {
        PillTabs(tabs: AppUninstallerViewModel.Mode.allCases, selection: $vm.mode, title: tabTitle)
            .fixedSize()
    }

    @ViewBuilder
    private var sortPicker: some View {
        if vm.mode != .orphaned {
            SweepMenuPicker(label: "Sort by", options: AppUninstallerViewModel.SortOrder.allCases,
                            selection: $vm.sortOrder, title: \.rawValue)
            .help("Last used puts the apps you haven't opened for longest first")
        }
    }

    /// The Leftovers actions on their own row, right-aligned, in the stacked toolbars.
    @ViewBuilder
    private var toolbarActionsRow: some View {
        if vm.mode == .orphaned && !state.orphanedGroups.isEmpty {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                toolbarActions(spacing: 8)
            }
        }
    }

    /// 12pt apart on the one-row toolbar, 8pt on the narrow second row (Leftovers board).
    @ViewBuilder
    private func toolbarActions(spacing: CGFloat) -> some View {
        if vm.mode == .orphaned && !state.orphanedGroups.isEmpty {
            HStack(spacing: spacing) {
                AddToTrayButton(count: selectedOrphanItems.count) {
                    CleanupTray.shared.add(state.orphanedGroups.flatMap { group in
                        group.items.filter { vm.selectedOrphanItemIDs.contains($0.id) }
                            .map { TrayItem.leftover($0, appName: group.displayName) }
                    })
                }
                .fixedSize()
                .disabled(state.isCleaning)
                Button(role: .destructive) {
                    vm.confirmClearSelectedOrphans = true
                } label: {
                    Text(selectedOrphanBytes > 0 ? "Clear Selected \(FileSizeHelper.formatBytes(selectedOrphanBytes))" : "Clear Selected")
                        .monospacedDigit()
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                .fixedSize()
                .disabled(selectedOrphanItems.isEmpty || state.isCleaning)

                Button("Clear All…", role: .destructive) {
                    vm.confirmClearAllOrphans = true
                }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                .fixedSize()
                .disabled(state.isCleaning)
            }
        }
    }

    private var toolbarRescan: some View {
        HStack(spacing: 12) {
            if state.isScanningApps {
                // AppsStates: 12 pt spinner, 6 pt gap, "Refreshing…" in caption inkSecondary.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            Button {
                Task { await state.scanApps() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
            .fixedSize()
            .disabled(state.isScanningApps)
        }
        .fixedSize()
    }

    private func select(_ app: InstalledAppItem) {
        vm.selectedAppID = app.id
        vm.selectedDataIDs = Set(app.associatedData.filter(\.isStrongMatch).map(\.id))
    }

    private var installedAppsContent: some View {
        Group {
            if filteredApps.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: vm.mode == .unused ? "checkmark.seal" : "magnifyingglass",
                    title: vm.mode == .unused && vm.searchText.isEmpty ? "No Long-Unused Apps" : "No Matching Apps",
                    message: vm.mode == .unused && vm.searchText.isEmpty
                        ? "Every app with a known last-opened date was used in the last 90 days."
                        : "No installed app matches your search."
                )
            } else {
                // List (340) beside the details (at least 460). A page narrower than that (the
                // cleanup tray open, or a small window) overflowed both edges; there the details
                // go under the list and the two share the height.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        appList
                            .frame(width: 340)
                        if let app = selectedApp {
                            appDetail(app)
                                .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
                                .layoutPriority(1)
                        }
                    }
                    VStack(spacing: 16) {
                        appList
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let app = selectedApp {
                            appDetail(app)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 20)
                .onAppear {
                    if vm.selectedAppID == nil, let first = filteredApps.first { select(first) }
                }
                .onChange(of: state.installedApps) { _, newApps in
                    if let current = newApps.first(where: { $0.id == vm.selectedAppID }) {
                        // Keep the user's ticks, minus folders that are gone.
                        vm.selectedDataIDs.formIntersection(Set(current.associatedData.map(\.id)))
                    } else if let first = filteredApps.first {
                        select(first)
                    }
                }
                .onChange(of: vm.mode) { _, _ in
                    if !filteredApps.contains(where: { $0.id == vm.selectedAppID }), let first = filteredApps.first {
                        select(first)
                    }
                }
            }
        }
    }

    private func appDetail(_ app: InstalledAppItem) -> some View {
        AppFootprintDetail(
            app: app,
            selectedDataIDs: $vm.selectedDataIDs,
            isBusy: state.isCleaning,
            onClearRebuildable: { vm.appToClearCaches = app },
            onUninstall: { vm.appToUninstall = app },
            onAddToTray: {
                let dataPaths = app.associatedData.filter { vm.selectedDataIDs.contains($0.id) }.map(\.path)
                CleanupTray.shared.add([TrayItem.app(app, dataPaths: dataPaths)])
            }
        )
    }

    private var appList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        AppFootprintRow(app: app, isSelected: app.id == selectedApp?.id) {
                            select(app)
                        }
                        .id(app.id)
                    }
                    if vm.mode == .footprint && vm.searchText.isEmpty && !state.orphanedGroups.isEmpty {
                        LeftoversSummaryRow(
                            appCount: state.orphanedGroups.count,
                            bytes: state.totalOrphanedAppDataBytes
                        ) {
                            vm.mode = .orphaned
                        }
                    }
                }
            }
            .onChange(of: vm.sortOrder) { _, _ in
                if let id = selectedApp?.id { proxy.scrollTo(id) }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var orphanedDataContent: some View {
        Group {
            if filteredOrphans.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: "No Orphaned App Data Found",
                    message: "Leftover folders in ~/Library from uninstalled apps will appear here.",
                    buttonTitle: "Rescan"
                ) {
                    Task { await state.scanApps() }
                }
            } else {
                // Leftovers board: groups collapsed by default, hairline between groups, rows not a List.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredOrphans.enumerated()), id: \.element.id) { index, group in
                            orphanGroupRow(group)
                                .overlay(alignment: .top) {
                                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                }
                            if vm.expandedOrphanGroupIDs.contains(group.id) {
                                ForEach(group.items) { item in
                                    orphanItemRow(item)
                                }
                            }
                        }
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 14)
            }
        }
    }

    private func orphanGroupRow(_ group: OrphanedAppDataGroup) -> some View {
        let isOpen = vm.expandedOrphanGroupIDs.contains(group.id)
        let count = group.items.count
        return HStack(spacing: 10) {
            Button {
                if isOpen { vm.expandedOrphanGroupIDs.remove(group.id) } else { vm.expandedOrphanGroupIDs.insert(group.id) }
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 11, height: 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide items" : "Show items")
            Toggle("", isOn: Binding(
                get: { group.items.allSatisfy { vm.selectedOrphanItemIDs.contains($0.id) } },
                set: { checked in
                    let ids = group.items.map(\.id)
                    if checked {
                        vm.selectedOrphanItemIDs.formUnion(ids)
                    } else {
                        vm.selectedOrphanItemIDs.subtract(ids)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.furlCheckbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(count) leftover \(count == 1 ? "item" : "items") in ~/Library" + (group.latestModified.map { " • last used \($0.relativeDescription)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { vm.expandedOrphanGroupIDs.remove(group.id) } else { vm.expandedOrphanGroupIDs.insert(group.id) }
            }
            Text(FileSizeHelper.formatBytes(group.totalSizeBytes))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ink)
            Button {
                vm.orphanedGroupToClear = group
            } label: {
                Text("Clear Data").foregroundStyle(Theme.danger)
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func orphanItemRow(_ item: AppDataItem) -> some View {
        HStack(spacing: 10) {
            SelectionCheckbox(id: item.id, selection: $vm.selectedOrphanItemIDs)
            BadgeView(text: item.location.rawValue, color: Theme.memory)
            Text(item.path)
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkSecondary)
            Button {
                DeletionService.revealInFinder(item.path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.leading, 54)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .pathContextMenu(item.path, allowOpen: false)
    }
}

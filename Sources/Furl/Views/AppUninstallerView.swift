import SwiftUI

/// The open confirm sheet: removed-app data, or uninstalling an app (with an app-only choice).
private enum PendingConfirm: Identifiable {
    case removed(RemovedApps.Confirm)
    case uninstall(InstalledAppItem, RemovedApps.Confirm, appOnly: RemovedApps.Confirm?)

    var confirm: RemovedApps.Confirm {
        switch self {
        case .removed(let c), .uninstall(_, let c, _): return c
        }
    }

    var id: String { confirm.paths.joined(separator: "\n") }
}

@MainActor
private final class AppUninstallerViewModel: ObservableObject {
    /// AppsOneList board: one list, with long-unused apps as a filter instead of a tab.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All apps"
        case unused = "Not opened in 90+ days"
        /// DevTools board: a third filter, so the sidebar and ⌘1–⌘8 don't change.
        case developer = "Developer tools"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Total size"
        case lastOpened = "Last opened"
        case name = "Name"
        var id: String { rawValue }
    }

    @Published var filter: Filter = .all
    @Published var searchText = ""
    @Published var selectedAppID: String?
    /// Set when a removed app is picked in the list; the detail then shows its folders.
    @Published var selectedRemovedID: String?
    @Published var selectedDataIDs = Set<String>()
    @Published var appToClearCaches: InstalledAppItem?
    @Published var pendingConfirm: PendingConfirm?
    @Published var tickedRemovedIDs = Set<String>()
    /// Ticked rows in the Developer tools filter.
    @Published var tickedDevIDs = Set<String>()
    /// Ticks "Select sure matches" made, so a rescan can drop any that no longer qualify.
    var autoTickedIDs = Set<String>()
    @Published var showAllRemoved = false
    @Published var sortOrder: SortOrder = .size
    /// The sort to go back to when the 90+ days filter is turned off.
    var sortBeforeFilter: SortOrder = .size
}

struct AppUninstallerView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = AppUninstallerViewModel()

    /// AppsOneList board: four removed apps show before "N more removed apps".
    private static let removedPreviewCount = 4

    private var filteredApps: [InstalledAppItem] {
        let matches = state.installedApps.filter { app in
            (vm.filter != .unused || app.isUnused90Days)
                && (vm.searchText.isEmpty
                    || app.name.localizedCaseInsensitiveContains(vm.searchText)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(vm.searchText))
        }
        switch vm.sortOrder {
        case .size:
            return matches.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
        case .name:
            return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastOpened:
            // Least recently opened first; apps macOS has no date for go last.
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

    /// The removed-apps group, hidden while the 90+ days filter is on.
    private var filteredRemoved: [OrphanedAppDataGroup] {
        guard vm.filter == .all else { return [] }
        return state.orphanedGroups.filter { group in
            vm.searchText.isEmpty
                || group.displayName.localizedCaseInsensitiveContains(vm.searchText)
                || group.appIdentifier.localizedCaseInsensitiveContains(vm.searchText)
        }
    }

    /// Ticked folders of the removed apps in the list right now (a search hides the rest), for the
    /// bar under the group. Board: each button acts only on what sits next to it.
    private var tickedRemoved: [(group: OrphanedAppDataGroup, items: [AppDataItem])] {
        RemovedApps.ticked(vm.tickedRemovedIDs, in: filteredRemoved)
    }

    private var selectedRemoved: OrphanedAppDataGroup? {
        guard let id = vm.selectedRemovedID else { return nil }
        return filteredRemoved.first { $0.id == id }
    }

    private var selectedApp: InstalledAppItem? {
        filteredApps.first { $0.id == vm.selectedAppID } ?? filteredApps.first
    }

    private var toTrash: Bool { state.deletionMode == .moveToTrash }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Apps & Leftovers", subtitle: "Each app with its caches, data and settings, plus data from apps you removed.") {
                HeaderSearchField(text: $vm.searchText, prompt: "Search apps and tools")
            }
            toolbarBar

            LimitedResultsLine(screen: .apps, hasResults: state.hasScannedApps)

            if vm.filter == .developer {
                DevToolsList(state: state, searchText: vm.searchText, ticked: $vm.tickedDevIDs)
            } else {
                appsContent
            }
        }
        .navigationTitle("Apps & Leftovers")
        .cleanSlateScreen()
        .onAppear(perform: takeDevToolsHandoff)
        .onChange(of: state.openDevToolsFilter) { _, _ in takeDevToolsHandoff() }
        .onChange(of: vm.filter) { old, filter in
            // AppsOneList: sort switches to Last opened while the filter is on, and back when it's off.
            if filter == .unused {
                vm.sortBeforeFilter = vm.sortOrder
                vm.sortOrder = .lastOpened
            } else if old == .unused {
                vm.sortOrder = vm.sortBeforeFilter
            }
            if filter == .developer && !state.hasScannedDevTools && !state.isScanningDevTools {
                Task { await state.scanDevTools() }
            }
            if selectedRemoved == nil { vm.selectedRemovedID = nil }
        }
        .onChange(of: state.orphanedGroups) { _, groups in
            // Drop ticks for folders that are gone, and auto-ticks that are no longer sure and Safe.
            vm.tickedRemovedIDs.formIntersection(Set(groups.flatMap(\.items).map(\.id)))
            let stale = RemovedApps.staleAutoTicks(vm.autoTickedIDs, in: groups)
            vm.tickedRemovedIDs.subtract(stale)
            vm.autoTickedIDs.subtract(stale)
        }
        .onChange(of: vm.tickedRemovedIDs) { _, ticked in
            // A folder the user unticks stops counting as auto-ticked.
            vm.autoTickedIDs.formIntersection(ticked)
        }
        .sheet(item: $vm.pendingConfirm) { pending in
            confirmSheet(pending)
        }
        .onAppear { openLeftoversReview() }
        .onChange(of: state.leftoversReviewID) { _, _ in openLeftoversReview() }
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
    }

    private func takeDevToolsHandoff() {
        guard state.openDevToolsFilter else { return }
        state.openDevToolsFilter = false
        vm.filter = .developer
    }

    @ViewBuilder
    private var appsContent: some View {
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
            listContent
        }
    }

    @ViewBuilder
    private func confirmSheet(_ pending: PendingConfirm) -> some View {
        switch pending {
        case .removed(let confirm):
            RemovedAppsConfirmSheet(confirm: confirm) {
                vm.pendingConfirm = nil
                trashRemoved(confirm)
            } onCancel: {
                vm.pendingConfirm = nil
            }
        case let .uninstall(app, confirm, appOnly):
            RemovedAppsConfirmSheet(
                confirm: confirm,
                secondaryTitle: appOnly.map { "App only (\(FileSizeHelper.formatBytes($0.totalBytes)))" },
                onSecondary: {
                    vm.pendingConfirm = nil
                    uninstall(app, dataPaths: [])
                }
            ) {
                vm.pendingConfirm = nil
                uninstall(app, dataPaths: Array(confirm.paths.dropFirst()))
            } onCancel: {
                vm.pendingConfirm = nil
            }
        }
    }

    /// Board: every confirm lists what goes, with sizes, and says where it goes.
    private func confirmUninstall(_ app: InstalledAppItem) {
        let data = app.associatedData.filter { vm.selectedDataIDs.contains($0.id) }
        let confirm = RemovedApps.uninstall(app, data: data, toTrash: toTrash)
        let appOnly = data.isEmpty ? nil : RemovedApps.uninstall(app, data: [], toTrash: toTrash)
        vm.pendingConfirm = .uninstall(app, confirm, appOnly: appOnly)
    }

    private func uninstall(_ app: InstalledAppItem, dataPaths: [String]) {
        guard app.allowsFootprintActions, AppFootprintSafety.isAllowed(app.bundlePath) else {
            ErrorLog.shared.redact(app.name)
            state.errorBanner = "\(app.name) is outside /Applications or managed by macOS, so it can't be removed here."
            return
        }
        // Only ~/Library app-data paths, and no folder that's already inside another one being removed.
        let paths = AppFootprintSafety.sanitize(dataPaths)
        Task { await state.uninstallApp(app, includeDataPaths: paths) }
    }

    /// Opens the confirm for exactly these ticked folders, built from the current scan.
    private func confirmTrashRemoved(_ picks: [(group: OrphanedAppDataGroup, items: [AppDataItem])]) {
        if let confirm = RemovedApps.confirm(for: picks, toTrash: toTrash) {
            vm.pendingConfirm = .removed(confirm)
        }
    }

    /// "Review…" on the trashed-app offer (LeftoversWhatsNew board): selects the app under Removed
    /// apps, ticks its sure matches (possible matches stay unticked) and opens the usual confirm.
    private func openLeftoversReview() {
        guard let id = state.leftoversReviewID else { return }
        state.leftoversReviewID = nil
        guard let group = state.orphanedGroups.first(where: { $0.id == id }) else { return }
        vm.filter = .all
        vm.searchText = ""
        vm.showAllRemoved = true
        vm.selectedRemovedID = group.id
        let sure = group.items.filter(\.isStrongMatch)
        guard !sure.isEmpty else { return }
        vm.tickedRemovedIDs.formUnion(sure.map(\.id))
        confirmTrashRemoved([(group, sure)])
    }

    /// Moves what the confirm listed, and only that. Each path is checked again here (still a
    /// ~/Library app-data folder, still in the scan) and by `clearOrphanedItems` (unchanged since
    /// the scan, not protected) right before it moves.
    private func trashRemoved(_ confirm: RemovedApps.Confirm) {
        let allowed = Set(AppFootprintSafety.sanitize(confirm.paths))
        let items = state.orphanedGroups.flatMap(\.items).filter { allowed.contains($0.path) }
        vm.tickedRemovedIDs.subtract(items.map(\.id))
        guard !items.isEmpty else { return }
        Task { await state.clearOrphanedItems(items, label: "folder(s) from removed apps") }
    }

    private func filterTitle(_ filter: AppUninstallerViewModel.Filter) -> String {
        switch filter {
        case .unused where state.hasScannedApps:
            return "\(filter.rawValue) · \(unusedCount)"
        case .developer where state.hasScannedDevTools:
            return "\(filter.rawValue) · \(state.devTools.rowCount)"
        default:
            return filter.rawValue
        }
    }

    /// One row when it fits; on a narrow page the filter gets its own row so the bar never
    /// overflows both edges.
    private var toolbarBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterTabs
                if vm.filter != .developer { sortPicker }
                Spacer(minLength: 12)
                toolbarRescan
            }
            VStack(alignment: .leading, spacing: 8) {
                filterTabs
                HStack(spacing: 8) {
                    if vm.filter != .developer { sortPicker }
                    Spacer(minLength: 8)
                    toolbarRescan
                }
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var filterTabs: some View {
        PillTabs(tabs: AppUninstallerViewModel.Filter.allCases, selection: $vm.filter, title: filterTitle)
            .fixedSize()
    }

    private var sortPicker: some View {
        SweepMenuPicker(label: "Sort by", options: AppUninstallerViewModel.SortOrder.allCases,
                        selection: $vm.sortOrder, title: \.rawValue)
        .help("Last opened puts the apps you haven't opened for longest first")
    }

    private var toolbarRescan: some View {
        let developer = vm.filter == .developer
        let busy = developer ? state.isScanningDevTools : state.isScanningApps
        return HStack(spacing: 12) {
            if busy {
                // AppsStates: 12 pt spinner, 6 pt gap, "Refreshing…" in caption inkSecondary.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            Button {
                Task { developer ? await state.scanDevTools() : await state.scanApps() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
            .fixedSize()
            .disabled(busy)
        }
        .fixedSize()
    }

    private func select(_ app: InstalledAppItem) {
        vm.selectedRemovedID = nil
        vm.selectedAppID = app.id
        vm.selectedDataIDs = Set(app.associatedData.filter(\.isStrongMatch).map(\.id))
    }

    private var listContent: some View {
        Group {
            if filteredApps.isEmpty && filteredRemoved.isEmpty {
                EmptyStatePlaceholder(
                    systemImage: vm.filter == .unused ? "checkmark.seal" : "magnifyingglass",
                    title: vm.filter == .unused && vm.searchText.isEmpty ? "No Long-Unused Apps" : "No Matching Apps",
                    message: vm.filter == .unused && vm.searchText.isEmpty
                        ? "Every app with a known last-opened date was used in the last 90 days."
                        : "No app matches your search."
                )
            } else {
                // List (360) beside the details (at least 460). A page narrower than that (the
                // cleanup tray open, or a small window) overflowed both edges; there the details
                // go under the list and the two share the height.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        appList
                            .frame(width: 360)
                        detail
                            .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
                            .layoutPriority(1)
                    }
                    VStack(spacing: 16) {
                        appList
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 18)
                .onAppear {
                    if vm.selectedAppID == nil, let first = filteredApps.first { select(first) }
                }
                .onChange(of: state.installedApps) { _, newApps in
                    if let current = newApps.first(where: { $0.id == vm.selectedAppID }) {
                        // Keep the user's ticks, minus folders that are gone.
                        vm.selectedDataIDs.formIntersection(Set(current.associatedData.map(\.id)))
                    } else if vm.selectedRemovedID == nil, let first = filteredApps.first {
                        select(first)
                    }
                }
                .onChange(of: vm.filter) { _, _ in
                    if !filteredApps.contains(where: { $0.id == vm.selectedAppID }), let first = filteredApps.first {
                        select(first)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let group = selectedRemoved {
            let picks = RemovedApps.ticked(vm.tickedRemovedIDs, in: [group])
            RemovedAppDetail(
                group: group,
                ticked: $vm.tickedRemovedIDs,
                deletionMode: state.deletionMode,
                tickedCount: picks.flatMap(\.items).count,
                tickedBytes: picks.flatMap(\.items).reduce(0) { $0 + $1.sizeBytes },
                isBusy: state.isCleaning,
                onAddToTray: { addToTray(picks) },
                onTrash: { confirmTrashRemoved(picks) }
            )
        } else if let app = selectedApp {
            AppFootprintDetail(
                app: app,
                selectedDataIDs: $vm.selectedDataIDs,
                isBusy: state.isCleaning,
                onClearRebuildable: { vm.appToClearCaches = app },
                onUninstall: { confirmUninstall(app) },
                onAddToTray: {
                    let dataPaths = app.associatedData.filter { vm.selectedDataIDs.contains($0.id) }.map(\.path)
                    CleanupTray.shared.add([TrayItem.app(app, dataPaths: dataPaths)])
                }
            )
        }
    }

    private func addToTray(_ picks: [(group: OrphanedAppDataGroup, items: [AppDataItem])]) {
        CleanupTray.shared.add(picks.flatMap { pick in
            pick.items.map { TrayItem.leftover($0, appName: pick.group.shownName) }
        })
    }

    private var appList: some View {
        let removed = filteredRemoved
        let showAll = vm.showAllRemoved || !vm.searchText.isEmpty || removed.count <= Self.removedPreviewCount + 1
        let shownRemoved = showAll ? removed : Array(removed.prefix(Self.removedPreviewCount))
        let hidden = removed.dropFirst(shownRemoved.count)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        AppFootprintRow(app: app, isSelected: vm.selectedRemovedID == nil && app.id == selectedApp?.id) {
                            select(app)
                        }
                        .id(app.id)
                    }
                    if !removed.isEmpty {
                        removedHeader
                        ForEach(shownRemoved) { group in
                            RemovedAppRow(
                                group: group,
                                isSelected: group.id == vm.selectedRemovedID,
                                ticked: $vm.tickedRemovedIDs
                            ) {
                                vm.selectedRemovedID = group.id
                            }
                            .id("removed:" + group.id)
                        }
                        if !hidden.isEmpty {
                            moreRemovedButton(count: hidden.count, bytes: hidden.reduce(0) { $0 + $1.totalSizeBytes })
                        }
                        if !tickedRemoved.isEmpty {
                            tickedBar(tickedRemoved)
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

    /// "REMOVED APPS · 12 · 3.0 GB" with "Select sure matches" on the right.
    private var removedHeader: some View {
        let groups = state.orphanedGroups
        let sure = RemovedApps.sureItemIDs(in: filteredRemoved)
        return HStack(spacing: 8) {
            Text("REMOVED APPS · \(groups.count) · \(FileSizeHelper.formatBytes(state.totalOrphanedAppDataBytes))")
                .font(Theme.sectionLabel)
                .tracking(0.4)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button("Select sure matches") {
                // Ticks only confident matches; a possible match is never ticked here.
                vm.tickedRemovedIDs.formUnion(sure)
                vm.autoTickedIDs.formUnion(sure)
                vm.showAllRemoved = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(sure.isEmpty ? Theme.inkTertiary : Theme.sweep)
            .disabled(sure.isEmpty)
            .help(sure.isEmpty ? "Nothing to tick: no sure match with data the app rebuilds. Tick folders yourself if you're sure."
                               : "Ticks caches, logs and other data apps rebuild, from removed apps Furl matched by ID. Possible matches and folders that may hold documents stay unticked.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(Theme.surfaceSubtle)
    }

    /// AppsOneList v90: "3 removed apps ticked · 2.3 GB" with Add to Tray and Move to Trash, the route
    /// to the several-apps confirm. Only shows while something in the group is ticked.
    private func tickedBar(_ picks: [(group: OrphanedAppDataGroup, items: [AppDataItem])]) -> some View {
        let bytes = picks.flatMap(\.items).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = FileSizeHelper.formatBytes(bytes)
        return VStack(alignment: .leading, spacing: 8) {
            (Text(RemovedApps.tickedSummary(appCount: picks.count)).foregroundColor(Theme.ink).fontWeight(.semibold)
             + Text(" · \(size)").foregroundColor(Theme.inkSecondary))
                .font(Theme.caption)
                .monospacedDigit()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AddToTrayButton(count: picks.count, height: 28) { addToTray(picks) }
                    .fixedSize()
                    .disabled(state.isCleaning)
                Button {
                    confirmTrashRemoved(picks)
                } label: {
                    Text(toTrash ? "Move \(size) to Trash" : "Delete \(size)").monospacedDigit()
                }
                .buttonStyle(SweepButtonStyle(kind: toTrash ? .primary : .danger, height: 28))
                .fixedSize()
                .disabled(state.isCleaning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.surfaceSubtle)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func moreRemovedButton(count: Int, bytes: Int64) -> some View {
        Button {
            vm.showAllRemoved = true
        } label: {
            Text("\(count) more removed \(count == 1 ? "app" : "apps"), \(FileSizeHelper.formatBytes(bytes))")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.sweep)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 40)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.surfaceSubtle)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityHint("Shows every removed app")
    }
}

// MARK: - Removed apps

/// One removed app in the list: a checkbox for all its folders, then a button that opens its folders.
private struct RemovedAppRow: View {
    let group: OrphanedAppDataGroup
    let isSelected: Bool
    @Binding var ticked: Set<String>
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let ids = group.items.map(\.id)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !ids.isEmpty && ids.allSatisfy(ticked.contains) },
                set: { checked in
                    if checked { ticked.formUnion(ids) } else { ticked.subtract(ids) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.furlCheckbox)
            .accessibilityLabel("Include \(group.shownName)")
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(group.shownName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !group.isSureMatch {
                                BadgeView(text: "Possible match", color: Theme.warning,
                                          help: "This is Furl\u{2019}s best guess. Check that no app you still use needs it.")
                                    .fixedSize()
                            }
                        }
                        Text(RemovedApps.rowSubtitle(group))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(FileSizeHelper.formatBytes(group.totalSizeBytes))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("Shows its folders")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.mintTint : (hovering ? Theme.hairline : Theme.surfaceSubtle))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onHover { hovering = $0 }
        .help(group.appIdentifier)
    }
}

/// Right-hand panel for a removed app: what's left, each folder with a checkbox, Tray and Trash.
private struct RemovedAppDetail: View {
    let group: OrphanedAppDataGroup
    @Binding var ticked: Set<String>
    let deletionMode: DeletionMode
    let tickedCount: Int
    let tickedBytes: Int64
    let isBusy: Bool
    let onAddToTray: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(group.shownName) · \(FileSizeHelper.formatBytes(group.totalSizeBytes)) left behind")
                .font(Theme.display(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(intro)
                .font(Theme.body)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        folderRow(item)
                    }
                }
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var intro: String {
        let name = group.shownName
        if group.isSureMatch {
            let when = group.latestModified.map { " It was last used \(RemovedApps.relative($0))." } ?? ""
            return "\(name) isn\u{2019}t installed.\(when) These folders match its ID, and Furl found no installed app that uses them."
        }
        return "This is Furl\u{2019}s best guess. The name only partly matches, so check that no app you still use needs it."
    }

    private func folderRow(_ item: AppDataItem) -> some View {
        HStack(spacing: 10) {
            SelectionCheckbox(id: item.id, selection: $ticked)
                .accessibilityLabel("Include \(item.location.rawValue)")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.location.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(item.path.abbreviatingHome)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.path)
            // WhySafe board: chip and Why? on every removable row.
            RiskChip(tier: WhySafe.leftoverTier(item))
            WhyButton(explanation: WhySafe.leftover(item, group: group, deletionMode: deletionMode))
            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Button {
                DeletionService.revealInFinder(item.path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .pathContextMenu(item.path, allowOpen: false)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            AddToTrayButton(count: tickedCount, height: 34, action: onAddToTray)
                .fixedSize()
                .disabled(tickedCount == 0 || isBusy)
            Button(action: onTrash) {
                Text(trashTitle).monospacedDigit()
            }
            .buttonStyle(SweepButtonStyle(kind: deletionMode == .moveToTrash ? .primary : .danger, height: 34))
            .fixedSize()
            .disabled(tickedCount == 0 || isBusy)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var trashTitle: String {
        // Moves only this app's ticked folders; the bar under the group handles several apps.
        let size = tickedBytes > 0 ? " \(FileSizeHelper.formatBytes(tickedBytes))" : ""
        return deletionMode == .moveToTrash ? "Move\(size) to Trash" : "Delete\(size)"
    }
}

/// AppsOneList confirms, drawn as a macOS alert: app icon, title, one line on where it goes, every
/// folder or app with its size, then full-width buttons with Cancel as the default, so Return never
/// moves or deletes anything.
private struct RemovedAppsConfirmSheet: View {
    let confirm: RemovedApps.Confirm
    var secondaryTitle: String? = nil
    var onSecondary: () -> Void = {}
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text(confirm.title)
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(confirm.message)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            list
            VStack(spacing: 8) {
                Button(action: onConfirm) {
                    Text(confirm.button).monospacedDigit().frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color(nsColor: .systemRed))
                if let secondaryTitle {
                    Button(action: onSecondary) {
                        Text(secondaryTitle).monospacedDigit().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.top, 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: 270)
        .onExitCommand(perform: onCancel)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(confirm.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(line.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = line.detail {
                                // Folder kinds wrap; they're never cut off.
                                Text(detail)
                                    .opacity(0.75)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(FileSizeHelper.formatBytes(line.bytes))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .help(line.name)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

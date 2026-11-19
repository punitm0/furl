import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI

// MARK: - Filters

private enum VerdictTab: String, CaseIterable, Identifiable {
    case junk = "Likely useless"
    case maybe = "Maybe"
    case keep = "Keep"
    case all = "All"

    var id: String { rawValue }

    func matches(_ label: SmartLabel) -> Bool {
        switch self {
        case .junk: return label == .junk
        case .maybe: return label == .maybe
        case .keep: return label == .keep
        case .all: return true
        }
    }
}

/// What kind of clutter a file is, for the filter chips under the tabs.
private enum ClutterKind: String, CaseIterable, Identifiable {
    case installers = "Installers"
    case archives = "Archives"
    case recordings = "Recordings"
    case copies = "Copies"
    case downloads = "Unfinished downloads"
    case logs = "Logs & backups"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .installers: return "shippingbox"
        case .archives: return "doc.zipper"
        case .recordings: return "record.circle"
        case .copies: return "doc.on.doc"
        case .downloads: return "arrow.down.circle.dotted"
        case .logs: return "doc.text"
        }
    }

    func matches(_ item: SmartReviewItem) -> Bool {
        let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        let name = item.name.lowercased()
        switch self {
        case .installers: return ["dmg", "pkg", "mpkg", "iso"].contains(ext)
        case .archives: return ["zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2"].contains(ext)
        case .recordings:
            return name.hasPrefix("screen recording") || name.hasPrefix("screenshot")
                || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
        case .copies: return item.signals.contains { $0.localizedCaseInsensitiveContains("duplicate copy") }
        case .downloads: return item.signals.contains { $0.localizedCaseInsensitiveContains("unfinished") }
        case .logs: return ext == "log" || ext == "bak" || ext == "trace" || name.hasSuffix("~")
        }
    }
}

@MainActor
private final class SmartReviewViewModel: ObservableObject {
    @Published var tab: VerdictTab = .junk
    /// Set once the user clicks a tab, so automatic tab changes leave their choice alone for this visit.
    @Published var userPickedTab = false
    @Published var kind: ClutterKind?
    @Published var sortOrder: SortOrder = .sizeDescending
    @Published var searchText = ""
    @Published var showConfirmDialog = false
    @Published var focusedID: String?
    /// Status re-checked while the screen is open, so turning Apple Intelligence on or finishing the model
    /// download is picked up without a restart. nil until the first re-check.
    @Published var liveStatus: SmartModelStatus?
}

// MARK: - View

struct SmartReviewView: View {
    @ObservedObject var state: AppState
    @StateObject private var vm = SmartReviewViewModel()
    /// Banner reasons the user closed, comma-separated `SmartModelStatus.Reason` raw values.
    @AppStorage("smartReviewDismissedModelBanners") private var dismissedBannersRaw = ""

    private var modelStatus: SmartModelStatus { vm.liveStatus ?? state.smartModelStatus }

    private var tabItems: [SmartReviewItem] {
        state.smartItems.filter { item in
            vm.tab.matches(item.verdict.label)
                && (vm.searchText.isEmpty
                    || item.name.localizedCaseInsensitiveContains(vm.searchText)
                    || item.path.localizedCaseInsensitiveContains(vm.searchText)
                    || item.verdict.reason.localizedCaseInsensitiveContains(vm.searchText))
        }
    }

    private var filteredItems: [SmartReviewItem] {
        tabItems
            .filter { vm.kind?.matches($0) ?? true }
            .sorted { lhs, rhs in
                vm.sortOrder.areInIncreasingOrder(
                    lhsSize: lhs.sizeBytes, rhsSize: rhs.sizeBytes,
                    lhsName: lhs.name, rhsName: rhs.name,
                    lhsDate: lhs.lastOpenedDate ?? lhs.modifiedDate, rhsDate: rhs.lastOpenedDate ?? rhs.modifiedDate
                )
            }
    }

    private var selectedItems: [SmartReviewItem] {
        state.smartItems.filter { state.selectedSmartIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var focusedItem: SmartReviewItem? {
        let items = filteredItems
        if let id = vm.focusedID, let item = items.first(where: { $0.id == id }) { return item }
        return items.first
    }

    private func count(_ label: SmartLabel) -> Int {
        state.smartItems.filter { $0.verdict.label == label }.count
    }

    /// Scanning or relabelling with the model; counts are still moving.
    private var isBusy: Bool { state.isScanningSmart || state.isReviewingSmart }

    /// Lands on a tab that has something in it, unless the user picked a tab this visit. Likely useless
    /// is the default; when it's empty but other tabs aren't, show All. While counts are still moving
    /// it only steps off an empty tab, so the list doesn't jump back and forth mid-scan.
    private func settleTab() {
        guard !vm.userPickedTab, !state.smartItems.isEmpty else { return }
        if count(.junk) == 0 { vm.tab = .all }
        else if !isBusy { vm.tab = .junk }
    }

    /// The tab picker's binding: a click counts as the user's choice.
    private var userTabSelection: Binding<VerdictTab> {
        Binding(get: { vm.tab }, set: { vm.userPickedTab = true; vm.tab = $0 })
    }

    private var usedModel: Bool {
        state.smartItems.contains { $0.verdict.source == .model }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            modelBanner
            reviewProgress

            LiveScanStripSlot(status: state.liveScans[.smartReview], onStop: { state.cancelSmartReview() },
                              onRescan: { Task { await state.scanSmartReview() } })

            if state.isScanningSmart && state.smartItems.isEmpty {
                VStack(spacing: 12) {
                    ScanningPlaceholder(message: "Looking through your files… \(state.smartScannedCount.formatted()) checked",
                                        status: state.liveScans[.smartReview])
                    CancelRunButton(title: "Stop review") { state.cancelSmartReview() }
                        .padding(.bottom, 40)
                }
            } else if !state.hasScannedSmart && !state.isScanningSmart {
                intro
            } else {
                // The list needs 380 pt beside the 320 pt details column, which still fits the
                // smallest window. When the cleanup tray narrows the page below that, the pair
                // overflowed both edges of the window; the list then takes the whole width and the
                // details column steps aside.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        resultsList
                            .frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity)
                        inspector
                            .frame(width: 320)
                            .frame(maxHeight: .infinity)
                            .background(Theme.surface)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                    }
                    resultsList
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
        }
        .cleanSlateScreen()
        .navigationTitle("Smart Review")
        .searchable(text: $vm.searchText, prompt: "Filter by name, path or reason")
        .task(id: modelStatus.unavailableReason?.mayResolveSoon == true) {
            await watchModelStatus()
        }
        .onAppear { settleTab() }
        .onChange(of: isBusy) { _, _ in settleTab() }
        .onChange(of: count(.junk)) { _, _ in settleTab() }
        .onChange(of: state.smartItems.isEmpty) { _, _ in settleTab() }
        .confirmationDialog(
            "Remove \(selectedItems.count) file\(selectedItems.count == 1 ? "" : "s")?",
            isPresented: $vm.showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(selectedBytes)))", role: .destructive) {
                Task { await state.cleanSelectedSmartItems() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let keepCount = selectedItems.filter { $0.verdict.label == .keep }.count
            Text((keepCount > 0 ? "\(keepCount) of these were labelled Keep. " : "")
                 + (state.deletionMode == .moveToTrash
                    ? "Files will be moved to the Trash, and you can undo."
                    : "Files will be permanently deleted and can't be recovered."))
        }
    }

    // MARK: Model status

    /// While the model is getting ready (or Apple Intelligence is off), re-check every few seconds.
    /// When it becomes available after a rules-only scan, rescan so the AI pass runs by itself.
    private func watchModelStatus() async {
        while !Task.isCancelled, modelStatus.unavailableReason?.mayResolveSoon == true {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let fresh = SmartReviewModel.status()
            guard fresh != modelStatus else { continue }
            vm.liveStatus = fresh
            if fresh == .available, state.smartUseModel, state.hasScannedSmart, !usedModel,
               !state.isScanningSmart, !state.isReviewingSmart {
                await state.scanSmartReview()
            }
        }
    }

    private var dismissedBanners: Set<String> {
        Set(dismissedBannersRaw.split(separator: ",").map(String.init))
    }

    private func dismissBanner(_ reason: SmartModelStatus.Reason) {
        dismissedBannersRaw = (dismissedBanners.union([reason.rawValue])).sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var modelBanner: some View {
        if state.smartUseModel, !state.isReviewingSmart,
           let reason = modelStatus.unavailableReason,
           !dismissedBanners.contains(reason.rawValue) {
            ModelUnavailableBanner(reason: reason) { dismissBanner(reason) }
                .padding(.horizontal, 24)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var reviewProgress: some View {
        if state.isReviewingSmart {
            HStack(spacing: 10) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.violet)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Intelligence is double-checking the top suggestions… \(state.smartReviewedCount) of \(state.smartReviewTotal)")
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                    // SmartReviewStates2: 4pt violet bar on violet at 18%.
                    MeterBar(fraction: Double(state.smartReviewedCount) / Double(max(state.smartReviewTotal, 1)),
                             color: Theme.violet, track: Theme.violet.opacity(0.18), height: 4)
                }
                Button("Stop") { state.cancelSmartReview() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Theme.violetTint)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    // MARK: Header & filters

    /// Same frame as ScreenHeader (64pt, page padding, bottom hairline); the subtitle carries a lock
    /// icon once results exist (SmartReview board) and reads "Not run yet" before the first run.
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Smart Review")
                        .font(Theme.pageTitle)
                        .tracking(-0.3)
                        .foregroundStyle(Theme.ink)
                    BadgeView(text: "Experimental", color: Theme.violet,
                              help: "New and still learning. Check each file before you move it to the Trash.")
                }
                Group {
                    if !state.hasScannedSmart && !state.isScanningSmart {
                        Text("Not run yet")
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "lock")
                                .font(.system(size: 10, weight: .semibold))
                            Text(usedModel
                                 ? "Checked on this Mac with Apple Intelligence. Only names, sizes and dates are used, never file contents."
                                 : "Checked on this Mac. Only names, sizes and dates are used, never file contents.")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .font(Theme.pageSubtitle)
                .foregroundStyle(Theme.inkSecondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if (state.hasScannedSmart || state.isScanningSmart) && !state.smartItems.isEmpty {
                PillTabs(tabs: [VerdictTab.junk, .maybe, .keep, .all], selection: userTabSelection) { tab in
                    switch tab {
                    case .junk: return "Likely useless · \(count(.junk))"
                    case .maybe: return "Maybe · \(count(.maybe))"
                    case .keep: return "Keep · \(count(.keep))"
                    case .all: return "All"
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .frame(minHeight: 64)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .anchorPreference(key: ScreenHeaderBoundsKey.self, value: .bounds) { $0 }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ClutterKind.allCases) { kind in
                        let n = tabItems.filter { kind.matches($0) }.count
                        if n > 0 || vm.kind == kind {
                            chip(kind, count: n)
                        }
                    }
                }
            }

            if !state.smartIgnoredPaths.isEmpty {
                Button("Show \(state.smartIgnoredPaths.count) hidden") {
                    state.resetSmartIgnoredPaths()
                    Task { await state.scanSmartReview() }
                }
                .buttonStyle(SweepLinkStyle())
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .disabled(state.isReviewingSmart)
                .help("Files you marked Not useless are hidden. Show them again and rescan.")
            }

            Menu {
                Picker("Sort", selection: $vm.sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Use Apple Intelligence", isOn: $state.smartUseModel)
            } label: {
                // SmartReviewStates2: plain icon + 12pt label, no chip or chevron.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text(vm.sortOrder.rawValue)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.ink)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort, and whether Apple's on-device model double-checks the top suggestions")

            Button {
                Task { await state.scanSmartReview() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ToolbarButtonStyle())
            .fixedSize()
            .disabled(state.isScanningSmart || state.isReviewingSmart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            filterBar
            list
            actionBar
        }
    }

    /// Filter chip from the SmartReview board: 32pt, 8pt corners, outlined, label only.
    private func chip(_ kind: ClutterKind, count: Int) -> some View {
        let on = vm.kind == kind
        return Button {
            vm.kind = on ? nil : kind
        } label: {
            Text(kind.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(on ? Theme.mintTint : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(on ? Theme.sweep : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(count) in this tab")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// First run (SmartReviewFirst board): what it looks for, what it never touches, and that
    /// nothing moves until the user chooses, before they press Start.
    private var intro: some View {
        ScrollView {
            // SmartReviewStates2 intro: one column, 10pt between every element.
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.sweep)
                    .frame(width: 44, height: 44)
                    .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Find files you probably don't need")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.ink)
                Text("Checks every file in your home folder by its name, size and dates. Never the contents. Usually 1 to 3 minutes.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                introGroup("Looks for", items: [
                    ("shippingbox", "Installers for apps you have"),
                    ("doc.zipper", "Archives already unzipped"),
                    ("circle.lefthalf.filled", "Unfinished downloads"),
                    ("arrow.down.to.line", "Downloads never opened"),
                    ("photo", "Old screenshots & recordings"),
                    ("doc.on.doc", "Copies like “(1)” and “copy”"),
                    ("doc.text", "Logs & backups"),
                    ("clock", "Untouched for 6+ months"),
                ], filled: true)
                introGroup("Leaves alone", items: [
                    ("nosign", "~/Library"),
                    ("nosign", "Photos library"),
                    ("nosign", "Music"),
                    ("nosign", "Applications"),
                    ("nosign", "Trash"),
                    ("nosign", "Code projects"),
                ], filled: false, footnote: "Code projects are covered by Caches & Junk and Git Worktrees instead.")

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.sweepDeep)
                        (Text("Read-only: nothing moves until you choose.").fontWeight(.semibold).foregroundColor(Theme.sweepDeep)
                         + Text(" You review every pick before anything goes to the Trash."))
                    }
                    modelStatusLine
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

                HStack(spacing: 8) {
                    Button("Start Smart Review") {
                        Task { await state.scanSmartReview() }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 38))
                    .fixedSize()
                    Spacer(minLength: 0)
                    (Text("Scope: ") + Text("Home folder").fontWeight(.semibold).foregroundColor(Theme.ink))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }

    @ViewBuilder
    private var modelStatusLine: some View {
        if state.smartModelStatus == .available && state.smartUseModel {
            HStack(spacing: 6) {
                Circle().fill(Theme.freeableBar).frame(width: 8, height: 8)
                    .padding(.horizontal, 2.5)
                Text("Apple Intelligence is on.").fontWeight(.semibold).foregroundColor(Theme.ink)
                    + Text(" It double-checks the top picks and explains each one, on this Mac.")
            }
        } else {
            HStack(spacing: 6) {
                Circle().strokeBorder(Theme.freeableBar, lineWidth: 1.5).frame(width: 8, height: 8)
                    .padding(.horizontal, 2.5)
                Text("Apple Intelligence is off.").fontWeight(.semibold).foregroundColor(Theme.ink)
                    + Text(" You still get every pick with its reason, from rules alone.")
                if state.smartModelStatus == .available {
                    Button("Turn it on") { state.smartUseModel = true }
                        .buttonStyle(SweepLinkStyle())
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func introGroup(_ title: String, items: [(String, String)], filled: Bool, footnote: String? = nil) -> some View {
        SectionLabel(text: title)
        FlowChips(items: items, filled: filled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        if let footnote {
            Text(footnote)
                .font(Theme.micro)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let items = filteredItems
        if items.isEmpty {
            EmptyStatePlaceholder(
                systemImage: "checkmark.seal",
                title: state.smartItems.isEmpty ? "Nothing Looks Useless" : "No Matches",
                message: state.smartItems.isEmpty
                    ? "No files in your home folder look like clutter right now."
                    : "Try another tab, filter or search."
            )
        } else {
            // SmartReview board: each file is its own outlined card, the focused one ringed in Sweep.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            SmartReviewRow(item: item, selection: $state.selectedSmartIDs,
                                           isFocused: item.id == focusedItem?.id)
                                .id(item.id)
                                .onTapGesture(count: 2) { DeletionService.revealInFinder(item.path) }
                                .onTapGesture { vm.focusedID = item.id }
                                .contextMenu { rowMenu(item) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                .onChange(of: vm.tab) { _, _ in
                    if let id = filteredItems.first?.id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: SmartReviewItem) -> some View {
        Button {
            DeletionService.revealInFinder(item.path)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Button {
            DeletionService.open(item.path)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        Button {
            DeletionService.copyPath(item.path)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            state.ignoreSmartItems([item.id])
        } label: {
            Label("Not Useless — Don't Suggest Again", systemImage: "hand.raised")
        }
    }

    private var actionBar: some View {
        let visible = filteredItems
        let allVisibleSelected = !visible.isEmpty && visible.allSatisfy { state.selectedSmartIDs.contains($0.id) }
        return HStack(spacing: 12) {
            (Text("\(selectedItems.count) of \(state.smartItems.count) selected")
                .fontWeight(.bold)
                .foregroundColor(Theme.ink)
            + Text(selectedItems.isEmpty ? "" : " · \(FileSizeHelper.formatBytes(selectedBytes))")
                .foregroundColor(Theme.inkTertiary))
                .font(Theme.body)
                .monospacedDigit()
                .lineLimit(1)

            Spacer()

            if allVisibleSelected {
                Button("Select none") { state.selectedSmartIDs.subtract(visible.map(\.id)) }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36))
                    .fixedSize()
            } else {
                Button("Select all \(visible.count)") { state.selectedSmartIDs.formUnion(visible.map(\.id)) }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36))
                    .fixedSize()
                    .disabled(visible.isEmpty)
            }

            if count(.junk) > 0 && vm.tab != .junk {
                Button("Select likely useless") { state.selectLikelyUselessSmartItems() }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .disabled(state.isReviewingSmart)
            }

            AddToTrayButton(count: selectedItems.count) {
                CleanupTray.shared.add(selectedItems.map(TrayItem.smart))
            }

            Button {
                vm.showConfirmDialog = true
            } label: {
                if state.isCleaning {
                    ProgressView().controlSize(.small)
                } else if selectedItems.isEmpty {
                    Text(state.deletionMode == .moveToTrash ? "Move to Trash" : "Delete")
                } else {
                    Text(state.deletionMode == .moveToTrash
                         ? "Move \(FileSizeHelper.formatBytes(selectedBytes)) to Trash"
                         : "Delete \(FileSizeHelper.formatBytes(selectedBytes))")
                }
            }
            .buttonStyle(SweepButtonStyle(kind: state.deletionMode == .permanent ? .danger : .primary, height: 36))
            .fixedSize()
            .disabled(selectedItems.isEmpty || state.isCleaning)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let item = focusedItem {
            SmartReviewInspector(item: item) {
                state.ignoreSmartItems([item.id])
            }
            .id(item.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.inkSecondary)
                Text("Select a file to see why it was flagged.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Shared bits

private func color(for label: SmartLabel) -> Color {
    switch label {
    case .junk: return Theme.sweep
    case .maybe: return Theme.warning
    case .keep: return Theme.memory
    }
}

private func extensionTag(for item: SmartReviewItem) -> String {
    let ext = URL(fileURLWithPath: item.path).pathExtension.uppercased()
    if ext.isEmpty { return "FILE" }
    if ["CRDOWNLOAD", "PART", "PARTIAL", "DOWNLOAD", "OPDOWNLOAD"].contains(ext) { return "PART" }
    return String(ext.prefix(4))
}

// MARK: - Row

private struct SmartReviewRow: View {
    let item: SmartReviewItem
    @Binding var selection: Set<String>
    var isFocused = false

    var body: some View {
        let tag = extensionTag(for: item)
        HStack(spacing: 10) {
            SelectionCheckbox(id: item.id, selection: $selection)
                .frame(width: 22)

            Text(tag)
                .font(.system(size: tag.count > 3 ? 9 : 10, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 36, height: 36)
                .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.verdict.source == .model {
                        Image(systemName: "apple.intelligence")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.violet)
                            .help("Double-checked by Apple Intelligence")
                    }
                }
                HStack(spacing: 4) {
                    ForEach(evidence, id: \.self) { tag in
                        Text(tag)
                            .font(Theme.micro)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(Theme.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Theme.sweep : Theme.border, lineWidth: isFocused ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(item.verdict.reason)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    /// Up to two short facts for the row: the strongest rule signals, or when it was last opened.
    private var evidence: [String] {
        var tags = Array(item.signals.filter { $0 != "In Downloads" && $0 != "Loose on the Desktop" }.prefix(2))
        if tags.count < 2 {
            if let opened = item.lastOpenedDate {
                tags.append("Opened \(opened.relativeDescription)")
            } else {
                tags.append("Never opened")
            }
        }
        return tags
    }
}

// MARK: - Inspector

private struct SmartReviewInspector: View {
    let item: SmartReviewItem
    let onNotUseless: () -> Void

    private var ruleLabel: SmartLabel {
        SmartReviewScanner.ruleVerdict(score: item.ruleScore, signals: item.signals).label
    }

    private var agreement: String {
        guard item.verdict.source == .model else { return "From Furl's rules · \(item.verdict.confidence)%" }
        if ruleLabel == item.verdict.label { return "Rules and AI agree · \(item.verdict.confidence)%" }
        return "AI says \(item.verdict.label.rawValue), rules said \(ruleLabel.rawValue)"
    }

    private var metaLine: String {
        var parts = [item.displayFolder, FileSizeHelper.formatBytes(item.sizeBytes)]
        if let source = item.downloadedFrom { parts.append("downloaded from \(source)") }
        return parts.joined(separator: " · ")
    }

    private var why: [String] {
        var lines: [String] = []
        // The model's reason often just restates rule signals ("A; B"); only show it when it adds something.
        if item.verdict.source == .model {
            let parts = item.verdict.reason.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }
            if !parts.allSatisfy({ item.signals.contains($0) }) { lines.append(item.verdict.reason) }
        }
        lines += item.signals
        if let opened = item.lastOpenedDate {
            lines.append("Last opened \(opened.formatted(date: .abbreviated, time: .omitted))")
        } else if !item.signals.contains(where: { $0.localizedCaseInsensitiveContains("never opened") }) {
            lines.append("Last opened never")
        }
        if let created = item.createdDate {
            lines.append("Added \(created.formatted(date: .abbreviated, time: .omitted))")
        }
        return lines
    }

    /// SmartReviewStates2 inspector: one column, 8pt between elements, buttons stacked full width.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    QuickLookThumbnail(path: item.path, tag: extensionTag(for: item))
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Text(metaLine)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(3)
                    }

                    HStack(spacing: 8) {
                        Text(item.verdict.label.rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(Theme.onSweep)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(color(for: item.verdict.label), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(agreement)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Why")
                        ForEach(why, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.sweep)
                                    .frame(width: 11)
                                Text(line)
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)

            VStack(spacing: 8) {
                Button("Show in Finder") {
                    DeletionService.revealInFinder(item.path)
                }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36, fullWidth: true))
                Button("Not useless", action: onNotUseless)
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36, fullWidth: true))
                    .help("Hide this file from Smart Review for good")
            }
        }
        .padding(20)
    }
}

// MARK: - Quick Look thumbnail

private struct QuickLookThumbnail: View {
    let path: String
    /// Extension tile shown until (or instead of) a Quick Look thumbnail (SmartReviewStates2).
    var tag: String = "FILE"
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
            } else {
                Text(tag)
                    .font(.system(size: tag.count > 3 ? 9 : 10, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 36, height: 36)
                    .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .task(id: path) {
            image = await Self.thumbnail(for: path)
        }
        .accessibilityLabel("Quick Look preview")
    }

    private static func thumbnail(for path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 260, height: 150),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return representation.nsImage
    }
}

// MARK: - Unavailable banner

/// Explains why Smart Review is using rules only and what the user can do about it.
private struct ModelUnavailableBanner: View {
    let reason: SmartModelStatus.Reason
    let onDismiss: () -> Void

    private static let appleIntelligenceSettings = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
    private static let softwareUpdate = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    /// Apple's "How to get Apple Intelligence" page: supported Macs, languages and regions.
    private static let requirements = URL(string: "https://support.apple.com/en-us/121115")!

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    private var title: String {
        switch reason {
        case .appleIntelligenceNotEnabled: return "Using rules only: Apple Intelligence is turned off"
        case .deviceNotEligible: return "Using rules only: this Mac can't run Apple Intelligence"
        case .osTooOld: return "Using rules only: update to macOS 26 to use AI review"
        case .modelNotReady: return "Using rules for now: the model is still downloading"
        case .unsupportedLanguage: return "Using rules only: not available in your language yet"
        case .other: return "Using rules only: the on-device model isn't available right now"
        }
    }

    private var message: String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "You'll still see suggestions, each with a reason. Turn it on for a second check that catches more and makes fewer mistakes."
        case .deviceNotEligible:
            return "Intel Macs can't run it. Smart Review uses rules only, and fewer files are marked Likely Useless."
        case .osTooOld:
            return "You're on macOS \(osVersion). The on-device model needs macOS 26 or later. Until then, rules only."
        case .modelNotReady:
            return "macOS is downloading the model. Results update by themselves when it's ready."
        case .unsupportedLanguage:
            return "Apple Intelligence isn't offered for your device language or region yet. Rules only for now."
        case .other:
            return "You'll still see suggestions, each with a reason. Furl checks again on the next scan."
        }
    }

    /// SmartReviewStates board: a card with an amber tile, title, one-line reason, action and dismiss.
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: reason == .modelNotReady ? "arrow.down.circle" : "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.warning)
                .frame(width: 36, height: 36)
                .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this message")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var action: some View {
        switch reason {
        case .appleIntelligenceNotEnabled, .other:
            Button("Open Settings") { NSWorkspace.shared.open(Self.appleIntelligenceSettings) }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 34))
                .fixedSize()
        case .deviceNotEligible:
            Button("Which Macs are supported?") { NSWorkspace.shared.open(Self.requirements) }
                .buttonStyle(SweepLinkStyle())
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        case .osTooOld:
            Button("Open Software Update") { NSWorkspace.shared.open(Self.softwareUpdate) }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 34))
                .fixedSize()
        case .unsupportedLanguage:
            Button("See supported languages") { NSWorkspace.shared.open(Self.requirements) }
                .buttonStyle(SweepLinkStyle())
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        case .modelNotReady:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Getting ready…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}


/// Wrapping row of small icon chips (SmartReviewFirst board): mint-filled for what Smart Review
/// looks for, outlined grey for what it leaves alone.
private struct FlowChips: View {
    let items: [(String, String)]
    let filled: Bool

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.1) { item in
                HStack(spacing: 5) {
                    // SmartReviewStates2: "Looks for" chips are text only; "Leaves alone" keep the icon.
                    if !filled {
                        Image(systemName: item.0)
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(item.1)
                        .font(.system(size: 12, weight: filled ? .medium : .regular))
                }
                .foregroundStyle(filled ? Theme.sweepDeep : Theme.inkSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(filled ? Theme.mintTint : Color.clear, in: Capsule())
                .overlay {
                    if !filled { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
                }
            }
        }
    }
}

/// Minimal flow layout: places subviews left to right, wrapping to new lines.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

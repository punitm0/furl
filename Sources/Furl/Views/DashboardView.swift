import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var processes = ProcessesStore.shared
    @State private var confirmEmptyTrash = false
    /// When the last scan area finished (or the scan started); drives the smooth progress.
    @State private var scanStepDate = Date()
    /// Redrawn ~8×/s while scanning so progress and the "Checking…" line keep moving.
    @State private var scanNow = Date()
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var snapshots = SnapshotsModel.shared
    @ObservedObject private var fullDiskAccess = FullDiskAccess.shared
    @ObservedObject private var autoSweep = AppServices.autoSweep

    var body: some View {
        VStack(spacing: 0) {
            header
            if fullDiskAccess.showsUpdateBanner, let version = fullDiskAccess.currentVersion {
                updatedBanner(version: version)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroPanel
                    StorageBreakdownCard(state: state)
                    if !state.hasScannedAnything && !state.isScanningAny {
                        firstRunCard
                    }
                    categoryGrid
                    smartPicksSection
                    trashCard
                    if state.hasDiscoveredProjects && state.projectRoots.isEmpty {
                        noProjectsHint
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .cleanSlateScreen()
        .navigationTitle("Overview")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess.refresh()
        }
        .confirmationDialog(
            "Empty the Trash?",
            isPresented: $confirmEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash (\(FileSizeHelper.formatBytes(state.trashSizeBytes)))", role: .destructive) {
                Task { await state.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash will be permanently deleted. This can't be undone.")
        }
    }

    // MARK: - Header

    private var headerSubtitle: String {
        if state.isScanningAny { return "Scanning your Mac…" }
        if let lastScan = state.lastScanDate { return "Scanned \(lastScan.relativeDescription)" }
        return "Find merged Git worktrees, stale caches, app leftovers and large files."
    }

    private var header: some View {
        ScreenHeader(title: "Overview", subtitle: headerSubtitle) {
            weekGrowthHint
            ViewThatFits(in: .horizontal) {
                PrivacyBadge()
                PrivacyBadge(compact: true)
                EmptyView()
            }
            Button {
                Task { await state.scanAll() }
            } label: {
                HStack(spacing: 6) {
                    if state.isScanningAny {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text(state.hasScannedAnything ? "Rescan" : "Scan All")
                    }
                }
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary))
            .disabled(state.isScanningAny)
            .help("Scan everything (⌘R)")
        }
    }

    /// One-time banner on the first launch of a new version when Full Disk Access is off
    /// (UpdatePermissions board). Mint, not warning orange: nothing is broken, Furl sees less.
    private func updatedBanner(version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sweep)
            Text("**Furl was updated to \(version).** macOS turned Full Disk Access off for the new version. Turn it on again so sizes stay complete.")
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show Me How") {
                SettingsTab.select(.permissions)
                AppWindows.activateForWindow()
                openSettings()
            }
            .buttonStyle(SweepLinkStyle())
            .font(.system(size: 12, weight: .medium))
            .fixedSize()
            Button {
                DeletionService.openFullDiskAccessSettings()
            } label: {
                ToolbarChipLabel(title: "Open Settings", weight: .medium)
            }
            .buttonStyle(.plain)
            .fixedSize()
            Button {
                fullDiskAccess.dismissUpdateBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.mintTint)
    }

    /// "+X GB this week" from saved snapshots; opens Snapshots › Why is my disk full?
    @ViewBuilder
    private var weekGrowthHint: some View {
        if let growth = snapshots.weekGrowth, growth >= 100_000_000 {
            Button {
                state.selectedSection = .snapshots
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("+\(FileSizeHelper.formatBytes(growth)) this week")
                }
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.warningTint))
            }
            .buttonStyle(.plain)
            .help("Your home folder grew this week. See what grew in Snapshots.")
        }
    }

    // MARK: - Hero

    private var reclaimable: Int64 {
        min(state.totalReclaimableBytes, state.diskUsage.usedBytes)
    }

    /// Which moment of the scan the hero is describing (HeroScanning board).
    private enum HeroPhase { case notScanned, firstScanEmpty, firstScanPartial, rescanning, done }

    private var heroPhase: HeroPhase {
        if state.isScanningAny {
            // Keep showing the last result only if there is a real one: lastScanDate is stamped
            // once a full scan has completed (never for a restarted, partial one), and a zero
            // total is no result worth holding on to. Otherwise show the scanning hero.
            if state.lastScanDate != nil && reclaimable > 0 { return .rescanning }
            return reclaimable > 0 ? .firstScanPartial : .firstScanEmpty
        }
        return state.hasScannedAnything ? .done : .notScanned
    }

    private var scanAreas: (done: Int, total: Int) {
        let running = [state.isScanningWorktrees, state.isScanningJunk, state.isScanningApps,
                       state.isScanningLargeFiles, state.isScanningDuplicates]
        return (running.filter { !$0 }.count, running.count)
    }

    private static let areaNames = ["Git worktrees", "caches & junk", "apps & leftovers", "large files", "duplicates"]

    /// Smooth 0…1 progress: finished areas set the floor, and the current step creeps toward
    /// the next one (never reaching it) so the bar never sits still while work is happening.
    private var scanFraction: Double {
        let areas = scanAreas
        guard areas.total > 0 else { return 0 }
        let t = max(0, scanNow.timeIntervalSince(scanStepDate))
        let creep = 0.92 * (1 - exp(-t / 6))
        return min(0.99, (Double(areas.done) + creep) / Double(areas.total))
    }

    /// "Checking caches & junk…", rotating through the areas still running.
    private var scanActivity: String {
        let running = [state.isScanningWorktrees, state.isScanningJunk, state.isScanningApps,
                       state.isScanningLargeFiles, state.isScanningDuplicates]
        let names = zip(Self.areaNames, running).filter { $0.1 }.map(\.0)
        guard !names.isEmpty else { return "Finishing up…" }
        let i = Int(scanNow.timeIntervalSinceReferenceDate / 2.5) % names.count
        return "Checking \(names[i])…"
    }

    private var heroEyebrow: String {
        let areas = scanAreas
        switch heroPhase {
        case .notScanned: return "See what you can get back"
        case .firstScanEmpty: return "Scanning your Mac · \(areas.done) of \(areas.total) areas"
        case .firstScanPartial: return "Found so far · \(areas.done) of \(areas.total) areas"
        case .rescanning: return "You can get back · updating"
        case .done:
            if reclaimable > 0 { return "You can get back" }
            return "All \(areas.total) areas checked" + (state.lastScanDate.map { " \($0.relativeDescription)" } ?? "")
        }
    }

    private var heroBody: String {
        switch heroPhase {
        case .notScanned:
            return "A full scan only reads. Nothing is moved until you choose."
        case .firstScanEmpty, .firstScanPartial:
            // HeroScanning board: no body line while the first scan runs (partial shows area chips).
            return ""
        case .rescanning:
            if let last = state.lastScanDate { return "Rescanning · last result from \(last.relativeDescription). Clean waits for the new numbers." }
            return "Rescanning. Clean waits for the new numbers."
        case .done:
            if reclaimable > 0 {
                return "Files go to the Trash first, so you can undo with ⌥⌘Z. Files Smart Review isn't sure about are left out."
            }
            // AuditDecisions: "Auto-Sweep checks again {nextRun}" only while Auto-Sweep is on.
            if let next = autoSweep.nextRunDescription {
                return "Your Mac is tidy. Auto-Sweep checks again \(next)."
            }
            return "Your Mac is tidy. Nothing to clean right now."
        }
    }

    private var canFreeLegend: String {
        switch heroPhase {
        case .notScanned: return ""
        case .firstScanEmpty: return "Can free · counting"
        case .firstScanPartial: return "Can free \(FileSizeHelper.formatBytes(reclaimable)) so far"
        case .rescanning, .done:
            return reclaimable > 0 ? "Can free \(FileSizeHelper.formatBytes(reclaimable))" : "Can free nothing"
        }
    }

    private var heroButtonTitle: String {
        switch heroPhase {
        case .firstScanEmpty: return "Scanning…"
        case .firstScanPartial: return "Scanning… \(Int(scanFraction * 100))%"
        case .notScanned: return "Scan All"
        // Rescan keeps the last result on the (disabled) button: Clean waits for the new numbers.
        case .rescanning, .done: return reclaimable > 0 ? "Clean \(FileSizeHelper.formatBytes(reclaimable))" : "Nothing to clean"
        }
    }

    private var heroPanel: some View {
        let disk = state.diskUsage
        let total = Double(max(disk.totalBytes, 1))
        let usedOther = max(0, disk.usedBytes - reclaimable)

        // Main board: padding 28, gap 32 between ring, text and buttons; minimum height 216.
        return HStack(alignment: .center, spacing: 32) {
            DiskRing(
                usedFraction: Double(usedOther) / total,
                freeableFraction: Double(reclaimable) / total,
                centerText: "\(Int((disk.usedFraction * 100).rounded()))%",
                caption: "used today",
                inUseBytes: usedOther,
                freeableBytes: heroPhase == .notScanned || heroPhase == .firstScanEmpty ? nil : reclaimable,
                freeBytes: disk.availableBytes,
                scanning: state.isScanningAny
            )
            .frame(width: 168, height: 168)

            VStack(alignment: .leading, spacing: 10) {
                Text(heroEyebrow)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.pineMuted)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        bigNumber(64)
                        if showsNumber { heroSuffix }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        bigNumber(52)
                        if showsNumber { heroSuffix }
                    }
                }
                if heroPhase == .firstScanEmpty {
                    // HeroScanning board: the number slot's progress, bar over the activity line.
                    VStack(alignment: .leading, spacing: 6) {
                        HeroProgressBar(fraction: scanFraction)
                        Text(scanActivity)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.pineMuted)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: 520)
                } else if state.isScanningAny {
                    // Motion board (as built): 220 pt bar with the activity line beside it.
                    HStack(spacing: 10) {
                        HeroProgressBar(fraction: scanFraction)
                            .frame(maxWidth: 220)
                        Text(scanActivity)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.pineMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if heroPhase == .firstScanPartial {
                    areaChips
                } else if !heroBody.isEmpty {
                    Text(heroBody)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.pineMuted)
                        .lineSpacing(3)
                        .frame(maxWidth: 470, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    heroLegend(.filled(Theme.pineMuted), label: "In use \(FileSizeHelper.formatBytes(usedOther))")
                    if heroPhase != .notScanned {
                        heroLegend(heroPhase == .firstScanEmpty ? .dashed(Theme.mint) : .filled(Theme.mint), label: canFreeLegend)
                    }
                    heroLegend(.outline, label: "Free \(FileSizeHelper.formatBytes(disk.availableBytes))")
                }
                .padding(.top, 4)
            }
            // The figure changes width as it counts; the column takes the space it's given instead.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                // Takes the user to the first category with something selected. A future
                // `AppState.cleanAllSafeItems()` could clean every category's safe items in one
                // pass with a single undo record.
                Button {
                    if heroPhase == .notScanned {
                        Task { await state.scanAll() }
                    } else {
                        state.selectedSection = firstCategoryWithSelection
                    }
                } label: {
                    HStack(spacing: 8) {
                        if heroPhase == .firstScanEmpty || heroPhase == .firstScanPartial {
                            HeroSpinner()
                        }
                        Text(heroButtonTitle)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: .heroPrimary, height: 48, fullWidth: true))
                .disabled(heroPhase != .notScanned && (heroPhase != .done || reclaimable == 0 || state.isCleaning))
                .help("Go to the items that are selected for cleaning")

                if heroPhase == .done && reclaimable == 0 {
                    // HeroScanning board, "Done, nothing to free".
                    Button("Rescan") {
                        Task { await state.scanAll() }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 44, fullWidth: true))
                } else {
                    Button("Review items first") {
                        state.selectedSection = .smartReview
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 44, fullWidth: true))
                }
            }
            .frame(width: 210)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(28)
        .frame(minHeight: 216)
        .background(Theme.pine, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(Theme.heroStroke, lineWidth: 1))
        .onChange(of: scanAreas.done) { scanStepDate = Date() }
        .onChange(of: state.isScanningAny) { scanStepDate = Date() }
        .task(id: state.isScanningAny) {
            while state.isScanningAny && !Task.isCancelled {
                scanNow = Date()
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    @ViewBuilder
    private func bigNumber(_ size: CGFloat) -> some View {
        switch heroPhase {
        case .notScanned:
            heroStatusText("Nothing scanned yet")
        case .firstScanEmpty:
            heroStatusText("Looking…")
        case .done where reclaimable == 0:
            heroStatusText("Nothing to clean")
        default:
            reclaimableNumber(size)
        }
    }

    /// Words in the number slot: 34 pt, -0.5 tracking (HeroScanning board), not the 64 pt figure.
    private func heroStatusText(_ text: String) -> some View {
        Text(text)
            .font(Theme.display(34))
            .tracking(-0.5)
            .foregroundStyle(Theme.onPine)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func reclaimableNumber(_ size: CGFloat) -> some View {
        Text(FileSizeHelper.formatBytes(reclaimable))
            .font(Theme.display(size))
            .tracking(-2)
            .foregroundStyle(Theme.mint)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .animation(.easeInOut, value: reclaimable)
    }

    private var showsNumber: Bool {
        switch heroPhase {
        case .firstScanPartial, .rescanning: return true
        case .done: return reclaimable > 0
        case .notScanned, .firstScanEmpty: return false
        }
    }

    private var heroSuffix: some View {
        let memory = processes.leftoverMemoryBytes
        return Group {
            if memory > 0 {
                (Text("of disk, and ").foregroundColor(Theme.onPine)
                 + Text(FileSizeHelper.formatBytes(memory)).bold().foregroundColor(Theme.memoryOnPine)
                 + Text(" of memory").foregroundColor(Theme.onPine))
            } else {
                Text(heroPhase == .firstScanPartial ? "so far" : "of disk").foregroundColor(Theme.onPine)
            }
        }
        .font(.system(size: 15))
    }

    private enum LegendDot {
        case filled(Color)
        /// "Can free · counting": dashed ring (HeroScanning board).
        case dashed(Color)
        /// Free space: hollow ring.
        case outline
    }

    private func heroLegend(_ dot: LegendDot, label: String) -> some View {
        HStack(spacing: 6) {
            switch dot {
            case .filled(let color):
                Circle().fill(color).frame(width: 8, height: 8)
            case .dashed(let color):
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5])).frame(width: 8, height: 8)
            case .outline:
                Circle().strokeBorder(Theme.storageFreeOnPine, lineWidth: 1.5).frame(width: 8, height: 8)
            }
            Text(label).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: 12))
        .foregroundStyle(Theme.pineMuted)
    }

    private struct ScanArea: Identifiable {
        let name: String
        let running: Bool
        var id: String { name }
    }

    /// First scan with results coming in: finished areas filled with a check, the rest outlined.
    private var areaChips: some View {
        let areas = [
            ScanArea(name: "Caches", running: state.isScanningJunk),
            ScanArea(name: "Worktrees", running: state.isScanningWorktrees),
            ScanArea(name: "Apps", running: state.isScanningApps),
            ScanArea(name: "Large files", running: state.isScanningLargeFiles),
            ScanArea(name: "Duplicates", running: state.isScanningDuplicates)
        ]
        return FlowRow(spacing: 6) {
            ForEach(areas) { area in
                HStack(spacing: 4) {
                    if !area.running {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Theme.mint)
                    }
                    Text(area.name)
                }
                .font(.system(size: 11))
                .foregroundStyle(area.running ? Theme.pineMuted : Theme.onPine)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(area.running ? Color.clear : Theme.pineTrack))
                .overlay { if area.running { Capsule().strokeBorder(Theme.pineBorder, lineWidth: 1) } }
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
    }

    /// Category the primary Clean button should open: the first one with items already selected.
    private var firstCategoryWithSelection: SidebarSection {
        if !state.selectedJunkIDs.isEmpty { return .junk }
        if !state.selectedWorktreeIDs.isEmpty { return .worktrees }
        if !state.selectedDuplicateIDs.isEmpty { return .duplicates }
        if !state.orphanedGroups.isEmpty { return .apps }
        return .smartReview
    }

    // MARK: - First run

    private var firstRunCard: some View {
        HStack(spacing: 16) {
            SweepMark(style: .tile)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready when you are")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("A full scan looks through your project folders, ~/Library caches, installed apps and your home folder. Nothing is removed without your confirmation, and by default items go to the Trash.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Start Scan") {
                Task { await state.scanAll() }
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 36))
        }
        .card()
    }

    // MARK: - Category cards

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
            SummaryCard(
                title: "Caches & Junk",
                value: valueText(state.totalJunkReclaimableBytes, scanned: state.hasScannedJunk),
                subtitle: state.hasScannedJunk ? junkSubtitle : "Not scanned yet",
                systemImage: SidebarSection.junk.systemImage,
                tint: Theme.accentTeal.fg,
                tintBackground: Theme.accentTeal.bg,
                isLoading: state.isScanningJunk
            ) {
                state.selectedSection = .junk
            }

            SummaryCard(
                title: "Merged Worktrees",
                value: valueText(state.totalWorktreeReclaimableBytes, scanned: state.hasScannedWorktrees),
                subtitle: state.hasScannedWorktrees ? "\(state.worktrees.filter(\.canAutoSelect).count) worktrees merged or squash-merged" : "Not scanned yet",
                systemImage: SidebarSection.worktrees.systemImage,
                tint: Theme.accentViolet.fg,
                tintBackground: Theme.accentViolet.bg,
                isLoading: state.isScanningWorktrees
            ) {
                state.selectedSection = .worktrees
            }

            SummaryCard(
                title: "Duplicates",
                value: valueText(state.totalDuplicateReclaimableBytes, scanned: state.hasScannedDuplicates),
                subtitle: state.hasScannedDuplicates ? "\(state.duplicateGroups.count) sets of identical files" : "Not scanned yet",
                systemImage: SidebarSection.duplicates.systemImage,
                tint: Theme.accentPink.fg,
                tintBackground: Theme.accentPink.bg,
                isLoading: state.isScanningDuplicates
            ) {
                state.selectedSection = .duplicates
            }

            SummaryCard(
                title: "Apps & Leftovers",
                value: valueText(state.totalOrphanedAppDataBytes, scanned: state.hasScannedApps),
                subtitle: state.hasScannedApps ? "\(state.orphanedGroups.count) uninstalled app leftovers" : "Not scanned yet",
                systemImage: SidebarSection.apps.systemImage,
                tint: Theme.accentBlue.fg,
                tintBackground: Theme.accentBlue.bg,
                isLoading: state.isScanningApps
            ) {
                state.selectedSection = .apps
            }

            SummaryCard(
                title: "Large Files",
                value: valueText(state.totalLargeFilesBytes, scanned: state.hasScannedLargeFiles),
                subtitle: state.hasScannedLargeFiles
                    ? "\(state.largeFiles.count) files over \(FileSizeHelper.formatBytes(state.largeFileThresholdMB * 1_000_000))"
                    : "Not scanned yet",
                systemImage: SidebarSection.largeFiles.systemImage,
                tint: Theme.accentTeal.fg,
                tintBackground: Theme.accentTeal.bg,
                isLoading: state.isScanningLargeFiles
            ) {
                state.selectedSection = .largeFiles
            }

            SummaryCard(
                title: "Space Map",
                value: state.spaceRoot.map { FileSizeHelper.formatBytes($0.sizeBytes) } ?? "Explore",
                subtitle: state.spaceRoot.map { _ in "mapped in \(state.spaceTarget?.name ?? "folder")" } ?? "See which folders use the most space",
                systemImage: SidebarSection.spaceMap.systemImage,
                tint: Theme.accentGreen.fg,
                tintBackground: Theme.accentGreen.bg,
                isLoading: state.isScanningSpace
            ) {
                state.selectedSection = .spaceMap
            }
        }
    }

    /// e.g. "node_modules ×42, DerivedData, Homebrew cache": the biggest item names.
    private var junkSubtitle: String {
        guard !state.junkItems.isEmpty else { return "Nothing found" }
        var counts: [String: Int] = [:]
        var bytes: [String: Int64] = [:]
        for item in state.junkItems {
            counts[item.name, default: 0] += 1
            bytes[item.name, default: 0] += item.sizeBytes
        }
        let top = bytes.sorted { $0.value > $1.value }.prefix(3).map { name, _ in
            let n = counts[name] ?? 1
            return n > 1 ? "\(name) ×\(n)" : name
        }
        return top.joined(separator: ", ")
    }

    private func valueText(_ bytes: Int64, scanned: Bool) -> String {
        scanned ? FileSizeHelper.formatBytes(bytes) : "—"
    }

    // MARK: - Smart Review picks

    private var smartPicks: [SmartReviewItem] {
        state.smartItems
            .filter { $0.verdict.label == .junk }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var smartPicksSection: some View {
        let picks = smartPicks
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sweep)
                Text(picks.isEmpty ? "Smart Review" : "Smart Review thinks these are useless")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if picks.isEmpty {
                    Button(state.hasScannedSmart ? "Open Smart Review" : "Run Smart Review") {
                        state.selectedSection = .smartReview
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(Theme.caption.weight(.medium))
                } else {
                    Button("See all \(picks.count)") {
                        state.selectedSection = .smartReview
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(Theme.caption.weight(.medium))
                }
            }
            .padding(.bottom, 8)

            if picks.isEmpty {
                Text(state.hasScannedSmart
                     ? "Nothing in Downloads, Desktop or Documents looks useless right now."
                     : "Looks through Downloads, Desktop and Documents for old installers, unzipped archives and files you never opened again. Runs on this Mac only.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(picks.prefix(3)) { item in
                    smartPickRow(item)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func smartPickRow(_ item: SmartReviewItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pickDetail(item))
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.verdict.reason)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .frame(width: 260, alignment: .leading)
            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(Theme.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { DeletionService.revealInFinder(item.path) }
        .pathContextMenu(item.path)
    }

    private func pickDetail(_ item: SmartReviewItem) -> String {
        var parts = [item.displayFolder]
        if let created = item.createdDate {
            parts.append("added \(created.relativeDescription)")
        } else if let first = item.signals.first {
            parts.append(first)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Trash

    private var trashCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.accentGray.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Trash")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text(state.trashSizeBytes > 0
                     ? "\(FileSizeHelper.formatBytes(state.trashSizeBytes)) waiting. Cleaned items stay here until you empty it."
                     : "Empty")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if state.lifetimeFreedBytes > 0 {
                Text("\(FileSizeHelper.formatBytes(state.lifetimeFreedBytes)) freed all-time")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.sweep)
            }
            Button("Empty Trash…") {
                confirmEmptyTrash = true
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
            .disabled(state.trashSizeBytes == 0 || state.isCleaning)
        }
        .card(padding: 14)
    }

    // MARK: - Scan folders

    /// Projects are discovered automatically; only when none were found is there anything to say.
    private var noProjectsHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(Theme.inkSecondary)
            Text("No projects found in your home folder.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
            Button("Add folders in Settings…") {
                SettingsTab.select(.folders)
                openSettings()
            }
            .buttonStyle(SweepLinkStyle())
            .font(Theme.caption.weight(.medium))
            .fixedSize()
            Spacer()
        }
    }
}

// MARK: - Disk ring

/// Donut chart: in use (muted), can free (mint), free (track). Drawn for a pine background.
struct DiskRing: View {
    let usedFraction: Double
    let freeableFraction: Double
    let centerText: String
    let caption: String
    var inUseBytes: Int64? = nil
    /// nil while nothing has been counted yet.
    var freeableBytes: Int64? = nil
    var freeBytes: Int64? = nil
    /// Shows the turning inner arc while a scan runs.
    var scanning: Bool = false
    var lineWidth: CGFloat = 16

    private enum Segment { case inUse, freeable, free }
    @State private var hovered: Segment?
    @State private var drawn: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.pineTrack, lineWidth: width(.free))
            Circle()
                .trim(from: 0, to: clamp(usedFraction) * drawn)
                .stroke(Theme.pineMuted, style: StrokeStyle(lineWidth: width(.inUse), lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: clamp(usedFraction + 0.005) * drawn, to: clamp(usedFraction + 0.005 + freeableFraction) * drawn)
                .stroke(Theme.mint, style: StrokeStyle(lineWidth: width(.freeable), lineCap: .butt))
                .rotationEffect(.degrees(-90))
            if scanning {
                // Board: r = 54 inside the r = 70 ring, so 16 pt in from the ring's centre line.
                ScanArc()
                    .padding(16)
                    .transition(.opacity)
            }
            VStack(spacing: 2) {
                Text(centerTitle)
                    .font(Theme.display(hovered == nil ? 30 : 22))
                    .foregroundStyle(hovered == .freeable ? Theme.mint : Theme.onPine)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(centerCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pineMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: 120)
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        // Board: r = 70 in a 168 box, so 14 pt around the stroke's centre line.
        .padding(lineWidth / 2 + 6)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = segment(at: point)
            case .ended: hovered = nil
            }
        }
        .animation(.easeInOut(duration: 0.6), value: freeableFraction)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { drawn = 1 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk: \(Int(usedFraction * 100))% in use, \(Int(freeableFraction * 100))% can be freed")
    }

    private func width(_ seg: Segment) -> CGFloat { hovered == seg ? lineWidth + 6 : lineWidth }

    private var centerTitle: String {
        switch hovered {
        case .inUse: return inUseBytes.map(FileSizeHelper.formatBytes) ?? centerText
        case .freeable: return freeableBytes.map { $0 > 0 ? FileSizeHelper.formatBytes($0) : "Nothing" } ?? "Counting…"
        case .free: return freeBytes.map(FileSizeHelper.formatBytes) ?? centerText
        case nil: return centerText
        }
    }

    private var centerCaption: String {
        switch hovered {
        case .inUse: return "in use, kept"
        case .freeable: return "can be freed"
        case .free: return "free now"
        case nil: return caption
        }
    }

    /// Maps the pointer to the ring segment under it (by angle, clockwise from 12 o'clock).
    private func segment(at point: CGPoint) -> Segment? {
        let side: CGFloat = 168
        let dx = point.x - side / 2, dy = point.y - side / 2
        let r = sqrt(dx * dx + dy * dy)
        guard r > side / 2 - lineWidth - 18, r < side / 2 + 6 else { return nil }
        var angle = atan2(dx, -dy) / (2 * .pi)
        if angle < 0 { angle += 1 }
        if angle < clamp(usedFraction) { return .inUse }
        if angle < clamp(usedFraction + 0.005 + freeableFraction) && freeableFraction > 0 { return .freeable }
        return .free
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

// MARK: - Scan arc

/// Inner arc inside the hero ring while scanning (AuditDecisions): about 65°, mint, round caps,
/// one turn per 1.6 s with no easing. Under Reduce Motion it stays still at 12 o'clock.
private struct ScanArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let sweep = 65.0 / 360
    private static let period = 1.6

    var body: some View {
        if reduceMotion {
            arc(turn: 0)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                arc(turn: t.truncatingRemainder(dividingBy: Self.period) / Self.period)
            }
        }
    }

    /// `turn` 0 centres the arc on 12 o'clock.
    private func arc(turn: Double) -> some View {
        Circle()
            .trim(from: 0, to: Self.sweep)
            .stroke(Theme.mint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .opacity(0.9)
            .rotationEffect(.degrees(-90 - Self.sweep * 180 + turn * 360))
            .accessibilityHidden(true)
    }
}

// MARK: - Hero progress

/// 6 pt bar on pine: pineTrack track, mint fill (HeroScanning and Motion boards).
private struct HeroProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.pineTrack)
                Capsule().fill(Theme.mint)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.15), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

/// The open-arc glyph on the disabled hero button while scanning.
private struct HeroSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Theme.pineMuted, style: StrokeStyle(lineWidth: 1.75))
            .frame(width: 10.5, height: 10.5)
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

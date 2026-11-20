import SwiftUI

struct DashboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var processes = ProcessesStore.shared
    @State private var confirmEmptyTrash = false
    @State private var confirmEmptyFurlItems = false
    /// When the current scan started; drives the "about 40 seconds left" estimate.
    @State private var scanStartDate = Date()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // First card in the page, so it scrolls away with the cards below it.
                    if fullDiskAccess.showsUpdateBanner, let version = fullDiskAccess.currentVersion {
                        updatedBanner(version: version)
                    }
                    if let summary = state.lastSafeClean {
                        freedBanner(summary)
                    }
                    heroPanel
                    if let summary = state.lastSafeClean {
                        trashLine(summary)
                    }
                    StorageBreakdownCard(state: state)
                    // AutoSweepTrust: offered after two manual cleans of the same kind.
                    AutoSweepSuggestionCard(store: autoSweep)
                    if !state.hasScannedAnything && !state.isScanningAny {
                        firstRunCard
                    }
                    categoryGrid
                    smartPicksSection
                    if state.lastSafeClean == nil {
                        trashCard
                    }
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
        .confirmationDialog(
            "Empty Furl’s items from the Trash?",
            isPresented: $confirmEmptyFurlItems,
            titleVisibility: .visible
        ) {
            Button("Empty Furl’s Items (\(FileSizeHelper.formatBytes(state.furlTrashBytes(store: autoSweep))))", role: .destructive) {
                Task { await state.emptyFurlTrashItems(store: autoSweep) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What Furl moved to the Trash will be permanently deleted. Your own Trash items are left alone. This can't be undone.")
        }
    }

    // MARK: - Header

    private var headerSubtitle: String {
        if state.isScanningAny { return "Scanning… \(Int(scanFraction * 100))%" }
        if let lastScan = state.lastScanDate { return "Scanned \(lastScan.relativeDescription)" }
        return "Find merged Git worktrees, stale caches, app leftovers and large files."
    }

    private var header: some View {
        ScreenHeader(title: "Overview", subtitle: headerSubtitle) {
            weekGrowthHint
            // The badge gives way as the page narrows (cleanup tray open): full, then compact,
            // then gone. It shares a ViewThatFits with the Scan button because an EmptyView
            // choice is no choice at all: ViewThatFits fell back to the compact badge and clipped
            // it to one letter.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    PrivacyBadge()
                    scanButton
                }
                HStack(spacing: 12) {
                    PrivacyBadge(compact: true)
                    scanButton
                }
                scanButton
            }
        }
    }

    private var scanButton: some View {
        Button {
            if state.isScanningAny {
                // GetSpaceBack board: "Scanning… 61%  Stop". Whatever was found stays on screen.
                for section in [SidebarSection.junk, .worktrees, .apps, .largeFiles, .duplicates] {
                    state.stopScan(section)
                }
            } else {
                Task { await state.scanAll() }
            }
        } label: {
            HStack(spacing: 6) {
                if !state.isScanningAny {
                    Image(systemName: "arrow.clockwise")
                }
                Text(state.isScanningAny ? "Stop" : state.hasScannedAnything ? "Rescan" : "Scan All")
            }
        }
        .buttonStyle(SweepButtonStyle(kind: .secondary))
        // Never squeezed to an icon and a sliver when the tray narrows the page.
        .fixedSize()
        .help(state.isScanningAny ? "Stop scanning. What was found so far stays." : "Scan everything (⌘R)")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        // An inset card with the same corners as the cards below it, not a square strip.
        .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// "+X GB this week" from saved snapshots; opens Disk › What grew.
    @ViewBuilder
    private var weekGrowthHint: some View {
        if let growth = snapshots.weekGrowth, growth >= 100_000_000 {
            Button {
                state.selectedSection = .disk
                state.diskView = .grew  // after the section, which resets it to What's big
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
            .help("Your home folder grew this week. See what grew in Disk › What grew.")
        }
    }

    // MARK: - Hero (GetSpaceBack board)

    /// Which moment the hero describes. The big number is only ever the safe, ticked amount.
    private enum HeroState: Equatable {
        case notScanned
        /// Caches & Junk hasn't finished, so there is no safe number yet.
        case waitingForCaches
        /// The safe number is known; other areas may still be scanning.
        case ready
        case cleaned(SafeCleanSummary)
    }

    private var heroState: HeroState {
        if let summary = state.lastSafeClean { return .cleaned(summary) }
        if !state.hasScannedAnything && !state.isScanningAny { return .notScanned }
        if state.isScanningJunk || !state.hasScannedJunk { return .waitingForCaches }
        return .ready
    }

    private var safePlan: AppState.SafeCleanupPlan { state.safeCleanupPlan }

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

    /// "About 40 seconds left", from how long the scan has taken so far; nil until there's a fair guess.
    private var scanTimeLeft: String? {
        let fraction = scanFraction
        let elapsed = scanNow.timeIntervalSince(scanStartDate)
        guard fraction > 0.1, elapsed > 3 else { return nil }
        let left = elapsed * (1 - fraction) / fraction
        if left < 10 { return "a few seconds left" }
        if left < 60 { return "about \(Int((left / 10).rounded()) * 10) seconds left" }
        let minutes = max(1, Int((left / 60).rounded()))
        return "about \(minutes) minute\(minutes == 1 ? "" : "s") left"
    }

    private func percentFull(_ used: Int64) -> Int {
        SafeCleanSummary.percent(used, of: state.diskUsage.totalBytes)
    }

    private func bytes(_ value: Int64) -> String { FileSizeHelper.formatBytes(value) }

    /// "0 GB" on the board, where the formatter would say "Zero KB".
    private func amount(_ value: Int64) -> String { value > 0 ? bytes(value) : "0 GB" }

    private var heroPanel: some View {
        // Board: padding 28, gap 28; ring 168, text column 300, steps take the rest behind a divider.
        // Narrower pages (cleanup tray open, small window) move the steps under the ring and text.
        let showsSteps = heroState != .notScanned
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                heroRing
                heroText.frame(width: 300, alignment: .leading)
                if showsSteps {
                    heroSteps
                        // A fixed ideal width: the detail lines are long and would otherwise make
                        // this layout look too wide and push the steps under the ring.
                        .frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 24)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.pineBorder).frame(width: 1) }
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 28) {
                    heroRing
                    heroText.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                if showsSteps { heroSteps }
            }
            VStack(alignment: .leading, spacing: 24) {
                heroRing
                heroText
                if showsSteps { heroSteps }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pine, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(Theme.heroStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Get space back")
        .onChange(of: scanAreas.done) { scanStepDate = Date() }
        .onChange(of: state.isScanningAny) {
            scanStepDate = Date()
            if state.isScanningAny { scanStartDate = Date() }
        }
        .task(id: state.isScanningAny) {
            while state.isScanningAny && !Task.isCancelled {
                scanNow = Date()
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    // MARK: Ring

    private var heroRing: some View {
        let disk = state.diskUsage
        let total = Double(max(disk.totalBytes, 1))
        let used: Int64
        let freeable: Int64
        let percent: Int
        switch heroState {
        case .cleaned(let summary):
            // The ring shows the fullness the clean leads to once the Trash is emptied.
            used = max(0, summary.diskBefore.usedBytes - summary.freedBytes)
            freeable = 0
            percent = summary.percentAfter
        case .notScanned, .waitingForCaches:
            used = disk.usedBytes
            freeable = 0
            percent = percentFull(disk.usedBytes)
        case .ready:
            freeable = min(safePlan.bytes, disk.usedBytes)
            used = max(0, disk.usedBytes - freeable)
            percent = percentFull(disk.usedBytes)
        }
        let counted = heroState == .ready
        return DiskRing(
            usedFraction: Double(used) / total,
            freeableFraction: Double(freeable) / total,
            centerText: "\(percent)%",
            caption: "full",
            inUseBytes: used,
            freeableBytes: counted ? freeable : nil,
            freeBytes: disk.availableBytes,
            scanning: state.isScanningAny,
            lineWidth: 14
        )
        .frame(width: 168, height: 168)
    }

    // MARK: Text column

    @ViewBuilder
    private var heroText: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch heroState {
            case .notScanned:
                heroEyebrow("See what you can get back")
                heroStatusText("Nothing scanned yet")
                heroLine("A full scan only reads. Nothing is moved until you choose.", strong: true)
                heroButtonRow {
                    Button {
                        Task { await state.scanAll() }
                    } label: {
                        Text("Scan All")
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroPrimary, height: 48))
                }
            case .waitingForCaches:
                heroEyebrow("Safe to remove right now")
                heroStatusText("Looking…")
                VStack(alignment: .leading, spacing: 6) {
                    HeroProgressBar(fraction: scanFraction)
                    Text(scanActivity)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.pineMuted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.top, 4)
                heroButtonRow {
                    Button {} label: {
                        HStack(spacing: 8) {
                            HeroSpinner()
                            Text("Scanning…")
                        }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroPrimary, height: 48))
                    .disabled(true)
                }
            case .ready:
                readyText
            case .cleaned(let summary):
                heroEyebrow("You got back")
                bigNumber(summary.freedBytes)
                heroLine("Now \(summary.percentAfter)% full (was \(summary.percentBefore)%) · \(bytes(summary.freeAfter)) free", strong: true)
                if let win = summary.biggestWin {
                    heroLine("Biggest win: \(win.name), \(bytes(win.bytes))", strong: false)
                }
                heroButtonRow {
                    Button {
                        Task { await state.undoSafeClean(store: autoSweep) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Undo")
                        }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 40))
                    .disabled(state.isCleaning)
                    .help("Put these items back from the Trash")
                    Button("See what moved") {
                        state.selectedSection = .activity
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 40))
                }
            }
        }
    }

    @ViewBuilder
    private var readyText: some View {
        let plan = safePlan
        let scanning = state.isScanningAny
        heroEyebrow("Safe to remove right now")
        if plan.bytes > 0 {
            bigNumber(plan.bytes)
            if scanning {
                heroLine("So far. Still checking, more may come.", strong: true)
                heroLine("You can start now. Nothing found later is added without asking.", strong: false)
            } else {
                let disk = state.diskUsage
                heroLine("Caches, logs and junk. All of it goes to the Trash.", strong: true)
                heroLine("\(percentFull(disk.usedBytes))% full → \(percentFull(max(0, disk.usedBytes - plan.bytes)))% full · \(bytes(disk.availableBytes + plan.bytes)) free after", strong: false)
            }
            heroButtonRow {
                Button {
                    // Exactly the items this button showed; anything found later waits for the next look.
                    let confirmed = plan.paths
                    Task { await state.cleanSafeNow(store: autoSweep, confirmedPaths: confirmed) }
                } label: {
                    HStack(spacing: 8) {
                        if state.safeCleanPhase != nil {
                            HeroSpinner()
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(moveTitle(plan.bytes))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: .heroPrimary, height: 48))
                .disabled(state.isCleaning)
                .help("Moves only caches and junk rated Safe and still ticked. Each item is checked again right before it moves.")
            }
        } else {
            heroStatusText(scanning ? "Nothing yet" : "Nothing to clean")
            if scanning {
                heroLine("Still checking. Anything safe shows up here.", strong: true)
            } else if let next = autoSweep.nextRunDescription {
                // AuditDecisions: "Auto-Sweep checks again {nextRun}" only while Auto-Sweep is on.
                heroLine("Your Mac is tidy. Auto-Sweep checks again \(next).", strong: true)
            } else {
                heroLine("Nothing safe to remove right now. Your Mac is tidy.", strong: true)
            }
            if !scanning {
                heroButtonRow {
                    Button("Rescan") {
                        Task { await state.scanAll() }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 40))
                }
            }
        }
    }

    private func moveTitle(_ value: Int64) -> String {
        switch state.safeCleanPhase {
        case .checking: return "Checking…"
        case .cleaning: return "Moving to Trash…"
        case nil: return "Move \(bytes(value)) to Trash"
        }
    }

    private func heroEyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.pineMuted)
    }

    /// 13 pt on-pine for the first line under the number, 12 pt muted for the second (board).
    private func heroLine(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: strong ? 13 : 12))
            .foregroundStyle(strong ? Theme.onPine : Theme.pineMuted)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func heroButtonRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .fixedSize()
            .padding(.top, 12)
    }

    private func bigNumber(_ value: Int64) -> some View {
        Text(bytes(value))
            .font(Theme.display(64))
            .tracking(-2)
            .foregroundStyle(Theme.mint)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .animation(.easeInOut, value: value)
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

    // MARK: Steps

    private var heroSteps: some View {
        let plan = safePlan
        let steps = state.spaceSteps
        let cleaned: SafeCleanSummary? = {
            if case .cleaned(let summary) = heroState { return summary }
            return nil
        }()
        // The space a step leads to, added up as you go. After a clean, the Trash's share counts as freed.
        let base = state.diskUsage.availableBytes + (cleaned?.freedBytes ?? 0)
        let afterSafe = base + plan.bytes
        let afterQuick = afterSafe + steps.quickLookBytes
        let afterYours = afterQuick + steps.largeFileBytes

        let quickScanning = state.isScanningWorktrees || state.isScanningDuplicates || state.isScanningApps
        return VStack(alignment: .leading, spacing: 0) {
            Text(stepsHeader(cleaned: cleaned != nil).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.pineMuted)
                .lineLimit(1)

            // 1. Safe now
            if let cleaned {
                StepRow(title: "Safe now",
                        detail: "Done. \(cleaned.itemCount) item\(cleaned.itemCount == 1 ? "" : "s") in the Trash",
                        amount: amount(plan.bytes),
                        after: plan.bytes > 0 ? "→ \(bytes(afterSafe)) free" : "nothing left",
                        isFirst: true) {
                    Text("✓ Done").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                }
            } else if heroState == .waitingForCaches {
                StepRow(title: "Safe now", detail: "Checking caches…", amount: "—", after: "",
                        isFirst: true, checking: true) { EmptyView() }
            } else {
                StepRow(title: "Safe now",
                        detail: plan.bytes > 0 ? "Caches and junk \(bytes(plan.bytes))" : "Nothing safe right now",
                        amount: amount(plan.bytes),
                        after: "→ \(bytes(afterSafe)) free",
                        isFirst: true) {
                    if plan.bytes > 0 {
                        Text("Ready").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                    }
                }
            }

            // 2. Quick look
            StepRow(title: "Quick look",
                    detail: quickScanning ? quickChecking : quickDetail(steps),
                    amount: quickScanning && steps.quickLookBytes == 0 ? "—" : amount(steps.quickLookBytes),
                    after: quickScanning ? (steps.quickLookBytes > 0 ? "so far" : "") : "→ \(bytes(afterQuick)) free",
                    checking: quickScanning) {
                Button("Review") {
                    // The tray, with what this step counts: nothing ticked that the sections wouldn't tick.
                    CleanupTray.shared.add(TrayItem.reclaimable(
                        junk: [],
                        worktrees: state.worktrees,
                        leftovers: state.orphanedGroups,
                        duplicates: state.duplicateGroups
                    ))
                }
                .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 32))
                .disabled(steps.quickLookBytes == 0 || state.isCleaning)
            }

            // 3. Your call
            StepRow(title: "Your call",
                    detail: state.isScanningLargeFiles ? "Checking large files…" : "Large files you haven’t changed in a year",
                    amount: state.isScanningLargeFiles && steps.largeFileBytes == 0 ? "—" : amount(steps.largeFileBytes),
                    after: state.isScanningLargeFiles ? (steps.largeFileBytes > 0 ? "so far" : "") : "→ \(bytes(afterYours)) free",
                    checking: state.isScanningLargeFiles) {
                Button("Pick files") {
                    state.selectedSection = .largeFiles
                }
                .buttonStyle(SweepButtonStyle(kind: .heroSecondary, height: 32))
            }
        }
    }

    private func stepsHeader(cleaned: Bool) -> String {
        if cleaned { return "Want more? These are still here" }
        if state.isScanningAny {
            return ["Still checking", scanTimeLeft].compactMap { $0 }.joined(separator: " · ")
        }
        return "Three steps, smallest risk first"
    }

    private var quickChecking: String {
        if state.isScanningWorktrees { return "Checking worktrees…" }
        if state.isScanningDuplicates { return "Checking duplicates…" }
        return "Checking app leftovers…"
    }

    private func quickDetail(_ steps: SpaceSteps) -> String {
        var parts: [String] = []
        if steps.worktreeBytes > 0 { parts.append("Merged worktrees \(bytes(steps.worktreeBytes))") }
        if steps.duplicateBytes > 0 { parts.append("Duplicate copies \(bytes(steps.duplicateBytes))") }
        if steps.leftoverBytes > 0 { parts.append("App leftovers \(bytes(steps.leftoverBytes))") }
        return parts.isEmpty ? "Nothing to look at" : parts.joined(separator: " · ")
    }

    // MARK: After cleaning

    /// Mint banner above the hero: what the clean freed, with Undo (board, after cleaning).
    private func freedBanner(_ summary: SafeCleanSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.sweep)
            (Text("Freed \(bytes(summary.freedBytes))").bold()
             + Text(" · now \(summary.percentAfter)% full (was \(summary.percentBefore)%)")
             + Text(summary.biggestWin.map { " · biggest win: \($0.name) \(bytes($0.bytes))" } ?? ""))
                .foregroundStyle(Theme.sweepDeep)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") {
                Task { await state.undoSafeClean(store: autoSweep) }
            }
            .buttonStyle(SweepLinkStyle())
            .font(.system(size: 13, weight: .medium))
            .disabled(state.isCleaning)
            .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// "17.9 GB is in the Trash, not gone yet" with the permanent "Empty Furl's items…" (asks first).
    private func trashLine(_ summary: SafeCleanSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(bytes(summary.freedBytes)) is in the Trash, not gone yet")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Text("macOS frees the space when the Trash is emptied. Your own Trash items are left alone.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Permanent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.dangerTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
            Button("Empty Furl’s items…") {
                confirmEmptyFurlItems = true
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 30))
            .fixedSize()
            .disabled(state.isCleaning || autoSweep.ledger.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
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
                title: "Disk",
                value: state.spaceRoot.map { FileSizeHelper.formatBytes($0.sizeBytes) } ?? "Explore",
                subtitle: state.spaceRoot.map { _ in "mapped in \(state.spaceTarget?.name ?? "folder")" } ?? "See which folders use the most space",
                systemImage: SidebarSection.disk.systemImage,
                tint: Theme.accentGreen.fg,
                tintBackground: Theme.accentGreen.bg,
                isLoading: state.isScanningSpace
            ) {
                state.diskView = .big
                state.selectedSection = .disk
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

// MARK: - Step row

/// One of the hero's three steps (GetSpaceBack board): title and detail, the amount with
/// "→ X GB free" under it, then the action. A step still scanning is dimmed with a spinner.
private struct StepRow<Trailing: View>: View {
    let title: String
    let detail: String
    let amount: String
    let after: String
    var isFirst = false
    var checking = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if checking {
                StepSpinner()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.onPine)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pineMuted)
                    .lineLimit(2)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text(amount)
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.onPine)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(after)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.pineMuted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 132, alignment: .trailing)
            HStack { trailing() }
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(Theme.pineBorder).frame(height: 1) }
        }
        .opacity(checking ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// 13 pt ring with a mint top arc, turning (board: a step that's still scanning).
private struct StepSpinner: View {
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.mint.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(Theme.mint, lineWidth: 2)
        }
        .frame(width: 11, height: 11)
        .frame(width: 13, height: 13)
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
        .onAppear { spinning = true }
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

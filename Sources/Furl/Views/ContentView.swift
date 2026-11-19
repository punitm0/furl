import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var processes = ProcessesStore.shared
    @ObservedObject private var compress = AppServices.compress
    @ObservedObject private var support = SupportStore.shared
    @ObservedObject private var inspector = InspectorStore.shared
    @ObservedObject private var reportProblem = ReportProblemStore.shared
    @State private var errorExpanded = false
    @State private var didRunLaunchScan = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 248, ideal: 264, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let progress = state.cleanupProgress {
                    cleanupProgressBar(progress)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let err = state.errorBanner {
                    errorBar(text: err)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    switch state.selectedSection {
                    case .dashboard:
                        DashboardView(state: state)
                    case .worktrees:
                        WorktreesView(state: state)
                    case .junk:
                        JunkCleanupView(state: state)
                    case .apps:
                        AppUninstallerView(state: state)
                    case .largeFiles:
                        LargeFilesView(state: state)
                    case .spaceMap:
                        SpaceMapView(state: state)
                    case .snapshots:
                        SnapshotsView(state: state)
                    case .duplicates:
                        DuplicatesView(state: state)
                    case .smartReview:
                        SmartReviewView(state: state)
                    case .processes:
                        ProcessesView(store: processes)
                    case .compress:
                        CompressView(store: compress)
                    case .activity:
                        ActivityView(state: state, compress: compress)
                    case .find:
                        FindView(state: state, store: inspector)
                    }
                }
                .id(state.selectedSection)
                // New screen fades up; the old one leaves at once so the two never overlap.
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .identity))
                // minWidth 0: a screen's content (a number growing a digit while scanning) must never
                // widen the detail column, or NavigationSplitView takes the space from the sidebar.
                // minHeight 0: likewise for height. Each column keeps its own minimum size, and wrapping
                // text measured at a tiny width (an empty state's message) reports a minimum taller than
                // the window; the split view then overflows and is centred, pushing the sidebar's top
                // rows and the screen header out of sight.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: 0.18), value: state.selectedSection)
            .background(Theme.ground)
            .tint(Theme.sweep)
            .overlay(alignment: .bottom) {
                if let banner = state.statusBanner {
                    statusToast(text: banner)
                        .padding(.bottom, 76)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.statusBanner)
            .animation(.easeInOut(duration: 0.2), value: state.cleanupProgress == nil)
            .animation(.easeInOut(duration: 0.2), value: state.errorBanner)
            .cleanupTrayColumn(state: state)
            .inspector(isPresented: inspectorPresented) {
                if let item = inspector.current {
                    InspectorPanel(state: state, store: inspector, item: item)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                }
            }
            .hidingToolbarTitle()
            .toolbarBackground(Theme.ground, for: .windowToolbar)
            .cleanupTrayToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("When removing files", selection: $state.deletionMode) {
                            ForEach(DeletionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(
                            state.deletionMode.rawValue,
                            systemImage: state.deletionMode == .moveToTrash ? "trash" : "flame"
                        )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(state.deletionMode == .permanent ? Theme.danger : Theme.ink)
                    }
                    .help("Choose whether cleaned items go to the Trash or are deleted permanently")
                }
            }
        }
        .task {
            state.refreshDiskInfo()
            if state.scanOnLaunch && !didRunLaunchScan {
                didRunLaunchScan = true
                await state.scanAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshDiskInfo()
        }
        // Queued by SupportStore after a cleanup that freed a lot of space.
        .sheet(item: $support.pendingPrompt) { prompt in
            SupportSheet(freedBytes: prompt.freedBytes, lifetimeBytes: state.lifetimeFreedBytes)
        }
        .sheet(isPresented: $state.showSupportSheet) {
            SupportSheet(freedBytes: nil, lifetimeBytes: state.lifetimeFreedBytes)
        }
        // Help › Report a Problem…, Settings › General › Help and About.
        .sheet(isPresented: $reportProblem.isPresented) {
            ReportProblemSheet(state: state)
        }
    }

    /// The Inspector shows while an item is set; closing it clears the item.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { inspector.current != nil },
            set: { if !$0 { inspector.close() } }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SweepWordmark()
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SidebarGroup.allCases) { group in
                        let sections = group.sections
                        if !sections.isEmpty {
                            if group.showsHeader {
                                SectionLabel(text: group.rawValue)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 14)
                                    .padding(.bottom, 6)
                            }
                            ForEach(sections) { section in
                                sidebarRow(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            VStack(spacing: 8) {
                sidebarDiskFooter
                // Support board: a quiet line under the disk meter.
                Button {
                    state.showSupportSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.sweep)
                        Text("Support Furl")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pay what you like, or find Furl on GitHub")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        // The line between sidebar and detail (AuditDecisions: sidebarBorder). An overlay, so it
        // never takes width from either column.
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.sidebarBorder).frame(width: 1)
        }
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        let isSelected = state.selectedSection == section
        return Button {
            state.selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.sweep : Theme.inkSecondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // Results still arriving: the mini spinner, plus the running total once there is one.
                if isScanning(section) {
                    ProgressView()
                        .controlSize(.mini)
                }
                if let badge = badge(for: section), !isScanning(section) || badge.isSize {
                    switch badge {
                    case .size(let text):
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Theme.inkSecondary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: text)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    case .count(let text, let memory):
                        CountPill(
                            text: text,
                            fg: memory ? Theme.memory : Theme.sweep,
                            bg: memory ? Theme.memoryTint : Theme.mintTint
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.surface)
                        .shadow(color: Theme.sidebarSelectionShadow, radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarDiskFooter: some View {
        let disk = state.diskUsage
        let total = Double(max(disk.totalBytes, 1))
        let reclaimable = min(state.totalReclaimableBytes, disk.usedBytes)
        let usedOther = max(0, disk.usedBytes - reclaimable)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(disk.volumeName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(FileSizeHelper.formatBytes(disk.availableBytes)) free")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(disk.usedFraction > 0.9 ? Theme.danger : Theme.usedBar)
                        .frame(width: geo.size.width * Double(usedOther) / total)
                    Rectangle().fill(Theme.freeableBar)
                        .frame(width: geo.size.width * Double(reclaimable) / total)
                    Spacer(minLength: 0)
                }
                .background(Theme.border)
                .clipShape(Capsule())
            }
            .frame(height: 6)
            .animation(.easeInOut, value: reclaimable)
            if state.sessionFreedBytes > 0 {
                Text("\(FileSizeHelper.formatBytes(state.sessionFreedBytes)) freed this session")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.sweep)
            } else if state.lifetimeFreedBytes > 0 {
                Text("\(FileSizeHelper.formatBytes(state.lifetimeFreedBytes)) freed since you started")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.sweep)
            } else {
                Text("of \(FileSizeHelper.formatBytes(disk.totalBytes))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .help("\(FileSizeHelper.formatBytes(disk.availableBytes)) free of \(FileSizeHelper.formatBytes(disk.totalBytes))")
    }

    private func isScanning(_ section: SidebarSection) -> Bool {
        switch section {
        case .dashboard: return false
        case .worktrees: return state.isScanningWorktrees
        case .junk: return state.isScanningJunk
        case .apps: return state.isScanningApps
        case .largeFiles: return state.isScanningLargeFiles
        case .spaceMap: return state.isScanningSpace
        case .duplicates: return state.isScanningDuplicates
        case .smartReview: return state.isScanningSmart || state.isReviewingSmart
        case .processes: return false
        case .compress: return compress.isScanning
        case .activity, .snapshots: return false
        case .find: return false
        }
    }

    private enum SidebarBadge {
        /// Reclaimable size, shown as quiet secondary text.
        case size(String)
        /// Count, shown as a tinted pill (mint, or Memory blue for RAM-related sections).
        case count(String, memory: Bool)

        var isSize: Bool { if case .size = self { true } else { false } }
    }

    private func badge(for section: SidebarSection) -> SidebarBadge? {
        func size(_ bytes: Int64) -> SidebarBadge? {
            bytes > 0 ? .size(FileSizeHelper.formatBytes(bytes)) : nil
        }
        switch section {
        case .dashboard:
            return nil
        case .worktrees:
            return size(state.totalWorktreeReclaimableBytes)
        case .junk:
            return size(state.totalJunkReclaimableBytes)
        case .apps:
            return size(state.totalOrphanedAppDataBytes)
        case .largeFiles:
            return size(state.totalLargeFilesBytes)
        case .spaceMap:
            return nil
        case .duplicates:
            return size(state.totalDuplicateReclaimableBytes)
        case .smartReview:
            let count = state.smartItems.filter { $0.verdict.label == .junk }.count
            return count > 0 ? .count("\(count)", memory: false) : nil
        case .processes:
            let count = processes.leftoverCount
            return count > 0 ? .count("\(count)", memory: true) : nil
        case .compress:
            return size(compress.estimatedSavingsBytes)
        case .activity, .find, .snapshots:
            return nil
        }
    }

    /// MenuSupportStates "Cleanup progress bar": mintTint strip, padding 28 × 10, gap 6;
    /// 13 pt semibold title, 13 pt "K of N", 12 pt current item truncated in the middle (max 360);
    /// 4 pt sweep bar on a sweep 18% track, indeterminate when the total is unknown.
    private func cleanupProgressBar(_ progress: AppState.CleanupProgressInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(progress.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if progress.total > 0 {
                    Text("\(min(progress.done + 1, progress.total)) of \(progress.total)")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 8)
                Text(progress.current)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360, alignment: .trailing)
            }
            CleanupProgressTrack(fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.mintTint)
    }

    /// Floating dark toast with Undo, per the SystemSurfaces board.
    private func statusToast(text: String) -> some View {
        // "Nothing cleaned" (everything changed since the scan): info icon, neutral, with Rescan.
        let isInfo = !state.statusRescanSections.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: isInfo ? "info.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isInfo ? Theme.inkSecondary : Theme.mint)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.onToast)
                .lineLimit(2)
            if isInfo {
                Button {
                    Task { await state.rescanSkipped() }
                } label: {
                    Text("Rescan")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onToast)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.toastUndoFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(state.isCleaning)
            } else if let undo = state.lastUndo {
                Button {
                    Task { await state.undoLastCleanup() }
                } label: {
                    Text("Undo  ⌥⌘Z")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onToast)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.toastUndoFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(state.isCleaning)
                .help("Put the \(undo.items.count) item(s) back where they were")
            }
            Button {
                state.statusBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onToast.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(Theme.toastBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.toastBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
    }

    /// Warning bar at the top of the detail column, per the SystemSurfaces board.
    private func errorBar(text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let multiple = lines.count > 1
        let mentionsPermissions = text.localizedCaseInsensitiveContains("permission")
            || text.localizedCaseInsensitiveContains("Full Disk Access")

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text(multiple ? "\(lines.count) problems occurred" : text)
                    .font(.system(size: 12, weight: multiple ? .bold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(errorExpanded ? nil : 2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if multiple {
                    Button(errorExpanded ? "Hide Details" : "Show Details") {
                        errorExpanded.toggle()
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                }
                if mentionsPermissions {
                    Button("Open Privacy Settings") {
                        DeletionService.openFullDiskAccessSettings()
                    }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                }
                Button {
                    state.errorBanner = nil
                    errorExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            if errorExpanded && multiple {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxHeight: 140)
                .background(Theme.errorDetailFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 6)
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 9)
        .background(Theme.warningTint)
    }
}

private extension View {
    /// Each screen draws its own `ScreenHeader`, so the window title is redundant.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// 4 pt bar for the cleanup progress strip: determinate fill, or a 25% segment sliding across.
private struct CleanupProgressTrack: View {
    /// nil when the total is unknown.
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sweep.opacity(0.18))
                if let fraction {
                    Capsule()
                        .fill(Theme.sweep)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    Capsule()
                        .fill(Theme.sweep)
                        .frame(width: geo.size.width * 0.25)
                        .offset(x: reduceMotion ? geo.size.width * 0.3 : (geo.size.width * 1.25) * phase - geo.size.width * 0.25)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            guard fraction == nil, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

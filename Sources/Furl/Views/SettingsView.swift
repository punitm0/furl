import ServiceManagement
import SwiftUI

/// Settings tabs; the menu bar and notifications can open Settings on a specific tab.
enum SettingsTab: String {
    case general, automation, folders, permissions

    static let storageKey = "settings.selectedTab"

    @MainActor
    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var autoSweep: AutoSweepStore
    @AppStorage(SettingsTab.storageKey) private var selectedTab: SettingsTab = .general
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UpdateChecker.Keys.automaticChecks) private var automaticUpdateChecks = true

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AutomationSettingsTab(state: state, store: autoSweep)
                .tabItem { Label("Automation", systemImage: "clock.arrow.2.circlepath") }
                .tag(SettingsTab.automation)
            foldersTab
                .tabItem { Label("Scanning", systemImage: "folder") }
                .tag(SettingsTab.folders)
            privacyTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 560, height: 520)
        // Settings stays system grey; only toggles, the selected tab and the ring take the accent.
        .tint(Theme.sweep)
        .onAppear { autoSweep.refreshLaunchAtLoginStatus() }
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                ThemePickerRow()
            }

            Section("Cleanup") {
                Picker("When removing files", selection: $state.deletionMode) {
                    ForEach(DeletionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(state.deletionMode == .moveToTrash
                     ? "Files go to the Trash and can be restored. Space is freed when you empty the Trash."
                     : "Files are removed immediately and cannot be recovered.")
                    .font(.system(size: 11))
                    .foregroundStyle(state.deletionMode == .permanent ? Theme.danger : Theme.inkSecondary)
            }

            Section("Scanning") {
                // SettingsMoved board: the "unused after" days and the large-file size live on their screens.
                Toggle("Scan everything when Furl opens", isOn: $state.scanOnLaunch)
                    .help("Also rescans worktrees and junk automatically when scan folders change")
            }

            Section("Menu bar") {
                Toggle("Show Furl in the menu bar", isOn: $autoSweep.showMenuBarItem)
                Toggle("Show free space next to the icon", isOn: $autoSweep.showFreeSpaceInMenuBar)
                    .disabled(!autoSweep.showMenuBarItem)
                Toggle("Keep running in the menu bar when the window closes", isOn: $autoSweep.keepRunningInMenuBar)
                    .disabled(!autoSweep.showMenuBarItem)
                    .help("Furl stays in the menu bar without a Dock icon, so Auto-Sweep and alerts keep working")
                Toggle("Open Furl at login", isOn: $autoSweep.launchAtLogin)
                if autoSweep.launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Furl in System Settings › General › Login Items.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                        Spacer()
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let error = autoSweep.launchAtLoginError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
            }

            Section("Stats") {
                LabeledContent("Space freed with Furl", value: FileSizeHelper.formatBytes(state.lifetimeFreedBytes))
                CommunityStatsSettingsRow()
            }

            // ReportProblem board: a Help section at the bottom with both actions.
            Section("Help") {
                helpRow(title: "Report a problem",
                        detail: "Gathers app and Mac details for you to review, then copy or post to GitHub.",
                        button: "Report a Problem…") {
                    AppWindows.registerOpenWindow { openWindow(id: "main") }
                    ReportProblemStore.shared.present()
                }
                helpRow(title: AboutVersion.label,
                        detail: automaticUpdateChecks
                            ? "Checks GitHub once a day. Nothing is downloaded until you click Install."
                            : "Checks GitHub only when you click.",
                        button: "Check for Updates…") {
                    UpdateChecker.openAboutAndCheck(openWindow: openWindow)
                }
                Toggle("Check for updates automatically", isOn: $automaticUpdateChecks)
            }
        }
        .formStyle(.grouped)
    }

    private func helpRow(title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button(button, action: action)
        }
    }

    private var foldersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projects are found automatically")
                        .font(.system(size: 13, weight: .bold))
                    Text(discoveredSummary)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                folderSection(
                    title: "Also scan",
                    caption: nil,
                    paths: state.extraScanRoots,
                    emptyText: "Nothing extra. Drop folders here or click Add.",
                    add: { state.addExtraScanRoot() },
                    addPath: { state.addExtraScanRoot(path: $0) },
                    remove: { state.removeExtraScanRoot($0) }
                )

                folderSection(
                    title: "Never scan",
                    caption: "Furl never looks inside these folders. “Don’t scan here” on any row adds to this list.",
                    paths: state.excludedScanRoots,
                    sources: state.excludedScanRootSources,
                    emptyText: "Nothing skipped.",
                    add: { state.addExcludedScanRoot() },
                    addPath: { state.addExcludedScanRoot(path: $0) },
                    remove: { state.removeExcludedScanRoot($0) }
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var discoveredSummary: String {
        let count = state.discoveredProjectRoots.count
        guard state.hasDiscoveredProjects || count > 0 else {
            return "Furl finds folders with Git repositories or project files (package.json, Cargo.toml, pyproject.toml, Xcode projects…) in your home folder during the next scan. ~/Library and the Trash are skipped."
        }
        if count == 0 {
            return "No projects found in your home folder. Add folders below if your projects live elsewhere."
        }
        return "Found \(count) project folder\(count == 1 ? "" : "s") in your home folder. ~/Library and the Trash are skipped."
    }

    private func folderSection(
        title: String, caption: String?, paths: [String], sources: [String: String] = [:], emptyText: String,
        add: @escaping () -> Void, addPath: @escaping (String) -> Void, remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: add) { Label("Add…", systemImage: "plus") }
                    .controlSize(.small)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScanFoldersList(paths: paths, sources: sources, emptyText: emptyText, addPath: addPath, remove: remove)
        }
    }

    private var privacyTab: some View {
        FullDiskAccessPane()
    }
}

/// Settings › Permissions, per the UpdatePermissions board: status for this version, the
/// "turn it on again after each update" note (with steps while it's off), and the actions.
private struct FullDiskAccessPane: View {
    @ObservedObject private var access = FullDiskAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Label("Full Disk Access", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                statusLine
            }
            Text("macOS blocks apps from reading some folders (Mail, Safari, Containers, the Trash) unless they have Full Disk Access. Without it, Furl skips those locations and some sizes may be under-reported.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            updateNote
            HStack(spacing: 8) {
                Button("Open Full Disk Access Settings") {
                    DeletionService.openFullDiskAccessSettings()
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                .fixedSize()
                if !access.isGranted {
                    Button {
                        access.revealAppInFinder()
                    } label: {
                        ToolbarChipLabel(title: "Reveal Furl in Finder", weight: .medium)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear { access.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            access.refresh()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if access.isGranted {
            Label("On for this version", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.success)
                .font(.system(size: 12, weight: .semibold))
        } else {
            Label(offText, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warning)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private var offText: String {
        if let version = access.currentVersion { return "Off for this version (\(version))" }
        return "Off for this version"
    }

    private var updateNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("After each update, turn it on again")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("Furl isn't notarized yet, so macOS treats every new version as a new app and forgets this permission.")
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !access.isGranted {
                VStack(alignment: .leading, spacing: 4) {
                    step(1, "Click **Open Full Disk Access Settings**.")
                    step(2, "If Furl is in the list, select it and click **−**. Switching it off and on again doesn't help.")
                    step(3, "Click **+** and choose Furl in Applications, or drag Furl into the list.")
                    step(4, "Quit and reopen Furl.")
                }
            }
        }
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(access.isGranted ? Theme.surface : Theme.warningTint,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(number).")
                .monospacedDigit()
                .frame(width: 18, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// Editable list of folders; accepts folders dropped from Finder.
struct ScanFoldersList: View {
    let paths: [String]
    /// "added from Caches & Junk" tags, keyed by path.
    var sources: [String: String] = [:]
    let emptyText: String
    let addPath: (String) -> Void
    let remove: (String) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if paths.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(paths.enumerated()), id: \.element) { index, root in
                    let exists = FileManager.default.fileExists(atPath: root)
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(exists ? Theme.sweep : Theme.warning)
                        Text(root.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(exists ? root : "\(root) — folder not found")
                        if let source = sources[root] {
                            Text("added from \(source)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Button {
                            DeletionService.revealInFinder(root)
                        } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                        .disabled(!exists)

                        Button {
                            remove(root)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from list")
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isDropTargeted ? Theme.sweep : Theme.border,
                              style: isDropTargeted ? StrokeStyle(lineWidth: 2, dash: [6]) : StrokeStyle(lineWidth: 1))
        )
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    addPath(url.path)
                    added = true
                }
            }
            return added
        } isTargeted: { isDropTargeted = $0 }
    }
}

// MARK: - Automation

private struct AutomationSettingsTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: AutoSweepStore
    @ObservedObject private var notifications = NotificationService.shared

    var body: some View {
        Form {
            // AutoSweepTrust: Off / Ask first / Automatic, what picking one turned on, and the next run.
            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-Sweep").font(.system(size: 12.5, weight: .semibold))
                        Text(modeCaption)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Auto-Sweep", selection: modeBinding) {
                        ForEach(AutoSweepMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if store.autoSweepEnabled {
                    if store.keepRunningInMenuBar && store.showMenuBarItem {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.sweep)
                            Text("Furl keeps running in the menu bar so it can do this.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Change") { SettingsTab.select(.general) }
                                .buttonStyle(SweepLinkStyle())
                                .font(.system(size: 11, weight: .medium))
                        }
                        .font(.system(size: 11))
                    } else {
                        // Turned off again in General: say plainly what that means.
                        HStack {
                            Text("Auto-Sweep only runs while Furl is open.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Spacer()
                            Button("Keep running in menu bar") {
                                store.showMenuBarItem = true
                                store.keepRunningInMenuBar = true
                            }
                            .controlSize(.small)
                        }
                    }
                    if !store.launchAtLogin {
                        HStack(spacing: 6) {
                            Text("After a restart, Auto-Sweep waits until you open Furl.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Spacer()
                            // Same setting as General › Open Furl at login; the line goes away once it's on.
                            Button("Open at login") { store.launchAtLogin = true }
                                .controlSize(.small)
                        }
                    }
                }
            }

            if store.autoSweepEnabled, store.nextRun != nil {
                Section {
                    nextRunRow
                }
            }

            Section {
                ruleRow(
                    isOn: $store.cachesEnabled,
                    title: "Clean caches and stale node_modules",
                    badge: ("Safe", Theme.sweep),
                    caption: "Safe caches, plus build and dependency folders not used in \(store.cachesUnusedDays) days"
                ) {
                    // A labelled Stepper inside a Form lays out as a full-width form row and squeezes the
                    // rule's title; a plain label beside a label-less Stepper keeps it compact.
                    HStack(spacing: 6) {
                        Text("\(store.cachesUnusedDays) days")
                            .monospacedDigit()
                            .dimmedWhenDisabled()
                        Stepper("Days unused", value: $store.cachesUnusedDays, in: 7...365, step: 7)
                            .labelsHidden()
                    }
                }
                if store.cachesEnabled {
                    scheduleRow
                }

                if store.stopLeftoverProcesses != nil {
                    ruleRow(
                        isOn: $store.stopProcessesEnabled,
                        title: "Stop dev servers left by closed agent sessions",
                        badge: ("Safe", Theme.sweep),
                        caption: "Claude Code, Codex, Cursor, Gemini CLI, Copilot"
                    ) {
                        FurlPopUp("Stop dev servers after", selection: $store.stopProcessesAfterHours,
                                  value: store.stopProcessesAfterHours >= 24 ? "After 1 day" : "After \(store.stopProcessesAfterHours) hour\(store.stopProcessesAfterHours == 1 ? "" : "s")") {
                            Text("After 1 hour").tag(1)
                            Text("After 4 hours").tag(4)
                            Text("After 1 day").tag(24)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                ruleRow(
                    isOn: $store.tidyDownloadsEnabled,
                    title: "Tidy Downloads",
                    badge: ("Check first", Theme.warning),
                    caption: "Installer images over a week old, unfinished downloads, archives you already unzipped"
                ) {
                    Text("Daily").foregroundStyle(.secondary).dimmedWhenDisabled()
                }

                if store.compressColdFolders != nil {
                    ruleRow(
                        isOn: $store.compressEnabled,
                        title: "Compress folders you haven't opened",
                        caption: "Lossless, files keep working as normal"
                    ) {
                        FurlPopUp("Compress folders after", selection: $store.compressUnusedDays, value: "In \(store.compressUnusedDays) days") {
                            Text("In 60 days").tag(60)
                            Text("In 90 days").tag(90)
                            Text("In 180 days").tag(180)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                // The heading fades with the rules so the whole group reads as off.
                Text("Rules").dimmedWhenDisabled()
            }
            .disabled(!store.autoSweepEnabled)

            // Defect H2: emptying Furl's Trash items is permanent, so it has its own group and starts unticked.
            Section {
                ruleRow(
                    isOn: $store.expireTrashEnabled,
                    title: "Empty Furl’s Trash items after \(store.expireTrashDays) days",
                    badge: ("Permanent", Theme.danger),
                    caption: "Only what Furl moved there. Your other Trash items are never touched. This can’t be undone."
                ) {
                    FurlPopUp("Empty Furl’s Trash items after", selection: $store.expireTrashDays, value: "\(store.expireTrashDays) days") {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Permanent").dimmedWhenDisabled()
            }
            .disabled(!store.autoSweepEnabled)

            Section("Alerts") {
                ruleRow(
                    isOn: $store.lowDiskAlertEnabled.withSideEffect(requestNotifications),
                    title: "Warn me when free space drops below",
                    caption: "A notification with what you can free"
                ) {
                    FurlPopUp("Warn below", selection: $store.lowDiskThresholdGB, value: "\(store.lowDiskThresholdGB) GB") {
                        ForEach([5, 10, 20, 30, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Notify me after each Auto-Sweep", isOn: $store.notifyAfterRun.withSideEffect(requestNotifications))
                    .disabled(!store.autoSweepEnabled)
                notificationStatus
            }

            Section {
                HStack {
                    if !store.autoSweepEnabled {
                        Text("Auto-Sweep is off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let next = store.nextRunDescription {
                        Text("Next run \(next)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isRunning { ProgressView().controlSize(.small) }
                    // Ask first: opens Review with a fresh list instead of cleaning straight away.
                    Button("Run now") {
                        Task { await AppServices.scheduler.runNow() }
                    }
                    .disabled(!store.autoSweepEnabled || store.isRunning || state.isCleaning)
                }
            }

            historySection
        }
        .formStyle(.grouped)
        .task { await notifications.refreshAuthorization() }
        .onAppear { AppServices.scheduler.refreshPreviewIfNeeded() }
        .onChange(of: store.mode) { _, _ in AppServices.scheduler.refreshPreviewIfNeeded() }
        .sheet(item: $store.listRequest) { request in
            AutoSweepListSheet(store: store, request: request)
        }
    }

    // MARK: Mode and next run

    private var modeCaption: String {
        switch store.mode {
        case .off: return "Furl won’t clean anything by itself."
        case .askFirst: return "Furl finds safe items on schedule and asks before moving them."
        case .automatic: return "Furl moves safe items to the Trash on schedule and tells you after."
        }
    }

    private var modeBinding: Binding<AutoSweepMode> {
        Binding(
            get: { store.mode },
            set: { newMode in
                store.setMode(newMode)
                requestNotifications(newMode != .off)
            }
        )
    }

    /// "Next: Sunday at 9:00 · about 5.0 GB" with the breakdown and See list. While an Ask first run
    /// waits for an answer, it says so with Review (also when its notification couldn't be shown).
    @ViewBuilder
    private var nextRunRow: some View {
        if let ask = store.pendingAsk {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.sweep)
                (Text("Auto-Sweep is ready").fontWeight(.semibold)
                    + Text(ask.totalBytes > 0 ? " · about \(FileSizeHelper.formatBytes(ask.totalBytes)) · waiting for you" : " · waiting for you"))
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Review") { store.listRequest = .review }
                    .controlSize(.small)
            }
        } else {
            upcomingRunRow
        }
    }

    private var upcomingRunRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.sweep)
            VStack(alignment: .leading, spacing: 1) {
                let when = store.nextRun.map { AutoSweepStore.dayAndTime($0.date) } ?? ""
                if let preview = store.nextRunPreview, !store.isPreviewing || !preview.isEmpty {
                    (Text("Next: \(when)").fontWeight(.semibold)
                        + Text(preview.isEmpty ? " · nothing to clean right now" : " · about \(FileSizeHelper.formatBytes(preview.totalBytes))"))
                        .font(.system(size: 12.5))
                    Text(nextRunCaption(preview))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    (Text("Next: \(when)").fontWeight(.semibold) + Text(" · checking what it would clean…"))
                        .font(.system(size: 12.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("See list") { store.listRequest = .seeList }
                .controlSize(.small)
                .disabled(store.nextRunPreview?.isEmpty ?? true)
        }
    }

    private func nextRunCaption(_ preview: AutoSweepPreview) -> String {
        let tail = store.mode == .askFirst ? "you’ll be asked first" : "Furl tells you after"
        let breakdown = preview.breakdown()
        return breakdown.isEmpty ? tail.prefix(1).uppercased() + tail.dropFirst() : "\(breakdown) · \(tail)"
    }

    // MARK: Rows

    private func ruleRow<Trailing: View>(
        isOn: Binding<Bool>, title: String, badge: (text: String, color: Color)? = nil, caption: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.furlCheckbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        // AutoSweepTrust: the risk tier chip beside each rule (10 pt on the colour's tint).
                        Text(badge.text)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(badge.color == Theme.sweep ? Theme.sweepDeep : badge.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(BadgeView.tint(for: badge.color), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .fixedSize()
                    }
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .dimmedWhenDisabled()
            // The text takes the spare width first; otherwise a wide trailing control squeezes the title
            // to one letter per line.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            trailing()
                .fixedSize()
                .disabled(!isOn.wrappedValue)
        }
    }

    private var scheduleRow: some View {
        HStack(spacing: 6) {
            Text("Runs").dimmedWhenDisabled()
            FurlPopUp("Runs", selection: $store.frequency, value: store.frequency.rawValue) {
                ForEach(AutoSweepFrequency.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if store.frequency == .weekly {
                Text("on").dimmedWhenDisabled()
                FurlPopUp("Day", selection: $store.weekday, value: "\(Calendar.current.weekdaySymbols[max(0, min(6, store.weekday - 1))])s") {
                    ForEach(1...7, id: \.self) { day in
                        Text("\(Calendar.current.weekdaySymbols[day - 1])s").tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } else if store.frequency == .monthly {
                Text("on the 1st").foregroundStyle(.secondary).dimmedWhenDisabled()
            }
            Text("at").dimmedWhenDisabled()
            FurlPopUp("Time", selection: $store.hour, value: String(format: "%d:%02d", store.hour, store.minute)) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%d:%02d", hour, store.minute)).tag(hour)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.leading, 28)
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var notificationStatus: some View {
        if !notifications.isAvailable {
            Text("Notifications need the Furl app bundle. Build it with scripts/build_app.sh.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            HStack {
                switch notifications.authorization {
                case .authorized, .provisional:
                    Label("Notifications allowed", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.sweep)
                case .denied:
                    Label("Notifications are off for Furl", systemImage: "bell")
                        .foregroundStyle(Theme.warning)
                default:
                    Label("Furl will ask before showing notifications", systemImage: "bell")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if notifications.authorization == .denied {
                    Button("Open Settings") { notifications.openSystemSettings() }
                        .controlSize(.small)
                }
                Button("Send Test") {
                    Task { await notifications.postTest() }
                }
                .controlSize(.small)
            }
            .font(.system(size: 11))
            if let error = notifications.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            if store.history.isEmpty {
                Text("Auto-Sweep runs and menu bar cleanups will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.history.prefix(30)) { run in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12))
                                Text(run.trigger.rawValue)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Text(run.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if let why = run.why {
                                Text(why)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            if !run.errors.isEmpty {
                                Text("\(run.errors.count) \(run.errors.count == 1 ? "item" : "items") couldn't be cleaned")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.warning)
                                    .help(run.errors.joined(separator: "\n"))
                            }
                        }
                        Spacer()
                        if run.undone {
                            Text("Undone").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if run.canUndo {
                            Button("Undo") {
                                Task { await state.undoAutoSweepRun(run, store: store) }
                            }
                            .controlSize(.small)
                            .disabled(state.isCleaning)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("History")
                Spacer()
                if !store.history.isEmpty {
                    Button("Clear") { store.clearHistory() }
                        .buttonStyle(SweepLinkStyle())
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private func requestNotifications(_ isOn: Bool) {
        guard isOn else { return }
        Task { await notifications.requestPermissionIfNeeded() }
    }
}

private extension Binding where Value == Bool {
    /// Runs `effect` after the user flips the toggle (e.g. to ask for notification permission).
    @MainActor
    func withSideEffect(_ effect: @escaping @MainActor (Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                wrappedValue = newValue
                effect(newValue)
            }
        )
    }
}

/// Settings › General › Stats: lifetime totals on this Mac.
private struct CommunityStatsSettingsRow: View {
    @ObservedObject private var ledger = StatsLedger.shared

    var body: some View {
        if ledger.lifetimeMemoryFreedBytes > 0 {
            LabeledContent("Memory freed by stopping processes",
                           value: FileSizeHelper.formatBytes(ledger.lifetimeMemoryFreedBytes))
        }
        if ledger.lifetimeFilesCompressed > 0 {
            LabeledContent("Files compressed", value: ledger.lifetimeFilesCompressed.formatted())
        }
    }

}

/// A disabled Form row keeps its text at full ink, so rules looked active while Auto-Sweep was off.
/// This fades plain text to the 45% the checkbox and pop-ups already use; don't put it on those
/// controls themselves or they fade twice.
private extension View {
    func dimmedWhenDisabled() -> some View { modifier(DimWhenDisabled()) }
}

private struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

import AppKit
import SwiftUI

// MARK: - Palette (from the Menu bar board; the manager can swap in the shared theme)

private enum MenuBarPalette {
    static let accent = Theme.sweep
    static let accentDeep = Theme.sweepDeep
    static let freeable = Theme.freeableBar
    static let used = Theme.usedBar
    static let track = Theme.border
    static let blue = Theme.memory
    static let orange = Theme.warning

    static func tint(_ tint: MenuBarExtraRow.Tint) -> Color {
        switch tint {
        case .blue: return blue
        case .orange: return orange
        case .green: return accent
        case .gray: return Theme.inkSecondary
        case .red: return Theme.danger
        }
    }
}

// MARK: - Menu bar label

/// The status item: template glyph plus (optionally) free space, e.g. "86 GB".
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: AutoSweepStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image)
            if store.showFreeSpaceInMenuBar, state.diskUsage.totalBytes > 0 {
                Text(MenuBarFormat.compact(state.diskUsage.availableBytes))
                    .monospacedDigit()
            }
        }
        .onAppear {
            // The label lives as long as the status item, so it's a reliable place to grab openWindow
            // for notification actions that need to bring the main window back.
            AppWindows.registerOpenWindow { openWindow(id: "main") }
            AppWindows.registerOpenAbout { openWindow(id: "about") }
        }
    }
}

enum MenuBarFormat {
    /// "86 GB" / "1.2 TB" / "740 MB" — short enough for the menu bar.
    static func compact(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10 && gb < 1000 { return "\(Int(gb.rounded())) GB" }
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// The Curl f glyph (Brand board, small-size shape), drawn as a template image so macOS tints it
/// for light and dark menu bars.
/// Main-actor only: older SDKs don't mark NSImage Sendable, so a plain shared static won't compile there.
@MainActor
enum MenuBarGlyph {
    static let image: NSImage = SweepMarkRenderer.image(points: 16, tile: false, glyph: true, curlHex: nil, inset: 0.5)
}

// MARK: - Popover

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: AutoSweepStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    private enum Confirm: Equatable { case clean, emptyTrash, extra(String) }
    @State private var confirming: Confirm?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primaryButton
            if let note = state.safeCleanNote {
                // "Clean safe items" left everything alone (same sentence as the toast).
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .labelStyle(TightLabelStyle())
                    .fixedSize(horizontal: false, vertical: true)
            }
            rows
            autoSweepLine
            privacyLine
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.surfaceSubtle.opacity(0.97))
        .onAppear {
            AppWindows.registerOpenWindow { openWindow(id: "main") }
            state.refreshDiskInfo()
            store.menuBarProviders.forEach { $0.menuBarWillAppear() }
            Task { await state.prepareSafeCleanup() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            MenuDiskRing(usedFraction: usedFraction, freeableFraction: freeableFraction)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(state.diskUsage.volumeName) · \(FileSizeHelper.formatBytes(state.diskUsage.availableBytes)) free")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                if reclaimableBytes > 0 {
                    Text(FileSizeHelper.formatBytes(reclaimableBytes))
                        .font(Theme.display(26))
                        .tracking(-0.5)
                        .foregroundStyle(MenuBarPalette.accent)
                        .contentTransition(.numericText())
                    // Like the Overview: a number from a scan still streaming in is only "so far".
                    Text(state.isScanningJunk ? "safe so far · still checking" : "safe to remove right now")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                } else if state.isScanningJunk {
                    Text("Looking…")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("checking caches")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("All tidy")
                        .font(Theme.display(22))
                        .foregroundStyle(MenuBarPalette.accent)
                    Text("nothing safe to clean right now")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The Overview's "Safe now" number (GetSpaceBack board: the same number everywhere).
    private var reclaimableBytes: Int64 { state.safeCleanupPlan.bytes }

    private var usedFraction: Double { state.diskUsage.usedFraction }

    private var freeableFraction: Double {
        guard state.diskUsage.totalBytes > 0 else { return 0 }
        return min(usedFraction, Double(reclaimableBytes) / Double(state.diskUsage.totalBytes))
    }

    // MARK: Primary action

    @ViewBuilder
    private var primaryButton: some View {
        let plan = state.safeCleanupPlan
        if confirming == .clean {
            ConfirmStrip(
                text: "Move \(plan.paths.count == 1 ? "1 safe item" : "\(plan.paths.count) safe items"), \(FileSizeHelper.formatBytes(plan.bytes)), to the Trash? You can undo this.",
                confirmTitle: "Move to Trash",
                onCancel: { confirming = nil },
                onConfirm: {
                    confirming = nil
                    // The plan this strip shows (same render), not one a later scan produced.
                    let confirmedPaths = plan.paths
                    run { _ = await state.cleanSafeItems(store: store, trigger: .menuBar, confirmedPaths: confirmedPaths) }
                }
            )
        } else {
            Button {
                confirming = .clean
            } label: {
                HStack(spacing: 8) {
                    if busy || state.isCleaning {
                        ProgressView().controlSize(.small).tint(Theme.onSweep)
                    }
                    Text(primaryTitle(plan))
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(Theme.onSweep)
                .background(MenuBarPalette.accent.opacity(plan.isEmpty || state.isScanningJunk ? 0.45 : 1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Waits for the caches scan to finish, as the Overview's button does.
            .disabled(plan.isEmpty || busy || state.isCleaning || state.isScanningJunk)
            .help("Only caches and junk rated Safe and still ticked. Everything goes to the Trash.")
        }
    }

    private func primaryTitle(_ plan: AppState.SafeCleanupPlan) -> String {
        if state.safeCleanPhase == .checking { return "Checking…" }
        if state.isCleaning { return "Cleaning…" }
        if state.isScanningJunk { return "Checking caches…" }
        if plan.isEmpty { return state.hasScannedForSafeCleanup ? "No safe items to clean" : "Finding safe items…" }
        return "Move \(FileSizeHelper.formatBytes(plan.bytes)) to Trash"
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            // Rows from other features (leftover processes, idle agent sessions…), refreshed while open.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let extras = store.menuBarProviders.flatMap(\.menuBarRows)
                VStack(spacing: 0) {
                    ForEach(Array(extras.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { MenuHairline() }
                        extraRow(row)
                    }
                    if !extras.isEmpty { MenuHairline() }
                }
            }

            trashRow
            MenuHairline()
            reviewRow
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func extraRow(_ row: MenuBarExtraRow) -> some View {
        if confirming == .extra(row.id), let confirmation = row.confirmation {
            ConfirmStrip(text: confirmation, confirmTitle: row.actionTitle ?? "OK",
                         onCancel: { confirming = nil },
                         onConfirm: {
                             confirming = nil
                             if let action = row.action { run(action) }
                         })
                .padding(8)
        } else {
            MenuRow(systemImage: row.systemImage, tint: MenuBarPalette.tint(row.tint), title: row.title, detail: row.detail) {
                if let title = row.actionTitle, row.action != nil {
                    RowButton(title: title) {
                        if row.confirmation != nil {
                            confirming = .extra(row.id)
                        } else if let action = row.action {
                            run(action)
                        }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    @ViewBuilder
    private var trashRow: some View {
        if confirming == .emptyTrash {
            ConfirmStrip(
                text: "Permanently erase everything in the Trash (\(FileSizeHelper.formatBytes(state.trashSizeBytes)))? This can't be undone.",
                confirmTitle: "Empty Trash",
                destructive: true,
                onCancel: { confirming = nil },
                onConfirm: {
                    confirming = nil
                    run {
                        await state.emptyTrash()
                        store.pruneLedger()
                    }
                }
            )
            .padding(8)
        } else {
            MenuRow(systemImage: "trash", tint: Theme.inkSecondary, title: "Trash",
                    detail: FileSizeHelper.formatBytes(state.trashSizeBytes)) {
                RowButton(title: "Empty…") { confirming = .emptyTrash }
                    .disabled(state.trashSizeBytes == 0 || busy || state.isCleaning)
            }
        }
    }

    private var reviewRow: some View {
        let reviewCount = state.smartItems.count
        let title = state.hasScannedSmart
            ? (reviewCount == 1 ? "1 file to review" : "\(reviewCount) files to review")
            : "Find files to review"
        return MenuRow(systemImage: "sparkle", tint: MenuBarPalette.accent, title: title, detail: nil) {
            Button(state.hasScannedSmart ? "Review" : "Smart Review") {
                AppWindows.showMain(section: .smartReview, state: state)
                dismiss()
            }
            .buttonStyle(SweepLinkStyle())
            .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: Footer lines

    @ViewBuilder
    private var autoSweepLine: some View {
        if store.autoSweepEnabled, store.nextRun != nil {
            // AutoSweepTrust "Menu bar · next run": the same preview as Settings, with See list.
            MenuBarNextRunCard(store: store, onSeeList: {
                store.listRequest = .seeList
                showSettings(tab: .automation)
            }, onReview: {
                store.listRequest = .review
                showSettings(tab: .automation)
            })
            .onAppear { AppServices.scheduler.refreshPreviewIfNeeded() }
        } else {
            autoSweepStatusLine
        }
    }

    private var autoSweepStatusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
            Text(autoSweepText)
                .lineLimit(2)
            if !store.autoSweepEnabled {
                Button("Set up") { showSettings(tab: .automation) }
                    .buttonStyle(SweepLinkStyle())
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.inkSecondary)
    }

    private var autoSweepText: String {
        guard store.autoSweepEnabled else { return "Auto-Sweep is off" }
        if store.isRunning { return "Auto-Sweep is running…" }
        var parts: [String] = []
        if let last = store.lastRunDate {
            let day = AutoSweepStore.relativeDay(last).components(separatedBy: " ").first ?? ""
            parts.append(store.lastRunBytes > 0
                         ? "Auto-Sweep ran \(day), freed \(FileSizeHelper.formatBytes(store.lastRunBytes))"
                         : "Auto-Sweep ran \(day), nothing to clean")
        } else {
            parts.append("Auto-Sweep is on")
        }
        if let next = store.nextRunDescription { parts.append("next \(next)") }
        return parts.joined(separator: " · ")
    }

    private var privacyLine: some View {
        Label("Works offline · Your files never leave your Mac", systemImage: "checkmark.shield")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MenuBarPalette.accentDeep)
            .labelStyle(TightLabelStyle())
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1).padding(.bottom, 10)
            HStack(spacing: 8) {
                Button {
                    AppWindows.showMain(section: nil, state: state)
                    dismiss()
                } label: {
                    Text("Open Furl")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    showSettings(tab: .general)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 34, height: 30)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")

                Menu {
                    Button("Quit Furl") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 30)
                .accessibilityLabel("More")
            }
        }
    }

    // MARK: Helpers

    private func showSettings(tab: SettingsTab) {
        SettingsTab.select(tab)
        AppWindows.activateForWindow()
        openSettings()
        dismiss()
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}

// MARK: - Pieces

private struct MenuDiskRing: View {
    let usedFraction: Double
    let freeableFraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(MenuBarPalette.track, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, usedFraction - freeableFraction))
                .stroke(MenuBarPalette.used, style: StrokeStyle(lineWidth: 8))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: max(0, usedFraction - freeableFraction), to: usedFraction)
                .stroke(MenuBarPalette.freeable, style: StrokeStyle(lineWidth: 8))
                .rotationEffect(.degrees(-90))
        }
        .padding(6)
        .animation(.easeOut(duration: 0.4), value: usedFraction)
        .animation(.easeOut(duration: 0.4), value: freeableFraction)
        .accessibilityLabel("\(Int(usedFraction * 100))% of disk used, \(Int(freeableFraction * 100))% can be freed")
    }
}

private struct MenuRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            (Text(title).foregroundColor(Theme.ink) + Text(detail.map { " · \($0)" } ?? "").foregroundColor(Theme.inkSecondary))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct MenuHairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

private struct RowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConfirmStrip: View {
    let text: String
    let confirmTitle: String
    var destructive = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: destructive ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .tint(destructive ? Theme.danger : MenuBarPalette.accent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

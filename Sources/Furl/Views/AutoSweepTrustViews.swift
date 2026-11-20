import SwiftUI

// AutoSweepTrust board pieces: the item list behind "See list" and the Ask first "Review", the menu
// bar's next-run card, and the Overview card that offers Ask first after repeated manual cleans.

// MARK: - Item list

/// One sheet for See list (Settings, menu bar) and Review (Ask first notification), grouped by rule in
/// Settings order. Review: Not now skips this run, Clean moves what's ticked. See list: a preview with
/// Done; unticked items are skipped on that run only. Unticking anything counts as changed, so that
/// run doesn't count toward the 3 approvals.
struct AutoSweepListSheet: View {
    @ObservedObject var store: AutoSweepStore
    let request: AutoSweepListRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    /// Fixed when the sheet opens so a refresh can't swap items under the user.
    @State private var preview: AutoSweepPreview?
    @State private var runDate: Date?

    private var isReview: Bool { request == .review }
    /// Long groups show this many items and "N more …".
    private static let collapsedCount = 4

    private struct Group: Identifiable {
        let id: String
        let title: String
        let badge: (text: String, color: Color)
        let items: [AutoSweepPreview.Item]
        var isPermanent = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty {
                        if isReview, preview == nil, store.isPreparingReview {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Checking what it would clean…")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                        } else {
                            Text("Nothing to clean right now.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    ForEach(groups.filter { !$0.isPermanent }) { groupCard($0) }
                    ForEach(groups.filter(\.isPermanent)) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Permanent")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 5)
                            groupCard(group)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Text(isReview
                     ? (hasPermanentTicked ? "Everything else goes to the Trash first. Each item is checked again right before it moves."
                                           : "Everything goes to the Trash first. Each item is checked again right before it moves.")
                     : "Unticked items are skipped on \(runDayName) only. To stop a rule, untick it in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isReview {
                    Button("Not now") {
                        // Skips this run; nothing moves.
                        store.pendingAsk = nil
                        dismiss()
                    }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    Button(selectedBytes > 0 ? "Clean \(FileSizeHelper.formatBytes(selectedBytes))" : "Clean") {
                        guard let preview else { return }
                        let changed = selected.count != preview.items.count
                        let approved = preview.keeping(selected)
                        dismiss()
                        Task { await AppServices.scheduler.approve(approved, changed: changed) }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                    .fixedSize()
                } else {
                    Button("Done") {
                        if let preview {
                            store.setSkippedForNextRun(Set(preview.items.map(\.id)).subtracting(selected), runDate: runDate)
                        }
                        dismiss()
                    }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 28))
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 520)
        .background(Theme.ground)
        .onAppear {
            let shown = isReview ? store.pendingAsk : store.nextRunPreview
            preview = shown
            runDate = isReview ? shown?.date : store.nextRun?.date
            let all = Set(shown?.items.map(\.id) ?? [])
            selected = isReview ? all : all.subtracting(store.skippedForNextRun)
        }
        .onChange(of: store.pendingAsk) { _, ask in
            // Review opened before its fresh list was ready: show it once, then keep it fixed.
            guard isReview, preview == nil, let ask else { return }
            preview = ask
            runDate = ask.date
            selected = Set(ask.items.map(\.id))
        }
    }

    // MARK: Header copy

    private var selectedBytes: Int64 {
        preview?.items.filter { selected.contains($0.id) && $0.kind != .process }.reduce(0) { $0 + $1.bytes } ?? 0
    }

    private var hasPermanentTicked: Bool {
        preview?.items.contains { $0.kind == .trash && selected.contains($0.id) } ?? false
    }

    private var title: String {
        if isReview {
            return selectedBytes > 0 ? "Auto-Sweep is ready · \(FileSizeHelper.formatBytes(selectedBytes))" : "Auto-Sweep is ready"
        }
        let total = preview?.totalBytes ?? 0
        return total > 0 ? "Next Auto-Sweep · about \(FileSizeHelper.formatBytes(total))" : "Next Auto-Sweep"
    }

    private var subtitle: String {
        let when = runDate.map(AutoSweepStore.dayAndTime) ?? ""
        let capitalized = when.prefix(1).uppercased() + when.dropFirst()
        if isReview { return capitalized.isEmpty ? "Waiting for you" : "\(capitalized) · waiting for you" }
        return "\(capitalized) · " + (store.mode == .askFirst ? "you’ll be asked first" : "Furl tells you after")
    }

    private var runDayName: String {
        runDate.map(AutoSweepStore.dayName) ?? "the next run"
    }

    // MARK: Groups

    private var groups: [Group] {
        guard let preview else { return [] }
        var groups: [Group] = []
        let caches = preview.items.filter { $0.kind == .cache || $0.kind == .dependency }
        if !caches.isEmpty {
            groups.append(Group(id: "caches", title: "Clean caches and stale node_modules", badge: ("Safe", Theme.sweep), items: caches))
        }
        let processes = preview.items(.process)
        if !processes.isEmpty {
            groups.append(Group(id: "processes", title: "Stop dev servers left by closed agent sessions",
                                badge: ("Safe", Theme.sweep), items: processes))
        }
        let downloads = preview.items(.download)
        if !downloads.isEmpty {
            groups.append(Group(id: "downloads", title: "Tidy Downloads", badge: ("Check first", Theme.warning), items: downloads))
        }
        let trash = preview.items(.trash)
        if !trash.isEmpty {
            groups.append(Group(id: "trash", title: "Empty Furl’s Trash items after \(store.expireTrashDays) days",
                                badge: ("Permanent", Theme.danger), items: trash, isPermanent: true))
        }
        return groups
    }

    private func groupCard(_ group: Group) -> some View {
        let ids = Set(group.items.map(\.id))
        let ticked = ids.intersection(selected)
        let bytes = group.items.filter { $0.kind != .process }.reduce(Int64(0)) { $0 + $1.bytes }
        let memory = group.items.filter { $0.kind == .process }.reduce(Int64(0)) { $0 + $1.bytes }
        let isExpanded = expanded.contains(group.id)
        let visible = group.isPermanent ? [] : (isExpanded ? group.items : Array(group.items.prefix(Self.collapsedCount)))
        let hidden = group.isPermanent ? [] : Array(group.items.dropFirst(visible.count))

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                checkbox(isOn: !ticked.isEmpty) { on in
                    if on { selected.formUnion(ids) } else { selected.subtract(ids) }
                }
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    badge(group.badge.text, group.badge.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(bytes > 0 ? FileSizeHelper.formatBytes(bytes) : "\(FileSizeHelper.formatBytes(memory)) RAM")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if group.isPermanent {
                rowDivider
                Text(permanentLine(group.items))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 34)
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
            }

            ForEach(visible) { item in
                rowDivider
                itemRow(item)
            }

            if !hidden.isEmpty {
                rowDivider
                Button(moreLabel(hidden)) { expanded.insert(group.id) }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 58)
                    .padding(.vertical, 7)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func itemRow(_ item: AutoSweepPreview.Item) -> some View {
        HStack(spacing: 10) {
            checkbox(isOn: selected.contains(item.id)) { on in
                if on { selected.insert(item.id) } else { selected.remove(item.id) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Dev servers show memory instead of size.
            Text(item.kind == .process ? "\(FileSizeHelper.formatBytes(item.bytes)) RAM" : FileSizeHelper.formatBytes(item.bytes))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private func checkbox(isOn: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.furlCheckbox)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color == Theme.sweep ? Theme.sweepDeep : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(BadgeView.tint(for: color), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }

    /// "13 more node_modules folders, 1.5 GB"
    private func moreLabel(_ items: [AutoSweepPreview.Item]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        let noun: String
        if items.allSatisfy({ $0.kind == .dependency }) {
            noun = items.count == 1 ? "node_modules folder" : "node_modules folders"
        } else if items.allSatisfy({ $0.kind == .process }) {
            noun = items.count == 1 ? "dev server" : "dev servers"
        } else {
            noun = items.count == 1 ? "item" : "items"
        }
        let size = items.first?.kind == .process ? "\(FileSizeHelper.formatBytes(bytes)) RAM" : FileSizeHelper.formatBytes(bytes)
        return "\(items.count) more \(noun), \(size)"
    }

    /// "212 items Furl moved to the Trash before Oct 22. This can’t be undone."
    private func permanentLine(_ items: [AutoSweepPreview.Item]) -> String {
        let cutoff = Date().addingTimeInterval(-Double(store.expireTrashDays) * 86_400)
        let day = cutoff.formatted(.dateTime.month(.abbreviated).day())
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return "\(count) Furl moved to the Trash before \(day). This can’t be undone."
    }
}

// MARK: - Menu bar

/// "Auto-Sweep Sunday · About 5.0 GB · asks first · See list" (menu bar, next run).
struct MenuBarNextRunCard: View {
    @ObservedObject var store: AutoSweepStore
    let onSeeList: () -> Void
    /// Ask first is waiting for an answer (also when its notification couldn't be shown).
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-Sweep \(store.nextRun.map { AutoSweepStore.dayName($0.date) } ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.pendingAsk != nil {
                Button("Review", action: onReview)
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
            } else if !(store.nextRunPreview?.isEmpty ?? true) {
                Button("See list", action: onSeeList)
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundStyle(Theme.sweepDeep)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var detail: String {
        let tail = store.mode == .askFirst ? "asks first" : "tells you after"
        if store.isRunning { return "Running now…" }
        if let ask = store.pendingAsk {
            return ask.totalBytes > 0 ? "About \(FileSizeHelper.formatBytes(ask.totalBytes)) · waiting for you" : "Waiting for you"
        }
        guard let preview = store.nextRunPreview else { return "Checking… · \(tail)" }
        if preview.isEmpty { return "Nothing to clean yet · \(tail)" }
        return "About \(FileSizeHelper.formatBytes(preview.totalBytes)) · \(tail)"
    }
}

// MARK: - Overview suggestion

/// "You’ve cleaned caches by hand twice this month": offers Ask first (never Automatic).
struct AutoSweepSuggestionCard: View {
    @ObservedObject var store: AutoSweepStore
    @ObservedObject private var log = ActivityLog.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let offer = AutoSweepSuggestion.offer(entries: log.entries, mode: store.mode,
                                                 dismissedAt: store.suggestionDismissedAt) {
            HStack(spacing: 14) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.sweepDeep)
                    .frame(width: 34, height: 34)
                    .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(offer))
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    Text(detail(offer))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Set up") {
                    store.cachesEnabled = true
                    store.setMode(.askFirst)
                    Task { await NotificationService.shared.requestPermissionIfNeeded() }
                    SettingsTab.select(.automation)
                    AppWindows.activateForWindow()
                    openSettings()
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 30))
                .fixedSize()
                Button("Not now") { store.suggestionDismissedAt = Date() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 30))
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private func title(_ offer: AutoSweepSuggestion.Offer) -> String {
        let times = offer.cleanCount == 2 ? "twice" : "\(offer.cleanCount) times"
        return "You’ve cleaned caches by hand \(times) this month"
    }

    private func detail(_ offer: AutoSweepSuggestion.Offer) -> String {
        let size = FileSizeHelper.formatBytes(max(offer.typicalBytes, 0))
        switch store.frequency {
        case .daily:
            return "Auto-Sweep can find them every day and ask you first. About \(size) each time."
        case .weekly:
            let day = Calendar.current.weekdaySymbols[max(0, min(6, store.weekday - 1))]
            return "Auto-Sweep can find them every \(day) and ask you first. About \(size) a week."
        case .monthly:
            return "Auto-Sweep can find them once a month and ask you first. About \(size) a month."
        }
    }
}

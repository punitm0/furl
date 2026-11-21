import SwiftUI

/// DiskScreen board: one screen for "what is using my disk". The storage bar sits on top of both
/// views; What's big (was Space Map) and What grew (was Snapshots) switch in the header.
struct DiskView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var snapshots: SnapshotsModel = .shared

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Disk", subtitle: subtitle) {
                DiskSegmented(
                    options: [DiskViewMode.big, .grew],
                    selection: $state.diskView,
                    title: { $0 == .big ? "What’s big" : "What grew" },
                    height: 24
                )
                .fixedSize()
                if isRescanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Scanning…").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    .fixedSize()
                } else {
                    Button("Rescan") { rescan() }
                        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 30))
                        .fixedSize()
                        .help(state.diskView == .big ? "Map the folders again" : "Scan again and save a new snapshot")
                }
            }

            LimitedResultsLine(screen: .disk, hasResults: state.spaceRoot != nil)

            if state.diskView == .big {
                LiveScanStripSlot(status: state.liveScans[.disk], onStop: { state.cancelSpaceScan() },
                                  onRescan: { Task { await state.scanSpace() } })
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DiskStorageBar(state: state, snapshots: snapshots)
                    switch state.diskView {
                    case .big: DiskBigView(state: state)
                    case .grew: DiskGrewView(state: state, model: snapshots)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 22)
                .frame(maxWidth: 1280, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Disk")
        .cleanSlateScreen()
    }

    private var isRescanning: Bool {
        state.diskView == .big ? state.isScanningSpace : state.isScanningLargeFiles
    }

    private var subtitle: String {
        switch state.diskView {
        case .big:
            if state.isScanningSpace { return "Mapping…" }
            guard let date = state.spaceScannedAt, state.spaceRoot != nil else {
                return "See which folders use the most space"
            }
            return "Scanned " + date.formatted(.relative(presentation: .named))
        case .grew:
            guard let base = snapshots.diff?.old else {
                return "Compares Furl’s own snapshots of your home folder"
            }
            return "Compared with the snapshot from " + base.date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private func rescan() {
        Task {
            switch state.diskView {
            case .big: await state.scanSpace()
            // Large Files refreshes the shared home index, which saves a snapshot.
            case .grew: await state.scanLargeFiles()
            }
        }
    }
}

// MARK: - Storage bar

/// "Macintosh HD · 414 GB used of 500 GB · 86 GB free" with the disk split by kind, and how much
/// the scans found to clean.
struct DiskStorageBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var snapshots: SnapshotsModel
    @State private var categoryTotals: [Int64]?

    private struct Slice: Identifiable {
        let id: String
        let color: Color
        let bytes: Int64
    }

    var body: some View {
        let disk = state.diskUsage
        let slices = makeSlices()
        let total = Double(max(disk.totalBytes, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(disk.volumeName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(FileSizeHelper.formatBytes(disk.usedBytes)) used of \(FileSizeHelper.formatBytes(disk.totalBytes)) · \(FileSizeHelper.formatBytes(disk.availableBytes)) free")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.totalReclaimableBytes > 0 {
                    Text("\(FileSizeHelper.formatBytes(state.totalReclaimableBytes)) can be cleaned")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.sweep)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                let gaps = CGFloat(max(0, slices.count - 1))
                HStack(spacing: 1) {
                    ForEach(slices) { slice in
                        Rectangle().fill(slice.color)
                            .frame(width: max(0, (geo.size.width - gaps) * CGFloat(Double(slice.bytes) / total)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(Theme.border)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(slices) { slice in
                    legend(slice.id, color: slice.color)
                }
                legend("Free", color: Theme.border, outlined: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .task(id: snapshots.latest?.id) {
            guard let id = snapshots.latest?.id else { categoryTotals = nil; return }
            categoryTotals = await SnapshotStore.shared.snapshot(id)?.categoryTotals
        }
    }

    private func legend(_ title: String, color: Color, outlined: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.controlBorder)
                    }
                }
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    /// Apps, Developer, Photos & media, Documents from the latest snapshot of the home folder (and
    /// the Apps scan); System is the rest of what's used. Without a snapshot, one "Used" slice.
    private func makeSlices() -> [Slice] {
        let used = state.diskUsage.usedBytes
        guard let totals = categoryTotals else {
            return [Slice(id: "Used", color: Theme.usedBar, bytes: used)]
        }
        func t(_ c: SnapshotCategory) -> Int64 { Int(c.rawValue) < totals.count ? totals[Int(c.rawValue)] : 0 }
        let installed = state.hasScannedApps ? state.installedApps.reduce(0) { $0 + $1.appSizeBytes } : 0
        let apps = installed + t(.appData)
        let developer = t(.developer) + t(.caches) + t(.aiModels) + t(.docker)
        let media = t(.media)
        let documents = t(.documents) + t(.downloads) + t(.other) + t(.trash)
        let system = max(0, used - apps - developer - media - documents)
        return [
            Slice(id: "Apps", color: DiskPalette.apps, bytes: apps),
            Slice(id: "Developer", color: DiskPalette.developer, bytes: developer),
            Slice(id: "Photos & media", color: DiskPalette.media, bytes: media),
            Slice(id: "Documents", color: DiskPalette.documents, bytes: documents),
            Slice(id: "System", color: DiskPalette.system, bytes: system),
        ]
    }
}

/// The board's five storage kinds, all existing Theme tokens.
enum DiskPalette {
    static let apps = Theme.usedBar
    static let developer = Theme.memory
    static let media = Theme.violet
    static let documents = Theme.storageSystem
    static let system = Theme.storageOther

    static func color(forPath path: String, advice: DiskAdvice) -> Color {
        if path == "/Applications" || path.hasPrefix("/Applications/") { return apps }
        switch DiskFindings.category(forPath: path) {
        case .developer, .caches, .aiModels, .docker: return developer
        case .media: return media
        case .appData: return apps
        case .documents, .downloads, .trash: return documents
        case .other:
            // ~/code and the like: developer when what was found there is developer stuff.
            return advice.section == .worktrees || advice.section == .junk ? developer : documents
        }
    }
}

// MARK: - Hand-off

enum DiskHandoff {
    /// Opens the section a row's chip names, filtered to that folder; "Open" shows it in the Inspector.
    @MainActor
    static func perform(_ advice: DiskAdvice, path: String, state: AppState) {
        guard let section = advice.section else {
            InspectorStore.shared.show(path: path, state: state)
            return
        }
        // Apps & Leftovers searches app names, not paths, so it opens unfiltered.
        state.handOff(to: section, filter: section == .apps ? nil : path)
    }
}

/// Clean (primary) / Review / Pick files / Open, 26 pt high.
struct DiskActionChip: View {
    let action: DiskAdvice.Action
    /// Named in the VoiceOver label, so "Clean" says which folder.
    let displayPath: String
    let onTap: () -> Void

    var body: some View {
        Button(action.title, action: onTap)
            .buttonStyle(SweepButtonStyle(kind: action == .clean ? .primary : .secondary, height: 26))
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .help(help)
            .accessibilityLabel("\(action.title) \(displayPath)")
    }

    private var help: String {
        switch action {
        case .clean: return "Open the safe items in this folder"
        case .review: return "Open what was found here so you can check it first"
        case .pickFiles: return "Open the large files in this folder"
        case .open: return "Show this folder in the Inspector"
        }
    }
}

// MARK: - What grew

/// Disk › What grew (was Snapshots): growth since Furl's own snapshot, each grown folder with an action.
struct DiskGrewView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SnapshotsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let diff = model.diff {
                summary(diff)
                rows(diff)
            } else {
                QuietEmptyState(
                    systemImage: "chart.line.uptrend.xyaxis",
                    title: model.latest == nil ? "No snapshot yet" : "Nothing to compare yet",
                    message: model.latest == nil
                        ? "Each scan saves a small summary of your folder sizes on this Mac. Scan once now, and again later, to see what grew."
                        : "Your first snapshot is saved. After the next scan this shows what grew."
                )
                .frame(minHeight: 260)
            }
        }
    }

    private var rangeOptions: [SnapshotsModel.Range] {
        var options: [SnapshotsModel.Range] = [.week, .month]
        if model.summaries.count > 1, let oldest = model.summaries.first { options.append(.since(oldest.id)) }
        return options
    }

    private func rangeTitle(_ r: SnapshotsModel.Range) -> String {
        switch r {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .since(let id):
            guard let s = model.summaries.first(where: { $0.id == id }) else { return "Since" }
            return "Since " + s.date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private var periodPhrase: String {
        switch model.range {
        case .today: return "today"
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .since: return rangeTitle(model.range).lowercased()
        }
    }

    private func summary(_ diff: SnapshotDiff) -> some View {
        let net = diff.net
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(net >= 0 ? "Grew" : "Shrank") \(periodPhrase)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                Text((net >= 0 ? "+" : "−") + FileSizeHelper.formatBytes(abs(net)))
                    .font(Theme.display(28, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(net >= 0 ? Theme.growth : Theme.sweep)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                if let forecast = forecast(diff) { Text(forecast) }
                Text("Snapshots are saved with each scan, one kept per day.")
            }
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 8)
            DiskSegmented(options: rangeOptions, selection: $model.range, title: rangeTitle, height: 20)
                .fixedSize()
        }
    }

    /// "At this rate the disk is full in about 6 weeks", from the growth between the two snapshots.
    private func forecast(_ diff: SnapshotDiff) -> String? {
        let days = diff.new.date.timeIntervalSince(diff.old.date) / 86_400
        guard diff.net > 0, days >= 1 else { return nil }
        let perDay = Double(diff.net) / days
        let left = Double(state.diskUsage.availableBytes) / perDay
        if left < 14 { return "At this rate the disk is full in about \(max(1, Int(left.rounded()))) days." }
        let weeks = Int((left / 7).rounded())
        guard weeks <= 52 else { return nil }
        return "At this rate the disk is full in about \(weeks) weeks."
    }

    @ViewBuilder
    private func rows(_ diff: SnapshotDiff) -> some View {
        let spots = diff.hotspots().filter { $0.delta > 0 }.prefix(10)
        let findings = state.diskFindings
        VStack(spacing: 0) {
            if spots.isEmpty {
                Text("Nothing grew by more than 25 MB \(periodPhrase).")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            ForEach(Array(spots.enumerated()), id: \.element.id) { index, change in
                if index > 0 { Divider().overlay(Theme.hairline) }
                let path = model.absolutePath(change.path)
                let advice = findings.advice(for: path, category: change.category)
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.growth)
                        .frame(width: 15)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayPath(change.path))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(subtitle(change))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("+" + FileSizeHelper.formatBytes(change.delta))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.growth)
                        .lineLimit(1)
                        .frame(width: 80, alignment: .trailing)
                    DiskActionChip(action: advice.action, displayPath: model.displayPath(change.path)) {
                        DiskHandoff.perform(advice, path: path, state: state)
                    }
                    .frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityElement(children: .contain)
                .pathContextMenu(path)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func subtitle(_ c: FolderChange) -> String {
        if c.isNew || c.oldSize == 0 { return "New · \(c.category.title)" }
        return "\(c.category.title) · \(FileSizeHelper.formatBytes(c.oldSize)) → \(FileSizeHelper.formatBytes(c.newSize))"
    }
}

// MARK: - Shared pieces

/// The board's compact segmented control: hairline track, a raised surface pill on the choice.
struct DiskSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: height)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// DiskScreen "Sections with nothing to do stay in the sidebar, quietly": a small tinted icon tile,
/// a short title and one calm line.
struct QuietEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.sweepDeep)
                .frame(width: 44, height: 44)
                .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

/// Overview card: the disk as a segmented bar (macOS, your files, apps, junk, purgeable, free)
/// with a legend. Clicking a slice explains what it is, what can be reclaimed and where to go.
struct StorageBreakdownCard: View {
    @ObservedObject var state: AppState
    @State private var snapshot: VolumeSnapshot?
    @State private var selected: StorageSlice?
    @State private var hovered: StorageSlice?
    @Environment(\.colorScheme) private var colorScheme

    init(state: AppState, selected: StorageSlice? = nil, snapshot: VolumeSnapshot? = nil) {
        self.state = state
        _selected = State(initialValue: selected)
        _snapshot = State(initialValue: snapshot)
    }

    /// Bar and legend order: what you keep (grey), what you could clear (colour), then free.
    private static let order: [StorageSlice] = [.system, .other, .apps, .junk, .purgeable, .free]

    var body: some View {
        let breakdown = makeBreakdown()
        VStack(alignment: .leading, spacing: 14) {
            header(breakdown)
            bar(breakdown)
            Text("Grey is what you keep. Colour is what you could clear. Click any slice.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
            legend(breakdown)
            if let selected, let entry = breakdown.entry(selected) {
                StorageSliceExplainer(state: state, entry: entry, snapshot: snapshot ?? .empty) {
                    self.selected = nil
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card(padding: 20)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .task(id: state.diskUsage.availableBytes) {
            snapshot = await Task.detached(priority: .utility) {
                StorageBreakdownService.snapshot()
            }.value
        }
    }

    private func makeBreakdown() -> StorageBreakdown {
        let apps: Int64? = state.hasScannedApps
            ? state.installedApps.reduce(0) { $0 + $1.appSizeBytes }
            : nil
        let junk: Int64? = state.hasScannedAnything || state.trashSizeBytes > 0 ? state.totalReclaimableBytes : nil
        let fallback = VolumeSnapshot(
            totalBytes: state.diskUsage.totalBytes,
            freeBytes: state.diskUsage.availableBytes,
            importantAvailableBytes: state.diskUsage.availableBytes,
            systemBytes: nil,
            volumeName: state.diskUsage.volumeName
        )
        return StorageBreakdown(snapshot: snapshot ?? fallback, appsBytes: apps, junkBytes: junk)
    }

    // MARK: Header

    private func header(_ breakdown: StorageBreakdown) -> some View {
        let available = (snapshot?.importantAvailableBytes) ?? state.diskUsage.availableBytes
        return HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: snapshot?.volumeName ?? state.diskUsage.volumeName)
                (Text(FileSizeHelper.formatBytes(available) + " available ")
                    .font(Theme.display(26))
                    .foregroundColor(Theme.ink)
                 + Text("of \(FileSizeHelper.formatBytes(breakdown.totalBytes))")
                    .font(Theme.display(17, weight: .medium))
                    .foregroundColor(Theme.inkSecondary))
                    .monospacedDigit()
            }
            Spacer()
            if let purgeable = snapshot?.purgeableBytes, purgeable > 0 {
                Text("includes \(FileSizeHelper.formatBytes(purgeable)) purgeable")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Bar

    private func bar(_ breakdown: StorageBreakdown) -> some View {
        let total = Double(max(breakdown.totalBytes, 1))
        let entries = Self.order.compactMap { breakdown.entry($0) }.filter { $0.bytes > 0 }
        return GeometryReader { geo in
            let gaps = CGFloat(max(entries.count - 1, 0)) * 2
            let width = max(0, geo.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    slice(entry, isFirst: index == 0, isLast: index == entries.count - 1,
                          width: max(3, width * Double(entry.bytes) / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 30)
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.5), value: breakdown.entries.map(\.bytes))
    }

    /// One slice of the bar. Its own function so the type checker doesn't time out on older toolchains.
    private func slice(_ entry: StorageBreakdown.Entry, isFirst: Bool, isLast: Bool, width: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 7 : 0,
            bottomLeadingRadius: isFirst ? 7 : 0,
            bottomTrailingRadius: isLast ? 7 : 0,
            topTrailingRadius: isLast ? 7 : 0,
            style: .continuous
        )
        return shape
            .fill(StorageSliceStyle.color(entry.slice))
            .overlay {
                if entry.slice == .free {
                    // Board: 1 pt inset controlBorder outline.
                    shape.strokeBorder(Theme.controlBorder, lineWidth: 1)
                }
            }
            .frame(width: width)
            .opacity(dimmed(entry.slice) ? 0.35 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? entry.slice : (hovered == entry.slice ? nil : hovered) }
            .onTapGesture { toggle(entry.slice) }
            .help("\(entry.slice.title): \(sizeText(entry))")
            .accessibilityElement()
            .accessibilityLabel("\(entry.slice.title), \(sizeText(entry))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle(entry.slice) }
    }

    private func dimmed(_ slice: StorageSlice) -> Bool {
        if let selected { return selected != slice }
        if let hovered { return hovered != slice }
        return false
    }

    private func toggle(_ slice: StorageSlice) {
        selected = selected == slice ? nil : slice
    }

    // MARK: Legend

    private func legend(_ breakdown: StorageBreakdown) -> some View {
        // Board: three equal columns, 12 pt gaps.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(Self.order.compactMap { breakdown.entry($0) }) { entry in
                legendCard(entry)
            }
        }
    }

    private func legendCard(_ entry: StorageBreakdown.Entry) -> some View {
        let isSelected = selected == entry.slice
        return Button {
            toggle(entry.slice)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StorageSliceStyle.swatch(entry.slice)
                    Text(entry.slice.title)
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Text("Estimate")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .opacity(entry.isEstimate && entry.isMeasured ? 1 : 0)
                        .accessibilityHidden(!(entry.isEstimate && entry.isMeasured))
                }
                Text(sizeText(entry))
                    .font(Theme.display(22))
                    .foregroundStyle(entry.isMeasured ? Theme.ink : Theme.inkSecondary)
                    .monospacedDigit()
                Text(StorageSliceStyle.caption(entry, state: state))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(14)
            // Board: mintTint at 50% (light) / 60% (dark).
            .background(isSelected ? Theme.mintTint.opacity(colorScheme == .dark ? 0.6 : 0.5) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.sweep : (hovered == entry.slice ? Theme.controlBorder : Theme.border),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.slice : (hovered == entry.slice ? nil : hovered) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sizeText(_ entry: StorageBreakdown.Entry) -> String {
        guard entry.isMeasured else { return "—" }
        return (entry.isEstimate ? "≈ " : "") + FileSizeHelper.formatBytes(entry.bytes)
    }
}

// MARK: - Style

enum StorageSliceStyle {
    static func color(_ slice: StorageSlice) -> Color {
        switch slice {
        case .system: return Theme.storageSystem
        case .other: return Theme.storageOther
        case .apps: return Theme.memory
        case .junk: return Theme.sweep
        case .purgeable: return Theme.mint
        case .free: return Theme.surface
        }
    }

    static func swatch(_ slice: StorageSlice) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(slice))
            .overlay {
                if slice == .free {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1)
                }
            }
            .frame(width: 10, height: 10)
    }

    @MainActor
    static func caption(_ entry: StorageBreakdown.Entry, state: AppState) -> String {
        switch entry.slice {
        case .apps:
            return entry.isMeasured ? "\(state.installedApps.count) installed apps" : "Scan Apps to measure"
        case .junk:
            return entry.isMeasured ? "What Furl found it can clean" : "Scan to find caches and junk"
        case .system:
            return entry.isMeasured ? "macOS, recovery, updates and swap" : "Couldn't read the system volumes"
        case .purgeable:
            return "macOS frees this by itself when needed"
        case .other:
            return "Documents, photos, mail and the rest"
        case .free:
            return "Ready to use now"
        }
    }
}

// MARK: - Explainer

/// What a slice is, what can be reclaimed from it, and which section to open.
struct StorageSliceExplainer: View {
    @ObservedObject var state: AppState
    let entry: StorageBreakdown.Entry
    let snapshot: VolumeSnapshot
    let onClose: () -> Void

    private struct Destination: Identifiable {
        let section: SidebarSection
        let detail: String?
        var id: SidebarSection { section }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StorageSliceStyle.swatch(entry.slice)
                Text(entry.slice.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if entry.isEstimate {
                    BadgeView(text: "Estimate", color: Theme.inkSecondary,
                              help: "Worked out from what macOS reports, not measured file by file")
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            HStack(alignment: .top, spacing: 24) {
                block(title: "What it is", text: whatItIs)
                block(title: "What you can reclaim", text: reclaim)
            }

            let destinations = self.destinations
            if !destinations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where to go")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                    FlowRow(spacing: 8) {
                        ForEach(destinations) { dest in
                            Button {
                                state.selectedSection = dest.section
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: dest.section.systemImage)
                                    Text(dest.section.rawValue)
                                    if let detail = dest.detail {
                                        Text(detail)
                                            .foregroundStyle(Theme.inkSecondary)
                                            .monospacedDigit()
                                    }
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.ink)
                                }
                            }
                            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 30))
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.inkTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bytes(_ value: Int64) -> String { FileSizeHelper.formatBytes(value) }

    private var whatItIs: String {
        switch entry.slice {
        case .apps:
            return "The app bundles in /Applications and ~/Applications. Their settings and caches live in your Library and are counted under your files."
        case .junk:
            return "Everything Furl's scans found it can clean: caches and build files, merged Git worktrees, leftovers from deleted apps, extra copies of duplicate files, and what's waiting in the Trash."
        case .system:
            return "The read-only macOS system volume plus Preboot, Recovery, downloaded updates and the VM volume that holds swap and the sleep image. Measured with diskutil."
        case .purgeable:
            return "Space macOS can free on its own when it needs room: local Time Machine snapshots, iCloud files also stored on this Mac, and some caches. macOS reports it as the gap between free and available space, so the size is an estimate."
        case .other:
            return "Everything else: documents, photos, mail, messages, developer tools and app data in your Library. It's what's left after the measured slices, so it's an estimate and it may include things Furl hasn't scanned yet."
        case .free:
            return "Space that isn't used by anything right now."
        }
    }

    private var reclaim: String {
        switch entry.slice {
        case .apps:
            guard state.hasScannedApps else { return "Scan Apps to see how big each app is. Uninstalling also removes its leftovers." }
            let leftovers = state.totalOrphanedAppDataBytes
            return "Uninstall apps you don't use; Furl removes their support files too, and by default they go to the Trash."
                + (leftovers > 0 ? " Apps you already deleted left \(bytes(leftovers)) behind." : "")
        case .junk:
            guard entry.isMeasured else { return "Run a scan to find caches, build files and other junk." }
            return "Up to \(bytes(entry.bytes)). Most of it is rebuilt automatically when needed. Items go to the Trash first, so you can undo with ⌥⌘Z."
        case .system:
            return "Nothing safely. macOS manages this space. Swap shrinks after a restart, or after closing apps that use a lot of memory."
        case .purgeable:
            return "Usually nothing to do: \(bytes(snapshot.purgeableBytes)) already counts as available, and macOS clears it when space runs low."
        case .other:
            return "This is mostly your own data, so Furl doesn't clean it automatically. Large Files, Smart Review and Space Map help you find what's big and what you no longer need."
        case .free:
            let total = max(snapshot.totalBytes, state.diskUsage.totalBytes)
            let percent = total > 0 ? Int((Double(entry.bytes) / Double(total) * 100).rounded()) : 0
            return "\(percent)% of the disk is free. Keep some room so macOS can install updates and grow swap."
        }
    }

    private var destinations: [Destination] {
        func size(_ value: Int64, _ scanned: Bool) -> String? { scanned && value > 0 ? bytes(value) : nil }
        switch entry.slice {
        case .apps:
            return [Destination(section: .apps, detail: size(entry.bytes, entry.isMeasured))]
        case .junk:
            return [
                Destination(section: .junk, detail: size(state.totalJunkReclaimableBytes, state.hasScannedJunk)),
                Destination(section: .worktrees, detail: size(state.totalWorktreeReclaimableBytes, state.hasScannedWorktrees)),
                Destination(section: .duplicates, detail: size(state.totalDuplicateReclaimableBytes, state.hasScannedDuplicates)),
                Destination(section: .apps, detail: size(state.totalOrphanedAppDataBytes, state.hasScannedApps).map { "\($0) leftovers" })
            ]
        case .system:
            return [Destination(section: .processes, detail: nil)]
        case .purgeable, .free:
            return []
        case .other:
            return [
                Destination(section: .largeFiles, detail: size(state.totalLargeFilesBytes, state.hasScannedLargeFiles)),
                Destination(section: .smartReview, detail: nil),
                Destination(section: .spaceMap, detail: nil)
            ]
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

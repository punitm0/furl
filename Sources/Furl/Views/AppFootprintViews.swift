import SwiftUI

// MARK: - App list

/// One row in the Apps footprint list: icon, name, last-opened line, total footprint.
struct AppFootprintRow: View {
    let app: InstalledAppItem
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIconView(bundlePath: app.bundlePath, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if app.isAppleApp {
                            BadgeView(text: "Apple", color: Theme.inkSecondary, help: "Managed by macOS; shown for reference only.")
                        }
                    }
                    Text(app.lastOpenedDescription)
                        .font(Theme.caption)
                        .foregroundStyle(app.isUnused90Days ? Theme.warning : Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(FileSizeHelper.formatBytes(app.totalSizeBytes))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.mintTint : (hovering ? Theme.surfaceSubtle : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .pathContextMenu(app.bundlePath, allowOpen: false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Footprint breakdown

/// Stacked bar of an app's footprint, one segment per category.
struct FootprintBar: View {
    let slices: [FootprintSlice]
    var height: CGFloat = 14

    var body: some View {
        let total = max(1, slices.reduce(Int64(0)) { $0 + $1.bytes })
        let visible = slices.filter { $0.bytes > 0 }
        GeometryReader { geo in
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { slice in
                    Rectangle()
                        .fill(slice.category.color)
                        .overlay(Rectangle().strokeBorder(slice.category.outline, lineWidth: 1))
                        .frame(width: max(3, (geo.size.width - gaps) * CGFloat(Double(slice.bytes) / Double(total))))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Footprint breakdown")
        .accessibilityValue(visible.map { "\($0.category.rawValue) \(FileSizeHelper.formatBytes($0.bytes))" }.joined(separator: ", "))
    }
}

/// Right-hand panel: total footprint, breakdown, per-folder detail and the two actions.
struct AppFootprintDetail: View {
    let app: InstalledAppItem
    @Binding var selectedDataIDs: Set<String>
    let isBusy: Bool
    let onClearRebuildable: () -> Void
    let onUninstall: () -> Void
    var onAddToTray: (() -> Void)? = nil

    @State private var expanded = Set<FootprintCategory>()

    var body: some View {
        let slices = app.footprintSlices
        VStack(alignment: .leading, spacing: 18) {
            header
            FootprintBar(slices: slices)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slices) { slice in
                        legendRow(slice)
                        if expanded.contains(slice.category) {
                            if slice.category == .app {
                                itemRow(name: "\(app.name).app", path: app.bundlePath, bytes: app.appSizeBytes, item: nil)
                            } else {
                                ForEach(slice.items) { item in
                                    itemRow(name: item.name, path: item.path, bytes: item.sizeBytes, item: item)
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .onChange(of: app.id) { _, _ in expanded.removeAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(app.name) · \(FileSizeHelper.formatBytes(app.totalSizeBytes)) in total")
                .font(Theme.display(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(app.dataSizeBytes > 0
                 ? "The app itself is only \(FileSizeHelper.formatBytes(app.appSizeBytes))"
                 : "No data in ~/Library")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
    }

    private func legendRow(_ slice: FootprintSlice) -> some View {
        let isOpen = expanded.contains(slice.category)
        let count = slice.category == .app ? 1 : slice.items.count
        return Button {
            if isOpen { expanded.remove(slice.category) } else { expanded.insert(slice.category) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(slice.category.color)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(slice.category.outline, lineWidth: 1))
                    .frame(width: 10, height: 10)
                Text(slice.category == .app ? "\(app.name).app" : slice.category.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                if slice.category != .app {
                    Text(count == 1 ? "1 folder" : "\(count) folders")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                if slice.category.isRebuildable {
                    RiskChip(tier: .safe, help: "Safe: the app recreates these when it needs them.")
                }
                Spacer()
                Text(FileSizeHelper.formatBytes(slice.bytes))
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Hide folders" : "Show folders")
    }

    private func itemRow(name: String, path: String, bytes: Int64, item: AppDataItem?) -> some View {
        HStack(spacing: 10) {
            if let item {
                Toggle("", isOn: Binding(
                    get: { selectedDataIDs.contains(item.id) },
                    set: { checked in
                        if checked { selectedDataIDs.insert(item.id) } else { selectedDataIDs.remove(item.id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.furlCheckbox)
                .help("Include when uninstalling")
                .disabled(!app.allowsFootprintActions)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let item, !item.isStrongMatch {
                        BadgeView(text: "Possible match", color: Theme.warning, help: "Name only partly matches this app; it may belong to a related app. Not included by default.")
                    }
                }
                Text(path)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(FileSizeHelper.formatBytes(bytes))
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
            Button {
                DeletionService.revealInFinder(path)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.leading, 20)
        .padding(.vertical, 4)
        .pathContextMenu(path, allowOpen: false)
    }

    private var footer: some View {
        // Apps board: the note on its own line, the buttons right-aligned under it.
        VStack(alignment: .leading, spacing: 10) {
            footerText
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                footerButtons
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footerText: some View {
        Text(footerNote)
            .font(Theme.body)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(2)
    }

    @ViewBuilder private var footerButtons: some View {
        if let onAddToTray {
            AddToTrayButton(count: app.allowsFootprintActions ? 1 : 0, action: onAddToTray)
                .disabled(!app.allowsFootprintActions || isBusy)
        }
        Button(action: onClearRebuildable) {
            Text(app.rebuildableBytes > 0
                 ? "Clear caches & logs · \(FileSizeHelper.formatBytes(app.rebuildableBytes))"
                 : "Clear caches & logs")
                .monospacedDigit()
        }
        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 40))
        .fixedSize()
        .disabled(!app.allowsFootprintActions || app.rebuildableItems.isEmpty || isBusy)
        .help("Move this app's caches and logs to the Trash. It rebuilds them as needed.")

        Button(action: onUninstall) {
            Text("Uninstall with leftovers")
        }
        .buttonStyle(SweepButtonStyle(kind: .primary, height: 40))
        .fixedSize()
        .disabled(!app.allowsFootprintActions || isBusy)
    }

    private var footerNote: String {
        if app.isAppleApp { return "Apple apps are managed by macOS and can't be changed here." }
        var parts = [app.lastOpenedDescription]
        if let date = app.lastOpenedDate, !app.isRunning {
            parts[0] = "Last opened \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        parts.append("Version \(app.version)")
        return parts.joined(separator: " · ")
    }
}

/// Pill tab control from the Apps board (Footprint · Unused 90+ days · Leftovers).
struct PillTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    @Namespace private var pill
    @State private var hovered: Tab?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                let isOn = tab == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isOn ? Theme.ink : (hovered == tab ? Theme.ink : Theme.inkSecondary))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            // One highlight that slides between tabs instead of jumping.
                            if isOn {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else if hovered == tab {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.surface.opacity(0.45))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                }
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension FootprintCategory {
    var color: Color {
        switch self {
        // Apps boards: the .app slice is C9D0CC / 3B4641 (storageOther), Application Support is pine.
        case .app: return Theme.storageOther
        case .applicationSupport: return Theme.pine
        case .containers: return Theme.memory
        case .caches: return Theme.sweep
        case .logs: return Theme.mint
        case .preferences: return Theme.violet
        case .webData: return Theme.accentTeal.fg
        }
    }

    /// AppsDark: pine needs its 1 px inset stroke to read on dark surfaces (clear in light mode).
    var outline: Color {
        self == .applicationSupport ? Theme.heroStroke : .clear
    }
}

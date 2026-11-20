import AppKit
import SwiftUI

/// Disk › What's big (was Space Map): the biggest folders, each ending in an action that hands off
/// to the section that can clean it. The old map (bar, legend, % list, Remove) is behind "Show as map".
struct DiskBigView: View {
    @ObservedObject var state: AppState
    @State private var showMap = false
    @State private var nodeToRemove: SpaceNode?
    @State private var targets: [SpaceAnalyzer.ScanTarget] = []

    private static let palette: [Color] = Theme.chartPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.isScanningSpace && state.spaceCurrent == nil {
                scanningView
            } else if let current = state.spaceCurrent {
                if state.spaceMapIsStale { staleNotice }
                if showMap {
                    mapToolbar
                    breadcrumb(for: current)
                    summary(for: current)
                    mapList(for: current)
                } else {
                    listHeader(for: current)
                    folderList(for: current)
                }
            } else {
                QuietEmptyState(systemImage: "internaldrive", title: "Nothing mapped yet",
                                message: "Rescan to see which folders use the most space.")
                    .frame(minHeight: 260)
            }
        }
        .onAppear {
            targets = SpaceAnalyzer.availableTargets()
            // Scan automatically the first time Disk is opened.
            if state.spaceRoot == nil && !state.isScanningSpace {
                Task { await state.scanSpace() }
            }
        }
        .confirmationDialog(
            "Remove “\(nodeToRemove?.name ?? "")”?",
            isPresented: Binding(get: { nodeToRemove != nil }, set: { if !$0 { nodeToRemove = nil } }),
            titleVisibility: .visible
        ) {
            if let node = nodeToRemove {
                Button("\(state.deletionMode.rawValue) (\(FileSizeHelper.formatBytes(node.sizeBytes)))", role: .destructive) {
                    Task { await state.removeSpaceNode(node) }
                    nodeToRemove = nil
                }
                Button("Cancel", role: .cancel) { nodeToRemove = nil }
            }
        } message: {
            if let node = nodeToRemove {
                Text(Self.displayPath(node.path) + (state.deletionMode == .moveToTrash ? "\n\nIt goes to the Trash; you can undo right after." : "\n\nThis can't be undone."))
            }
        }
    }

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return DiskFindings.contains(home, path) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: List (DiskScreen "What's big")

    /// "Biggest folders · Macintosh HD › Users › you", each crumb that is a mapped folder a button.
    private func listHeader(for node: SpaceNode) -> some View {
        let chain = node.ancestry
        let rootParts = (chain.first?.path ?? "").split(separator: "/").dropLast().map(String.init)
        return HStack(spacing: 8) {
            Text("Biggest folders").fontWeight(.semibold).foregroundStyle(Theme.ink)
            Text("·")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text(state.diskUsage.volumeName)
                    ForEach(rootParts, id: \.self) { part in
                        Text("›")
                        Text(part)
                    }
                    ForEach(chain, id: \.id) { crumb in
                        Text("›")
                        if crumb === node {
                            Text((crumb.path as NSString).lastPathComponent).foregroundStyle(Theme.ink)
                        } else {
                            Button((crumb.path as NSString).lastPathComponent) { state.spaceCurrent = crumb }
                                .buttonStyle(.plain)
                                .help("Back to \(Self.displayPath(crumb.path))")
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            unreadableLink
            Button("Show as map") { withAnimation(.easeOut(duration: 0.15)) { showMap = true } }
                .buttonStyle(SweepLinkStyle())
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
    }

    private func folderList(for node: SpaceNode) -> some View {
        let rows = node.children.filter { !$0.isAggregate }
        let maxSize = Double(max(rows.first?.sizeBytes ?? 1, 1))
        let findings = state.diskFindings
        return VStack(spacing: 0) {
            if let parent = node.parent {
                Button { state.spaceCurrent = parent } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back to \(Self.displayPath(parent.path))")
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: [.command])
                .help("Back (⌘[)")
                Divider().overlay(Theme.hairline)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, child in
                if index > 0 { Divider().overlay(Theme.hairline) }
                let advice = findings.advice(for: child.path)
                DiskFolderRow(
                    node: child,
                    advice: advice,
                    color: DiskPalette.color(forPath: child.path, advice: advice),
                    barFraction: Double(child.sizeBytes) / maxSize,
                    onOpen: { state.spaceCurrent = child },
                    onAction: { DiskHandoff.perform(advice, path: child.path, state: state) },
                    onRemove: { nodeToRemove = child }
                )
            }
            if rows.isEmpty {
                Text(node.isPackage ? "This is an app or package; its contents aren't listed." : "This folder is empty or couldn't be read.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .id(state.spaceRevision)
    }

    @ViewBuilder private var unreadableLink: some View {
        if state.spaceUnreadableCount > 0 && !state.isScanningSpace {
            Button {
                DeletionService.openFullDiskAccessSettings()
            } label: {
                Label("\(state.spaceUnreadableCount.formatted()) folders unreadable", systemImage: "lock")
            }
            .buttonStyle(SweepLinkStyle())
            .font(.system(size: 11))
            .help("macOS blocked access to these folders. Grant Full Disk Access for a complete picture.")
        }
    }

    // MARK: Map (behind "Show as map")

    private var mapToolbar: some View {
        HStack(spacing: 12) {
            Text("Map")
                .foregroundStyle(Theme.inkSecondary)
            Menu {
                ForEach(targets) { target in
                    Button {
                        Task { await state.scanSpace(target: target) }
                    } label: {
                        Label(target.name, systemImage: target.systemImage)
                    }
                }
                Divider()
                Button("Choose Folder…") {
                    Task { await state.scanCustomSpaceFolder() }
                }
            } label: {
                ToolbarChipLabel(title: state.spaceTarget?.name ?? "Home Folder",
                                 systemImage: state.spaceTarget?.systemImage ?? "house",
                                 showsChevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(state.isScanningSpace)
            .help("Choose what to analyze")

            Spacer()
            unreadableLink
            Button("Show as list") { withAnimation(.easeOut(duration: 0.15)) { showMap = false } }
                .buttonStyle(SweepLinkStyle())
        }
        .controlSize(.small)
        .font(.system(size: 12))
    }

    private var scanningView: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.large)
            Text("Mapping \(state.spaceTarget?.name ?? "folder")…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
            Text("\(state.spaceScannedCount.formatted()) items scanned")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
            ScanStripBar(fraction: state.liveScans[.disk]?.fraction)
                .frame(width: 220)
                .clipShape(Capsule())
            CancelRunButton(compact: true) { state.cancelSpaceScan() }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var staleNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Items were restored from the Trash. Rescan to update the map.")
                .font(.system(size: 12))
            Spacer()
            Button("Rescan") { Task { await state.scanSpace() } }
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private func breadcrumb(for node: SpaceNode) -> some View {
        let chain = node.ancestry
        return HStack(spacing: 8) {
            Button {
                if let parent = node.parent { state.spaceCurrent = parent }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.borderless)
            .disabled(node.parent == nil)
            .opacity(node.parent == nil ? 0.35 : 1)
            .keyboardShortcut("[", modifiers: [.command])
            .help("Back (⌘[)")
            .accessibilityLabel("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Button(crumb.name) {
                            state.spaceCurrent = crumb
                        }
                        .buttonStyle(.borderless)
                        .font(crumb === node ? .system(size: 13, weight: .semibold) : .system(size: 12))
                        .foregroundStyle(crumb === node ? Theme.ink : Theme.inkSecondary)
                    }
                }
            }
        }
    }

    private func summary(for node: SpaceNode) -> some View {
        let top = Array(node.children.prefix(8))
        let total = Double(max(node.sizeBytes, 1))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(FileSizeHelper.formatBytes(node.sizeBytes))
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("in \(node.itemCount.formatted()) items")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button {
                    DeletionService.revealInFinder(node.path)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
            }

            SegmentedUsageBar(
                segments: top.enumerated().map { index, child in
                    .init(id: child.id, fraction: Double(child.sizeBytes) / total, color: color(for: index, child: child))
                },
                height: 22
            )

            FlowLegend(items: top.enumerated().map { index, child in
                (color(for: index, child: child), child.name, FileSizeHelper.formatBytes(child.sizeBytes))
            })
        }
        .card()
        .id(state.spaceRevision)
    }

    private func color(for index: Int, child: SpaceNode) -> Color {
        child.isAggregate ? Self.palette[6].opacity(0.5) : Self.palette[index % Self.palette.count]
    }

    private func mapList(for node: SpaceNode) -> some View {
        let maxSize = Double(max(node.children.first?.sizeBytes ?? 1, 1))
        let total = Double(max(node.sizeBytes, 1))

        return VStack(spacing: 2) {
            ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                SpaceRow(
                    node: child,
                    color: color(for: index, child: child),
                    barFraction: Double(child.sizeBytes) / maxSize,
                    shareOfParent: Double(child.sizeBytes) / total,
                    onOpen: { state.spaceCurrent = child },
                    onRemove: { nodeToRemove = child }
                )
            }
            if node.children.isEmpty {
                Text(node.isPackage ? "This is an app or package; its contents aren't listed." : "This folder is empty or couldn't be read.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding()
            }
        }
        .id(state.spaceRevision)
    }
}

/// One "What's big" row: folder icon, path and what was found, size bar, size, action chip.
private struct DiskFolderRow: View {
    let node: SpaceNode
    let advice: DiskAdvice
    let color: Color
    let barFraction: Double
    let onOpen: () -> Void
    let onAction: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    private var accessibilityName: String {
        "\(DiskBigView.displayPath(node.path)), \(FileSizeHelper.formatBytes(node.sizeBytes)), \(detail)"
    }

    private var nameBlock: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(DiskBigView.displayPath(node.path))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovering && node.canDrillIn ? Theme.sweep : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // The path is the drill-in: a real button, so Tab and VoiceOver reach it. Rows that
            // can't be opened are a plain label, not a disabled button.
            if node.canDrillIn {
                Button(action: onOpen) {
                    nameBlock.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .accessibilityLabel(accessibilityName)
                .accessibilityHint("Shows the folders inside")
                .help("Show what's inside \(node.name)")
            } else {
                nameBlock
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityName)
                    .help(node.path)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.hairline)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                        .frame(width: max(4, geo.size.width * min(1, barFraction)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text(FileSizeHelper.formatBytes(node.sizeBytes))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 64, alignment: .trailing)

            DiskActionChip(action: advice.action, displayPath: DiskBigView.displayPath(node.path), onTap: onAction)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            if node.canDrillIn {
                Button("Show What's Inside", action: onOpen)
            }
            Button("Show in Inspector") {
                InspectorStore.shared.show(path: node.path, state: AppServices.state)
            }
            Button("Reveal in Finder") {
                DeletionService.revealInFinder(node.path)
            }
            Button("Copy Path") {
                DeletionService.copyPath(node.path)
            }
            Divider()
            Button("Remove…", role: .destructive, action: onRemove)
                .disabled(DeletionService.isProtected(node.path))
        }
    }

    private var detail: String {
        if let found = advice.detail { return found }
        return node.isDirectory ? "\(node.itemCount.formatted()) items" : "File"
    }
}

private struct SpaceRow: View {
    let node: SpaceNode
    let color: Color
    let barFraction: Double
    let shareOfParent: Double
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        // A real button, not a tap gesture: Tab, Space and VoiceOver can drill in too.
        Button {
            if node.canDrillIn { onOpen() }
        } label: {
            HStack(spacing: 12) {
                icon
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(node.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if node.isDirectory && !node.isAggregate {
                            Text("\(node.itemCount.formatted()) items")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geo.size.width * barFraction))
                    }
                    .frame(height: 6)
                }

                Text(shareOfParent.formatted(.percent.precision(.fractionLength(shareOfParent < 0.01 ? 1 : 0))))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 48, alignment: .trailing)

                Text(FileSizeHelper.formatBytes(node.sizeBytes))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 80, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .opacity(node.canDrillIn ? 1 : 0)
                    .frame(width: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering && node.canDrillIn ? Theme.ink.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(node.name), \(FileSizeHelper.formatBytes(node.sizeBytes))")
        .accessibilityHint(node.canDrillIn ? "Shows the folders inside" : "")
        .contextMenu {
            if !node.isAggregate {
                if node.canDrillIn {
                    Button("Show What's Inside", action: onOpen)
                }
                Button("Reveal in Finder") {
                    DeletionService.revealInFinder(node.path)
                }
                Button("Copy Path") {
                    DeletionService.copyPath(node.path)
                }
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
                .disabled(DeletionService.isProtected(node.path))
            }
        }
        .help(node.isAggregate ? "Files and folders under 1 MB, grouped together" : node.path)
    }

    @ViewBuilder private var icon: some View {
        if node.isAggregate {
            Image(systemName: "square.stack.3d.down.right")
                .foregroundStyle(Theme.inkSecondary)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
        }
    }
}

/// Legend that wraps onto multiple lines.
private struct FlowLegend: View {
    let items: [(Color, String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Circle().fill(item.0).frame(width: 8, height: 8)
                    Text(item.1).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Text(item.2).foregroundStyle(Theme.inkSecondary).monospacedDigit().fixedSize()
                }
                .font(.system(size: 11))
            }
        }
    }
}

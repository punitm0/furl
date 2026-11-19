import AppKit
import SwiftUI

struct SpaceMapView: View {
    @ObservedObject var state: AppState
    @State private var nodeToRemove: SpaceNode?
    @State private var targets: [SpaceAnalyzer.ScanTarget] = []

    private static let palette: [Color] = Theme.chartPalette

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Space Map", subtitle: "See what takes up space, then drill into the biggest folders.")
            toolbarBar

            LiveScanStripSlot(status: state.liveScans[.spaceMap], onStop: { state.cancelSpaceScan() },
                              onRescan: { Task { await state.scanSpace() } })

            if state.isScanningSpace && state.spaceCurrent == nil {
                scanningView
            } else if let current = state.spaceCurrent {
                if state.spaceMapIsStale {
                    staleNotice
                }
                breadcrumb(for: current)
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(for: current)
                        childList(for: current)
                    }
                    .padding(20)
                }
            } else {
                EmptyStatePlaceholder(
                    systemImage: "chart.bar.doc.horizontal",
                    title: "See Where Your Space Went",
                    message: "Scan a folder or drive to see what takes up space, then drill into the biggest folders.",
                    buttonTitle: "Scan Home Folder"
                ) {
                    Task { await state.scanSpace() }
                }
            }
        }
        .navigationTitle("Space Map")
        .cleanSlateScreen()
        .onAppear {
            targets = SpaceAnalyzer.availableTargets()
            // Scan automatically the first time the section is opened.
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
                Text(node.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") + (state.deletionMode == .moveToTrash ? "\n\nIt goes to the Trash; you can undo right after." : "\n\nThis can't be undone."))
            }
        }
    }

    // MARK: Toolbar

    private var toolbarBar: some View {
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

            if state.isScanningSpace {
                // Spinner and the compact Cancel only; the central view shows "Mapping…" and the
                // item count (design answer h).
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    CancelRunButton(compact: true) { state.cancelSpaceScan() }
                }
                .foregroundStyle(Theme.inkSecondary)
            } else {
                Button {
                    Task { await state.scanSpace() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ToolbarButtonStyle())
            }
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
        .background(Theme.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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
            ScanStripBar(fraction: state.liveScans[.spaceMap]?.fraction)
                .frame(width: 220)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background(Theme.warningTint)
    }

    // MARK: Breadcrumb

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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Summary

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

    // MARK: Children

    private func childList(for node: SpaceNode) -> some View {
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

private struct SpaceRow: View {
    let node: SpaceNode
    let color: Color
    let barFraction: Double
    let shareOfParent: Double
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
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
        .onHover { isHovering = $0 }
        .onTapGesture {
            if node.canDrillIn { onOpen() }
        }
        .contextMenu {
            if !node.isAggregate {
                if node.canDrillIn {
                    Button("Open in Space Map", action: onOpen)
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

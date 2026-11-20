import SwiftUI

/// The cleanup tray: items added from any section, cleaned with one action.
struct CleanupTrayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tray: CleanupTray
    /// Covering the page on a narrow window: shows Close, and finishing a clean closes the tray.
    var takeover = false
    var close: () -> Void = {}
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .readableColumn(takeover)

            if tray.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(TraySource.allCases, id: \.self) { source in
                            let items = tray.items(from: source)
                            if !items.isEmpty {
                                group(source, items: items)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .readableColumn(takeover)
                }
            }

            footer
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 22)
                .readableColumn(takeover)
                // Runs the full card width even when the contents are a centred column.
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .onAppear { tray.pruneMissing(state: state) }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(primaryTitle, role: .destructive) {
                Task {
                    await tray.clean(state: state)
                    if takeover { close() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if takeover {
                    // Takeover board: the count sits under the title, Close takes the right.
                    Text("Cleanup tray")
                        .font(Theme.display(22, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if !tray.items.isEmpty {
                        Text(countLine)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cleanup tray")
                            .font(Theme.display(22, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        if !tray.items.isEmpty {
                            Text(countLine)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                if let notice = tray.notice {
                    Text(notice)
                        .font(Theme.micro.weight(.medium))
                        .foregroundStyle(Theme.sweep)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if takeover {
                Button(action: close) {
                    Label {
                        Text("Close")
                    } icon: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))
                .keyboardShortcut(.cancelAction)
                .help("Close the tray (Esc)")
            }
        }
    }

    private var countLine: String {
        let n = tray.items.count
        let s = tray.sourceCount
        return "\(n) item\(n == 1 ? "" : "s") from \(s) screen\(s == 1 ? "" : "s")"
    }

    private func group(_ source: TraySource, items: [TrayItem]) -> some View {
        let prefix = CleanupTray.sharedBranchPrefix(items)
        return VStack(alignment: .leading, spacing: 2) {
            Text("From \(source.section.rawValue)")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(items) { item in
                TrayRow(item: item, tray: tray, sharedPrefix: prefix)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.inkSecondary)
            Text("The tray is empty")
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.ink)
            Text("Select items on any cleanup screen and choose Add to Tray. Nothing is removed until you clean the tray.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.pine)
                    .padding(.top, 1)
                Text(noteText)
                    .font(Theme.caption)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.ink)
                    // No .fixedSize(vertical:) here: the split view measures this panel at a
                    // near-zero width, the text then reported one letter per line, and that
                    // height overflowed the window and pushed the sidebar out of view.
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if tray.isCleaning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tray.phase)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }

            if takeover {
                // Takeover board: Empty Tray on the left, the clean action takes the rest.
                HStack(spacing: 10) {
                    Button(action: emptyTray) {
                        Text("Empty Tray").padding(.horizontal, 10)
                    }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 44))
                    .fixedSize()
                    .disabled(tray.items.isEmpty || tray.isCleaning)
                    primaryButton
                }
            } else {
                primaryButton
                Button("Empty Tray", action: emptyTray)
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 38, fullWidth: true))
                    .disabled(tray.items.isEmpty || tray.isCleaning)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            confirming = true
        } label: {
            Text(primaryTitle)
                .monospacedDigit()
        }
        .buttonStyle(SweepButtonStyle(kind: .primary, height: 44, fullWidth: true))
        .disabled(tray.includedItems.isEmpty || tray.isCleaning || state.isCleaning)
    }

    private func emptyTray() {
        tray.removeAll()
        if takeover { close() }
    }

    private var permanentCount: Int {
        tray.includedItems.filter(\.isPermanent).count
    }

    private var noteText: String {
        if state.deletionMode == .permanent {
            return "System folders can't be added. Delete Permanently is on, so items are removed for good."
        }
        var text = "System folders can't be added. Files go to the Trash by default, and Undo puts a whole cleanup back."
        if permanentCount > 0 {
            text += " \(permanentCount) item\(permanentCount == 1 ? "" : "s") (worktrees, Docker, simulators) can't go to the Trash and \(permanentCount == 1 ? "is" : "are") removed for good."
        }
        return text
    }

    private var primaryTitle: String {
        CleanupTray.primaryTitle(
            hasItems: !tray.items.isEmpty,
            includedCount: tray.includedItems.count,
            permanentCount: permanentCount,
            bytes: tray.includedBytes,
            mode: state.deletionMode
        )
    }

    private var confirmTitle: String {
        let n = tray.includedItems.count
        return "Clean \(n) item\(n == 1 ? "" : "s") from the tray?"
    }

    private var confirmMessage: String {
        let size = FileSizeHelper.formatBytes(tray.includedBytes)
        if state.deletionMode == .permanent {
            return "\(size) will be deleted permanently. This can't be undone."
        }
        var text = "\(size) goes to the Trash. You can undo the whole cleanup."
        if permanentCount > 0 {
            text += " \(permanentCount) item\(permanentCount == 1 ? "" : "s") can't go to the Trash and will be removed for good."
        }
        return text
    }
}

private struct TrayRow: View {
    let item: TrayItem
    @ObservedObject var tray: CleanupTray
    /// From `CleanupTray.sharedBranchPrefix`, worked out once for the whole list.
    var sharedPrefix = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { item.included },
                set: { tray.setIncluded(item.id, $0) }
            ))
            .toggleStyle(.furlCheckbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(CleanupTray.displayTitle(item, sharedPrefix: sharedPrefix))
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        // A branch's distinctive part is at its end ("…-0c93f3").
                        .truncationMode(item.source == .worktrees ? .head : .middle)
                        .help(item.title)
                    // WhySafe board: the same one-word chips as the lists.
                    if item.checkFirst == true {
                        RiskChip(tier: .checkFirst, compact: true)
                    }
                    if item.isPermanent {
                        RiskChip(tier: .permanent, compact: true,
                                 help: "Can't go to the Trash. It's removed for good.")
                    }
                }
                let needsAccess = tray.needsAccessIDs.contains(item.id)
                Text(needsAccess ? "Needs Full Disk Access to check" : item.subtitle)
                    .font(Theme.micro)
                    .foregroundStyle(needsAccess ? Theme.warning : Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(FileSizeHelper.formatBytes(item.bytes))
                .font(Theme.body)
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
            Button {
                tray.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove from the tray")
            .disabled(tray.isCleaning)
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 6)
        .background(hovering ? Theme.surfaceSubtle : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.path)
        .pathContextMenu(item.path, allowOpen: !item.isPseudoPath)
    }
}

/// "Add to Tray" for selection bars.
struct AddToTrayButton: View {
    var count: Int
    /// 32 by default (Tray board); the Apps footer draws 40 and narrow Leftovers 28.
    var height: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add to Tray", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(SweepButtonStyle(kind: .secondary, height: height))
        .disabled(count == 0)
        .help("Collect these in the cleanup tray and clean everything at once")
    }
}

/// Tray board (v77): beside the page the tray is a radius-14 card inset 12 pt in its column, under
/// the page header's strip, which runs on over the column. Below `takeoverBelow` the tray replaces
/// the page (TrayTakeover board) and closes when it's done with.
private extension View {
    /// Over a wide page the rows would run 700 pt; the takeover keeps its contents a readable, centred column.
    @ViewBuilder func readableColumn(_ on: Bool) -> some View {
        if on {
            frame(maxWidth: 640).frame(maxWidth: .infinity)
        } else {
            self
        }
    }
}

enum TrayLayout {
    static let minColumn: CGFloat = 340
    static let idealColumn: CGFloat = 400
    static let maxColumn: CGFloat = 520
    static let inset: CGFloat = 12
    /// Narrowest page that stays beside the tray; any narrower and the tray takes over the page.
    static let minPage: CGFloat = 560
    static let headerHeight: CGFloat = 64
    /// Detail column width under which the tray takes over the page (TrayTakeover board).
    static let takeoverBelow: CGFloat = 984
}

/// The page header's frame, so the tray column can carry its strip and hairline across.
struct ScreenHeaderBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Lays the tray out beside the page, or over it on a narrow page.
private struct CleanupTrayColumn: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var tray = CleanupTray.shared
    @AppStorage("cleanupTrayWidth") private var storedWidth: Double = Double(TrayLayout.idealColumn)
    @State private var dragStartWidth: CGFloat?
    @State private var takeover = false

    private var columnWidth: CGFloat {
        min(TrayLayout.maxColumn, max(TrayLayout.minColumn, CGFloat(storedWidth)))
    }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            // TrayTakeover board: under 984 pt the tray replaces the page. Above it, a widened
            // tray still leaves the page its 560 pt.
            let column = max(TrayLayout.minColumn, min(columnWidth, geo.size.width - TrayLayout.minPage))
            let narrow = geo.size.width < TrayLayout.takeoverBelow
            let isTakeover = tray.isPresented && narrow
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, tray.isPresented && !isTakeover ? column : 0)
                .opacity(isTakeover ? 0 : 1)
                .allowsHitTesting(!isTakeover)
                .accessibilityHidden(isTakeover)
                .overlayPreferenceValue(ScreenHeaderBoundsKey.self, alignment: .topTrailing) { header in
                    if tray.isPresented {
                        Group {
                            // By width, not by isTakeover, so a closing takeover leaves as itself.
                            if narrow {
                                CleanupTrayView(state: state, tray: tray, takeover: true) { close() }
                                    .padding(TrayLayout.inset)
                            } else {
                                sideColumn(headerBottom: header.map { geo[$0].maxY }, hairline: header != nil)
                                    .frame(width: column)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            .onChange(of: isTakeover, initial: true) { _, now in takeover = now }
        }
        // The column has no fill of its own: the window ground shows through, under the toolbar too.
        .background(Theme.ground)
        .animation(.easeOut(duration: 0.2), value: tray.isPresented)
        // Taking over the page is a detour: picking another screen ends it.
        .onChange(of: state.selectedSection) { _, _ in
            if takeover { close() }
        }
    }

    private func close() {
        tray.isPresented = false
    }

    /// `headerBottom` is nil on screens whose title scrolls with the page (Snapshots, History):
    /// the card keeps its place below a 64 pt strip, without a hairline to continue.
    private func sideColumn(headerBottom: CGFloat?, hairline: Bool) -> some View {
        let top = max(0, headerBottom ?? TrayLayout.headerHeight)
        return VStack(spacing: 0) {
            // The page header's strip and its hairline run on over the column (v77).
            Color.clear
                .frame(height: top)
                .overlay(alignment: .bottom) {
                    if hairline { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            CleanupTrayView(state: state, tray: tray, takeover: false) {}
                .padding(TrayLayout.inset)
        }
        .overlay(alignment: .leading) { resizeHandle(top: top) }
    }

    /// The 12 pt gap between page and card resizes the column, as the inspector edge did.
    private func resizeHandle(top: CGFloat) -> some View {
        Color.clear
            .frame(width: TrayLayout.inset)
            .padding(.top, max(0, top))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? columnWidth
                        dragStartWidth = start
                        let next = min(TrayLayout.maxColumn, max(TrayLayout.minColumn, start - value.translation.width))
                        storedWidth = Double(next)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

/// The toolbar's tray button.
private struct CleanupTrayToolbar: ViewModifier {
    @ObservedObject var tray = CleanupTray.shared

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tray.isPresented.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tray.items.isEmpty ? "tray" : "tray.full")
                            if !tray.items.isEmpty {
                                Text("\(tray.items.count)")
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(tray.items.isEmpty ? Theme.ink : Theme.sweep)
                    }
                    .help(tray.items.isEmpty ? "Cleanup tray" : "Cleanup tray · \(FileSizeHelper.formatBytes(tray.totalBytes))")
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }
    }
}

extension View {
    /// Puts the cleanup tray beside (or over) the page. Apply to the detail column's page.
    func cleanupTrayColumn(state: AppState) -> some View {
        modifier(CleanupTrayColumn(state: state))
    }

    func cleanupTrayToolbar() -> some View {
        modifier(CleanupTrayToolbar())
    }
}

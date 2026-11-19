import SwiftUI

/// The cleanup tray: items added from any section, cleaned with one action.
struct CleanupTrayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var tray: CleanupTray
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)

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
                }
            }

            footer
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 22)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .onAppear { tray.pruneMissing(state: state) }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(primaryTitle, role: .destructive) {
                Task { await tray.clean(state: state) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cleanup tray")
                    .font(Theme.display(22, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !tray.items.isEmpty {
                    Text(countLine)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            if let notice = tray.notice {
                Text(notice)
                    .font(Theme.micro.weight(.medium))
                    .foregroundStyle(Theme.sweep)
            }
        }
    }

    private var countLine: String {
        let n = tray.items.count
        let s = tray.sourceCount
        return "\(n) item\(n == 1 ? "" : "s") from \(s) screen\(s == 1 ? "" : "s")"
    }

    private func group(_ source: TraySource, items: [TrayItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("From \(source.section.rawValue)")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(items) { item in
                TrayRow(item: item, tray: tray)
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

            Button {
                confirming = true
            } label: {
                Text(primaryTitle)
                    .monospacedDigit()
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 44, fullWidth: true))
            .disabled(tray.includedItems.isEmpty || tray.isCleaning || state.isCleaning)

            Button("Empty Tray") {
                tray.removeAll()
            }
            .buttonStyle(SweepButtonStyle(kind: .secondary, height: 38, fullWidth: true))
            .disabled(tray.items.isEmpty || tray.isCleaning)
        }
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
        if tray.items.isEmpty { return state.deletionMode == .permanent ? "Delete" : "Move to Trash" }
        let size = FileSizeHelper.formatBytes(tray.includedBytes)
        if state.deletionMode == .permanent { return "Delete \(size)" }
        if !tray.includedItems.isEmpty && permanentCount == tray.includedItems.count { return "Remove \(size)" }
        return "Move \(size) to Trash"
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
                    Text(item.title)
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isPermanent {
                        Text("Permanent")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warningTint, in: Capsule())
                    }
                }
                Text(item.subtitle)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
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

/// Toolbar button + trailing inspector column hosting the tray.
private struct CleanupTrayInspector: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var tray = CleanupTray.shared

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $tray.isPresented) {
                CleanupTrayView(state: state, tray: tray)
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
            }
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
    func cleanupTrayInspector(state: AppState) -> some View {
        modifier(CleanupTrayInspector(state: state))
    }
}

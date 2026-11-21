import AppKit
import SwiftUI

/// FirstClean board: one sheet, three steps. Pick three Safe items, move them to the Trash, then put
/// them back with Undo (the primary button). It proves the safety net by doing it. Skip, Not Now and
/// Escape close it for good.
struct FirstCleanSheet: View {
    @ObservedObject var state: AppState
    let store: AutoSweepStore
    let picks: [FirstCleanOffer.Pick]

    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case pick
        case moved(FirstCleanMove)
        case undone(FirstCleanUndo)
    }

    @State private var step: Step = .pick
    @State private var working = false
    /// The last move, kept for "Move Again" after Undo.
    @State private var lastMove: FirstCleanMove?

    private var total: Int64 { picks.reduce(Int64(0)) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch step {
            case .pick: pickStep
            case .moved(let move): movedStep(move)
            case .undone(let undo): undoneStep(undo)
            }
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 540, alignment: .leading)
        .background(Theme.surface)
        .interactiveDismissDisabled(working)
    }

    // MARK: Header

    private var stepNumber: Int {
        switch step {
        case .pick: return 1
        case .moved: return 2
        case .undone: return 3
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("First clean · \(stepNumber) of 3".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if stepNumber < 3 {
                Button("Skip") { dismiss() }
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                    .disabled(working)
            }
        }
    }

    private func titleBlock(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.display(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 1 · Pick

    private var pickStep: some View {
        Group {
            titleBlock("Start with \(picks.count) safe thing\(picks.count == 1 ? "" : "s")",
                       "Apps rebuild these by themselves. They go to the Trash first, so you can undo.")
            itemList { pick in
                row(pick, tile: .mint, detail: Label {
                    Text(FirstCleanOffer.whyLine(pick.item))
                } icon: {
                    Image(systemName: "info.circle").font(.system(size: 11, weight: .medium))
                }) {
                    RiskChip(tier: .safe)
                }
            }
            buttons {
                Button("Not Now") { dismiss() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button {
                    move()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                        Text(working ? "Moving to Trash…" : "Move \(FileSizeHelper.formatBytes(total)) to Trash")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 32))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 2 · Moved

    private func movedStep(_ move: FirstCleanMove) -> some View {
        let moved = movedPicks(move)
        let bytes = moved.reduce(Int64(0)) { $0 + $1.bytes }
        return Group {
            titleBlock("\(FileSizeHelper.formatBytes(bytes)) is in the Trash",
                       "Not gone yet. You can see \(moved.count == 1 ? "it" : "them") in Finder’s Trash.")
            itemList(moved) { pick in
                row(pick, tile: .grey, detail: Text("from \(Self.folder(of: pick.path))")) {
                    Text("In the Trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                Text("Try it: put \(moved.count == 1 ? "it" : "them") back. Nothing is lost.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.sweepDeep)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.mintTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Button("Show in Trash") {
                    let urls = move.run.trashed.map { URL(fileURLWithPath: $0.trashPath) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .buttonStyle(SweepLinkStyle())
                .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Keep Them There") { dismiss() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button {
                    undo(move)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold))
                        Text(working ? "Putting Back…" : "Undo")
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: .primary, height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 3 · Undone

    private func undoneStep(_ undo: FirstCleanUndo) -> some View {
        let shown = picks.filter { undo.back.contains($0.path) || undo.notFound.contains($0.path) || undo.failed.contains($0.path) }
        let back = shown.filter { undo.back.contains($0.path) }
        let againBytes = back.reduce(Int64(0)) { $0 + $1.bytes }
        return Group {
            titleBlock(undoneTitle(back: back.count, of: shown.count),
                       back.isEmpty ? "Nothing was moved back." : "Each folder is where it was, byte for byte.")
            itemList(shown) { pick in
                let isBack = undo.back.contains(pick.path)
                row(pick, tile: isBack ? .mint : .grey, detail: Text("in \(Self.folder(of: pick.path))")) {
                    if isBack {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            Text("Back")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.sweep)
                        .fixedSize()
                    } else {
                        Text(undo.notFound.contains(pick.path) ? "Not found in the Trash" : "Couldn’t put back")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize()
                    }
                }
            }
            Text("Undo works for every cleanup until you empty the Trash: in History, or ⌥⌘Z.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Leave Them") { dismiss() }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                if againBytes > 0 {
                    Button {
                        moveAgain(back)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                            Text(working ? "Moving to Trash…" : "Move \(FileSizeHelper.formatBytes(againBytes)) to Trash Again")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(SweepButtonStyle(kind: .primary, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
            }
        }
    }

    private func undoneTitle(back: Int, of total: Int) -> String {
        if back == total { return total == 1 ? "It’s back" : "All \(total) are back" }
        return "\(back) of \(total) are back"
    }

    // MARK: Rows

    private enum Tile { case mint, grey }

    private func itemList<Row: View>(_ items: [FirstCleanOffer.Pick]? = nil,
                                     @ViewBuilder row: @escaping (FirstCleanOffer.Pick) -> Row) -> some View {
        let list = items ?? picks
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.path) { index, pick in
                row(pick)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func row<Detail: View, Trailing: View>(_ pick: FirstCleanOffer.Pick, tile: Tile, detail: Detail,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tile == .mint ? Theme.sweep : Theme.inkSecondary)
                .frame(width: 30, height: 30)
                .background(tile == .mint ? Theme.mintTint : Theme.hairline,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                // Same name as the "biggest win" line: "ChatGPT caches", not com.openai.codex.
                Text(AppState.friendlyName(pick.item))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                detail
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            Text(FileSizeHelper.formatBytes(pick.bytes))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }

    /// "~/Library/Developer/Xcode": the folder an item sits in, with the home folder shortened.
    static func folder(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if parent == home { return "~" }
        return parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }

    private func movedPicks(_ move: FirstCleanMove) -> [FirstCleanOffer.Pick] {
        let moved = Set(move.run.trashed.map(\.originalPath))
        return picks.filter { moved.contains($0.path) }
    }

    // MARK: Actions

    private func move() {
        guard !working else { return }
        working = true
        Task {
            let result = await state.firstCleanMove(picks, store: store)
            working = false
            if let result {
                lastMove = result
                step = .moved(result)
            } else {
                // Nothing moved (each item changed since the scan): the Overview says so; nothing to undo.
                dismiss()
            }
        }
    }

    private func undo(_ move: FirstCleanMove) {
        guard !working else { return }
        working = true
        Task {
            let result = await state.undoFirstClean(move, store: store)
            working = false
            step = .undone(result)
        }
    }

    /// Moves the same items again, then closes with the Overview's after-clean state. No fourth step.
    private func moveAgain(_ items: [FirstCleanOffer.Pick]) {
        guard !working else { return }
        working = true
        Task {
            _ = await state.firstCleanMove(items, store: store)
            working = false
            dismiss()
        }
    }
}

import SwiftUI

/// Side panel describing one scan result: facts from disk, why it was flagged, whether it's safe,
/// what rebuilds it, and actions. Shown by `ContentView` for `InspectorStore.shared.current`.
struct InspectorPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: InspectorStore
    let item: InspectorItem

    @State private var details: InspectorDetails?
    @State private var confirmRemove = false

    init(state: AppState, store: InspectorStore, item: InspectorItem, details: InspectorDetails? = nil) {
        self.state = state
        self.store = store
        self.item = item
        _details = State(initialValue: details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                contentStack
            }
            actions
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .task(id: item.id) {
            guard item.isOnDisk else { return }
            let path = item.path
            details = await Task.detached(priority: .userInitiated) {
                InspectorDetails.load(path: path)
            }.value
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(removeLabel, role: .destructive) {
                Task { await store.remove(item, state: state) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    /// Everything above the action buttons.
    var contentStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            safetyPill
            facts
            textBlock("Why Furl flagged it", item.whyFlagged)
            textBlock("Is it safe to remove?", item.safetyNote)
            textBlock("What would rebuild it", item.rebuild)
            if let details, details.isDirectory, !details.largestInside.isEmpty {
                largestInside(details)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Inspector")
                Text(item.name)
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(item.displayFolder)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.path)
            }
            Spacer(minLength: 0)
            Button {
                store.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close the Inspector (Esc)")
        }
    }

    private var safetyPill: some View {
        let (fg, bg): (Color, Color) = {
            switch item.safety {
            case .safe: return (Theme.safe, Theme.safeTint)
            case .review: return (Theme.warning, Theme.warningTint)
            case .caution: return (Theme.danger, Theme.dangerTint)
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: item.safety.systemImage)
            Text(item.safety.title)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(bg, in: Capsule())
    }

    // MARK: Facts

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            if let details, !details.exists {
                factRow("Status", "No longer on disk", highlight: true)
            }
            factRow(item.source == .duplicate ? "Frees" : "Size", FileSizeHelper.formatBytes(item.sizeBytes), strong: true)
            if let details, details.exists, details.allocatedBytes > 0 {
                if abs(details.allocatedBytes - item.sizeBytes) > max(item.sizeBytes / 50, 1_000_000) {
                    factRow("Size on disk", FileSizeHelper.formatBytes(details.allocatedBytes) + (details.isPartial ? "+" : ""))
                }
                if details.logicalBytes > details.allocatedBytes + 1_000_000 {
                    factRow("Logical size", FileSizeHelper.formatBytes(details.logicalBytes))
                    factRow("APFS compression saved", FileSizeHelper.formatBytes(details.logicalBytes - details.allocatedBytes), accent: true)
                }
                if details.isDirectory {
                    factRow("Files · folders", "\(details.fileCount.formatted()) · \(details.folderCount.formatted())" + (details.isPartial ? "+" : ""))
                }
            }
            factRow("Last used", lastUsedText)
            if let modified = details?.modified ?? item.modifiedDate {
                factRow(item.source == .worktree ? "Last commit" : "Last modified",
                        (item.source == .worktree ? item.modifiedDate ?? modified : modified).relativeDescription)
            }
            factRow("Kind", item.kind)
            factRow("Found by", item.source.rawValue)
            if details == nil && item.isOnDisk {
                GridRow {
                    ProgressView().controlSize(.small)
                    Text("Reading from disk…")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .font(Theme.body)
    }

    private var lastUsedText: String {
        if let date = item.lastUsedDate ?? details?.lastUsed { return date.relativeDescription }
        if details == nil && item.isOnDisk { return "…" }
        return "Not recorded"
    }

    private func factRow(_ label: String, _ value: String, strong: Bool = false, accent: Bool = false, highlight: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.inkSecondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .fontWeight(strong || accent ? .semibold : .regular)
                .foregroundStyle(highlight ? Theme.danger : (accent ? Theme.sweep : Theme.ink))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(2)
        }
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(text)
                .font(Theme.body)
                .foregroundStyle(Theme.inkTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func largestInside(_ details: InspectorDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Largest inside")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
            ForEach(details.largestInside) { child in
                HStack {
                    Text(child.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(FileSizeHelper.formatBytes(child.bytes))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                }
                .font(Theme.body)
            }
        }
    }

    // MARK: Actions

    private var permanent: Bool { item.isPermanent || state.deletionMode == .permanent }

    private var removeLabel: String {
        switch item.source {
        case .app: return "Uninstall"
        case .worktree: return "Remove Worktree"
        default: return permanent ? "Delete Permanently" : "Move to Trash"
        }
    }

    private var confirmTitle: String {
        switch item.source {
        case .app: return "Uninstall \(item.name)?"
        case .worktree: return "Remove the worktree \(item.name)?"
        default: return permanent ? "Delete \(item.name) permanently?" : "Move \(item.name) to the Trash?"
        }
    }

    private var confirmMessage: String {
        switch item.source {
        case .worktree:
            return "Runs git worktree remove. The folder is deleted, not moved to the Trash, but the branch and its commits stay in the repository."
        case .app:
            return permanent
                ? "The app and its support files are deleted permanently."
                : "The app and its support files go to the Trash. Undo with ⌥⌘Z."
        default:
            if item.isPermanent { return "This is removed by its own tool and can't be restored from the Trash." }
            return permanent
                ? "Delete Permanently is on, so this can't be undone."
                : "You can put it back with ⌥⌘Z or from the Trash."
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if item.canRemove {
                Button {
                    confirmRemove = true
                } label: {
                    HStack(spacing: 6) {
                        if store.isRemoving { ProgressView().controlSize(.small) }
                        Text(removeLabel + "…")
                    }
                }
                .buttonStyle(SweepButtonStyle(kind: permanent && item.source != .worktree ? .danger : .primary, height: 40, fullWidth: true))
                .disabled(store.isRemoving || state.isCleaning || details?.exists == false)
            }
            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    DeletionService.revealInFinder(item.path)
                }
                .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36, fullWidth: true))
                .disabled(!item.isOnDisk || details?.exists == false)

                if !item.id.hasPrefix("plain:") {
                    Button("Ignore") {
                        store.ignore(item, state: state)
                    }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 36, fullWidth: true))
                    .help("Hide this from Find and from \(item.source.section.rawValue), including after future scans")
                }
            }
            if state.selectedSection != item.source.section && !item.id.hasPrefix("plain:") {
                Button {
                    state.selectedSection = item.source.section
                } label: {
                    HStack(spacing: 4) {
                        Text("Open in \(item.source.section.rawValue)")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(Theme.caption.weight(.medium))
                }
                .buttonStyle(SweepLinkStyle())
                .padding(.top, 2)
            }
        }
    }
}

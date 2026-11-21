import AppKit
import SwiftUI

/// Apps & Leftovers › "Developer tools" (DevTools board): one card with four groups, then a bar for
/// what's ticked. Only unused versions that go to the Trash are ever ticked for you; Homebrew and
/// global packages are listed, never ticked, and each removal says plainly when it can't be undone.
struct DevToolsList: View {
    @ObservedObject var state: AppState
    let searchText: String
    @Binding var ticked: Set<String>
    @State private var confirm: DevToolsConfirm?

    private var snapshot: DevToolsSnapshot { state.devTools }

    private func matches(_ name: String, _ extra: String = "") -> Bool {
        searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText)
            || extra.localizedCaseInsensitiveContains(searchText)
    }

    private var versions: [DevVersion] { snapshot.versions.filter { matches($0.displayName, $0.manager.label) } }
    private var brewOld: [BrewOldVersions] { snapshot.brewOld.filter { matches($0.formula) } }
    private var leaves: [BrewLeaf] { snapshot.brewLeaves.filter { matches($0.name) } }
    private var packages: [GlobalPackage] { snapshot.packages.filter { matches($0.name, $0.manager.label) } }

    private var toTrash: Bool { state.deletionMode == .moveToTrash }

    var body: some View {
        Group {
            if !state.hasScannedDevTools {
                if state.isScanningDevTools {
                    ScanningPlaceholder(message: "Looking for Node, Python and Rust versions, Homebrew and global packages…")
                } else {
                    EmptyStatePlaceholder(
                        systemImage: "hammer",
                        title: "See Your Developer Tools",
                        message: "Find old Node, Python and Rust versions no project asks for, older Homebrew versions, and packages you installed.",
                        buttonTitle: "Scan Developer Tools"
                    ) {
                        Task { await state.scanDevTools() }
                    }
                }
            } else if snapshot.rowCount == 0 {
                EmptyStatePlaceholder(
                    systemImage: "checkmark.seal",
                    title: "No Developer Tools Found",
                    message: "Furl looked for Node, Python and Rust versions, Homebrew and global packages, and found none."
                )
            } else if versions.isEmpty && brewOld.isEmpty && leaves.isEmpty && packages.isEmpty {
                EmptyStatePlaceholder(systemImage: "magnifyingglass", title: "No Matching Tools",
                                      message: "No tool matches your search.")
            } else {
                content
            }
        }
        .onChange(of: state.devTools) { _, snap in
            // Drop ticks for rows that are gone or no longer removable.
            let live = Set(snap.versions.filter(\.isRemovable).map(\.id) + snap.brewLeaves.map(\.id) + snap.packages.map(\.id))
            ticked.formIntersection(live)
        }
        .sheet(item: $confirm) { c in
            DevToolsConfirmSheet(confirm: c) {
                confirm = nil
                perform(c.action)
            } onCancel: {
                confirm = nil
            }
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !versions.isEmpty { versionsGroup }
                    if !brewOld.isEmpty { brewOldGroup }
                    if !leaves.isEmpty { leavesGroup }
                    if !packages.isEmpty { packagesGroup }
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            if tickedCount > 0 { tickedBar }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 16)
    }

    // MARK: - Groups

    private var versionsGroup: some View {
        let unused = snapshot.unusedVersions
        let selectable = versions.filter { $0.isRemovable && $0.goesToTrash }.map(\.id)
        return Group {
            DevGroupHeader(title: "OLD VERSIONS NO PROJECT USES",
                           detail: "\(unused.count) · \(FileSizeHelper.formatBytes(unused.reduce(0) { $0 + $1.sizeBytes }))") {
                Button("Select unused versions") { ticked.formUnion(selectable) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectable.isEmpty ? Theme.inkTertiary : Theme.sweep)
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .disabled(selectable.isEmpty)
                    .help("Ticks old versions no project asks for that go to the Trash. Nothing permanent is ticked for you.")
            }
            ForEach(versions) { v in
                DevRow(
                    leading: v.isRemovable ? .checkbox(v.id) : .locked,
                    ticked: $ticked,
                    name: v.displayName,
                    badges: [.tool(v.manager.label)] + (v.goesToTrash || !v.isRemovable ? [] : [.tier(.permanent)])
                        + (WhySafe.devVersionBadge(v).map { [.state($0)] } ?? []),
                    subtitle: WhySafe.devVersionSubtitle(v),
                    why: WhySafe.devVersion(v, projectCount: snapshot.projectCount, deletionMode: state.deletionMode),
                    whyAction: keepAction(v),
                    bytes: v.sizeBytes,
                    revealPath: v.path
                )
            }
        }
    }

    private func keepAction(_ v: DevVersion) -> WhyAction? {
        if v.status == .unused {
            return WhyAction(title: "Always keep \(v.keepName)") { state.setKeep(v, true); ticked.remove(v.id) }
        }
        if v.status == .kept {
            return WhyAction(title: "Stop keeping \(v.keepName)") { state.setKeep(v, false) }
        }
        return nil
    }

    private var brewOldGroup: some View {
        let all = snapshot.brewOld
        let bytes = all.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return Group {
            DevGroupHeader(title: "OLDER HOMEBREW VERSIONS",
                           detail: "\(all.count) \(all.count == 1 ? "formula" : "formulae") · \(FileSizeHelper.formatBytes(bytes))") {
                Button("Clean Up Older Versions…") { confirm = DevToolsConfirm.brewCleanup(all) }
                    .buttonStyle(SweepButtonStyle(kind: .secondary, height: 24))
                    .fixedSize()
                    .disabled(state.isCleaning)
            }
            ForEach(brewOld) { o in
                DevRow(leading: .none, ticked: $ticked, name: o.formula, badges: [.tier(.permanent)],
                       subtitle: WhySafe.brewOldSubtitle(o), why: WhySafe.brewOld(o), whyAction: nil,
                       bytes: o.sizeBytes, revealPath: o.oldPaths.first)
            }
        }
    }

    private var leavesGroup: some View {
        let all = snapshot.brewLeaves
        return Group {
            DevGroupHeader(title: "HOMEBREW PACKAGES YOU INSTALLED",
                           detail: "\(all.count) · \(FileSizeHelper.formatBytes(all.reduce(0) { $0 + $1.sizeBytes })) · nothing else needs these") {
                EmptyView()
            }
            ForEach(leaves) { l in
                DevRow(leading: .checkbox(l.id), ticked: $ticked, name: l.name,
                       badges: [.tier(.checkFirst), .tier(.permanent)],
                       subtitle: WhySafe.brewLeafSubtitle(l), why: WhySafe.brewLeaf(l), whyAction: nil,
                       bytes: l.sizeBytes, revealPath: l.path)
            }
        }
    }

    private var packagesGroup: some View {
        let counts = GlobalPackage.Manager.allCases.compactMap { m -> String? in
            let n = snapshot.packages.filter { $0.manager == m }.count
            return n > 0 ? "\(m.rawValue) \(n)" : nil
        }
        return Group {
            DevGroupHeader(title: "GLOBAL PACKAGES", detail: counts.joined(separator: " · ")) { EmptyView() }
            ForEach(packages) { p in
                DevRow(leading: .checkbox(p.id), ticked: $ticked, name: p.name,
                       badges: [.tool(p.manager.label), .tier(.checkFirst), .tier(.permanent)],
                       subtitle: WhySafe.packageSubtitle(p), why: WhySafe.package(p), whyAction: nil,
                       bytes: p.sizeBytes, revealPath: p.path)
            }
        }
    }

    // MARK: - Ticked bar

    private var tickedPicks: (versions: [DevVersion], leaves: [BrewLeaf], packages: [GlobalPackage]) {
        (snapshot.versions.filter { ticked.contains($0.id) && $0.isRemovable },
         snapshot.brewLeaves.filter { ticked.contains($0.id) },
         snapshot.packages.filter { ticked.contains($0.id) })
    }

    private var tickedCount: Int {
        let p = tickedPicks
        return p.versions.count + p.leaves.count + p.packages.count
    }

    /// "2 ticked · 594 MB · both go to the Trash" and the button that acts on exactly those rows.
    private var tickedBar: some View {
        let picks = tickedPicks
        let count = picks.versions.count + picks.leaves.count + picks.packages.count
        let bytes = picks.versions.reduce(Int64(0)) { $0 + $1.sizeBytes }
            + picks.leaves.reduce(Int64(0)) { $0 + $1.sizeBytes } + picks.packages.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let trashCount = toTrash ? picks.versions.filter(\.goesToTrash).count : 0
        let allTrash = trashCount == count
        let size = FileSizeHelper.formatBytes(bytes)
        let where_: String = {
            if allTrash { return count == 1 ? "goes to the Trash" : (count == 2 ? "both go to the Trash" : "all go to the Trash") }
            if trashCount == 0 { return "can’t be undone" }
            return "\(trashCount) to the Trash, \(count - trashCount) can’t be undone"
        }()
        return HStack(spacing: 12) {
            (Text("\(count) ticked · ") + Text(size).fontWeight(.semibold).foregroundColor(Theme.ink) + Text(" · \(where_)"))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                remove(picks)
            } label: {
                Label(allTrash ? "Move \(size) to Trash" : "Remove \(size)…", systemImage: "trash").monospacedDigit()
            }
            .buttonStyle(SweepButtonStyle(kind: allTrash ? .primary : .danger, height: 30))
            .fixedSize()
            .disabled(state.isCleaning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// Trash-only moves go straight away (Undo brings them back); anything permanent asks first.
    private func remove(_ picks: (versions: [DevVersion], leaves: [BrewLeaf], packages: [GlobalPackage])) {
        let action = DevToolsConfirm.Action.remove(picks.versions, picks.leaves, picks.packages)
        if toTrash && picks.leaves.isEmpty && picks.packages.isEmpty && picks.versions.allSatisfy(\.goesToTrash) {
            perform(action)
        } else {
            confirm = DevToolsConfirm.make(action, deletionMode: state.deletionMode)
        }
    }

    private func perform(_ action: DevToolsConfirm.Action) {
        switch action {
        case let .remove(versions, leaves, packages):
            ticked.subtract(versions.map(\.id) + leaves.map(\.id) + packages.map(\.id))
            Task { await state.removeDevTools(versions: versions, leaves: leaves, packages: packages) }
        case .brewCleanup(let items):
            Task { await state.cleanUpOldHomebrew(items) }
        }
    }
}

// MARK: - Rows

/// "OLD VERSIONS NO PROJECT USES   3 · 2.0 GB" with the group's action on the right.
private struct DevGroupHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surfaceSubtle)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private enum DevRowBadge: Hashable {
    /// The tool it came from ("nvm", "npm -g"), grey.
    case tool(String)
    /// Check first / Permanent.
    case tier(RiskTier)
    /// In use / Default / Kept, mint.
    case state(String)
}

private enum DevRowLeading: Equatable {
    case checkbox(String)
    case locked
    case none
}

private struct DevRow: View {
    let leading: DevRowLeading
    @Binding var ticked: Set<String>
    let name: String
    let badges: [DevRowBadge]
    let subtitle: String
    let why: WhyExplanation
    let whyAction: WhyAction?
    let bytes: Int64
    let revealPath: String?

    private var isTicked: Bool {
        if case .checkbox(let id) = leading { return ticked.contains(id) }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingView.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(badges, id: \.self) { badge(for: $0) }
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WhyButton(explanation: why, action: whyAction)
            Text(FileSizeHelper.formatBytes(bytes))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isTicked ? Theme.mintTint : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .contextMenu {
            if let revealPath {
                Button("Reveal in Finder") { DeletionService.revealInFinder(revealPath) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .checkbox(let id):
            SelectionCheckbox(id: id, selection: $ticked)
                .accessibilityLabel("Include \(name)")
        case .locked:
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .help("Furl won’t remove this one")
                .accessibilityLabel("Kept")
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder private func badge(for b: DevRowBadge) -> some View {
        switch b {
        case .tool(let label):
            BadgeView(text: label, color: Theme.inkSecondary).fixedSize()
        case .tier(let tier):
            RiskChip(tier: tier, compact: true)
        case .state(let label):
            BadgeView(text: label, color: Theme.sweepDeep, background: Theme.mintTint).fixedSize()
        }
    }
}

// MARK: - Confirm

/// What a confirm lists and what it runs. Built from the rows the user picked, nothing else.
struct DevToolsConfirm: Identifiable {
    enum Action {
        case remove([DevVersion], [BrewLeaf], [GlobalPackage])
        case brewCleanup([BrewOldVersions])
    }

    struct Line: Identifiable {
        let name: String
        let detail: String?
        let permanent: Bool
        let bytes: Int64
        var id: String { name + (detail ?? "") }
    }

    let id = UUID()
    let action: Action
    let title: String
    let message: String
    let lines: [Line]
    let footnote: String?
    let button: String

    static func brewCleanup(_ items: [BrewOldVersions]) -> DevToolsConfirm {
        let bytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = FileSizeHelper.formatBytes(bytes)
        var lines = items.prefix(2).map {
            Line(name: $0.formula, detail: $0.oldVersions.joined(separator: ", "), permanent: true, bytes: $0.sizeBytes)
        }
        let rest = items.dropFirst(2)
        if !rest.isEmpty {
            let names = rest.prefix(3).map(\.formula).joined(separator: ", ") + (rest.count > 3 ? "…" : "")
            lines.append(Line(name: "\(rest.count) more", detail: names, permanent: false,
                              bytes: rest.reduce(Int64(0)) { $0 + $1.sizeBytes }))
        }
        let n = items.count
        return DevToolsConfirm(
            action: .brewCleanup(items),
            title: "Remove \(n) older Homebrew \(n == 1 ? "version" : "versions")?",
            message: "\(size). Homebrew deletes them for good; they don’t go to the Trash. The versions you use stay.",
            lines: lines,
            footnote: "Runs brew cleanup with auto-update and analytics off, so nothing is sent.",
            button: "Remove \(size)")
    }

    static func make(_ action: Action, deletionMode: DeletionMode) -> DevToolsConfirm? {
        guard case let .remove(versions, leaves, packages) = action else { return nil }
        let count = versions.count + leaves.count + packages.count
        let bytes = versions.reduce(Int64(0)) { $0 + $1.sizeBytes } + leaves.reduce(Int64(0)) { $0 + $1.sizeBytes }
            + packages.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = FileSizeHelper.formatBytes(bytes)
        // One Homebrew package (board) or one global package: name it, no list.
        if count == 1, let leaf = leaves.first {
            return DevToolsConfirm(
                action: action, title: "Uninstall \(leaf.name)?",
                message: "\(size). Homebrew deletes it for good. Furl can’t tell when you last used it, so check you don’t need it.",
                lines: [], footnote: "Nothing else installed needs it. Reinstall any time with brew install \(leaf.name).",
                button: "Uninstall \(leaf.name)")
        }
        if count == 1, let pkg = packages.first {
            let tool = pkg.manager == .pipx ? "pipx" : pkg.manager.rawValue
            return DevToolsConfirm(
                action: action, title: "Uninstall \(pkg.name)?",
                message: "\(size). \(tool) deletes it for good. Furl can’t tell when you last ran it, so check you don’t need it.",
                lines: [], footnote: "Reinstall any time with \(pkg.manager.installCommand(pkg.name)).",
                button: "Uninstall \(pkg.name)")
        }
        let toTrash = deletionMode == .moveToTrash
        var lines: [Line] = versions.map {
            Line(name: $0.displayName, detail: $0.manager.label, permanent: !($0.goesToTrash && toTrash), bytes: $0.sizeBytes)
        }
        lines += leaves.map { Line(name: $0.name, detail: "Homebrew", permanent: true, bytes: $0.sizeBytes) }
        lines += packages.map { Line(name: $0.name, detail: $0.manager.label, permanent: true, bytes: $0.sizeBytes) }
        let trashCount = lines.filter { !$0.permanent }.count
        let message: String
        if trashCount == 0 {
            message = toTrash || versions.isEmpty
                ? "\(size). Each tool deletes its own for good; nothing goes to the Trash."
                : "\(size). Delete Permanently is on, so nothing goes to the Trash."
        } else {
            message = "\(size). \(trashCount) \(trashCount == 1 ? "goes" : "go") to the Trash. The rest \(count - trashCount == 1 ? "is" : "are") deleted for good by \(count - trashCount == 1 ? "its" : "their") own tool."
        }
        let footnote = leaves.isEmpty && packages.isEmpty
            ? "Furl checks again right before removing that no project asks for these."
            : "Runs each tool’s own uninstall with update checks and analytics off, so nothing is sent."
        return DevToolsConfirm(action: action, title: "Remove \(count) \(count == 1 ? "item" : "items")?",
                               message: message, lines: lines, footnote: footnote, button: "Remove \(size)")
    }
}

/// The caution confirm, drawn as a macOS alert (DevTools board): app icon with a caution badge, title,
/// what happens, the list, a footnote, then full-width buttons with Cancel as the default.
private struct DevToolsConfirmSheet: View {
    let confirm: DevToolsConfirm
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black.opacity(0.85), Color(nsColor: .systemYellow))
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
            Text(confirm.title)
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text(confirm.message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !confirm.lines.isEmpty { list }
            if let footnote = confirm.footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                Button(action: onConfirm) {
                    Text(confirm.button).monospacedDigit().frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color(nsColor: .systemRed))
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(.top, 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: confirm.lines.isEmpty ? 280 : 300)
        .onExitCommand(perform: onCancel)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(confirm.lines.enumerated()), id: \.element.id) { index, line in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let detail = line.detail {
                                Text(detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if line.permanent { RiskChip(tier: .permanent, compact: true) }
                        Text(FileSizeHelper.formatBytes(line.bytes))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

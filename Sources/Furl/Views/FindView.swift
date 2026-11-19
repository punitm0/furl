import SwiftUI

/// ⌘F: one search across every current scan result. Selecting a row opens the Inspector.
struct FindView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: InspectorStore
    @State private var query = ""
    @State private var source: InspectorSource?
    @FocusState private var fieldFocused: Bool

    /// Rows drawn at most; the count still reports every match.
    private static let rowLimit = 500

    var body: some View {
        let started = Date()
        let catalog = store.catalog(state)
        let matches = filter(catalog)
        let elapsed = Date().timeIntervalSince(started)

        VStack(spacing: 0) {
            ScreenHeader(title: "Find", subtitle: "Search everything the last scans found")
            VStack(alignment: .leading, spacing: 14) {
                searchField(count: matches.count, elapsed: elapsed)
                chips(catalog)
                Text("Searches the last scan's results, so they appear as you type. Hidden folders included. Your files never leave your Mac.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 4)

            if catalog.isEmpty {
                emptyState
            } else {
                results(matches)
            }
            if !store.ignoredPaths.isEmpty {
                ignoredFooter
            }
        }
        .cleanSlateScreen()
        .onAppear { fieldFocused = true }
        .onChange(of: store.focusRequest) { fieldFocused = true }
    }

    // MARK: Search

    private func filter(_ items: [InspectorItem]) -> [InspectorItem] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            if let source, item.source != source { return false }
            guard !tokens.isEmpty else { return true }
            let haystack = "\(item.name) \(item.path) \(item.kind) \(item.searchExtras)"
            return tokens.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func searchField(count: Int, elapsed: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            TextField("Find any file, folder, app or branch", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($fieldFocused)
                .onSubmit { openFirst() }
            if !query.isEmpty {
                Text("\(count.formatted()) result\(count == 1 ? "" : "s") · \(String(format: "%.2f", elapsed)) s")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .monospacedDigit()
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(fieldFocused ? Theme.sweep : Theme.border, lineWidth: fieldFocused ? 1.5 : 1)
        )
    }

    private func chips(_ catalog: [InspectorItem]) -> some View {
        var counts: [InspectorSource: Int] = [:]
        for item in catalog { counts[item.source, default: 0] += 1 }
        return FlowRow(spacing: 6) {
            FilterChip(title: "All", detail: "\(catalog.count)", isActive: source == nil) { source = nil }
            ForEach(InspectorSource.allCases) { kind in
                if let n = counts[kind], n > 0 {
                    FilterChip(title: kind.rawValue, systemImage: kind.systemImage, detail: "\(n)", isActive: source == kind) {
                        source = source == kind ? nil : kind
                    }
                }
            }
        }
    }

    private func openFirst() {
        if let first = filter(store.catalog(state)).first {
            store.show(first)
        }
    }

    // MARK: Results

    private var selection: Binding<String?> {
        Binding(
            get: { store.current?.id },
            set: { id in
                guard let id else { return }
                if let item = store.catalog(state).first(where: { $0.id == id }) { store.show(item) }
            }
        )
    }

    private func results(_ matches: [InspectorItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Name and path").frame(maxWidth: .infinity, alignment: .leading)
                Text("Found by").frame(width: 120, alignment: .leading)
                Text("Size").frame(width: 80, alignment: .trailing)
                Text("Modified").frame(width: 96, alignment: .leading)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Theme.surfaceSubtle)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            if matches.isEmpty {
                VStack(spacing: 6) {
                    Text("No results for “\(query)”")
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    Text("Only items from the current scan results are searched. Try a shorter word, or rescan.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            } else {
                List(selection: selection) {
                    ForEach(matches.prefix(Self.rowLimit)) { item in
                        row(item).tag(item.id)
                    }
                    if matches.count > Self.rowLimit {
                        Text("Showing the \(Self.rowLimit) largest of \(matches.count.formatted()). Type more to narrow it down.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .selectionDisabled()
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 14)
    }

    private func row(_ item: InspectorItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayFolder)
                    .font(Theme.micro)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: item.source.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                Text(item.source.rawValue)
                    .lineLimit(1)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.inkTertiary)
            .frame(width: 120, alignment: .leading)
            Text(FileSizeHelper.formatBytes(item.sizeBytes))
                .font(Theme.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 80, alignment: .trailing)
            Text(item.modifiedDate?.relativeDescription ?? "—")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Inspector") { store.show(item) }
            if item.isOnDisk {
                Button("Reveal in Finder") { DeletionService.revealInFinder(item.path) }
                Button("Copy Path") { DeletionService.copyPath(item.path) }
            }
            Divider()
            Button("Ignore") { store.ignore(item, state: state) }
        }
    }

    // MARK: Empty & footer

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.inkSecondary)
            Text(state.isScanningAny ? "Scanning…" : "Nothing to search yet")
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.ink)
            Text("Find searches the results of Furl's scans: caches and junk, worktrees, large files, duplicates, apps and Smart Review.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan Everything") {
                Task { await state.scanAll() }
            }
            .buttonStyle(SweepButtonStyle(kind: .primary, height: 34))
            .disabled(state.isScanningAny)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ignoredFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
            Text("\(store.ignoredPaths.count) ignored item\(store.ignoredPaths.count == 1 ? "" : "s") hidden from Find and scans")
            Spacer()
            Button("Restore All") { store.restoreIgnored() }
                .buttonStyle(SweepLinkStyle())
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, Theme.Space.page)
        .padding(.bottom, 12)
    }
}

import Charts
import SwiftUI

/// Snapshots › "Why is my disk full?": what grew between saved snapshots of the home index.
struct SnapshotsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SnapshotsModel = .shared
    @State private var byCategory = false
    @State private var expanded: Set<String> = []
    @State private var pendingDelete: String?

    // No Theme token pairs these values yet (dark side matches Theme.warning); see report.
    private static let grewColor = Theme.growth
    private static let chartLine = Theme.growthLine
    @Environment(\.colorScheme) private var colorScheme
    /// Expanded rows: mint tint at 35% (light) / 60% (dark), as the boards draw it.
    private var openRowFill: Color { Theme.mintTint.opacity(colorScheme == .dark ? 0.6 : 0.35) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            mainCard.frame(minWidth: 680, maxWidth: .infinity)
                            sideColumn.frame(width: 300)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            mainCard
                            sideColumn
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
        }
        .cleanSlateScreen()
        .navigationTitle("Snapshots")
        .confirmationDialog("Delete this snapshot?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) {
                if let id = pendingDelete { model.delete(id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You won't be able to compare against this point any more. Your files aren't touched.")
        }
    }

    private var sideColumn: some View {
        VStack(spacing: 14) {
            savedSnapshots
            if model.diff == nil { firstRunCard }
        }
    }

    // MARK: Header

    private var header: some View {
        // The range tabs move under the title when the page is narrow (cleanup tray open) instead
        // of being squeezed to "This mo…".
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                headerTitle
                    .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                rangeTabsControl
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                rangeTabsControl
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SNAPSHOTS").font(Theme.micro).tracking(0.5).foregroundStyle(Theme.inkSecondary)
            Text("Why is my disk full?")
                .font(Theme.display(30, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            headline.font(.system(size: 14)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var rangeTabsControl: some View {
        PillTabs(tabs: rangeTabs, selection: $model.range, title: rangeTitle)
            .fixedSize()
            .disabled(model.summaries.count < 2)
            .opacity(model.summaries.count < 2 ? 0.5 : 1)
    }

    private var headline: Text {
        guard let diff = model.diff else {
            if let latest = model.latest {
                return Text("\(FileSizeHelper.formatBytes(latest.total)) in your home folder. After the next scan this shows what grew.")
            }
            return Text("Run a scan to save your first snapshot.")
        }
        let period = periodPhrase
        let top = diff.categories.filter { $0.delta > 0 && $0.category != .other && $0.delta * 5 >= max(1, diff.net) }.sorted { $0.delta > $1.delta }.prefix(2).map(\.category.title)
        let net = diff.net
        let verb = net >= 0 ? "grew" : "shrank"
        var text = Text("It \(verb) ") + Text(FileSizeHelper.formatBytes(abs(net))).bold()
            .foregroundColor(net >= 0 ? Self.grewColor : Theme.sweep) + Text(" \(period).")
        if net > 0, !top.isEmpty {
            text = text + Text(" Most of it is \(top.joined(separator: " and ").lowercased()).")
        }
        return text
    }

    private var rangeTabs: [SnapshotsModel.Range] {
        var tabs: [SnapshotsModel.Range] = [.today, .week, .month]
        if case .since = model.range { tabs.append(model.range) }
        return tabs
    }

    private func rangeTitle(_ r: SnapshotsModel.Range) -> String {
        if case .since(let id) = r { return sinceLabel(id) }
        return r.title
    }

    private var periodPhrase: String {
        switch model.range {
        case .today: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .since(let id): return "since \(sinceLabel(id))"
        }
    }

    private func sinceLabel(_ id: String) -> String {
        guard let s = model.summaries.first(where: { $0.id == id }) else { return "Since" }
        return "Since " + s.date.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: Main card

    @ViewBuilder
    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let diff = model.diff {
                summaryStrip(diff)
                Divider().overlay(Theme.hairline)
                groupBar(diff)
                Divider().overlay(Theme.hairline)
                if byCategory { categoryRows(diff) } else { folderRows(diff) }
            } else {
                biggestFolders
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border))
    }

    private func summaryStrip(_ diff: SnapshotDiff) -> some View {
        HStack(alignment: .center, spacing: 28) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Grew").foregroundStyle(Theme.inkSecondary)
                    Text("+" + FileSizeHelper.formatBytes(diff.grew)).font(Theme.display(20)).foregroundStyle(Self.grewColor)
                }
                GridRow {
                    Text("Shrank").foregroundStyle(Theme.inkSecondary)
                    Text("−" + FileSizeHelper.formatBytes(-diff.shrank)).font(Theme.display(20)).foregroundStyle(Theme.sweep)
                }
                GridRow {
                    Text("Used now").foregroundStyle(Theme.inkSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(FileSizeHelper.formatBytes(diff.new.volumeUsed)).font(Theme.display(20)).fixedSize()
                        Text("of \(FileSizeHelper.formatBytes(diff.new.volumeTotal))").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .font(Theme.body)
            .fixedSize()
            .frame(minWidth: 230, alignment: .leading)
            growthChart(diff)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func growthChart(_ diff: SnapshotDiff) -> some View {
        let points = model.chartPoints
        let low = points.map(\.total).min() ?? 0, high = points.map(\.total).max() ?? 1
        let pad = max(Int64(1), (high - low) / 4)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Home folder size, snapshot by snapshot")
                Spacer()
                Text(signed(diff.net) + " net")
            }
            .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            Chart(points) { p in
                AreaMark(x: .value("Date", p.date), yStart: .value("Low", Double(low - pad)), yEnd: .value("Size", Double(p.total)))
                    .foregroundStyle(Theme.warningTint)
                LineMark(x: .value("Date", p.date), y: .value("Size", Double(p.total)))
                    .foregroundStyle(Self.chartLine)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Date", p.date), y: .value("Size", Double(p.total)))
                    .foregroundStyle(Self.chartLine)
                    .symbolSize(p.id == points.last?.id ? 50 : 20)
            }
            .chartYScale(domain: Double(low - pad)...Double(high + pad))
            .chartYAxis(.hidden)
            .chartXAxis {
                if points.count <= 7 {
                    AxisMarks(values: points.map(\.date)) { _ in
                        // Snapshots minutes apart would print the same time twice; skip overlaps.
                        AxisValueLabel(format: axisFormat(points), collisionResolution: .greedy)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel(format: axisFormat(points), collisionResolution: .greedy)
                    }
                }
            }
            .frame(height: 96)
            .accessibilityLabel("Home folder size went from \(FileSizeHelper.formatBytes(diff.old.total)) to \(FileSizeHelper.formatBytes(diff.new.total))")
        }
    }

    private func axisFormat(_ points: [SnapshotSummary]) -> Date.FormatStyle {
        guard let first = points.first, let last = points.last,
              last.date.timeIntervalSince(first.date) >= 2 * 86_400 else { return .dateTime.hour().minute() }
        return .dateTime.weekday(.abbreviated).day()
    }

    private func groupBar(_ diff: SnapshotDiff) -> some View {
        let growth = diff.categories.filter { $0.delta >= 1_000_000 }.sorted { $0.delta > $1.delta }
        let sum = max(1, growth.map(\.delta).reduce(0, +))
        return HStack(spacing: 16) {
            PillTabs(tabs: [false, true], selection: $byCategory) { $0 ? "By category" : "By folder" }
                .fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(growth.prefix(6)) { c in
                            Rectangle().fill(c.category.color)
                                .frame(width: max(2, geo.size.width * CGFloat(c.delta) / CGFloat(sum) - 2))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 12) {
                    ForEach(growth.prefix(5)) { c in
                        Text("\(c.category.title) \(FileSizeHelper.formatBytes(c.delta))")
                    }
                }
                .font(Theme.micro).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Rows

    @ViewBuilder
    private func folderRows(_ diff: SnapshotDiff) -> some View {
        let spots = diff.hotspots()
        if spots.isEmpty {
            emptyRow("Nothing changed by more than 25 MB \(periodPhrase).")
        } else {
            let scale = max(1, spots.map { abs($0.delta) }.max() ?? 1)
            ForEach(Array(spots.enumerated()), id: \.element.id) { i, change in
                if i > 0 { Divider().overlay(Theme.hairline) }
                folderRow(change, diff: diff, scale: scale, subtitle: rowSubtitle(change))
            }
        }
    }

    @ViewBuilder
    private func categoryRows(_ diff: SnapshotDiff) -> some View {
        let cats = diff.categories.filter { abs($0.delta) >= 1_000_000 }.sorted { abs($0.delta) > abs($1.delta) }
        if cats.isEmpty {
            emptyRow("No category changed by more than 1 MB \(periodPhrase).")
        } else {
            let scale = max(1, cats.map { abs($0.delta) }.max() ?? 1)
            ForEach(Array(cats.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider().overlay(Theme.hairline) }
                let key = "cat:\(c.category.rawValue)"
                let isOpen = expanded.contains(key)
                rowShell(
                    open: isOpen, expandable: true, toggle: { toggle(key) },
                    title: Text(c.category.title).font(Theme.bodyStrong),
                    subtitle: "\(FileSizeHelper.formatBytes(c.oldSize)) → \(FileSizeHelper.formatBytes(c.newSize))",
                    fraction: Double(abs(c.delta)) / Double(scale), color: c.delta >= 0 ? c.category.color : Theme.sweep,
                    delta: c.delta, action: c.delta > 0 ? cleanButton(c.category, path: nil, primary: i == 0) : nil
                )
                if isOpen {
                    childList(diff.hotspots(in: c.category), diff: diff)
                }
            }
        }
    }

    private func folderRow(_ change: FolderChange, diff: SnapshotDiff, scale: Int64, subtitle: String, primary: Bool = false) -> some View {
        let isOpen = expanded.contains(change.path)
        return VStack(spacing: 0) {
            rowShell(
                open: isOpen, expandable: change.hasChildren, toggle: { toggle(change.path) },
                title: titleText(change),
                subtitle: subtitle,
                fraction: Double(abs(change.delta)) / Double(scale),
                color: change.delta >= 0 ? change.category.color : Theme.sweep,
                delta: change.delta,
                action: change.delta > 0 ? cleanButton(change.category, path: change.path, primary: false) : nil
            )
            .pathContextMenu(model.absolutePath(change.path))
            if isOpen {
                childList(diff.children(of: change.path, minDelta: 1_000_000), diff: diff)
            }
        }
    }

    private func childList(_ children: [FolderChange], diff: SnapshotDiff) -> AnyView {
        let shown = Array(children.prefix(10))
        let scale = max(1, shown.map { abs($0.delta) }.max() ?? 1)
        return AnyView(VStack(spacing: 0) {
            if shown.isEmpty {
                Text("The change is in files directly inside this folder.")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 26)
            }
            ForEach(shown) { child in
                HStack(spacing: 12) {
                    Button { if child.hasChildren { toggle(child.path) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded.contains(child.path) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .opacity(child.hasChildren ? 1 : 0)
                            Text(child.name).lineLimit(1).truncationMode(.middle)
                            if child.isNew { Text("· new").foregroundStyle(Theme.inkSecondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    MeterBar(fraction: Double(abs(child.delta)) / Double(scale),
                             color: child.delta >= 0 ? child.category.color : Theme.sweep, track: Theme.border, height: 4)
                        .frame(minWidth: 50, maxWidth: 120)
                    Text(signed(child.delta)).monospacedDigit()
                        .foregroundStyle(child.delta >= 0 ? Self.grewColor : Theme.sweep)
                        .frame(width: 74, alignment: .trailing)
                    Button("Open in Inspector") {
                        InspectorStore.shared.show(path: model.absolutePath(child.path), state: state)
                    }
                    .buttonStyle(SweepLinkStyle())
                    .frame(width: 150, alignment: .trailing)
                }
                .font(Theme.caption)
                .frame(height: 26)
                .pathContextMenu(model.absolutePath(child.path))
                if expanded.contains(child.path) {
                    childList(diff.children(of: child.path, minDelta: 1_000_000), diff: diff)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 20)
        .padding(.bottom, 8)
        .background(openRowFill))
    }

    private func rowShell(
        open: Bool, expandable: Bool, toggle: @escaping () -> Void, title: Text, subtitle: String,
        fraction: Double, color: Color, delta: Int64, action: AnyView?
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 11)
                        .opacity(expandable ? 1 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        title.lineLimit(1).truncationMode(.head)
                        Text(subtitle).font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            .frame(minWidth: 200)
            .layoutPriority(1)
            MeterBar(fraction: fraction, color: color, track: Theme.hairline, height: 6).frame(minWidth: 50, maxWidth: 150)
            Text(signed(delta)).font(Theme.bodyStrong).monospacedDigit()
                .foregroundStyle(delta >= 0 ? Self.grewColor : Theme.sweep)
                .lineLimit(1)
                .frame(width: 80, alignment: .trailing)
            Group { action ?? AnyView(Color.clear) }.frame(width: 170)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(open ? openRowFill : Color.clear)
    }

    private func titleText(_ change: FolderChange) -> Text {
        var t = Text(model.displayPath(change.path)).font(Theme.bodyStrong)
        if change.isNew { t = t + Text("  NEW").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.violet) }
        if change.isGone { t = t + Text("  REMOVED").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.sweep) }
        return t
    }

    private func rowSubtitle(_ c: FolderChange) -> String {
        if c.isNew { return "\(c.category.title) · new, \(FileSizeHelper.formatBytes(c.newSize))" }
        if c.isGone { return "\(c.category.title) · was \(FileSizeHelper.formatBytes(c.oldSize))" }
        return "\(c.category.title) · \(FileSizeHelper.formatBytes(c.oldSize)) → \(FileSizeHelper.formatBytes(c.newSize))"
    }

    private func cleanButton(_ category: SnapshotCategory, path: String?, primary: Bool) -> AnyView {
        AnyView(
            Button(category.cleanTitle) { clean(category, path: path) }
                .buttonStyle(SweepButtonStyle(kind: primary ? .primary : .secondary, height: 30, fullWidth: true))
                .font(.system(size: 12, weight: .semibold))
        )
    }

    private func clean(_ category: SnapshotCategory, path: String?) {
        if let section = category.cleanSection {
            state.selectedSection = section
        } else if let path {
            InspectorStore.shared.show(path: model.absolutePath(path), state: state)
        } else {
            state.selectedSection = .spaceMap
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(Theme.body).foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }

    // MARK: First run

    private var biggestFolders: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.latest == nil ? "No snapshots yet" : "Biggest folders right now")
                .font(Theme.bodyStrong).padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.hairline)
            if model.latest == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each scan saves a small summary of your folder sizes on this Mac. Scan once now, and again later, to see what grew.")
                        .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                    Button("Scan now") { Task { await state.scanLargeFiles() } }
                        .buttonStyle(SweepButtonStyle(kind: .primary))
                }
                .padding(20)
            } else {
                let top = model.biggest
                let scale = max(1, top.first?.size ?? 1)
                ForEach(Array(top.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    HStack(spacing: 12) {
                        Text(model.displayPath(item.path)).font(Theme.bodyStrong).lineLimit(1).truncationMode(.head)
                            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        MeterBar(fraction: Double(item.size) / Double(scale), color: Theme.usedBar, height: 6).frame(minWidth: 50, maxWidth: 150)
                        Text(FileSizeHelper.formatBytes(item.size)).font(Theme.bodyStrong).monospacedDigit()
                            .frame(width: 74, alignment: .trailing)
                        Button("Open in Inspector") {
                            InspectorStore.shared.show(path: model.absolutePath(item.path), state: state)
                        }
                        .buttonStyle(SweepLinkStyle()).frame(width: 140, alignment: .trailing)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .pathContextMenu(model.absolutePath(item.path))
                }
            }
        }
    }

    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.summaries.count < 2 ? "FIRST RUN · ONLY ONE SCAN" : "NOTHING OLDER TO COMPARE")
                .font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.inkSecondary)
            Text(model.latest == nil ? "No snapshot yet" : "Your first snapshot is saved")
                .font(Theme.display(17, weight: .semibold))
            Text(firstRunText).font(Theme.caption).foregroundStyle(Theme.inkTertiary).lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.controlBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private var firstRunText: String {
        guard let latest = model.latest else { return "Scan once to save a summary of your folder sizes." }
        return "\(FileSizeHelper.formatBytes(latest.total)) in your home folder now. After the next scan this screen shows what grew. Until then, the biggest folders are listed here."
    }

    // MARK: Saved snapshots

    private var savedSnapshots: some View {
        let baseID = model.diff?.old.id
        return VStack(alignment: .leading, spacing: 4) {
            Text("Saved snapshots").font(.system(size: 14, weight: .semibold)).padding(.bottom, 6)
            if model.summaries.isEmpty {
                Text("None yet.").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            ForEach(model.summaries.reversed().prefix(12)) { s in
                let isLatest = s.id == model.latest?.id
                let isBase = s.id == baseID
                Button {
                    if !isLatest { model.range = .since(s.id) }
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(isLatest ? Theme.sweep : (isBase ? Color.clear : Theme.controlBorder))
                            .overlay(Circle().strokeBorder(isBase ? Self.chartLine : .clear, lineWidth: 2))
                            .frame(width: 8, height: 8)
                        HStack(spacing: 4) {
                            Text(dateLabel(s.date)).fontWeight(isLatest ? .semibold : .regular)
                            if isBase { Text("· compared").foregroundStyle(Theme.inkSecondary) }
                        }
                        Spacer()
                        Text(FileSizeHelper.formatBytes(s.total)).monospacedDigit()
                            .foregroundStyle(isLatest ? Theme.ink : Theme.inkSecondary)
                    }
                    .font(Theme.body)
                    .frame(height: 30)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isBase ? Theme.warningTint : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isLatest ? "Latest snapshot" : "Compare with the latest")
                .contextMenu {
                    if !isLatest {
                        Button("Compare with latest") { model.range = .since(s.id) }
                    }
                    Button("Delete Snapshot…", role: .destructive) { pendingDelete = s.id }
                }
            }
            Text("Each scan saves a small summary on this Mac. Nothing is rescanned to compare. Click a snapshot to compare it with the latest.")
                .font(Theme.micro).foregroundStyle(Theme.inkSecondary).lineSpacing(2).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.border))
    }

    // MARK: Helpers

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func signed(_ v: Int64) -> String {
        v >= 0 ? "+" + FileSizeHelper.formatBytes(v) : "−" + FileSizeHelper.formatBytes(-v)
    }

    private func dateLabel(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(d) { return "Today, \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday, \(time)" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

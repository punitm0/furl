import Charts
import SwiftUI

/// Timeline of everything Furl did, with what it won back.
struct ActivityView: View {
    @ObservedObject var state: AppState
    @ObservedObject var compress: CompressStore
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var autoSweep = AppServices.autoSweep
    @State private var confirmingClear = false

    private var rows: [ActivityRowModel] {
        let own = log.entries.map { ActivityRowModel(entry: $0, canUndo: log.canUndo($0, compress: compress)) }
        let runs = autoSweep.history.map { ActivityRowModel(run: $0, canUndo: log.canUndo($0)) }
        return (own + runs).sorted { $0.date > $1.date }
    }

    var body: some View {
        let rows = self.rows
        let totals = ActivityTotals(rows: rows)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(totals, isEmpty: rows.isEmpty)
                statCards(totals)
                WeeklyChart(rows: rows)
                timeline(rows)
                Text("This history never leaves your Mac. It's stored in ~/Library/Application Support/Furl.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cleanSlateScreen()
        .onAppear { log.refreshRestorable() }
        .confirmationDialog("Clear History?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes Furl's own record of cleanups, stopped processes and compress runs. Auto-Sweep History stays in Settings › Automation. Nothing on disk changes.")
        }
    }

    // MARK: Header & cards

    private func header(_ totals: ActivityTotals, isEmpty: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HISTORY")
                    .font(Theme.caption)
                    .tracking(0.5)
                    .foregroundStyle(Theme.inkSecondary)
                Text(headline(totals, isEmpty: isEmpty))
                    .font(Theme.display(32, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                Button("Clear History…", role: .destructive) { confirmingClear = true }
                    .disabled(log.entries.isEmpty)
            } label: {
                // HistoryDark: 18 pt ellipsis.circle in inkTertiary, 30 × 30 hit area.
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }

    private func headline(_ totals: ActivityTotals, isEmpty: Bool) -> String {
        if isEmpty { return "Your cleanups will show up here" }
        var text = "You've won back \(bytesText(totals.disk))"
        if totals.memory > 0 {
            text += " and \(bytesText(totals.memory)) of memory"
        }
        return text
    }

    private func statCards(_ totals: ActivityTotals) -> some View {
        HStack(spacing: 12) {
            StatCard(title: "Disk freed", value: bytesText(totals.disk), color: Theme.sweep,
                     help: "Cleaned by Furl and not undone. Items in the Trash count here; emptying the Trash doesn't add them again.")
            StatCard(title: "Memory freed", value: bytesText(totals.memory), color: Theme.memory,
                     help: "Memory returned by stopping leftover processes. Counted apart from disk space.")
            StatCard(title: "Saved by Compress & Shrink", value: bytesText(totals.compress), color: Theme.ink,
                     help: "Space Compress, Shrink and format conversion saved by making files smaller instead of deleting them. The originals went to the Trash.")
            StatCard(title: "Cleanups undone", value: "\(totals.undone) of \(totals.cleanups)", color: Theme.ink,
                     help: "Cleanups you put back with Undo.")
        }
    }

    // MARK: Timeline

    private func timeline(_ rows: [ActivityRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Timeline")
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.ink)
            if rows.isEmpty {
                Text("Nothing yet. Cleanups, Auto-Sweep runs, stopped processes, compress runs and Trash empties are listed here.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            } else {
                let days = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.date) }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Text(dayTitle(day))
                        .font(Theme.micro.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(days[day] ?? []) { row in
                        ActivityRow(row: row, isBusy: log.isUndoing || state.isCleaning,
                                    onUndo: { Task { await undo(row) } },
                                    onTurnOff: turnOffAction(row))
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20)
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// AutoSweepTrust History: "Don’t do this again" unticks the rule behind an Auto-Sweep run.
    private func turnOffAction(_ row: ActivityRowModel) -> (() -> Void)? {
        guard case .autoSweep(let run) = row.source, run.trigger == .scheduled,
              autoSweep.hasRulesOn(of: run) else { return nil }
        return { autoSweep.turnOffRules(of: run) }
    }

    private func undo(_ row: ActivityRowModel) async {
        switch row.source {
        case .entry(let entry):
            await log.undo(entry, state: state, compress: compress)
        case .autoSweep(let run):
            await state.undoAutoSweepRun(run, store: autoSweep)
        }
    }
}

/// FileSizeHelper spells 0 as "Zero KB"; the stat cards read better with a number.
private func bytesText(_ bytes: Int64) -> String {
    bytes > 0 ? FileSizeHelper.formatBytes(bytes) : "0 KB"
}

// MARK: - Row model

struct ActivityRowModel: Identifiable {
    enum Source {
        case entry(ActivityEntry)
        case autoSweep(AutoSweepRun)
    }

    let id: String
    let date: Date
    let systemImage: String
    let accent: Theme.Accent
    let title: String
    let detail: String
    let itemCount: Int
    let disk: Int64
    let memory: Int64
    let compress: Int64
    let permanent: Bool
    let automatic: Bool
    /// AutoSweepTrust: each run is tagged Auto-Sweep or You.
    let byAutoSweep: Bool
    /// "Why: weekly rule …" under an Auto-Sweep run.
    let why: String?
    let undone: Bool
    let canUndo: Bool
    /// Items left alone because they changed since the scan.
    let skippedCount: Int
    /// Counts toward "Disk freed" / "Cleanups undone" (not Trash empties, processes or compress).
    let isCleanup: Bool
    let source: Source

    init(entry: ActivityEntry, canUndo: Bool) {
        id = entry.id.uuidString
        date = entry.date
        title = entry.title
        detail = entry.detail
        itemCount = entry.itemCount
        memory = entry.memoryBytes
        compress = entry.compressBytes
        permanent = entry.permanentBytes > 0 && entry.trashed.isEmpty
        automatic = entry.automatic
        byAutoSweep = false
        why = nil
        undone = entry.undone
        self.canUndo = canUndo
        skippedCount = entry.skippedCount ?? 0
        source = .entry(entry)
        switch entry.kind {
        case .cleanup:
            systemImage = SidebarSection(rawValue: entry.title)?.systemImage ?? "trash"
            accent = Theme.accentGreen
            disk = entry.diskBytes
            isCleanup = true
        case .tray:
            systemImage = "tray.full"
            accent = Theme.accentGreen
            disk = entry.diskBytes
            isCleanup = true
        case .processes:
            systemImage = "memorychip"
            accent = Theme.accentBlue
            disk = 0
            isCleanup = false
        case .compress, .shrink, .format:
            // Shrink and Format share the Compress row's teal tile, each with its own icon (design).
            switch entry.kind {
            case .shrink: systemImage = "arrow.down.right.and.arrow.up.left"
            case .format: systemImage = "arrow.triangle.2.circlepath"
            default: systemImage = "arrow.down.right.and.arrow.up.left"
            }
            accent = Theme.accentTeal
            disk = 0
            isCleanup = false
        case .emptyTrash:
            systemImage = "trash.slash"
            accent = Theme.accentGray
            disk = entry.diskBytes
            isCleanup = false
        }
    }

    init(run: AutoSweepRun, canUndo: Bool) {
        id = run.id.uuidString
        date = run.date
        systemImage = run.trigger == .scheduled || run.trigger == .manual ? "clock.arrow.2.circlepath" : "sparkles"
        accent = Theme.accentTeal
        byAutoSweep = run.trigger == .scheduled
        if run.parts.contains(where: { $0.rule == .safeClean }) {
            title = "Clean safe items · \(run.trigger.rawValue)"
            detail = run.summary
        } else {
            title = run.whatText
            detail = byAutoSweep ? "Auto-Sweep" : "Auto-Sweep · \(run.trigger.rawValue)"
        }
        why = run.why
        itemCount = run.totalItems
        // Expired Trash items were counted when they were moved; compress and processes have their own totals.
        disk = run.parts.filter { ![.processes, .compress, .expireTrash].contains($0.rule) }.reduce(0) { $0 + $1.bytes }
        memory = run.parts.filter { $0.rule == .processes }.reduce(0) { $0 + $1.bytes }
        compress = run.parts.filter { $0.rule == .compress }.reduce(0) { $0 + $1.bytes }
        permanent = false
        automatic = false
        undone = run.undone
        self.canUndo = canUndo
        skippedCount = run.skippedCount ?? 0
        isCleanup = disk > 0 || !run.trashed.isEmpty
        source = .autoSweep(run)
    }
}

struct ActivityTotals {
    var disk: Int64 = 0
    var memory: Int64 = 0
    var compress: Int64 = 0
    var cleanups = 0
    var undone = 0

    init(rows: [ActivityRowModel]) {
        for row in rows {
            if row.isCleanup {
                cleanups += 1
                if row.undone { undone += 1 }
            }
            guard !row.undone else { continue }
            if row.isCleanup { disk += row.disk }
            memory += row.memory
            compress += row.compress
        }
    }
}

// MARK: - Pieces

private struct StatCard: View {
    let title: String
    let value: String
    let color: Color
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkSecondary)
            Text(value)
                .font(Theme.display(26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18, radius: 12)
        .help(help)
    }
}

private struct ActivityRow: View {
    let row: ActivityRowModel
    let isBusy: Bool
    let onUndo: () -> Void
    var onTurnOff: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(row.accent.fg)
                .frame(width: 30, height: 30)
                .background(row.accent.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.ink)
                    if row.undone {
                        tag("Undone", fg: Theme.inkSecondary, bg: Theme.hairline)
                    } else if row.permanent {
                        tag(RiskTier.permanent.label, fg: RiskTier.permanent.foreground, bg: RiskTier.permanent.tint)
                    }
                    if row.byAutoSweep {
                        tag("Auto-Sweep", fg: Theme.sweepDeep, bg: Theme.mintTint)
                    } else if row.automatic {
                        tag("Automatic", fg: Theme.inkSecondary, bg: Theme.hairline)
                    } else {
                        tag("You", fg: Theme.inkSecondary, bg: Theme.hairline)
                    }
                }
                Text(row.why ?? row.detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                if row.skippedCount > 0 {
                    Text("\(row.skippedCount) left alone: changed since the scan")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let onTurnOff {
                Button("Don’t do this again", action: onTurnOff)
                    .buttonStyle(SweepLinkStyle())
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .help("Unticks this rule in Settings › Automation")
            }
            VStack(alignment: .trailing, spacing: 2) {
                if let amount {
                    Text(amount.text)
                        .font(Theme.bodyStrong)
                        .monospacedDigit()
                        .foregroundStyle(row.undone ? Theme.inkSecondary : amount.color)
                        .strikethrough(row.undone)
                }
                Text(row.date.formatted(date: .omitted, time: .shortened) + " · \(row.itemCount) item\(row.itemCount == 1 ? "" : "s")")
                    .font(Theme.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            Group {
                if row.canUndo {
                    Button("Undo", action: onUndo)
                        .buttonStyle(SweepButtonStyle(kind: .secondary, height: 28))
                        .disabled(isBusy)
                        .help("Put these items back where they were")
                } else {
                    Color.clear
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private var amount: (text: String, color: Color)? {
        if row.memory > 0 && row.disk == 0 {
            return (FileSizeHelper.formatBytes(row.memory) + " memory", Theme.memory)
        }
        if row.compress > 0 && row.disk == 0 {
            return (FileSizeHelper.formatBytes(row.compress) + " saved", Theme.violet)
        }
        if row.disk > 0 {
            var text = FileSizeHelper.formatBytes(row.disk)
            if row.memory > 0 { text += " + \(FileSizeHelper.formatBytes(row.memory)) memory" }
            return (text, row.isCleanup ? Theme.sweep : Theme.inkSecondary)
        }
        return nil
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// "Disk freed per week", last 12 weeks.
private struct WeeklyChart: View {
    let rows: [ActivityRowModel]
    @State private var grown = false
    @State private var hoveredLabel: String?

    private struct Week: Identifiable {
        let start: Date
        let bytes: Int64
        var id: Date { start }
        var label: String { start.formatted(.dateTime.month(.abbreviated).day()) }
    }

    private var weeks: [Week] {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        let starts = (0..<12).reversed().compactMap { cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        var totals: [Date: Int64] = [:]
        for row in rows where row.isCleanup && !row.undone {
            guard let start = cal.dateInterval(of: .weekOfYear, for: row.date)?.start else { continue }
            totals[start, default: 0] += row.disk
        }
        return starts.map { Week(start: $0, bytes: totals[$0] ?? 0) }
    }

    var body: some View {
        let weeks = self.weeks
        let peak = weeks.max { $0.bytes < $1.bytes }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk freed per week")
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("Last 12 weeks · stays on this Mac")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            Chart {
                ForEach(weeks) { week in
                    BarMark(
                        x: .value("Week", week.label),
                        y: .value("Freed", grown ? Double(week.bytes) : 0),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(barColor(week, peak: peak))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .top, spacing: 4) {
                        if week.bytes > 0 && (hoveredLabel == nil ? week.id == peak?.id : hoveredLabel == week.label) {
                            Text(FileSizeHelper.formatBytes(week.bytes))
                                .font(Theme.micro.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                // Baseline under the bars (History board: 1px hairline).
                RuleMark(y: .value("Baseline", 0))
                    .foregroundStyle(Theme.hairline)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                // Every other week, so labels don't collide when the tray narrows the page.
                AxisMarks(values: weeks.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.label)) { _ in
                    AxisValueLabel()
                        .font(Theme.micro)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .chartXSelection(value: $hoveredLabel)
            .frame(height: 200)
            .overlay {
                if weeks.allSatisfy({ $0.bytes == 0 }) {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.sweep)
                        Text("No space freed in the last 12 weeks yet")
                            .font(Theme.bodyStrong)
                            .foregroundStyle(Theme.ink)
                        Text("Each cleanup adds a bar here, week by week.")
                            .font(Theme.micro)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.bottom, 20)
                }
            }
            .accessibilityLabel("Bar chart of disk freed per week for the last 12 weeks")
        }
        .card(padding: 24, radius: 12)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { grown = true } }
    }

    private func barColor(_ week: Week, peak: Week?) -> Color {
        // Pine is near-invisible on the dark surface, so the highlight lifts to mint there.
        let highlight = Theme.chartHighlight
        if let hoveredLabel { return hoveredLabel == week.label ? highlight : Theme.sweep.opacity(0.45) }
        return week.id == peak?.id && week.bytes > 0 ? highlight : Theme.sweep
    }
}

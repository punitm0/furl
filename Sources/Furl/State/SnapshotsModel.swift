import Foundation
import SwiftUI

/// Drives the Snapshots screen ("Why is my disk full?") and the Dashboard's weekly hint.
@MainActor
final class SnapshotsModel: ObservableObject {
    static let shared = SnapshotsModel()

    enum Range: Hashable {
        case today, week, month
        /// Compare a chosen saved snapshot with the latest.
        case since(String)

        var title: String {
            switch self {
            case .today: return "Today"
            case .week: return "This week"
            case .month: return "This month"
            case .since: return "Since"
            }
        }
    }

    @Published private(set) var summaries: [SnapshotSummary] = []
    @Published var range: Range = .week { didSet { if range != oldValue { recompute() } } }
    @Published private(set) var diff: SnapshotDiff?
    @Published private(set) var isComputing = false
    /// Biggest folders from the only snapshot (first-run state).
    @Published private(set) var biggest: [(path: String, size: Int64)] = []
    @Published private(set) var rootPath = ScanIndexCache.homePath

    private var observer: NSObjectProtocol?
    private var generation = 0

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .snapshotsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in SnapshotsModel.shared.reload() }
        }
        reload()
    }

    /// Hook the shared index so every full or incremental scan saves a snapshot.
    static func connect() {
        _ = shared
        Task {
            await ScanIndexCache.shared.setOnRefresh { index in
                guard index.rootPath == ScanIndexCache.homePath else { return }
                Task { await SnapshotStore.shared.record(index) }
            }
        }
    }

    func reload() {
        Task {
            let list = await SnapshotStore.shared.summaries()
            summaries = list
            if case .since(let id) = range, !list.contains(where: { $0.id == id }) { range = .week }
            recompute()
        }
    }

    var latest: SnapshotSummary? { summaries.last }

    /// The snapshot a range compares against, or nil when there's nothing older to compare with.
    func baseline(for range: Range, now: Date = Date()) -> SnapshotSummary? {
        guard let latest, summaries.count > 1 else { return nil }
        let older = summaries.dropLast()
        let pick: SnapshotSummary?
        switch range {
        case .today:
            let start = Calendar.current.startOfDay(for: now)
            pick = older.last(where: { $0.date < start }) ?? older.first
        case .week:
            pick = older.last(where: { $0.date <= now.addingTimeInterval(-7 * 86_400) }) ?? older.first
        case .month:
            pick = older.last(where: { $0.date <= now.addingTimeInterval(-30 * 86_400) }) ?? older.first
        case .since(let id):
            pick = older.first(where: { $0.id == id })
        }
        return pick?.id == latest.id ? nil : pick
    }

    /// Net change of the home folder over the last week (Dashboard hint).
    var weekGrowth: Int64? {
        guard let latest, let base = baseline(for: .week) else { return nil }
        return latest.total - base.total
    }

    /// Snapshots inside the current range, for the growth chart.
    var chartPoints: [SnapshotSummary] {
        guard let base = baseline(for: range) else { return summaries }
        return summaries.filter { $0.date >= base.date }
    }

    func absolutePath(_ rel: String) -> String { rel.isEmpty ? rootPath : rootPath + "/" + rel }

    func displayPath(_ rel: String) -> String {
        let home = ScanIndexCache.homePath
        let abs = absolutePath(rel)
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    func delete(_ id: String) {
        Task { await SnapshotStore.shared.delete(id) }
    }

    private func recompute() {
        generation += 1
        let gen = generation
        guard let latest else { diff = nil; biggest = []; return }
        guard let base = baseline(for: range) else {
            diff = nil
            Task {
                let snap = await SnapshotStore.shared.snapshot(latest.id)
                guard gen == generation else { return }
                biggest = snap?.biggestFolders() ?? []
                if let snap { rootPath = snap.rootPath }
            }
            return
        }
        isComputing = true
        Task {
            let result = await SnapshotStore.shared.diff(from: base.id, to: latest.id)
            guard gen == generation else { return }
            diff = result
            if let result { rootPath = result.rootPath }
            isComputing = false
        }
    }
}

extension SnapshotCategory {
    var color: Color {
        switch self {
        // Lime, not orange: orange only ever means caution in Furl.
        case .developer: return Theme.lime
        case .aiModels: return Theme.chartPalette[1]
        case .media: return Theme.accentPink.fg
        case .docker: return Theme.chartPalette[2]
        case .caches: return Theme.accentTeal.fg
        case .documents: return Color(light: 0x5C7CFA, dark: 0x91A7FF)
        case .downloads: return Theme.downloads
        case .appData: return Color(light: 0xAE3EC9, dark: 0xE599F7)
        case .trash: return Theme.chartPalette[6]
        case .other: return Theme.inkSecondary
        }
    }

    /// Where to clean this kind of space; nil → the Inspector.
    var cleanSection: SidebarSection? {
        switch self {
        case .developer, .caches, .aiModels, .docker: return .junk
        case .media: return .compress
        case .documents, .downloads: return .largeFiles
        case .appData: return .apps
        case .trash: return .dashboard
        case .other: return nil
        }
    }

    var cleanTitle: String {
        switch self {
        case .developer, .caches, .docker: return "Clean in Caches & Junk"
        case .aiModels: return "Review in Caches & Junk"
        case .media: return "Shrink in Compress"
        case .documents, .downloads: return "Review in Large Files"
        case .appData: return "Review in Apps"
        case .trash: return "Empty Trash in Overview"
        case .other: return "Open in Inspector"
        }
    }
}

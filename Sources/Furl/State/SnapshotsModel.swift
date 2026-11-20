import Foundation
import SwiftUI

/// Drives Disk › What grew and the Dashboard's weekly hint.
@MainActor
final class SnapshotsModel: ObservableObject {
    static let shared = SnapshotsModel()

    enum Range: Hashable {
        case today, week, month
        /// Compare a chosen saved snapshot with the latest.
        case since(String)
    }

    @Published private(set) var summaries: [SnapshotSummary] = []
    @Published var range: Range = .week { didSet { if range != oldValue { recompute() } } }
    @Published private(set) var diff: SnapshotDiff?
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

    func absolutePath(_ rel: String) -> String { rel.isEmpty ? rootPath : rootPath + "/" + rel }

    func displayPath(_ rel: String) -> String {
        let home = ScanIndexCache.homePath
        let abs = absolutePath(rel)
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    private func recompute() {
        generation += 1
        let gen = generation
        // With nothing older to compare, there's no diff; don't load the whole snapshot for it.
        guard let latest, let base = baseline(for: range) else { diff = nil; return }
        Task {
            let result = await SnapshotStore.shared.diff(from: base.id, to: latest.id)
            guard gen == generation else { return }
            diff = result
            if let result { rootPath = result.rootPath }
        }
    }
}

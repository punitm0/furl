import Foundation

extension Notification.Name {
    /// Posted on the main thread after a snapshot is saved or removed.
    static let snapshotsChanged = Notification.Name("Furl.snapshotsChanged")
}

/// Saves a compact, LZFSE-compressed snapshot after each home index refresh, in
/// `~/Library/Application Support/Furl/Snapshots/`, and prunes the history:
/// today's first and latest, the last of each day for 30 days, then the last of each week for 6 months.
actor SnapshotStore {
    static let shared = SnapshotStore()

    /// Two refreshes closer than this replace each other instead of adding a snapshot.
    static let minInterval: TimeInterval = 20

    private let directory: URL
    private var manifest: [SnapshotSummary] = []
    private var loaded = false
    private var cache: [String: DiskSnapshot] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? AppIdentity.supportDirectory.appendingPathComponent("Snapshots", isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".snapshot") }

    // MARK: Reading

    /// Oldest first.
    func summaries() -> [SnapshotSummary] {
        loadIfNeeded()
        return manifest
    }

    func snapshot(_ id: String) -> DiskSnapshot? {
        if let hit = cache[id] { return hit }
        guard let data = try? Data(contentsOf: fileURL(id)),
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let snap = try? JSONDecoder().decode(DiskSnapshot.self, from: raw) else { return nil }
        if cache.count > 6 { cache.removeAll() }
        cache[id] = snap
        return snap
    }

    func diff(from oldID: String, to newID: String) -> SnapshotDiff? {
        loadIfNeeded()
        guard let os = manifest.first(where: { $0.id == oldID }), let ns = manifest.first(where: { $0.id == newID }),
              let o = snapshot(oldID), let n = snapshot(newID) else { return nil }
        return SnapshotDiff(old: o, oldSummary: os, new: n, newSummary: ns)
    }

    // MARK: Writing

    /// Called with every fresh home index (full or incremental).
    func record(_ index: FileIndex, now: Date = Date()) {
        loadIfNeeded()
        let snap = SnapshotBuilder.make(from: index, disk: DiskInfoService.currentDiskUsage(), date: now)
        guard snap.names.count > 1 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let raw = try JSONEncoder().encode(snap)
            let packed = try (raw as NSData).compressed(using: .lzfse) as Data
            let id = String(Int64(now.timeIntervalSince1970))
            try packed.write(to: fileURL(id), options: .atomic)
            cache[id] = snap

            if let last = manifest.last, now.timeIntervalSince(last.date) < Self.minInterval, last.id != id {
                removeFile(last.id)
                manifest.removeLast()
            }
            manifest.removeAll { $0.id == id }
            manifest.append(SnapshotSummary(
                id: id, date: now, total: snap.total, volumeUsed: snap.volumeUsed,
                volumeTotal: snap.volumeTotal, folderCount: snap.names.count
            ))
            prune(now: now)
            saveManifest()
            NSLog("Furl snapshot %@: %d folders, %d KB", id, snap.names.count, packed.count / 1024)
        } catch {
            NSLog("Furl snapshot save failed: %@", error.localizedDescription)
            return
        }
        Task { @MainActor in NotificationCenter.default.post(name: .snapshotsChanged, object: nil) }
    }

    func delete(_ id: String) {
        loadIfNeeded()
        removeFile(id)
        manifest.removeAll { $0.id == id }
        saveManifest()
        Task { @MainActor in NotificationCenter.default.post(name: .snapshotsChanged, object: nil) }
    }

    // MARK: Retention

    /// Which summaries to keep. Pure, so it can be reasoned about (and tested) on its own.
    static func retained(_ all: [SnapshotSummary], now: Date, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        var keep = Set<String>()
        var lastPerDay: [Date: SnapshotSummary] = [:]
        var lastPerWeek: [DateComponents: SnapshotSummary] = [:]
        let todays = all.filter { $0.date >= today }
        if let first = todays.min(by: { $0.date < $1.date }) { keep.insert(first.id) }
        if let last = todays.max(by: { $0.date < $1.date }) { keep.insert(last.id) }
        for s in all where s.date < today {
            let age = now.timeIntervalSince(s.date)
            if age <= 30 * 86_400 {
                let day = calendar.startOfDay(for: s.date)
                if (lastPerDay[day]?.date ?? .distantPast) < s.date { lastPerDay[day] = s }
            } else if age <= 183 * 86_400 {
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: s.date)
                if (lastPerWeek[week]?.date ?? .distantPast) < s.date { lastPerWeek[week] = s }
            }
        }
        keep.formUnion(lastPerDay.values.map(\.id))
        keep.formUnion(lastPerWeek.values.map(\.id))
        return keep
    }

    private func prune(now: Date) {
        let keep = Self.retained(manifest, now: now)
        for s in manifest where !keep.contains(s.id) { removeFile(s.id) }
        manifest.removeAll { !keep.contains($0.id) }
    }

    // MARK: Files

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([SnapshotSummary].self, from: data) {
            manifest = list.filter { FileManager.default.fileExists(atPath: fileURL($0.id).path) }
                .sorted { $0.date < $1.date }
        }
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
    }

    private func removeFile(_ id: String) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
    }

}

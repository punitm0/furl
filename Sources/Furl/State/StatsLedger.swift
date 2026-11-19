import Combine
import Foundation

/// One change to Furl's numbers, recorded when it really happened:
/// - `disk`: bytes that left the disk (permanent deletes, worktree removal, command-based junk
///   cleanups, Furl's own Trash items when they're emptied or expire),
/// - `compress`: Compress/Shrink savings (after minus before) and how many files,
/// - `memory`: memory freed by stopping processes (never part of the disk numbers),
/// - `reversal`: an undo/restore that takes an earlier event back out,
/// - `legacy`: the pre-ledger lifetime total, migrated once. It is never reported.
struct StatsEvent: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case disk, memory, compress, reversal, legacy
    }

    /// Where the bytes came from. Raw values are what the stats Worker accepts (stats-worker/src/schema.ts).
    enum Category: String, Codable, Sendable {
        case junk, worktrees, apps, duplicates, trash, other
        case largeFiles = "large_files"
        case smartReview = "smart_review"
        case autoSweep = "auto_sweep"
        case processes
        case compress, shrink
        case legacy, reversal
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let category: Category
    let bytes: Int64
    let files: Int
    /// For `disk`: how many things were removed (a cache folder, an app, a worktree each count as one).
    /// nil in events recorded before item counts existed.
    var items: Int? = nil
    /// For `reversal`: the event it undoes.
    let reverses: UUID?
    /// Set once the community stats server answered 2xx for this event.
    var sentAt: Date?
}

/// The append-only ledger behind every "freed" number Furl shows, and the single source of
/// truth for what community stats may report. Lives in
/// ~/Library/Application Support/Furl/stats-ledger.json (owner-only, see PrivateStorage).
/// Events are only ever appended; the one field that changes is `sentAt`.
@MainActor
final class StatsLedger: ObservableObject {
    static let shared = StatsLedger()

    private struct File: Codable {
        var version = 1
        var events: [StatsEvent] = []
    }

    @Published private(set) var events: [StatsEvent] = []

    /// Disk freed by cleanups plus Compress/Shrink savings, minus anything undone, plus the legacy total.
    @Published private(set) var lifetimeFreedBytes: Int64 = 0
    @Published private(set) var lifetimeMemoryFreedBytes: Int64 = 0
    @Published private(set) var lifetimeFilesCompressed = 0

    private let url: URL
    /// See `recordRun`.
    private var runEvents: [String: UUID] = [:]

    init(url: URL = AutoSweepStore.supportDirectory.appendingPathComponent("stats-ledger.json"),
         defaults: UserDefaults = .standard) {
        self.url = url
        if let file = Self.load(url) {
            events = file.events
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Unreadable: keep it aside rather than overwrite the history with an empty ledger.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        migrateLegacyTotal(defaults)
        recompute()
    }

    // MARK: - Recording

    @discardableResult
    func recordDiskFreed(_ bytes: Int64, items: Int, category: StatsEvent.Category) -> UUID? {
        append(kind: .disk, category: category, bytes: bytes, items: items)
    }

    @discardableResult
    func recordMemoryFreed(_ bytes: Int64, category: StatsEvent.Category) -> UUID? {
        append(kind: .memory, category: category, bytes: bytes)
    }

    /// Compress or Shrink: measured before/after savings for `files` files.
    @discardableResult
    func recordCompressed(savedBytes: Int64, files: Int, category: StatsEvent.Category) -> UUID? {
        guard files > 0 else { return nil }
        return append(kind: .compress, category: category, bytes: max(0, savedBytes), files: files)
    }

    /// One Compress or Shrink run's savings, recorded once however many callers ask (the store hook below
    /// and History both do, in either order), so History can keep the event's id and reverse it later.
    /// Keyed by the run's start, in memory: a run is only ever recorded in the session it finished in.
    @discardableResult
    func recordRun(category: StatsEvent.Category, startedAt: Date, savedBytes: Int64, files: Int) -> UUID? {
        let key = "\(category.rawValue)|\(startedAt.timeIntervalSinceReferenceDate)"
        if let id = runEvents[key] { return id }
        let id = recordCompressed(savedBytes: savedBytes, files: files, category: category)
        if let id { runEvents[key] = id }
        return id
    }

    /// For History entries saved before they kept the event id: the unreversed Compress/Shrink event
    /// recorded for that run (same category, bytes and file count, within a minute of it finishing).
    func legacyRunEvent(category: StatsEvent.Category, savedBytes: Int64, files: Int, finishedAt: Date) -> UUID? {
        let reversed = Set(events.compactMap(\.reverses))
        return events.last { event in
            event.kind == .compress && event.category == category && !reversed.contains(event.id)
                && event.bytes == max(0, savedBytes) && event.files == files
                && abs(event.date.timeIntervalSince(finishedAt)) < 60
        }?.id
    }

    /// Takes an earlier event back out (its originals were restored). No-op if it was already reversed.
    func reverse(_ id: UUID) {
        guard let original = events.first(where: { $0.id == id }),
              original.kind != .reversal, original.kind != .legacy,
              !events.contains(where: { $0.reverses == id })
        else { return }
        events.append(StatsEvent(id: UUID(), date: Date(), kind: .reversal, category: .reversal,
                                 bytes: 0, files: 0, reverses: id, sentAt: nil))
        commit()
    }

    @discardableResult
    private func append(kind: StatsEvent.Kind, category: StatsEvent.Category, bytes: Int64, files: Int = 0,
                        items: Int? = nil) -> UUID? {
        guard bytes > 0 || files > 0 else { return nil }
        let event = StatsEvent(id: UUID(), date: Date(), kind: kind, category: category,
                               bytes: bytes, files: files, items: items.map { max(0, $0) }, reverses: nil, sentAt: nil)
        events.append(event)
        commit()
        return event.id
    }

    // MARK: - Reporting support

    /// Events community stats may still send, oldest first. Legacy totals are never reported.
    var unsentReportableEvents: [StatsEvent] {
        events.filter { $0.sentAt == nil && $0.kind != .legacy }
    }

    func markSent(_ ids: Set<UUID>, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        for index in events.indices where ids.contains(events[index].id) && events[index].sentAt == nil {
            events[index].sentAt = date
        }
        commit()
    }

    // MARK: - Totals

    private func recompute() {
        let reversed = Set(events.compactMap(\.reverses))
        var disk: Int64 = 0
        var memory: Int64 = 0
        var files = 0
        for event in events where !reversed.contains(event.id) {
            switch event.kind {
            case .disk, .compress, .legacy: disk += event.bytes
            case .memory: memory += event.bytes
            case .reversal: break
            }
            if event.kind == .compress { files += event.files }
        }
        lifetimeFreedBytes = disk
        lifetimeMemoryFreedBytes = memory
        lifetimeFilesCompressed = files
    }

    // MARK: - Persistence

    /// The old `lifetimeFreedBytes` UserDefaults value becomes one `legacy` event, once.
    private func migrateLegacyTotal(_ defaults: UserDefaults) {
        let key = "lifetimeFreedBytes"
        guard defaults.object(forKey: key) != nil else { return }
        let legacy = Int64(defaults.integer(forKey: key))
        if legacy > 0, !events.contains(where: { $0.kind == .legacy }) {
            events.insert(StatsEvent(id: UUID(), date: Date(), kind: .legacy, category: .legacy,
                                     bytes: legacy, files: 0, reverses: nil, sentAt: nil), at: 0)
            guard save() else { return } // keep the old value until the ledger has it on disk
        }
        defaults.removeObject(forKey: key)
    }

    private func commit() {
        recompute()
        save()
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(events: events)) else { return false }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func load(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }
}

extension StatsEvent.Category {
    /// The category for space freed from a main-window section.
    init(section: SidebarSection) {
        switch section {
        case .junk: self = .junk
        case .worktrees: self = .worktrees
        case .apps: self = .apps
        case .largeFiles: self = .largeFiles
        case .duplicates: self = .duplicates
        case .smartReview: self = .smartReview
        default: self = .other
        }
    }
}

// MARK: - Compress / Shrink wiring

extension StatsLedger {
    /// Records each Compress and Shrink run's measured savings, and reverses them if the run is undone
    /// on its screen. Undo from History reverses through the event id it keeps (ActivityLog); `reverse`
    /// is a no-op for an event already reversed, so neither path counts twice.
    /// Chains onto existing hooks (ActivityLog uses `onRunCompleted` too). Call once at launch.
    func connect(compress: CompressStore) {
        var lastCompressEvent: UUID?
        let previousRun = compress.onRunCompleted
        compress.onRunCompleted = { [weak self] run in
            previousRun?(run)
            lastCompressEvent = self?.recordRun(category: .compress, startedAt: run.startedAt,
                                                savedBytes: run.savedBytes, files: run.count(.compressed))
            if run.count(.compressed) > 0 { CommunityStatsReporter.shared.cleanupSucceeded() }
        }
        let previousUndo = compress.onUndoCompleted
        compress.onUndoCompleted = { [weak self] restored, notRestored in
            previousUndo?(restored, notRestored)
            if restored > 0, let id = lastCompressEvent { self?.reverse(id) }
            lastCompressEvent = nil
        }

        let shrink = compress.shrink
        var lastShrinkEvent: UUID?
        let previousShrinkRun = shrink.onRunCompleted
        shrink.onRunCompleted = { [weak self] run in
            previousShrinkRun?(run)
            let shrunk = run.items.filter { $0.status == .shrunk }.count
            lastShrinkEvent = self?.recordRun(category: .shrink, startedAt: run.startedAt,
                                              savedBytes: run.savedBytes, files: shrunk)
            if shrunk > 0 { CommunityStatsReporter.shared.cleanupSucceeded() }
        }
        let previousShrinkUndo = shrink.onUndoCompleted
        shrink.onUndoCompleted = { [weak self] restored, notRestored in
            previousShrinkUndo?(restored, notRestored)
            if restored > 0, let id = lastShrinkEvent { self?.reverse(id) }
            lastShrinkEvent = nil
        }
    }
}

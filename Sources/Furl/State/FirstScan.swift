import Foundation

/// FirstScan and FirstClean boards: what Furl remembers about full scans (how long the last one took,
/// whether the first one has finished) and whether the guided first clean was already offered.
@MainActor
final class FirstScanRecord: ObservableObject {
    static let shared = FirstScanRecord()

    private enum Keys {
        static let lastDuration = "lastFullScanSeconds"
        static let firstCleanOffered = "firstCleanOffered"
    }

    private let defaults: UserDefaults
    /// How long the last full scan that ran to the end took; nil until one has.
    @Published private(set) var lastDuration: TimeInterval?
    /// The guided first clean is offered at most once, ever.
    @Published private(set) var firstCleanOffered: Bool
    /// The first full scan just ended: the Overview offers the guided first clean (or decides not to)
    /// the next time it is on screen.
    @Published private(set) var firstCleanDue = false

    private var startedAt: Date?
    private var stopped = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastDuration = defaults.object(forKey: Keys.lastDuration) as? TimeInterval
        firstCleanOffered = defaults.bool(forKey: Keys.firstCleanOffered)
    }

    /// No full scan has run to the end yet: the Overview shows the first-scan promise and states.
    var isFirstScan: Bool { lastDuration == nil }

    func scanStarted(at date: Date = Date()) {
        guard startedAt == nil else { return }
        startedAt = date
        stopped = false
    }

    /// A stopped scan didn't end: it records no time and doesn't count as the first scan.
    func scanStopped() {
        if startedAt != nil { stopped = true }
    }

    func scanFinished(at date: Date = Date()) {
        guard let start = startedAt else { return }
        startedAt = nil
        guard !stopped else { return }
        let wasFirst = isFirstScan
        let duration = max(0, date.timeIntervalSince(start))
        lastDuration = duration
        defaults.set(duration, forKey: Keys.lastDuration)
        if wasFirst && !firstCleanOffered { firstCleanDue = true }
    }

    /// Called once the Overview has offered the guided first clean, or decided not to.
    func markFirstCleanOffered() {
        firstCleanDue = false
        guard !firstCleanOffered else { return }
        firstCleanOffered = true
        defaults.set(true, forKey: Keys.firstCleanOffered)
    }

    /// "A full scan takes about 2–5 minutes…" before the first scan; the last scan's time after that.
    var promise: String {
        guard let last = lastDuration else {
            return "A full scan takes about 2–5 minutes and only reads. You can use results as they arrive."
        }
        return "Your last scan took \(Self.durationText(last)) and only read. You can use results as they arrive."
    }

    nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1 ? "about a minute" : "about \(minutes) minutes"
    }
}

/// FirstClean board, "Which three" and "Not offered".
enum FirstCleanOffer {
    /// Below this the guide isn't worth an interruption.
    static let minimumBytes: Int64 = 500_000_000
    /// Each pick is worth showing on its own: a 12 KB .DS_Store isn't a first clean.
    static let minimumPickBytes: Int64 = 10_000_000

    struct Pick: Equatable, Sendable {
        let item: JunkItem
        let bytes: Int64

        var path: String { item.path }

        static func == (a: Pick, b: Pick) -> Bool { a.item.id == b.item.id && a.bytes == b.bytes }
    }

    /// The three biggest items the Overview's safe number counts (Safe, ticked, movable), each from
    /// a different folder, biggest first.
    static func picks(plan: AppState.SafeCleanupPlan, junk: [JunkItem], limit: Int = 3) -> [Pick] {
        let byPath = Dictionary(junk.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = plan.paths.compactMap { path -> Pick? in
            guard let item = byPath[path] else { return nil }
            return Pick(item: item, bytes: plan.itemBytes[path] ?? item.sizeBytes)
        }
        .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }

        var folders = Set<String>()
        var picks: [Pick] = []
        for pick in candidates where picks.count < limit && pick.bytes >= minimumPickBytes {
            let folder = URL(fileURLWithPath: pick.path).deletingLastPathComponent().path
            guard folders.insert(folder).inserted else { continue }
            picks.append(pick)
        }
        return picks
    }

    /// Not offered when nothing is Safe, when the picks add up to less than 500 MB, or when the user
    /// has already cleaned something (from a list, the menu bar or a Shortcut).
    static func shouldOffer(_ picks: [Pick], hasCleanedBefore: Bool) -> Bool {
        guard !picks.isEmpty, !hasCleanedBefore else { return false }
        return picks.reduce(Int64(0)) { $0 + $1.bytes } >= minimumBytes
    }

    /// The Why? line under each pick: the first line of that item's Why? popover, word for word.
    static func whyLine(_ item: JunkItem) -> String {
        let text = WhySafe.junk(item, deletionMode: .moveToTrash).lines.first?.text ?? item.reason
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

extension AppState {
    /// Any cleanup so far, from any screen, the menu bar, Auto-Sweep or a Shortcut.
    func hasCleanedBefore(store: AutoSweepStore) -> Bool {
        if !store.history.isEmpty || lifetimeFreedBytes > 0 { return true }
        return ActivityLog.shared.entries.contains { $0.kind != .processes }
    }
}

// MARK: - Guided first clean: move and verified undo

/// What the guided first clean moved: the History run, and how each item looked in the Trash right
/// after the move, so Undo can tell whether it is still there unchanged.
struct FirstCleanMove: Equatable {
    let run: AutoSweepRun
    /// Keyed by Trash path.
    let trashStamps: [String: CleanupStamp]

    static func == (a: Self, b: Self) -> Bool { a.run.id == b.run.id && a.trashStamps == b.trashStamps }
}

/// The result of the guided Undo, by original path.
struct FirstCleanUndo: Equatable {
    var back: Set<String> = []
    /// Not in the Trash any more, or changed there: left alone (FirstClean board: "Not found in the Trash").
    var notFound: Set<String> = []
    /// In the Trash but couldn't be put back (e.g. something new is at the original place).
    var failed: Set<String> = []
}

extension FirstCleanOffer {
    /// Before Undo: the item at `trashPath` is still the one Furl moved there (same inode), with the
    /// same kind, modification date and size it had right after the move.
    nonisolated static func isUnchangedInTrash(_ entry: TrashLedgerEntry, stamp: CleanupStamp?,
                                               isStillOurs: (TrashLedgerEntry) -> Bool = { $0.isStillOurs },
                                               matches: (CleanupStamp, String) -> Bool = { $0.matches($1) }) -> Bool {
        guard isStillOurs(entry), let stamp else { return false }
        return matches(stamp, entry.trashPath)
    }
}

extension AppState {
    /// Moves the picks through the Overview's normal safe clean (Trash, on-disk re-check, one History
    /// entry, one Undo) and remembers how they look in the Trash. Nil when nothing moved.
    func firstCleanMove(_ picks: [FirstCleanOffer.Pick], store: AutoSweepStore) async -> FirstCleanMove? {
        let before = lastSafeClean?.run.id
        await cleanSafeNow(store: store, confirmedPaths: picks.map(\.path))
        guard let run = lastSafeClean?.run, run.id != before, !run.trashed.isEmpty else { return nil }
        let paths = run.trashed.map(\.trashPath)
        let stamps = await Task.detached(priority: .userInitiated) {
            var stamps: [String: CleanupStamp] = [:]
            for path in paths { stamps[path] = CleanupStamp.read(path, includeSize: true) }
            return stamps
        }.value
        return FirstCleanMove(run: run, trashStamps: stamps)
    }

    /// The guided Undo: the same Undo as History and ⌥⌘Z, after checking each item is still in the
    /// Trash with the same size and date. Items that aren't are left alone; the rest go back.
    func undoFirstClean(_ move: FirstCleanMove, store: AutoSweepStore) async -> FirstCleanUndo {
        guard !isCleaning else { return FirstCleanUndo() }
        let current = store.history.first { $0.id == move.run.id } ?? move.run
        guard current.canUndo else { return FirstCleanUndo(notFound: Set(move.run.trashed.map(\.originalPath))) }
        isCleaning = true
        let stamps = move.trashStamps
        let entries = current.trashed
        let (outcome, notFound) = await Task.detached(priority: .userInitiated) {
            let verified = entries.filter { FirstCleanOffer.isUnchangedInTrash($0, stamp: stamps[$0.trashPath]) }
            let verifiedPaths = Set(verified.map(\.trashPath))
            let notFound = entries.filter { !verifiedPaths.contains($0.trashPath) }.map(\.originalPath)
            return (DeletionService.restore(verified.map(\.asTrashedItem)), notFound)
        }.value
        isCleaning = false

        let backTrash = Set(outcome.restoredItems.map(\.trashPath))
        let remaining = entries.filter { !backTrash.contains($0.trashPath) && $0.isStillOurs }
        store.markRestored(current.id, remaining: remaining)
        ActivityLog.shared.refreshRestorable()
        if remaining.isEmpty, lastSafeClean?.run.id == current.id { lastSafeClean = nil }

        var result = FirstCleanUndo()
        result.back = Set(outcome.restoredItems.map(\.originalPath))
        result.notFound = Set(notFound)
        result.failed = Set(entries.map(\.originalPath)).subtracting(result.back).subtracting(result.notFound)
        if !result.failed.isEmpty, !outcome.errors.isEmpty {
            errorBanner = outcome.errors.joined(separator: "\n")
        }
        refreshDiskInfo()
        // The restored items are listed again (and can be moved again) after a fresh look.
        if hasScannedJunk { Task { await self.scanJunk() } }
        return result
    }
}

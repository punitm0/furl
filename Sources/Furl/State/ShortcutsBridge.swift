import Foundation

/// The one place the Shortcuts actions (`Intents/FurlAppIntents.swift`) touch the app. They use the
/// Overview's "Safe now" plan (`AppState.safeCleanupPlan`, GetSpaceBack board: "the same number
/// everywhere") and clean through the same `AppState.cleanSafeItems`, so the rules stay in one place:
/// only caches and junk rated Safe and still ticked, never worktrees, Docker or Simulator items (they
/// can't go to the Trash), nothing protected; Trash only, every item re-checked right before it moves,
/// one History entry that Undo puts back.
@MainActor
enum ShortcutsBridge {

    /// One "Safe now" item as Shortcuts sees it.
    struct SafeItem: Equatable, Sendable {
        var path: String
        var bytes: Int64
    }

    struct SafeNow: Equatable, Sendable {
        var items: [SafeItem] = []
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
        var isEmpty: Bool { items.isEmpty }
    }

    enum CleanOutcome: Sendable {
        /// At least one item went to the Trash: the History run Undo restores.
        case cleaned(AutoSweepRun)
        /// Every item had changed since the scan, so nothing moved.
        case nothingMoved
        /// Nothing moved because every move failed.
        case failed
        /// Another cleanup is running.
        case busy
    }

    private static var state: AppState { AppServices.state }

    /// Scans if Furl hasn't yet, rescans results older than the usual 10 minutes, then returns the
    /// "Safe now" items. Never changes anything on disk.
    static func safeItems() async -> SafeNow {
        await state.prepareSafeCleanup()
        await state.refreshSafeCleanupScans(maxAge: AppState.safeCleanupMaxResultAge)
        return safeNow(from: state.safeCleanupPlan)
    }

    /// The plan's items in the plan's order, with its per-item sizes: the total is `plan.bytes`.
    nonisolated static func safeNow(from plan: AppState.SafeCleanupPlan) -> SafeNow {
        SafeNow(items: plan.paths.map { SafeItem(path: $0, bytes: plan.itemBytes[$0] ?? 0) })
    }

    /// "Free up to…" (board: "Stops once the target is reached"). Every "Safe now" item is the same
    /// risk (junk rated Safe; worktrees and permanent items are never in the plan), so there is one
    /// group. It fills the target biggest first, taking only items no bigger than what's still needed,
    /// then finishes with the smallest single item that covers the rest. So a 1 GB target with a
    /// 50 GB cache and 600 MB and 500 MB logs moves the two logs (1.1 GB), not the 50 GB cache. If one
    /// item alone covers the target with less than that, it's used alone. If all the safe items
    /// together are less than the target, it takes them all.
    nonisolated static func pick(_ items: [SafeItem], toFree target: Int64) -> [SafeItem] {
        guard target > 0 else { return [] }
        let ordered = items.enumerated()
            .filter { $0.element.bytes > 0 }
            .sorted { a, b in
                a.element.bytes != b.element.bytes ? a.element.bytes > b.element.bytes : a.offset < b.offset
            }
            .map(\.element)
        var picked: [SafeItem] = []
        var left: [SafeItem] = []
        var remaining = target
        for item in ordered {
            if remaining > 0 && item.bytes <= remaining {
                picked.append(item)
                remaining -= item.bytes
            } else {
                left.append(item)
            }
        }
        // Everything not taken is bigger than what's left, so the smallest of them covers it.
        if remaining > 0, let finisher = left.min(by: { $0.bytes < $1.bytes }) {
            picked.append(finisher)
        }
        // One item that covers the target on its own wins if it moves less than the fill above.
        let total = picked.reduce(Int64(0)) { $0 + $1.bytes }
        if let single = ordered.filter({ $0.bytes >= target }).min(by: { $0.bytes < $1.bytes }), single.bytes < total {
            return [single]
        }
        return picked
    }

    /// Moves exactly `items` (what the confirm described) to the Trash through the Overview's path.
    static func clean(_ items: [SafeItem]) async -> CleanOutcome {
        guard !state.isCleaning else { return .busy }
        let run = await state.cleanSafeItems(store: AppServices.autoSweep, trigger: .shortcuts,
                                             confirmedPaths: items.map(\.path))
        guard let run else { return state.isCleaning ? .busy : .nothingMoved }
        // `cleanSafeItems` records a run when moves failed too; with nothing in the Trash there is
        // nothing to report as moved and nothing to undo.
        return run.trashed.isEmpty ? .failed : .cleaned(run)
    }

    // MARK: - Stop leftover servers / Tidy project (WorktreesShortcuts board)

    /// Leftovers the Shortcuts action may stop, after a fresh look at the process list. Stops nothing.
    static func stoppableLeftovers() async -> [LeftoverProcess] {
        LeftoverServers.eligible(await ProcessesStore.shared.freshLeftovers())
    }

    static func stopLeftovers(ids: Set<String>) async -> (stopped: Int, stuck: Int, bytes: UInt64) {
        await ProcessesStore.shared.stopConfirmedLeftovers(ids: ids)
    }

    struct TidyPlan: Sendable {
        var project: String
        var folders: [ProjectTidy.Folder]
        /// Read before the confirm, so anything that changes while it's up is left alone.
        var stamps: [String: CleanupStamp]
        var bytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    }

    /// Finds the folders off the main thread. Changes nothing.
    static func tidyPlan(root: String) async -> TidyPlan {
        await Task.detached(priority: .userInitiated) {
            let folders = ProjectTidy.find(in: root)
            return TidyPlan(project: URL(fileURLWithPath: root).lastPathComponent, folders: folders,
                            stamps: CleanupStamp.read(folders.map(\.path)))
        }.value
    }

    static func tidy(_ plan: TidyPlan) async -> AppState.TidyOutcome {
        await state.tidyProject(plan.folders, stamps: plan.stamps, project: plan.project, store: AppServices.autoSweep)
    }

    /// How full the startup disk is right now, for the result notification.
    static var percentFull: Int {
        Int((state.diskUsage.usedFraction * 100).rounded())
    }

    // MARK: - Copy (GetSpaceBack board, "Shortcuts / App Intents")

    nonisolated static func confirmTitle(bytes: Int64) -> String {
        "Move \(FileSizeHelper.formatBytes(bytes)) to the Trash?"
    }

    /// Same wording as the Overview's and the low-disk alert's confirm.
    nonisolated static let confirmBody = "Furl’s “Safe now” items: caches, logs and junk rated Safe. You can undo this in Furl."

    nonisolated static let nothingToDoText = "Nothing safe to remove right now. Your Mac is tidy."

    static func resultText(bytes: Int64, percentFull: Int, skipped: Int) -> String {
        AppState.withSkipped("Moved \(FileSizeHelper.formatBytes(bytes)) to the Trash. Now \(percentFull)% full.", skipped)
    }
}

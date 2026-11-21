import Foundation

/// "Tidy project" from Shortcuts (WorktreesShortcuts board). Trash only, every folder re-checked
/// against the stamp taken before the confirm, one History entry that Undo puts back.
extension AppState {

    enum TidyOutcome: Sendable {
        case cleaned(AutoSweepRun, skipped: Int)
        /// Every folder had changed since it was listed, so nothing moved.
        case nothingMoved
        /// Nothing moved because every move failed.
        case failed
        /// Another cleanup is running.
        case busy
    }

    func tidyProject(_ folders: [ProjectTidy.Folder], stamps: [String: CleanupStamp], project: String,
                     store: AutoSweepStore) async -> TidyOutcome {
        guard !isCleaning else { return .busy }
        isCleaning = true
        defer { isCleaning = false }

        // A folder with no stamp was gone (or unreadable) before the confirm: never move it.
        let targets = folders.filter { stamps[$0.path] != nil }
        let result = await Self.moveToTrash(targets.map(\.path), expected: stamps)
        let trashed = Set(result.trashedItems.map(\.originalPath))
        let moved = targets.filter { trashed.contains($0.path) }
        let skipped = folders.count - targets.count + result.skippedPaths.count
        noteSkippedSinceScan(skipped, in: "Tidy project")

        junkItems.removeAll { $0.command == nil && !Self.pathExists($0.path) }
        selectedJunkIDs.formIntersection(Set(junkItems.map(\.id)))
        refreshDiskInfo()

        if !result.errors.isEmpty { errorBanner = result.errors.joined(separator: "\n") }
        guard !moved.isEmpty else { return result.errors.isEmpty ? .nothingMoved : .failed }

        let run = AutoSweepRun(
            date: Date(),
            trigger: .shortcuts,
            parts: [AutoSweepRunPart(rule: .caches, itemCount: moved.count, bytes: result.reclaimedBytes,
                                     detail: "Tidy project: \(moved.count) rebuildable folder(s) in \(project)")],
            trashed: Self.ledgerEntries(result),
            errors: result.errors,
            skippedCount: skipped > 0 ? skipped : nil
        )
        store.record(run, countsAsAutoSweep: false)
        return .cleaned(run, skipped: skipped)
    }
}

import Foundation

/// The Overview's Trash line (TrashEmpty board): how much of what Furl moved to the Trash is still
/// there, rechecked when the Overview appears. Only Furl's own items are ever looked at.
@MainActor
final class FurlTrashStore: ObservableObject {
    static let shared = FurlTrashStore()

    /// Furl's items that still look like Furl left them (quick check: place, inode, kind, date).
    @Published private(set) var items: [TrashLedgerEntry] = []
    /// True while the confirm's full check (sizes) runs.
    @Published private(set) var isPreparing = false

    var bytes: Int64 { items.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) } }

    private var generation = 0

    func refresh(ledger: [TrashLedgerEntry]) async {
        generation += 1
        let mine = generation
        let found = await Task.detached(priority: .utility) {
            ledger.filter { FurlTrash.check($0, deep: false) == .matches }
        }.value
        // A newer refresh (or an empty) may have finished meanwhile.
        guard mine == generation else { return }
        items = found
    }

    /// The full check behind the confirm: everything the line counted plus anything recorded since.
    func prepareEmpty(ledger: [TrashLedgerEntry]) async -> FurlTrashPlan {
        isPreparing = true
        defer { isPreparing = false }
        let candidates = items + ledger
        return await Task.detached(priority: .userInitiated) {
            FurlTrashPlan.make(candidates)
        }.value
    }

    fileprivate func clear(_ removed: Set<String>) {
        generation += 1
        items.removeAll { removed.contains($0.trashPath) }
    }
}

extension AppState {
    /// Deletes, for good, the items the confirm showed. Each is checked again right before it goes;
    /// anything that no longer matches exactly is skipped. One History entry, marked Permanent, no Undo.
    func emptyFurlTrash(_ plan: FurlTrashPlan, store: AutoSweepStore, trash: FurlTrashStore = .shared) async {
        guard !isCleaning, !plan.matched.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        let entries = plan.matched
        let outcome = await Task.detached(priority: .userInitiated) {
            FurlTrash.empty(entries)
        }.value

        // Deleted ones are gone; ones that changed or went away aren't Furl's to claim any more.
        // Ones that couldn't be confirmed stay recorded and are never deleted.
        var forget = Set(outcome.deleted.map(\.trashPath))
        for skipped in outcome.skipped where skipped.check == .gone || skipped.check == .changed {
            forget.insert(skipped.entry.trashPath)
        }
        store.removeFromLedger(forget)
        trash.clear(forget)

        let count = outcome.deleted.count
        let skippedCount = plan.notMatchedCount + outcome.skipped.count
        recordFreed(outcome.bytes, items: count, category: .trash)
        refreshDiskInfo()
        if count > 0 {
            ActivityLog.shared.recordEmptyFurlTrash(bytes: outcome.bytes, count: count, skipped: skippedCount)
            // What Furl put in the Trash is gone for good now: no Undo on the banner.
            lastUndo = nil
            lastSafeClean = nil
            let disk = diskUsage
            let percent = SafeCleanSummary.percent(disk.usedBytes, of: disk.totalBytes)
            statusBanner = "Deleted \(FileSizeHelper.formatBytes(outcome.bytes)) for good. Now \(percent)% full."
        } else {
            statusBanner = "Nothing was deleted. Furl’s items changed or are no longer in the Trash."
        }
        if !outcome.errors.isEmpty {
            errorBanner = outcome.errors.joined(separator: "\n")
        }
        await trash.refresh(ledger: store.ledger)
    }
}

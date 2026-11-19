import Foundation

/// What the live strip under a screen header shows while results are still arriving (canvas:
/// "Results still arriving"). One per scan-based section, in `AppState.liveScans` / `CompressStore.live`.
struct LiveScanStatus: Equatable {
    enum Phase: Equatable { case running, finished, stopped }

    var phase: Phase = .running
    /// Results on screen so far (items, groups, apps…), counted with `noun`.
    var foundCount = 0
    var foundBytes: Int64 = 0
    /// 0...1 when the total is known; nil shows the indeterminate sweep.
    var fraction: Double?
    /// e.g. "Looking through your home folder · 182,400 files checked".
    var detail = ""
    /// The folder being looked at, shown truncated.
    var current = ""
    var noun = ScanNoun.items
    var changedAt = Date()

    var countText: String {
        "\(foundCount.formatted()) \(foundCount == 1 ? noun.singular : noun.plural)"
    }
}

struct ScanNoun: Equatable {
    let singular: String
    let plural: String
    static let items = ScanNoun(singular: "item", plural: "items")
    static let files = ScanNoun(singular: "file", plural: "files")
    static let groups = ScanNoun(singular: "group", plural: "groups")
    static let worktrees = ScanNoun(singular: "worktree", plural: "worktrees")
    static let apps = ScanNoun(singular: "app", plural: "apps")
    static let folders = ScanNoun(singular: "folder", plural: "folders")
    static let candidates = ScanNoun(singular: "candidate", plural: "candidates")
}

/// The shared streaming loop: every `interval` it hands whatever the background scanner queued in
/// `batcher` to `merge` (on the main actor, so a list is updated at most ~2× a second instead of per
/// item), then refreshes the live status from `progress` and `totals`.
@MainActor
final class ScanStream<Payload> {
    let batcher = ScanBatcher<Payload>()
    let progress: ScanProgress
    private var loop: Task<Void, Never>?
    private let merge: @MainActor ([Payload]) -> Void
    private let publish: @MainActor (LiveScanStatus) -> Void
    private let totals: @MainActor () -> (count: Int, bytes: Int64)
    private var status: LiveScanStatus

    static var interval: Duration { .milliseconds(450) }

    init(progress: ScanProgress = ScanProgress(), noun: ScanNoun,
         totals: @escaping @MainActor () -> (count: Int, bytes: Int64),
         publish: @escaping @MainActor (LiveScanStatus) -> Void,
         merge: @escaping @MainActor ([Payload]) -> Void) {
        self.progress = progress
        self.merge = merge
        self.publish = publish
        self.totals = totals
        self.status = LiveScanStatus(noun: noun)
        publish(status)
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Merges anything still queued and refreshes the status now.
    func flush() { tick() }

    private func tick() {
        let batch = batcher.drain()
        if !batch.isEmpty { merge(batch) }
        let (count, bytes) = totals()
        var next = status
        next.foundCount = count
        next.foundBytes = bytes
        next.fraction = progress.fraction
        next.current = progress.current
        let phase = progress.phase
        let walked = progress.items
        next.detail = phase.isEmpty ? "" : (walked > 0 && progress.fraction == nil
            ? "\(phase) · \(walked.formatted()) files checked" : phase)
        if next != status {
            status = next
            publish(next)
        }
    }

    /// The finished line (or the stopped line when the user stopped the scan). A finished scan's caller
    /// has already put the complete result on screen, so batches still queued are dropped; a stopped
    /// scan merges them, since what was found is all there is. Returns the status published.
    @discardableResult
    func finish(stopped: Bool) -> LiveScanStatus {
        loop?.cancel()
        loop = nil
        if !stopped { _ = batcher.drain() }
        tick()
        status.phase = stopped ? .stopped : .finished
        status.fraction = stopped ? status.fraction : 1
        status.changedAt = Date()
        publish(status)
        return status
    }
}

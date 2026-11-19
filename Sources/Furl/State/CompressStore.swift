import Foundation
import SwiftUI

/// State for the Compress screen. Scans run off the main thread; everything published here is main-actor only.
@MainActor
final class CompressStore: ObservableObject {
    // MARK: Options

    @Published var options = CompressOptions() {
        didSet {
            if oldValue.minDaysUnused != options.minDaysUnused, scanResult != nil { folderScanIsStale = true }
            recomputeSummaries()
        }
    }

    // MARK: Scan state

    @Published private(set) var scanResult: CompressScanResult?
    @Published private(set) var summaries: [CompressCategorySummary] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFileCount = 0
    /// The age filter changed since the scan; folder candidates depend on it, so a re-scan is needed before running.
    @Published private(set) var folderScanIsStale = false
    /// The live strip under the header while results are still arriving (and briefly after).
    @Published private(set) var live: LiveScanStatus?

    // MARK: Run state

    @Published private(set) var isRunning = false
    @Published private(set) var phase = ""
    @Published private(set) var processedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var savedSoFar: Int64 = 0
    @Published private(set) var lastRun: CompressRunResult?
    @Published private(set) var lastUndoSummary: String?

    /// Called on the main actor after a run finishes, so the app can register an undo entry
    /// (use `undoLastRun()` to reverse it, not `DeletionService.restore`).
    var onRunCompleted: ((CompressRunResult) -> Void)?
    /// Called after `undoLastRun()` with how many originals came back (StatsLedger reverses the run's savings).
    var onUndoCompleted: ((_ restored: Int, _ notRestored: [CompressUndoRecord]) -> Void)?

    private var progress: CompressProgress?

    /// Opt-in lossy Shrink mode (see ShrinkStore). Kept separate so lossless results are never mixed with lossy ones.
    let shrink = ShrinkStore()

    init() {}

    // MARK: Derived values

    var hasScanned: Bool { scanResult != nil }
    var isBusy: Bool { isScanning || isRunning }
    var tools: CompressTools { scanResult?.tools ?? .none }
    var skipped: [CompressSkipGroup] { scanResult?.skipped ?? [] }

    /// Files the last scan skipped, or packed less tightly, because a tool is missing (Recommended tools card).
    var toolFinds: [OptionalTool: ToolFind] {
        scanResult.map { CompressionService.toolFinds($0, options: options) } ?? [:]
    }

    /// Tools worth recommending from the last scan, minus the ones the user waved off with "Not now".
    func recommendedTools(dismissed: Set<OptionalTool>) -> [OptionalTool] {
        OptionalTool.lossless.filter { toolFinds[$0] != nil && !dismissed.contains($0) }
    }
    var progressFraction: Double { totalCount == 0 ? 0 : Double(processedCount) / Double(totalCount) }

    /// Sample-based estimate of what a run with the current options would save.
    var estimatedSavingsBytes: Int64 {
        summaries.filter { options.enabledCategories.contains($0.category) && $0.available && !isEstimatePending($0.category) }
            .reduce(0) { $0 + $1.estimatedSavings }
    }

    var eligibleCandidates: [CompressCandidate] {
        guard let scanResult else { return [] }
        let available = Set(summaries.filter(\.available).map(\.category))
        return CompressionService.eligibleCandidates(scanResult, options: options).filter { available.contains($0.category) }
    }

    var eligibleFileCount: Int { eligibleCandidates.filter { $0.category != .folders }.count }
    var eligibleFolderCount: Int { eligibleCandidates.filter { $0.category == .folders }.count }

    func summary(for category: CompressCategory) -> CompressCategorySummary? {
        summaries.first { $0.category == category }
    }

    func isEnabled(_ category: CompressCategory) -> Bool { options.enabledCategories.contains(category) }

    func setCategory(_ category: CompressCategory, enabled: Bool) {
        if enabled { options.enabledCategories.insert(category) } else { options.enabledCategories.remove(category) }
    }

    func candidates(for category: CompressCategory) -> [CompressCandidate] {
        eligibleCandidates.filter { $0.category == category }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Actions

    func scan() async {
        guard !isBusy else { return }
        isScanning = true
        scannedFileCount = 0
        phase = "Starting…"
        scanResult = nil
        recomputeSummaries()
        let progress = CompressProgress()
        self.progress = progress
        // Results still arriving: candidates show as they're found, each category's saving once its
        // sample is measured (canvas "Results still arriving").
        let stream = ScanStream<CompressScanResult>(
            noun: .candidates,
            totals: { [unowned self] in
                let found = scanResult?.candidates ?? []
                return (found.count, found.reduce(0) { $0 + $1.sizeBytes })
            },
            publish: { [weak self] in self?.live = $0 }
        ) { [weak self] partials in
            guard let self, let latest = partials.last else { return }
            scanResult = latest
            recomputeSummaries()
        }
        let live = stream.progress
        let poller = poll(progress) { [weak self] p in
            guard let self else { return }
            phase = p.phase
            scannedFileCount = p.done
            if p.done > live.items { live.addItems(p.done - live.items) }
            let sampling = p.phase.hasPrefix("Measuring") || p.phase.hasPrefix("Trying")
            live.setPhase(sampling ? "Measuring savings on a sample" : "Looking through your home folder")
            if sampling, let found = scanResult {
                live.setSteps(done: found.sampleRatios.count, total: max(1, Self.sampledCategoryCount(found)))
            }
        }
        let options = self.options
        let batcher = stream.batcher
        let result = await Task.detached(priority: .userInitiated) {
            CompressionService.scan(options: options, progress: progress) { batcher.append($0) }
        }.value
        poller.cancel()
        let stopped = progress.isCancelled
        if !stopped {
            scanResult = result
            folderScanIsStale = false
            recomputeSummaries()
        } else {
            live.cancel()
            // What was found stays on screen, but a run first scans again for the full list and estimates.
            if scanResult != nil { folderScanIsStale = true }
        }
        let final = stream.finish(stopped: stopped)
        isScanning = false
        phase = ""
        self.progress = nil
        if !stopped {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.live?.changedAt == final.changedAt { self?.live = nil }
            }
        }
    }

    /// Categories whose saving is measured on a sample (folders always; others when they have a small enough file).
    private static func sampledCategoryCount(_ scan: CompressScanResult) -> Int {
        1 + Set(scan.candidates.filter { $0.category != .folders && $0.sizeBytes <= 30 * 1024 * 1024 }.map(\.category)).count
    }

    /// True while a category's saving hasn't been measured yet (scan still running, or stopped early).
    func isEstimatePending(_ category: CompressCategory) -> Bool {
        guard isScanning || live?.phase == .stopped, let scanResult else { return false }
        return scanResult.sampleRatios[category] == nil
    }

    func run() async {
        guard !isBusy, !shrink.isBusy else { return }
        if folderScanIsStale || scanResult == nil {
            await scan()
            // Stopped: what's on screen is partial (no folders measured yet), so don't compress it.
            guard live?.phase != .stopped else { return }
        }
        guard let scanResult else { return }
        let candidates = eligibleCandidates
        guard !candidates.isEmpty else { return }

        isRunning = true
        lastUndoSummary = nil
        processedCount = 0
        totalCount = candidates.count
        savedSoFar = 0
        let progress = CompressProgress()
        self.progress = progress
        let poller = poll(progress) { [weak self] p in
            self?.phase = p.phase
            self?.processedCount = p.done
            self?.totalCount = max(p.total, 1)
            self?.savedSoFar = p.saved
        }
        let options = self.options
        let tools = scanResult.tools
        let result = await Task.detached(priority: .userInitiated) {
            CompressionService.run(candidates: candidates, tools: tools, options: options, progress: progress)
        }.value
        poller.cancel()

        lastRun = result
        isRunning = false
        phase = ""
        self.progress = nil
        // Drop what changed from the scan so the estimate reflects what's left.
        let touched = Set(result.items.filter { $0.status == .compressed || $0.status == .notSmaller }.map(\.path))
        self.scanResult?.candidates.removeAll { touched.contains($0.path) }
        recomputeSummaries()
        onRunCompleted?(result)
    }

    func cancel() {
        progress?.cancel()
        phase = "Stopping after the current item…"
    }

    /// Restores the originals of the last run from the Trash and moves the compressed copies to the Trash.
    @discardableResult
    func undoLastRun() async -> (restored: Int, errors: [String]) {
        guard let run = lastRun, !isBusy else { return (0, []) }
        let records = run.undoRecords
        let each = await Task.detached(priority: .userInitiated) { CompressionService.undoEach(records) }.value
        let outcome = (restored: each.filter { $0.error == nil }.count, errors: each.compactMap(\.error))
        lastRun = nil
        onUndoCompleted?(outcome.restored, each.filter { $0.error != nil }.map(\.record))
        lastUndoSummary = outcome.errors.isEmpty
            ? "Restored \(outcome.restored) original\(outcome.restored == 1 ? "" : "s")."
            : "Restored \(outcome.restored); \(outcome.errors.count) couldn't be restored."
        return outcome
    }

    func dismissResults() {
        lastRun = nil
        lastUndoSummary = nil
    }

    // MARK: Helpers

    private func recomputeSummaries() {
        guard let scanResult else { summaries = []; return }
        summaries = CompressionService.summaries(scanResult, options: options)
    }

    private func poll(_ progress: CompressProgress, update: @escaping @MainActor (CompressProgress) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                update(progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}

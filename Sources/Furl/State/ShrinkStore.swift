import Foundation
import SwiftUI

/// State for the lossy Shrink panel inside Compress. Owned by `CompressStore.shrink`.
@MainActor
final class ShrinkStore: ObservableObject {
    @Published var options = ShrinkOptions() {
        didSet {
            if oldValue.encodeSignature != options.encodeSignature || oldValue.kinds != options.kinds {
                estimateIsStale = scanResult != nil
            }
        }
    }

    /// Folders to look in. Defaults to the home folder (minus ~/Library); "Choose Folder…" narrows it.
    /// Dev check from the built bundle, like `-FurlTestNotification`:
    /// `open Furl.app --args -SweepMacShrinkRoot /path/to/samples`.
    @Published var roots: [String] = UserDefaults.standard.string(forKey: "SweepMacShrinkRoot").map { [$0] }
        ?? ShrinkService.defaultRoots()

    @Published private(set) var scanResult: ShrinkScanResult?
    @Published private(set) var ratios: [ShrinkKind: Double] = [:]
    @Published private(set) var estimateIsStale = false
    @Published private(set) var isScanning = false
    /// The live strip while results are still arriving (and briefly after).
    @Published private(set) var live: LiveScanStatus?
    @Published private(set) var isEstimating = false
    @Published private(set) var isRunning = false
    @Published private(set) var phase = ""
    @Published private(set) var processedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var savedSoFar: Int64 = 0

    @Published private(set) var preview: ShrinkPreview?
    @Published private(set) var isPreviewing = false
    @Published var previewTarget: ShrinkCandidate?

    @Published private(set) var lastRun: ShrinkRunResult?
    @Published private(set) var lastUndoSummary: String?

    /// Called after a run, like `CompressStore.onRunCompleted`. Undo with `undoLastRun()`.
    var onRunCompleted: ((ShrinkRunResult) -> Void)?
    /// Called after `undoLastRun()` with how many originals came back (StatsLedger reverses the run's savings).
    var onUndoCompleted: ((_ restored: Int, _ notRestored: [CompressUndoRecord]) -> Void)?

    private var progress: CompressProgress?

    /// The "Format suggestions" tab. Shares this store's folders, allowed folders and recent-file rule.
    let formats = FormatStore()

    var hasScanned: Bool { scanResult != nil }
    var isBusy: Bool { isScanning || isRunning || isEstimating || formats.isBusy }
    var progressFraction: Double { totalCount == 0 ? 0 : Double(processedCount) / Double(totalCount) }

    var eligible: [ShrinkCandidate] {
        guard let scanResult else { return [] }
        return ShrinkService.eligible(scanResult, options: options)
    }

    func eligible(_ kind: ShrinkKind) -> [ShrinkCandidate] {
        eligible.filter { $0.kind == kind }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var skipGroups: [ShrinkSkipGroup] {
        guard let scanResult else { return [] }
        return ShrinkService.skipGroups(scanResult, options: options)
    }

    /// What the last scan found that a missing Shrink tool would handle (shown on its tool card).
    func toolFind(_ tool: OptionalTool) -> ToolFind? {
        guard let scanResult else { return nil }
        let matches: [ShrinkCandidate]
        let noun: String
        switch tool {
        case .pngquant:
            guard options.tools.pngquant == nil else { return nil }
            matches = scanResult.candidates.filter { $0.kind == .png }
            noun = "PNG"
        case .mozjpeg:
            guard options.tools.mozjpeg == nil, options.imageFormat == .keep else { return nil }
            matches = scanResult.candidates.filter {
                $0.kind == .photos && ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
            }
            noun = "JPEG"
        default:
            return nil
        }
        guard !matches.isEmpty else { return nil }
        return ToolFind(count: matches.count, bytes: matches.reduce(0) { $0 + $1.sizeBytes }, noun: noun)
    }

    /// Re-checks which Shrink tools are installed (after an install, or when the app comes back to the front).
    func refreshTools() {
        let tools = ShrinkTools.detect()
        if options.tools != tools { options.tools = tools }
    }

    func bytes(_ kind: ShrinkKind) -> Int64 { eligible(kind).reduce(0) { $0 + $1.sizeBytes } }

    func estimatedSavings(_ kind: ShrinkKind) -> Int64 {
        guard let ratio = ratios[kind] else { return 0 }
        return Int64(Double(bytes(kind)) * max(0, 1 - ratio))
    }

    var estimatedSavingsBytes: Int64 {
        ShrinkKind.allCases.filter { options.kinds.contains($0) }.reduce(0) { $0 + estimatedSavings($1) }
    }

    var rootsLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return roots.map { $0 == home ? "your home folder" : ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
    }

    // MARK: Actions

    func setKind(_ kind: ShrinkKind, enabled: Bool) {
        if enabled { options.kinds.insert(kind) } else { options.kinds.remove(kind) }
    }

    func allow(folder: String) {
        options.allowedFolders.insert(folder)
    }

    func disallow(folder: String) {
        options.allowedFolders.remove(folder)
    }

    func scan() async {
        guard !isBusy else { return }
        isScanning = true
        phase = "Starting…"
        processedCount = 0
        scanResult = nil
        preview = nil
        previewTarget = nil
        let progress = CompressProgress()
        self.progress = progress
        // Results still arriving: files show as they're found; the estimate is measured once the walk ends.
        let stream = ScanStream<ShrinkScanResult>(
            noun: .files,
            totals: { [unowned self] in
                let found = scanResult?.candidates ?? []
                return (found.count, found.reduce(0) { $0 + $1.sizeBytes })
            },
            publish: { [weak self] in self?.live = $0 }
        ) { [weak self] partials in
            guard let self, let latest = partials.last else { return }
            scanResult = latest
        }
        let live = stream.progress
        let poller = poll(progress) { [weak self] p in
            self?.phase = p.phase
            self?.processedCount = p.done
            live.setPhase(p.phase)
        }
        let roots = self.roots
        let batcher = stream.batcher
        let (result, tools) = await Task.detached(priority: .userInitiated) {
            (ShrinkService.scan(roots: roots, progress: progress) { batcher.append($0) }, ShrinkTools.detect())
        }.value
        poller.cancel()
        if options.tools != tools { options.tools = tools }
        let stopped = progress.isCancelled
        if stopped { live.cancel() } else { scanResult = result }
        let final = stream.finish(stopped: stopped)
        isScanning = false
        self.progress = nil
        guard !stopped else {
            phase = ""
            // A stopped scan's list is partial and unchecked for open files: Shrink scans again first.
            if scanResult != nil { estimateIsStale = true }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.live?.changedAt == final.changedAt { self?.live = nil }
        }
        await estimate()
    }

    /// Re-measures savings on a small sample with the current settings.
    func estimate() async {
        guard let scanResult, !isRunning, !isEstimating else { return }
        isEstimating = true
        let progress = CompressProgress()
        self.progress = progress
        let poller = poll(progress) { [weak self] p in self?.phase = p.phase }
        let options = self.options
        let pool = ShrinkService.eligible(scanResult, options: options)
        let ratios = await Task.detached(priority: .userInitiated) {
            await ShrinkService.sampleRatios(pool, options: options, progress: progress)
        }.value
        poller.cancel()
        if !progress.isCancelled {
            self.ratios = ratios
            estimateIsStale = false
        }
        isEstimating = false
        phase = ""
        self.progress = nil
    }

    /// Picks a sensible item to preview: the current target if still eligible, else the largest photo, else anything.
    func defaultPreviewTarget() -> ShrinkCandidate? {
        let all = eligible
        if let target = previewTarget, all.contains(target) { return target }
        return eligible(.photos).first ?? eligible(.videos).first ?? eligible(.pdfs).first
    }

    func loadPreview(for candidate: ShrinkCandidate? = nil) async {
        guard let target = candidate ?? defaultPreviewTarget() else { preview = nil; return }
        previewTarget = target
        if let preview, preview.candidate == target, preview.signature == options.encodeSignature { return }
        isPreviewing = true
        let options = self.options
        let result = await Task.detached(priority: .userInitiated) { await ShrinkService.preview(target, options: options) }.value
        // Ignore a result for an item or setting the user has since moved away from.
        if previewTarget == target, result.signature == self.options.encodeSignature {
            preview = result
        }
        isPreviewing = false
    }

    func run() async {
        // A stopped scan's list is partial and wasn't checked for open files.
        guard !isBusy, options.enabled, live?.phase != .stopped else { return }
        let candidates = eligible
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
        let result = await Task.detached(priority: .userInitiated) {
            await ShrinkService.run(candidates, options: options, progress: progress)
        }.value
        poller.cancel()
        lastRun = result
        isRunning = false
        phase = ""
        self.progress = nil
        let touched = Set(result.items.filter { $0.status == .shrunk || $0.status == .keptOriginal }.map(\.path))
        scanResult?.candidates.removeAll { touched.contains($0.path) }
        preview = nil
        onRunCompleted?(result)
    }

    func cancel() {
        progress?.cancel()
        phase = "Stopping after the current item…"
    }

    /// Same undo as lossless Compress: the shrunk copy goes to the Trash and the original comes back.
    @discardableResult
    func undoLastRun() async -> (restored: Int, errors: [String]) {
        guard let run = lastRun, !isBusy else { return (0, []) }
        let records = run.undoRecords
        let each = await Task.detached(priority: .userInitiated) { CompressionService.undoEach(records) }.value
        let outcome = (restored: each.filter { $0.error == nil }.count, errors: each.compactMap(\.error))
        lastRun = nil
        onUndoCompleted?(outcome.restored, each.filter { $0.error != nil }.map(\.record))
        lastUndoSummary = outcome.errors.isEmpty
            ? "Restored \(outcome.restored) original\(outcome.restored == 1 ? "" : "s") at full quality."
            : "Restored \(outcome.restored); \(outcome.errors.count) couldn't be restored."
        return outcome
    }

    func dismissResults() {
        lastRun = nil
        lastUndoSummary = nil
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

import Foundation
import SwiftUI

/// State for the "Format suggestions" tab inside Shrink. Owned by `ShrinkStore.formats`.
/// Lists files that would be much smaller in another format; converts only what the user picks.
@MainActor
final class FormatStore: ObservableObject {
    @Published private(set) var scanResult: FormatScanResult?
    @Published var selected: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var phase = ""
    @Published private(set) var processedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var lastRun: FormatRunResult?
    @Published private(set) var lastUndoSummary: String?

    /// Called after a run, like `CompressStore.onRunCompleted` (History records it). Undo with `undoLastRun()`.
    var onRunCompleted: ((FormatRunResult) -> Void)?
    /// Called after `undoLastRun()` with how many originals came back.
    var onUndoCompleted: ((_ restored: Int, _ notRestored: [CompressUndoRecord]) -> Void)?

    private var progress: CompressProgress?

    var isBusy: Bool { isScanning || isRunning }
    var suggestions: [FormatSuggestion] { scanResult?.suggestions ?? [] }
    var selectedSuggestions: [FormatSuggestion] { suggestions.filter { selected.contains($0.path) } }
    var selectedSavings: Int64 { selectedSuggestions.reduce(0) { $0 + $1.estimatedSavings } }
    var selectedLossyCount: Int { selectedSuggestions.filter { !$0.conversion.isLossless }.count }
    var progressFraction: Double { totalCount == 0 ? 0 : Double(processedCount) / Double(totalCount) }

    func toggle(_ suggestion: FormatSuggestion) {
        if selected.contains(suggestion.path) { selected.remove(suggestion.path) } else { selected.insert(suggestion.path) }
    }

    func setAll(_ conversion: FormatConversion, selected on: Bool) {
        let paths = suggestions.filter { $0.conversion == conversion }.map(\.path)
        if on { selected.formUnion(paths) } else { selected.subtract(paths) }
    }

    func scan(roots: [String], options: ShrinkOptions) async {
        guard !isBusy else { return }
        isScanning = true
        phase = "Starting…"
        processedCount = 0
        totalCount = 0
        let progress = CompressProgress()
        self.progress = progress
        let poller = poll(progress)
        let result = await Task.detached(priority: .userInitiated) {
            await FormatService.scan(roots: roots, options: options, progress: progress)
        }.value
        poller.cancel()
        isScanning = false
        phase = ""
        self.progress = nil
        guard !progress.isCancelled else { return }
        scanResult = result
        selected = selected.intersection(result.suggestions.map(\.path))
    }

    func convertSelected(options: ShrinkOptions) async {
        let picks = selectedSuggestions
        guard !isBusy, !picks.isEmpty else { return }
        isRunning = true
        lastUndoSummary = nil
        processedCount = 0
        totalCount = picks.count
        let progress = CompressProgress()
        self.progress = progress
        let poller = poll(progress)
        let result = await Task.detached(priority: .userInitiated) {
            await FormatService.convert(picks, options: options, progress: progress)
        }.value
        poller.cancel()
        lastRun = result
        isRunning = false
        phase = ""
        self.progress = nil
        let touched = Set(result.items.filter { $0.status != .failed }.map(\.path))
        scanResult?.suggestions.removeAll { touched.contains($0.path) }
        selected.subtract(touched)
        onRunCompleted?(result)
    }

    func cancel() {
        progress?.cancel()
        phase = "Stopping after the current file…"
    }

    /// Same undo as Compress and Shrink: the converted file goes to the Trash and the original comes back.
    @discardableResult
    func undoLastRun() async -> (restored: Int, errors: [String]) {
        guard let run = lastRun, !isBusy else { return (0, []) }
        let records = run.undoRecords
        let each = await Task.detached(priority: .userInitiated) { CompressionService.undoEach(records) }.value
        let outcome = (restored: each.filter { $0.error == nil }.count, errors: each.compactMap(\.error))
        lastRun = nil
        onUndoCompleted?(outcome.restored, each.filter { $0.error != nil }.map(\.record))
        lastUndoSummary = outcome.errors.isEmpty
            ? "Restored \(outcome.restored) original\(outcome.restored == 1 ? "" : "s") in their old format."
            : "Restored \(outcome.restored); \(outcome.errors.count) couldn't be restored."
        return outcome
    }

    func dismissResults() {
        lastRun = nil
        lastUndoSummary = nil
    }

    private func poll(_ progress: CompressProgress) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.phase = progress.phase
                self?.processedCount = progress.done
                self?.totalCount = progress.total
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}

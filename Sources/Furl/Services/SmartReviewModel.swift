import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Second pass of Smart Review: asks Apple's on-device language model (Apple Intelligence) to judge
/// each candidate from its metadata. Nothing leaves the Mac, and file contents are never read.
enum SmartReviewModel {
    /// Files per prompt. Small batches keep each request well inside the model's context window.
    static let batchSize = 6

    static func status() -> SmartModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled:
                    // Apple Intelligence can't be turned on at all when the device language or region
                    // isn't supported, so tell the user that instead of sending them to a switch they can't flip.
                    return .unavailable(model.supportsLocale() ? .appleIntelligenceNotEnabled : .unsupportedLanguage)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                @unknown default:
                    return .unavailable(.other)
                }
            }
        }
        #endif
        return .unavailable(.osTooOld)
    }

    /// Reviews one batch. Returns verdicts keyed by item id; items the model skipped or failed on are omitted.
    static func review(_ items: [SmartReviewItem]) async -> [String: SmartVerdict] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await reviewWithModel(items)
        }
        #endif
        return [:]
    }

    // MARK: - Prompt facts

    /// Plain-text description of one file. Only metadata: name, folder, size, dates, origin and rule signals.
    static func describe(_ item: SmartReviewItem, index: Int) -> String {
        let now = Date()
        func ago(_ date: Date?) -> String {
            guard let date else { return "unknown" }
            return SmartReviewScanner.ageText(max(0, now.timeIntervalSince(date) / 86_400)) + " ago"
        }
        var lines = [
            "File \(index):",
            "  name: \(item.name)",
            "  folder: \(item.displayFolder)",
            "  size: \(FileSizeHelper.formatBytes(item.sizeBytes))",
            "  created: \(ago(item.createdDate))",
            "  modified: \(ago(item.modifiedDate))",
            "  last opened: \(item.lastOpenedDate == nil ? "never (or unknown)" : ago(item.lastOpenedDate))"
        ]
        if let source = item.downloadedFrom { lines.append("  downloaded from: \(source)") }
        if !item.signals.isEmpty { lines.append("  observations: \(item.signals.joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }

    /// The model only sees metadata, so it can't be the sole reason a file is called useless.
    /// It may only say "junk" when the rules already found real evidence, and never for personal media
    /// or documents (photos, PDFs, office files) — those top out at "maybe".
    static func guarded(_ label: SmartLabel, for item: SmartReviewItem) -> SmartLabel {
        guard label == .junk else { return label }
        let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        if SmartReviewScanner.personalExts.contains(ext) && item.ruleScore < 60 { return .maybe }
        if item.ruleScore < 30 { return .maybe }
        return .junk
    }

    static let instructions = """
    You help a Mac user decide which of their files are probably useless clutter they could delete.
    You only see metadata (name, folder, size, dates, download source), never the file contents.

    Label each file:
    - "junk": almost certainly safe to delete. Typical cases: an installer whose app is already installed, \
    an archive that was already extracted, an unfinished download, an old log, an old screenshot or screen \
    recording nobody opened again, an obvious duplicate copy.
    - "maybe": plausibly clutter but the user should glance at it first.
    - "keep": likely to matter. Personal documents, photos, creative work, source code, financial or legal \
    records, and anything recently used should default to keep unless the evidence is strong.

    Be conservative: when unsure, prefer "maybe" or "keep". Deleting something important is far worse than \
    leaving clutter.

    The reason must only use facts listed for that same file (its name, folder, size, dates, source and \
    observations). Never mention apps, dates or facts that are not written in that file's entry. \
    Do not repeat the file name in the reason.
    """
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct SmartFileVerdict {
    @Guide(description: "The file number exactly as given in the prompt")
    var index: Int
    @Guide(description: "The file's name, copied exactly from the prompt")
    var name: String
    @Guide(description: "junk, maybe or keep", .anyOf(["junk", "maybe", "keep"]))
    var label: String
    @Guide(description: "How confident you are in this label, 0 to 100", .range(0...100))
    var confidence: Int
    @Guide(description: "One short sentence (under 16 words) explaining the label using concrete facts")
    var reason: String
}

@available(macOS 26.0, *)
@Generable
struct SmartFileVerdicts {
    @Guide(description: "One verdict per file, in the same order as the files were listed")
    var verdicts: [SmartFileVerdict]
}

@available(macOS 26.0, *)
extension SmartReviewModel {
    fileprivate static func reviewWithModel(_ items: [SmartReviewItem]) async -> [String: SmartVerdict] {
        guard SystemLanguageModel.default.isAvailable, !items.isEmpty else { return [:] }

        let listing = items.enumerated()
            .map { describe($0.element, index: $0.offset + 1) }
            .joined(separator: "\n\n")
        let prompt = "Review these \(items.count) files and return one verdict for each.\n\n\(listing)"

        // A fresh session per batch: no history to overflow the context window, and batches stay independent.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: SmartFileVerdicts.self,
                options: GenerationOptions(temperature: 0.2)
            )
            var out: [String: SmartVerdict] = [:]
            for verdict in response.content.verdicts {
                let i = verdict.index - 1
                // Drop answers that got their files mixed up.
                guard items.indices.contains(i),
                      verdict.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(items[i].name) == .orderedSame
                else { continue }
                var label: SmartLabel
                switch verdict.label {
                case "junk": label = .junk
                case "keep": label = .keep
                default: label = .maybe
                }
                label = guarded(label, for: items[i])
                let reason = verdict.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                out[items[i].id] = SmartVerdict(
                    label: label,
                    confidence: max(0, min(100, verdict.confidence)),
                    reason: reason.isEmpty ? items[i].verdict.reason : reason,
                    source: .model
                )
            }
            return out
        } catch {
            // Guardrail hits, context overflow, etc.: keep the rule verdicts for this batch.
            return [:]
        }
    }
}
#endif

import AppIntents
import Foundation

// GetSpaceBack board, "Shortcuts / App Intents. No new screen, just a confirm and a result".
// Three actions in the Shortcuts app. They run inside Furl on this Mac and send nothing anywhere.
// Everything they read or clean goes through `ShortcutsBridge`, which uses the Overview's
// "Safe now" items and the same Trash-first clean.
//
// The action list only appears in Shortcuts when the bundle carries `Metadata.appintents`, which
// `scripts/build_app.sh` generates (SwiftPM doesn't). `swift run Furl` has no bundle, so no actions.

/// "Get safe space": returns the number, e.g. 17.9 GB. Doesn't change anything.
struct GetSafeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get safe space"
    static let description = IntentDescription(
        "Returns how much Furl can safely move to the Trash right now, for example 17.9 GB. Doesn’t change anything."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> & ProvidesDialog {
        let safe = await ShortcutsBridge.safeItems()
        let text = safe.isEmpty
            ? ShortcutsBridge.nothingToDoText
            : "\(FileSizeHelper.formatBytes(safe.bytes)) is safe to remove right now."
        return .result(value: .furlBytes(safe.bytes), dialog: "\(text)")
    }
}

/// "Move safe items to Trash": always asks first. Same items as "Safe now".
struct MoveSafeItemsToTrashIntent: AppIntent {
    static let title: LocalizedStringResource = "Move safe items to Trash"
    static let description = IntentDescription(
        "Moves Furl’s “Safe now” items to the Trash. Always asks first, and you can undo it in Furl."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> {
        let safe = await ShortcutsBridge.safeItems()
        let moved = try await confirmAndMove(safe.items)
        return .result(value: .furlBytes(moved))
    }
}

/// "Free up to…": stops once the target is reached, safest first. Always asks first.
struct FreeUpToIntent: AppIntent {
    static let title: LocalizedStringResource = "Free up to…"
    static let description = IntentDescription(
        "Moves “Safe now” items to the Trash, safest first, until the amount is reached. Always asks first, and you can undo it in Furl."
    )

    @Parameter(title: "Amount", defaultValue: 10, defaultUnit: .gigabytes, supportsNegativeNumbers: false)
    var amount: Measurement<UnitInformationStorage>

    static var parameterSummary: some ParameterSummary {
        Summary("Free up to \(\.$amount)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> {
        let target = Int64(max(0, amount.converted(to: .bytes).value).rounded(.up))
        let safe = await ShortcutsBridge.safeItems()
        let moved = try await confirmAndMove(ShortcutsBridge.pick(safe.items, toFree: target))
        return .result(value: .furlBytes(moved))
    }
}

enum FurlShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case busy
    case nothingMoved

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .busy: "Furl is already cleaning. Try again in a moment."
        // No paths here: the details stay in Furl (History and the error banner).
        case .nothingMoved: "Nothing could be moved to the Trash. Open Furl to see why."
        }
    }
}

private extension AppIntent {
    /// The board's confirm (system sheet), then the result notification. Cancelling the confirm
    /// throws, so nothing moves. Returns the bytes that went to the Trash.
    @MainActor
    func confirmAndMove(_ items: [ShortcutsBridge.SafeItem]) async throws -> Int64 {
        let notifications = AppServices.notifications
        guard !items.isEmpty else {
            await notifications.postShortcutNothingToDo(ShortcutsBridge.nothingToDoText)
            return 0
        }
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        let text = ShortcutsBridge.confirmTitle(bytes: bytes) + " "
            + ShortcutsBridge.confirmBody
        if #available(macOS 15.0, *) {
            try await requestConfirmation(
                actionName: .custom(acceptLabel: "Move to Trash", acceptAlternatives: [],
                                    denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: "\(text)"
            )
        } else {
            // macOS 14: the only confirm that takes our text, requestConfirmation(result:), is
            // deprecated and would add a build warning, so this sheet shows no amount. It still
            // always asks before anything moves.
            try await requestConfirmation()
        }

        switch await ShortcutsBridge.clean(items) {
        case .busy:
            throw FurlShortcutError.busy
        case .nothingMoved:
            await notifications.postShortcutNothingToDo(AppState.nothingCleanedText)
            return 0
        case .failed:
            throw FurlShortcutError.nothingMoved
        case .cleaned(let run):
            let text = ShortcutsBridge.resultText(bytes: run.totalBytes, percentFull: ShortcutsBridge.percentFull,
                                                  skipped: run.skippedCount ?? 0)
            await notifications.postShortcutResult(text, runID: run.id, canUndo: run.canUndo)
            return run.totalBytes
        }
    }
}

private extension Measurement where UnitType == UnitInformationStorage {
    static func furlBytes(_ bytes: Int64) -> Self { Measurement(value: Double(bytes), unit: .bytes) }
}

import AppIntents
import Foundation

// GetSpaceBack board, "Shortcuts / App Intents. No new screen, just a confirm and a result".
// Five actions in the Shortcuts app (WorktreesShortcuts board adds Stop leftover servers and Tidy project). They run inside Furl on this Mac and send nothing anywhere.
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

/// "Stop leftover servers": stops dev servers Furl marks as leftover. Always asks first.
struct StopLeftoverServersIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop leftover servers"
    static let description = IntentDescription(
        "Stops dev servers Furl marks as leftover: started by an agent or an editor that has since closed, and not in a terminal. Never databases or tunnels. Always asks first."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let notifications = AppServices.notifications
        let servers = await ShortcutsBridge.stoppableLeftovers()
        guard !servers.isEmpty else {
            await notifications.postShortcutMessage(LeftoverServers.nothingText)
            return .result(value: 0)
        }
        let text = ([LeftoverServers.confirmTitle(count: servers.count), LeftoverServers.confirmBody]
            + servers.map { LeftoverServers.confirmLine($0) } + [LeftoverServers.confirmFooter])
            .joined(separator: "\n")
        try await furlConfirm(text, acceptLabel: LeftoverServers.acceptLabel(count: servers.count))

        let outcome = await ShortcutsBridge.stopLeftovers(ids: Set(servers.map(\.id)))
        if outcome.stopped == 0 && outcome.stuck == 0 {
            // They all exited or changed while the confirm was up.
            await notifications.postShortcutMessage(LeftoverServers.nothingText)
        } else {
            await notifications.postShortcutMessage(
                LeftoverServers.resultText(count: outcome.stopped, bytes: outcome.bytes, stuck: outcome.stuck))
        }
        return .result(value: outcome.stopped)
    }
}

/// "Tidy project": moves a folder's rebuildable folders (node_modules, build output) to the Trash.
/// Always asks first.
struct TidyProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Tidy project"
    static let description = IntentDescription(
        "Pick a folder. Moves its rebuildable folders (node_modules, build output) to the Trash. Always asks first, and you can undo it in Furl."
    )

    @Parameter(title: "Folder", description: "The project folder to tidy.")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Tidy \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> {
        guard let url = folder.fileURL else { throw FurlShortcutError.notAFolder }
        let root = url.standardizedFileURL.path
        switch ProjectTidy.check(root: root) {
        case .notAFolder?: throw FurlShortcutError.notAFolder
        case .tooBroad?, .protected?: throw FurlShortcutError.folderTooBroad
        case nil: break
        }

        let notifications = AppServices.notifications
        let plan = await ShortcutsBridge.tidyPlan(root: root)
        guard !plan.folders.isEmpty else {
            await notifications.postShortcutMessage(ProjectTidy.nothingText(project: plan.project))
            return .result(value: .furlBytes(0))
        }
        let text = ([ProjectTidy.confirmTitle(bytes: plan.bytes, project: plan.project), ProjectTidy.confirmBody]
            + plan.folders.map(ProjectTidy.confirmLine) + [ProjectTidy.confirmFooter])
            .joined(separator: "\n")
        try await furlConfirm(text, acceptLabel: ProjectTidy.acceptLabel(bytes: plan.bytes))

        switch await ShortcutsBridge.tidy(plan) {
        case .busy:
            throw FurlShortcutError.busy
        case .nothingMoved:
            await notifications.postShortcutNothingToDo(AppState.nothingCleanedText)
            return .result(value: .furlBytes(0))
        case .failed:
            throw FurlShortcutError.nothingMoved
        case .cleaned(let run, let skipped):
            let text = ProjectTidy.resultText(bytes: run.totalBytes, project: plan.project, skipped: skipped)
            await notifications.postShortcutResult(text, runID: run.id, canUndo: run.canUndo)
            return .result(value: .furlBytes(run.totalBytes))
        }
    }
}

enum FurlShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case busy
    case nothingMoved
    case notAFolder
    case folderTooBroad

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .busy: "Furl is already cleaning. Try again in a moment."
        // No paths here: the details stay in Furl (History and the error banner).
        case .nothingMoved: "Nothing could be moved to the Trash. Open Furl to see why."
        case .notAFolder: "Pick a folder for Tidy project."
        case .folderTooBroad: "Pick one project folder, not your home folder or a system folder."
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
        try await furlConfirm(text, acceptLabel: "Move to Trash")

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

extension AppIntent {
    /// The system confirm sheet. Every Furl action that changes something calls this, even when it
    /// runs in an automation; cancelling throws, so nothing happens.
    @MainActor
    func furlConfirm(_ text: String, acceptLabel: String) async throws {
        if #available(macOS 15.0, *) {
            try await requestConfirmation(
                actionName: .custom(acceptLabel: LocalizedStringResource(stringLiteral: acceptLabel), acceptAlternatives: [],
                                    denyLabel: "Cancel", denyAlternatives: [], destructive: true),
                dialog: "\(text)"
            )
        } else {
            // macOS 14: the only confirm that takes our text, requestConfirmation(result:), is
            // deprecated and would add a build warning, so this sheet shows no text. It still
            // always asks before anything changes.
            try await requestConfirmation()
        }
    }
}

private extension Measurement where UnitType == UnitInformationStorage {
    static func furlBytes(_ bytes: Int64) -> Self { Measurement(value: Double(bytes), unit: .bytes) }
}

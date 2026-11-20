import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Local notifications only (UNUserNotificationCenter): low-disk alerts, Auto-Sweep summaries and the
/// one-per-version update notice.
/// Nothing is sent anywhere; notifications are scheduled on this Mac.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    enum Category {
        static let lowDisk = "SWEEPMAC_LOW_DISK"
        static let summary = "SWEEPMAC_AUTOSWEEP_SUMMARY"
        static let updateAvailable = "FURL_UPDATE_AVAILABLE"
        /// Result of a Shortcuts "Move safe items to Trash" / "Free up to…" run, with Undo.
        static let shortcutResult = "FURL_SHORTCUT_RESULT"
        static let shortcutNothing = "FURL_SHORTCUT_NOTHING"
        static let askFirst = "FURL_AUTOSWEEP_ASK"
        static let offerAutomatic = "FURL_AUTOSWEEP_OFFER_AUTOMATIC"
    }

    enum Action {
        static let cleanNow = "SWEEPMAC_CLEAN_NOW"
        static let review = "SWEEPMAC_REVIEW"
        static let viewHistory = "SWEEPMAC_VIEW_HISTORY"
        static let askClean = "FURL_AUTOSWEEP_CLEAN"
        static let askReview = "FURL_AUTOSWEEP_REVIEW"
        /// Undo on a Shortcuts result or an Auto-Sweep done notification.
        static let undoRun = "FURL_UNDO_RUN"
        static let switchToAutomatic = "FURL_AUTOSWEEP_SWITCH_AUTOMATIC"
        static let keepAsking = "FURL_AUTOSWEEP_KEEP_ASKING"
    }

    /// userInfo key holding the History run that Undo restores (Shortcuts result, Auto-Sweep done).
    nonisolated static let runIDKey = "furlRunID"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    /// Wired by the app: what the notification buttons do.
    var onCleanNow: (@MainActor () -> Void)?
    var onReview: (@MainActor () -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    var onUpdateAvailable: (@MainActor () -> Void)?
    /// Ask first: Clean and Review.
    var onAskClean: (@MainActor () -> Void)?
    var onAskReview: (@MainActor () -> Void)?
    /// The done notification's Undo.
    var onUndoRun: (@MainActor (UUID) -> Void)?
    /// The one-time Automatic offer.
    var onSwitchToAutomatic: (@MainActor () -> Void)?

    /// UNUserNotificationCenter throws an exception when the process isn't inside an .app bundle
    /// (e.g. `swift run`), so every call is guarded by this.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? {
        isAvailable ? UNUserNotificationCenter.current() : nil
    }

    func configure() {
        guard let center else {
            lastError = "Notifications need the Furl.app bundle (build it with scripts/build_app.sh)."
            return
        }
        center.delegate = self
        registerCategories(cleanTitle: "Clean now")
        Task { await refreshAuthorization() }
    }

    /// The low-disk alert's clean button names the safe number ("Free 17.9 GB", GetSpaceBack board),
    /// so the categories are registered again with that title before each alert.
    private func registerCategories(cleanTitle: String) {
        guard let center else { return }
        let clean = UNNotificationAction(identifier: Action.cleanNow, title: cleanTitle, options: [.foreground])
        let review = UNNotificationAction(identifier: Action.review, title: "Open Furl", options: [.foreground])
        // Clean (Ask first) and Undo work without bringing a window forward.
        let askClean = UNNotificationAction(identifier: Action.askClean, title: "Clean", options: [])
        let askReview = UNNotificationAction(identifier: Action.askReview, title: "Review", options: [.foreground])
        let undo = UNNotificationAction(identifier: Action.undoRun, title: "Undo", options: [])
        let switchAutomatic = UNNotificationAction(identifier: Action.switchToAutomatic, title: "Switch to Automatic", options: [])
        let keepAsking = UNNotificationAction(identifier: Action.keepAsking, title: "Keep asking", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.lowDisk, actions: [clean, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.summary, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.shortcutResult, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.shortcutNothing, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.askFirst, actions: [askClean, askReview], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.offerAutomatic, actions: [switchAutomatic, keepAsking], intentIdentifiers: [])
        ])
    }

    func refreshAuthorization() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// Asks once; afterwards macOS remembers the answer and the user changes it in System Settings.
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        guard let center else { return false }
        await refreshAuthorization()
        switch authorization {
        case .authorized, .provisional: return true
        case .denied: return false
        default:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                lastError = nil
                await refreshAuthorization()
                return granted
            } catch {
                lastError = error.localizedDescription
                await refreshAuthorization()
                return false
            }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.getfurl.furl"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Posting

    /// `safeBytes` is the Overview's "Safe now" number, the same one the menu bar shows.
    func postLowDisk(freeBytes: Int64, volumeName: String, safeBytes: Int64) async {
        let content = UNMutableNotificationContent()
        content.title = "Your disk is almost full"
        let left = "Only \(FileSizeHelper.formatBytes(freeBytes)) left."
        content.body = safeBytes > 0
            ? "\(left) Furl can free \(FileSizeHelper.formatBytes(safeBytes)) safely."
            : "\(left) Open Furl to see what you can free."
        registerCategories(cleanTitle: safeBytes > 0 ? "Free \(FileSizeHelper.formatBytes(safeBytes))" : "Clean now")
        content.categoryIdentifier = Category.lowDisk
        content.sound = .default
        await post(content, id: "low-disk")
    }

    /// AutoSweepTrust "Automatic · after it ran": what moved, with Undo.
    func postSummary(_ run: AutoSweepRun) async {
        guard run.totalItems > 0 || !run.errors.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if run.totalItems > 0 {
            content.title = Self.doneTitle(run)
            content.body = Self.doneBody(run)
            content.userInfo = [Self.runIDKey: run.id.uuidString]
        } else {
            content.title = "Auto-Sweep needs attention"
            content.body = run.errors.first ?? "Some items couldn't be cleaned."
        }
        content.categoryIdentifier = Category.summary
        await post(content, id: "autosweep-\(run.id.uuidString)")
    }

    /// GetSpaceBack board, Shortcuts result: "Moved 17.9 GB to the Trash. Now 79% full." with Undo.
    /// No title, so macOS shows "Furl" above it as drawn.
    func postShortcutResult(_ text: String, runID: AutoSweepRun.ID, canUndo: Bool) async {
        let content = UNMutableNotificationContent()
        content.body = text
        content.categoryIdentifier = canUndo ? Category.shortcutResult : Category.shortcutNothing
        content.userInfo = [Self.runIDKey: runID.uuidString]
        await post(content, id: "shortcut-\(runID.uuidString)")
    }

    /// GetSpaceBack board, "When there is nothing to do".
    func postShortcutNothingToDo(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.body = text
        content.categoryIdentifier = Category.shortcutNothing
        await post(content, id: "shortcut-nothing")
    }

    static func doneTitle(_ run: AutoSweepRun) -> String {
        if run.totalBytes > 0 {
            return run.trashed.isEmpty
                ? "Auto-Sweep freed \(FileSizeHelper.formatBytes(run.totalBytes))"
                : "Auto-Sweep moved \(FileSizeHelper.formatBytes(run.totalBytes)) to the Trash"
        }
        let stopped = run.parts.filter { $0.rule == .processes }.reduce(0) { $0 + $1.itemCount }
        return stopped == 1 ? "Auto-Sweep stopped 1 dev server" : "Auto-Sweep stopped \(stopped) dev servers"
    }

    /// "Caches and stale node_modules. Undo in History."
    static func doneBody(_ run: AutoSweepRun) -> String {
        var body = run.whatText
        if !run.trashed.isEmpty { body += ". Undo in History." } else if !body.isEmpty { body += "." }
        return body
    }

    /// AutoSweepTrust "Ask first · on schedule": what the run would clean, with Clean and Review.
    @discardableResult
    func postAskFirst(_ preview: AutoSweepPreview) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = preview.totalBytes > 0
            ? "Auto-Sweep found \(FileSizeHelper.formatBytes(preview.totalBytes))"
            : "Auto-Sweep found something to clean"
        content.body = [preview.sentence + ".", preview.safetySentence].filter { !$0.isEmpty && $0 != "." }.joined(separator: " ")
        content.categoryIdentifier = Category.askFirst
        content.sound = .default
        return await post(content, id: "autosweep-ask")
    }

    /// AutoSweepTrust "After 3 approved runs, once".
    /// Returns whether it was shown (false with notifications off).
    func postOfferAutomatic() async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Let Auto-Sweep run by itself?"
        content.body = "You approved the last \(AutoSweepTrustLadder.approvalsBeforeOffer) runs without changes. Furl can do it and tell you after."
        content.categoryIdentifier = Category.offerAutomatic
        return await post(content, id: "autosweep-offer-automatic")
    }

    func postTest() async {
        let content = UNMutableNotificationContent()
        content.title = "Furl notifications are on"
        content.body = "You'll get low-disk warnings and Auto-Sweep summaries here. Works offline · Your files never leave your Mac."
        content.categoryIdentifier = Category.lowDisk
        await post(content, id: "test-\(UUID().uuidString)")
    }

    /// UpdateCheck board, "the one notice": only when notifications are already allowed. It never asks
    /// for permission; with notifications off there is no other hint.
    func postUpdateAvailable(version: String) async {
        guard let center else { return }
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Furl \(version) is available"
        content.body = "Click to see what's new and install it. Your settings and history stay."
        content.categoryIdentifier = Category.updateAvailable
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
        do {
            try await center.add(request)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func post(_ content: UNMutableNotificationContent, id: String) async -> Bool {
        guard let center else { return false }
        guard await requestPermissionIfNeeded() else { return false }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let runID = (response.notification.request.content.userInfo[Self.runIDKey] as? String).flatMap(UUID.init)
        await MainActor.run {
            switch action {
            case Action.cleanNow: self.onCleanNow?()
            case Action.review: self.onReview?()
            case Action.viewHistory: self.onOpenHistory?()
            case Action.askClean: self.onAskClean?()
            case Action.askReview: self.onAskReview?()
            case Action.undoRun:
                if let runID { self.onUndoRun?(runID) } else { self.onOpenHistory?() }
            case Action.switchToAutomatic: self.onSwitchToAutomatic?()
            case Action.keepAsking: break
            default:
                // Clicking the notification body.
                switch category {
                case Category.summary: self.onOpenHistory?()
                case Category.updateAvailable: self.onUpdateAvailable?()
                case Category.shortcutResult: self.onOpenHistory?()
                case Category.askFirst: self.onAskReview?()
                case Category.offerAutomatic: break
                default: self.onReview?()
                }
            }
        }
    }
}

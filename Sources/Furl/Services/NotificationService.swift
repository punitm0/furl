import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Local notifications only (UNUserNotificationCenter): low-disk alerts and Auto-Sweep summaries.
/// Nothing is sent anywhere; notifications are scheduled on this Mac.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    enum Category {
        static let lowDisk = "SWEEPMAC_LOW_DISK"
        static let summary = "SWEEPMAC_AUTOSWEEP_SUMMARY"
    }

    enum Action {
        static let cleanNow = "SWEEPMAC_CLEAN_NOW"
        static let review = "SWEEPMAC_REVIEW"
        static let viewHistory = "SWEEPMAC_VIEW_HISTORY"
    }

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    /// Wired by the app: what the notification buttons do.
    var onCleanNow: (@MainActor () -> Void)?
    var onReview: (@MainActor () -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?

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
        let clean = UNNotificationAction(identifier: Action.cleanNow, title: "Clean now", options: [.foreground])
        let review = UNNotificationAction(identifier: Action.review, title: "Review", options: [.foreground])
        let history = UNNotificationAction(identifier: Action.viewHistory, title: "View History", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.lowDisk, actions: [clean, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.summary, actions: [history], intentIdentifiers: [])
        ])
        Task { await refreshAuthorization() }
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

    func postLowDisk(freeBytes: Int64, volumeName: String, safeBytes: Int64) async {
        let content = UNMutableNotificationContent()
        content.title = "Only \(FileSizeHelper.formatBytes(freeBytes)) left on \(volumeName)"
        content.body = safeBytes > 0
            ? "\(FileSizeHelper.formatBytes(safeBytes)) can be freed safely. Files go to the Trash first."
            : "Open Furl to see what you can free."
        content.categoryIdentifier = Category.lowDisk
        content.sound = .default
        await post(content, id: "low-disk")
    }

    func postSummary(_ run: AutoSweepRun) async {
        guard run.totalItems > 0 || !run.errors.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if run.totalItems > 0 {
            content.title = "Auto-Sweep moved \(FileSizeHelper.formatBytes(run.totalBytes)) to the Trash"
            content.body = run.summary + ". You can undo it in Furl."
        } else {
            content.title = "Auto-Sweep needs attention"
            content.body = run.errors.first ?? "Some items couldn't be cleaned."
        }
        content.categoryIdentifier = Category.summary
        await post(content, id: "autosweep-\(run.id.uuidString)")
    }

    func postTest() async {
        let content = UNMutableNotificationContent()
        content.title = "Furl notifications are on"
        content.body = "You'll get low-disk warnings and Auto-Sweep summaries here. Works offline · Your files never leave your Mac."
        content.categoryIdentifier = Category.lowDisk
        await post(content, id: "test-\(UUID().uuidString)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) async {
        guard let center else { return }
        guard await requestPermissionIfNeeded() else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
        await MainActor.run {
            switch action {
            case Action.cleanNow: self.onCleanNow?()
            case Action.review: self.onReview?()
            case Action.viewHistory: self.onOpenHistory?()
            default:
                // Clicking the notification body.
                if category == Category.summary { self.onOpenHistory?() } else { self.onReview?() }
            }
        }
    }
}

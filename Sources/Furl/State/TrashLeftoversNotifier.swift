import Foundation

/// When an app lands in the Trash while Furl runs, offers once to remove what it left in ~/Library
/// (LeftoversWhatsNew board). "Review…" opens the Apps & Leftovers confirm; nothing moves without it.
@MainActor
final class TrashLeftoversNotifier {
    static let shared = TrashLeftoversNotifier()

    private var watcher: TrashWatcher?
    /// Apps being looked at right now, so a burst of Trash events checks each only once.
    private var inFlight = Set<String>()

    func start() {
        guard watcher == nil else { return }
        let watcher = TrashWatcher { url in
            Task { @MainActor in TrashLeftoversNotifier.shared.appTrashed(at: url) }
        }
        self.watcher = watcher
        watcher.start()
    }

    private func appTrashed(at url: URL) {
        guard TrashedAppLeftovers.isEnabled() else { return }
        Task {
            // Give Finder a moment to finish the move before reading the bundle.
            try? await Task.sleep(for: .seconds(2))
            guard let app = await Self.read(url), inFlight.insert(app.bundleID.lowercased()).inserted else { return }
            defer { inFlight.remove(app.bundleID.lowercased()) }
            let notified = Set(TrashedAppLeftovers.notified())
            guard TrashedAppLeftovers.isEnabled(), !notified.contains(app.bundleID.lowercased()) else { return }
            let items = await Self.leftovers(for: app)
            guard TrashedAppLeftovers.shouldNotify(items: items, bundleID: app.bundleID,
                                                   enabled: TrashedAppLeftovers.isEnabled(),
                                                   alreadyNotified: Set(TrashedAppLeftovers.notified())) else { return }
            let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            if await NotificationService.shared.postTrashedAppLeftovers(app, bytes: total) {
                TrashedAppLeftovers.recordNotified(app.bundleID)
            }
        }
    }

    /// "Review…": measures again (folders may have changed since the notification) and opens the
    /// Apps & Leftovers confirm for this app.
    func review(bundleID: String, name: String, state: AppState) {
        Task {
            let app = TrashedApp(bundleID: bundleID, name: name)
            let items = await Self.leftovers(for: app)
            let groups = TrashedAppLeftovers.groups(from: items, bundleID: bundleID, appName: name)
            let stamps = await Self.stamps(items.map(\.path))
            state.reviewTrashedAppLeftovers(groups, mainID: bundleID.lowercased(), stamps: stamps)
            AppWindows.showMain(section: .apps, state: state)
        }
    }

    private nonisolated static func read(_ url: URL) async -> TrashedApp? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: TrashedAppLeftovers.readTrashedApp(at: url))
            }
        }
    }

    private nonisolated static func leftovers(for app: TrashedApp) async -> [AppDataItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: AppUninstallerService.leftovers(
                    forTrashedBundleID: app.bundleID, appName: app.name))
            }
        }
    }

    private nonisolated static func stamps(_ paths: [String]) async -> [String: CleanupStamp] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: CleanupStamp.read(paths))
            }
        }
    }
}

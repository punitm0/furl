import AppKit
import Combine
import Foundation

/// Drives Auto-Sweep and low-disk alerts while Furl is running (in the menu bar or with its
/// window open). Uses NSBackgroundActivityScheduler (App Nap–friendly) plus a wake-from-sleep
/// check, so a slot missed while the Mac slept runs as soon as it wakes. Also refreshes the free
/// space shown in the menu bar.
@MainActor
final class AutoSweepScheduler {
    private let state: AppState
    private let store: AutoSweepStore
    private let notifications: NotificationService

    private var activity: NSBackgroundActivityScheduler?
    private var labelTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isTicking = false

    init(state: AppState, store: AutoSweepStore, notifications: NotificationService) {
        self.state = state
        self.store = store
        self.notifications = notifications
    }

    func start() {
        guard activity == nil else { return }

        state.observeTrashForLedger(store: store).store(in: &cancellables)

        let activity = NSBackgroundActivityScheduler(identifier: "app.getfurl.furl.autosweep")
        activity.repeats = true
        activity.interval = 15 * 60
        activity.tolerance = 5 * 60
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.tick()
                completion(.finished)
            }
        }
        self.activity = activity

        // Cheap: just re-reads volume capacity for the menu bar label.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFreeSpace() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // Give the network/disk a moment after wake.
                    try? await Task.sleep(for: .seconds(20))
                    await self?.tick()
                }
            }
            .store(in: &cancellables)

        Task {
            try? await Task.sleep(for: .seconds(10))
            await tick()
        }
    }

    func refreshFreeSpace() {
        state.diskUsage = DiskInfoService.currentDiskUsage()
    }

    /// Checks what's due. Safe to call often.
    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        refreshFreeSpace()
        await checkLowDisk()

        if store.isScheduledRunDue {
            await runScheduled(trigger: .scheduled)
        }
        if store.isDailyRunDue {
            await runDaily(trigger: .scheduled)
        }
    }

    /// Settings › Automation › "Run now": every enabled rule, immediately.
    func runNow() async {
        guard !store.isRunning else { return }
        if store.cachesEnabled { await runScheduled(trigger: .manual) }
        if store.hasDailyRules { await runDaily(trigger: .manual) }
    }

    private func runScheduled(trigger: AutoSweepRun.Trigger) async {
        guard !store.isRunning, !state.isCleaning else { return }
        store.isRunning = true
        defer { store.isRunning = false }
        let run = await state.runScheduledAutoSweep(store: store, trigger: trigger)
        store.markScheduledRun(run.date)
        store.record(run, countsAsAutoSweep: true)
        if store.notifyAfterRun { await notifications.postSummary(run) }
    }

    private func runDaily(trigger: AutoSweepRun.Trigger) async {
        guard !store.isRunning, !state.isCleaning else { return }
        store.isRunning = true
        defer { store.isRunning = false }
        let run = await state.runDailyAutoSweep(store: store, trigger: trigger)
        store.markDailyRun(run.date)
        store.record(run, countsAsAutoSweep: true)
        if store.notifyAfterRun { await notifications.postSummary(run) }
    }

    // MARK: - Low disk

    private func checkLowDisk() async {
        guard store.lowDiskAlertEnabled else { return }
        let usage = state.diskUsage
        guard usage.totalBytes > 0 else { return }
        let threshold = Int64(store.lowDiskThresholdGB) * 1_000_000_000

        if usage.availableBytes >= threshold {
            // Re-arm once space has recovered a little, so a fresh drop alerts again.
            if usage.availableBytes > threshold + 2_000_000_000 { store.lowDiskLastAlert = nil }
            return
        }
        // At most one alert a day while it stays low.
        if let last = store.lowDiskLastAlert, Date().timeIntervalSince(last) < 24 * 3600 { return }
        store.lowDiskLastAlert = Date()

        await state.prepareSafeCleanup()
        await notifications.postLowDisk(
            freeBytes: usage.availableBytes,
            volumeName: usage.volumeName,
            safeBytes: state.safeCleanupPlan.bytes
        )
    }
}

// MARK: - Downloads tidy-up

/// Conservative Downloads rules: installer images older than a week, unfinished browser downloads
/// older than two days, and archives older than a week that were already unzipped next to themselves
/// (the folder beside them holds the archive's top-level items and at least its size; see ArchiveExtractionCheck).
enum DownloadsTidier {
    struct Candidate: Sendable {
        let path: String
        let reason: String
        /// How the item looked when it was listed (kind and modification date), before the slower
        /// archive check ran. The tidy-up re-checks it right before moving; nil never passes.
        var stamp: CleanupStamp? = nil
        /// "Already unzipped": the folder that holds the archive's contents. Must still be there when
        /// the archive moves, or the archive would be the only copy left.
        var extractedFolder: String? = nil
    }

    static func candidates(now: Date = Date()) -> [Candidate] {
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard let children = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let installerExts: Set<String> = ["dmg", "pkg", "mpkg"]
        let partialExts: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
        let archiveExts: Set<String> = ["zip", "tar", "tgz", "gz", "xz", "bz2", "7z", "rar"]
        let names = Set(children.map(\.lastPathComponent))

        func age(_ url: URL) -> Double {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            return now.timeIntervalSince(date) / 86_400
        }

        // Read from the listing's prefetched values, i.e. as the item was when its age was judged.
        func stamp(_ url: URL) -> CleanupStamp? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  let modified = values.contentModificationDate else { return nil }
            let kind: CleanupStamp.Kind = values.isSymbolicLink == true ? .symlink : (values.isDirectory == true ? .directory : .file)
            return CleanupStamp(kind: kind, modified: modified)
        }

        var result: [Candidate] = []
        for url in children {
            let ext = url.pathExtension.lowercased()
            if installerExts.contains(ext), age(url) >= 7, ext != "dmg" || DiskImageCheck.isPlainInstallerImage(url) {
                result.append(Candidate(path: url.path, reason: "Installer image", stamp: stamp(url)))
            } else if partialExts.contains(ext), age(url) >= 2 {
                result.append(Candidate(path: url.path, reason: "Unfinished download", stamp: stamp(url)))
            } else if archiveExts.contains(ext), age(url) >= 7,
                      let folder = ArchiveExtractionCheck.extractedFolder(for: url),
                      names.contains(folder.lastPathComponent),
                      // The folder must hold what the archive lists (top-level names and size), not just share its name.
                      ArchiveExtractionCheck.isExtracted(archive: url) {
                result.append(Candidate(path: url.path, reason: "Already unzipped", stamp: stamp(url),
                                        extractedFolder: folder.path))
            }
        }
        return result.filter { !DeletionService.isProtected($0.path) }
    }
}

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

        switch store.mode {
        case .off:
            break
        case .automatic:
            let due = store.isScheduledRunDue || store.isDailyRunDue
            let skips = due ? store.takeSkips() : []
            if store.isScheduledRunDue {
                await runScheduled(trigger: .scheduled, skipping: skips)
            }
            if store.isDailyRunDue {
                await runDaily(trigger: .scheduled, skipping: skips)
            }
        case .askFirst:
            store.dropExpiredAsk()
            await askIfDue()
        }
        if store.previewDueBeforeSlot() { await refreshPreview() }
    }

    // MARK: - Next-run preview

    /// Works out what the next run would take (Settings › Automation, the menu bar). Moves nothing.
    func refreshPreview() async {
        guard let next = store.nextRun else {
            store.setPreview(nil)
            return
        }
        guard !store.isPreviewing else { return }
        store.isPreviewing = true
        defer { store.isPreviewing = false }
        let preview = await state.previewAutoSweep(store: store, scheduled: next.scheduled, daily: next.daily)
        store.setPreview(preview)
    }

    /// Settings and the menu bar ask for this when they appear; cheap when the preview is fresh.
    func refreshPreviewIfNeeded() {
        guard store.previewNeedsRefresh() else { return }
        Task { await refreshPreview() }
    }

    // MARK: - Ask first

    /// A run is due: list what it would clean in a notification with Clean and Review. Nothing moves
    /// until the user approves. The slot counts as used either way, so an unanswered ask isn't repeated
    /// every few minutes; the next one comes at the next slot.
    private func askIfDue() async {
        let scheduled = store.isScheduledRunDue
        let daily = store.isDailyRunDue
        guard scheduled || daily, !store.isRunning, !state.isCleaning, !store.isPreviewing else { return }
        store.isPreviewing = true
        var preview = await state.previewAutoSweep(store: store, scheduled: scheduled, daily: daily)
        store.isPreviewing = false
        // Switched away from Ask first while the list was being made: don't ask.
        guard store.mode == .askFirst else { return }
        // Items unticked in See list are left out of this run, and the run counts as changed.
        let skips = store.takeSkips()
        if !skips.isEmpty {
            let before = preview.items.count
            preview = preview.keeping(Set(preview.items.map(\.id)).subtracting(skips))
            preview.userSkipped = preview.items.count != before
        }
        let now = Date()
        if scheduled { store.markScheduledRun(now) }
        if daily { store.markDailyRun(now) }
        store.invalidatePreview()
        guard !preview.isEmpty else {
            // Nothing to ask about: only "last run" moves on (an empty run adds no History row).
            store.record(AutoSweepRun(date: now, trigger: .scheduled, parts: [], trashed: [], errors: []), countsAsAutoSweep: true)
            return
        }
        // Kept even if the notification can't be shown: Settings and the menu bar say it's waiting.
        store.pendingAsk = preview
        await notifications.postAskFirst(preview)
    }

    /// Clean on the Ask first notification, or Move to Trash in Review. `changed`: something was
    /// unticked, so this run doesn't count toward offering Automatic.
    func approve(_ preview: AutoSweepPreview, changed: Bool) async {
        guard !store.isRunning, !state.isCleaning else {
            // Busy with another clean: the ask stays waiting, and the user hears why nothing moved.
            state.statusBanner = "Auto-Sweep waits until the current clean finishes. Review it again in a moment."
            return
        }
        let wasAskFirst = store.mode == .askFirst
        store.pendingAsk = nil
        store.isRunning = true
        let run = await state.runApprovedAutoSweep(preview, store: store)
        store.record(run, countsAsAutoSweep: true)
        store.isRunning = false
        store.invalidatePreview()
        if store.notifyAfterRun { await notifications.postSummary(run) }
        // Only real Ask first approvals that cleaned something count toward offering Automatic.
        guard wasAskFirst, store.mode == .askFirst, run.totalItems > 0 else { return }
        if store.recordApproval(changed: changed || preview.userSkipped),
           await notifications.postOfferAutomatic() {
            store.markOfferedAutomatic()
        }
    }

    /// Clean from the notification. After a relaunch the plan is gone, so it opens Review instead
    /// of acting on items nobody has seen.
    func approvePendingFromNotification() async {
        store.dropExpiredAsk()
        guard store.mode == .askFirst, let pending = store.pendingAsk else {
            await review()
            return
        }
        await approve(pending, changed: false)
    }

    /// Review on the notification: the item list in Settings › Automation, with boxes to untick.
    /// Without a waiting ask, the sheet opens at once and fills in when a fresh list is ready.
    func review() async {
        store.dropExpiredAsk()
        SettingsTab.select(.automation)
        AppWindows.showSettings()
        guard store.mode == .askFirst else { return }
        store.listRequest = .review
        guard store.pendingAsk == nil, !store.isPreparingReview else { return }
        store.isPreparingReview = true
        let preview = await state.previewAutoSweep(store: store, scheduled: store.cachesEnabled, daily: store.hasDailyRules)
        store.isPreparingReview = false
        // Closed with Not now while the list was being made: nothing waits.
        guard store.mode == .askFirst, store.listRequest == .review else { return }
        store.pendingAsk = preview.isEmpty ? nil : preview
    }

    /// Settings › Automation › "Run now": in Automatic, every enabled rule at once. In Ask first it
    /// opens Review with a fresh list; nothing moves until the user approves it.
    func runNow() async {
        guard !store.isRunning else { return }
        if store.mode == .askFirst {
            store.pendingAsk = nil
            await review()
            return
        }
        if store.cachesEnabled { await runScheduled(trigger: .manual) }
        if store.hasDailyRules { await runDaily(trigger: .manual) }
    }

    private func runScheduled(trigger: AutoSweepRun.Trigger, skipping skips: Set<String> = []) async {
        guard !store.isRunning, !state.isCleaning else { return }
        store.isRunning = true
        defer { store.isRunning = false }
        let run = await state.runScheduledAutoSweep(store: store, trigger: trigger, skipping: skips)
        store.markScheduledRun(run.date)
        store.record(run, countsAsAutoSweep: true)
        store.invalidatePreview()
        if store.notifyAfterRun { await notifications.postSummary(run) }
    }

    private func runDaily(trigger: AutoSweepRun.Trigger, skipping skips: Set<String> = []) async {
        guard !store.isRunning, !state.isCleaning else { return }
        store.isRunning = true
        defer { store.isRunning = false }
        let run = await state.runDailyAutoSweep(store: store, trigger: trigger, skipping: skips)
        store.markDailyRun(run.date)
        store.record(run, countsAsAutoSweep: true)
        store.invalidatePreview()
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

        // The same settled, fresh number the Overview shows, not a partial one from a scan in progress.
        let plan = await state.freshSafeCleanupPlan()
        await notifications.postLowDisk(
            freeBytes: usage.availableBytes,
            volumeName: usage.volumeName,
            safeBytes: plan.bytes
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

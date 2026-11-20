import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let deletionMode = "deletionMode"
        /// Legacy hand-picked list; migrated into `extraScanRoots` once (see `migrateLegacyProjectRoots`).
        static let projectRoots = "projectRoots"
        static let extraScanRoots = "extraScanRoots"
        static let excludedScanRoots = "excludedScanRoots"
        /// Which screen a "Never scan" folder was added from (path → screen name), for the Settings list.
        static let excludedScanRootSources = "excludedScanRootSources"
        static let discoveredProjectRoots = "discoveredProjectRoots"
        static let staleDays = "staleDaysThreshold"
        static let largeFileThreshold = "largeFileThresholdMB"
        static let scanOnLaunch = "scanOnLaunch"
        static let duplicateRoots = "duplicateRoots"
        static let duplicateMinMB = "duplicateMinMB"
        static let smartIgnored = "smartReviewIgnoredPaths"
        static let smartUseModel = "smartReviewUseModel"
    }

    private let defaults = UserDefaults.standard

    @Published var selectedSection: SidebarSection = .dashboard {
        // Disk opens on What's big from anywhere (sidebar, ⌘4…, Storage, Overview); only the
        // growth link opens What grew, by setting it after the section.
        didSet { if selectedSection == .disk && oldValue != .disk { diskView = .big } }
    }
    /// Disk's two views; a link can open What grew directly.
    @Published var diskView: DiskViewMode = .big
    /// A path filter a Disk row hands to the section it opens; that section's search takes it once.
    private var pendingHandoffFilter: (section: SidebarSection, text: String)?
    /// Disk rows' view of the other sections' results; cleared when any of them changes.
    fileprivate var diskFindingsCache: DiskFindings?

    // MARK: Persisted settings
    @Published var deletionMode: DeletionMode {
        didSet { defaults.set(deletionMode.rawValue, forKey: Keys.deletionMode) }
    }
    /// Projects found automatically in the home index (folders with .git or a project manifest).
    /// Cached so Auto-Sweep has them before the first scan of a session.
    @Published private(set) var discoveredProjectRoots: [String] {
        didSet { defaults.set(discoveredProjectRoots, forKey: Keys.discoveredProjectRoots) }
    }
    /// Settings › Scanning › "Also scan": extra folders, e.g. projects on external drives.
    @Published var extraScanRoots: [String] {
        didSet {
            defaults.set(extraScanRoots, forKey: Keys.extraScanRoots)
            if oldValue != extraScanRoots { scheduleProjectRootRescan() }
        }
    }
    /// Settings › Scanning › "Never scan": never look for projects, worktrees, junk, large files or
    /// duplicates inside these. (Stored under the old "Exclude" key.)
    @Published var excludedScanRoots: [String] {
        didSet {
            defaults.set(excludedScanRoots, forKey: Keys.excludedScanRoots)
            guard oldValue != excludedScanRoots else { return }
            // "Don't scan here…" and its Undo update the lists themselves; a rescan would re-tick every Safe item.
            if skipNextRootRescan { skipNextRootRescan = false } else { scheduleProjectRootRescan() }
        }
    }
    /// "added from Caches & Junk": the screen a "Don't scan here…" came from, keyed by folder.
    @Published var excludedScanRootSources: [String: String] {
        didSet { defaults.set(excludedScanRootSources, forKey: Keys.excludedScanRootSources) }
    }
    /// The "Stop scanning …?" confirm, shown over the main window.
    @Published var pendingNeverScan: NeverScanRequest?
    /// Set right before a Never scan change that already updated the lists.
    var skipNextRootRescan = false
    /// Where worktree, dev-artifact and .DS_Store scans look: discovered projects plus "Also scan".
    /// Before anything has been discovered (first launch, index unavailable) the old default folders.
    var projectRoots: [String] {
        let base = discoveredProjectRoots.isEmpty && !hasDiscoveredProjects
            ? WorktreeScanner.defaultSearchRoots() : discoveredProjectRoots
        var seen = Set<String>()
        return (base + extraScanRoots).filter { !isExcluded($0) && seen.insert($0).inserted }
    }
    /// True once a scan has run discovery (even if it found nothing).
    @Published private(set) var hasDiscoveredProjects = false

    func isExcluded(_ path: String) -> Bool {
        Self.isExcluded(path, by: excludedScanRoots)
    }
    private var rootRescanTask: Task<Void, Never>?
    /// Caches & Junk toolbar: "Dependencies count as unused after N days". Re-filters the list without a rescan.
    @Published var staleDaysThreshold: Int {
        didSet {
            guard oldValue != staleDaysThreshold else { return }
            defaults.set(staleDaysThreshold, forKey: Keys.staleDays)
            applyStaleDaysChange()
        }
    }
    /// Junk found by the last scan that the current "unused after" days hide (young dependencies, recent archives).
    var heldBackJunk: [JunkItem] = []
    /// The days the last junk scan used; nil before the first scan finishes.
    var junkScannedStaleDays: Int?
    @Published var largeFileThresholdMB: Int64 {
        didSet {
            defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThreshold)
            applyLargeFileThresholdChange(from: oldValue)
        }
    }
    @Published var scanOnLaunch: Bool {
        didSet { defaults.set(scanOnLaunch, forKey: Keys.scanOnLaunch) }
    }
    /// Derived from the stats ledger (StatsLedger), which is the single source of truth.
    @Published private(set) var lifetimeFreedBytes: Int64 = 0
    @Published var duplicateRoots: [String] {
        didSet { defaults.set(duplicateRoots, forKey: Keys.duplicateRoots) }
    }
    @Published var duplicateMinimumMB: Int64 {
        didSet { defaults.set(duplicateMinimumMB, forKey: Keys.duplicateMinMB) }
    }

    /// The Min size picker stores whole MB; 0 stands for its "100 KB" option.
    var duplicateMinimumBytes: Int64 {
        duplicateMinimumMB == 0 ? 100_000 : duplicateMinimumMB * 1_000_000
    }
    /// Files the user marked "not useless"; Smart Review never suggests them again.
    @Published private(set) var smartIgnoredPaths: Set<String> {
        didSet { defaults.set(Array(smartIgnoredPaths), forKey: Keys.smartIgnored) }
    }
    @Published var smartUseModel: Bool {
        didSet { defaults.set(smartUseModel, forKey: Keys.smartUseModel) }
    }

    // MARK: Disk
    @Published var diskUsage: DiskUsageInfo = DiskInfoService.currentDiskUsage()
    @Published var trashSizeBytes: Int64 = 0
    /// When the last *completed* full scan finished (see `noteScanSectionFinished`). nil until one has.
    @Published var lastScanDate: Date?
    /// A `scanAll` is in progress; cleared (and `lastScanDate` stamped) once every area is idle.
    private var fullScanInFlight = false
    /// What every scan result looked like on disk when its scan finished. Every user-triggered
    /// delete (each section's Clean / Move to Trash / Delete, uninstall, Space Map, "Clean safe
    /// items") re-checks its items against it right before removing anything.
    var cleanupStamps = CleanupStampBook()
    @Published private(set) var sessionFreedBytes: Int64 = 0

    // MARK: Scan state
    @Published var isScanningWorktrees = false
    @Published var isScanningJunk = false
    @Published var isScanningApps = false
    @Published var isScanningLargeFiles = false
    @Published var isScanningDuplicates = false
    @Published var isScanningSpace = false
    @Published var isCleaning = false
    /// The live strip under each scan-based screen's header while results are still arriving,
    /// and for a moment after (finished) or until the next scan (stopped).
    @Published private(set) var liveScans: [SidebarSection: LiveScanStatus] = [:]
    private var liveProgress: [SidebarSection: ScanProgress] = [:]

    struct CleanupProgressInfo: Equatable {
        let title: String
        let done: Int
        let total: Int
        let current: String
    }
    /// Live progress for a running cleanup; nil when idle.
    @Published private(set) var cleanupProgress: CleanupProgressInfo?

    /// Scans requested while the same scan was already running; they re-run once it finishes.
    var pendingRescans = Set<SidebarSection>()

    @Published private(set) var hasScannedWorktrees = false
    @Published private(set) var hasScannedJunk = false
    @Published private(set) var hasScannedApps = false
    @Published private(set) var hasScannedLargeFiles = false
    @Published private(set) var hasScannedDuplicates = false

    @Published var worktrees: [WorktreeItem] = [] { didSet { diskFindingsCache = nil } }
    @Published var selectedWorktreeIDs = Set<String>()

    @Published var junkItems: [JunkItem] = [] {
        didSet {
            diskFindingsCache = nil
            refreshSafeCleanupPlan()
        }
    }
    @Published var selectedJunkIDs = Set<String>() {
        didSet {
            noteSafeCleanVetoes(removed: oldValue.subtracting(selectedJunkIDs))
            refreshSafeCleanupPlan()
        }
    }
    /// "Safe now" (GetSpaceBack board), kept up to date as junk results and ticks change so views can
    /// read it on every redraw. See `AppState.safeCleanupPlan(junk:ticked:isProtected:isBrowserRunning:)`.
    private(set) var safeCleanupPlan = SafeCleanupPlan()
    /// `DeletionService.isProtected` answers, remembered per path while the plan is rebuilt per streamed batch.
    private var protectedPathCache: [String: Bool] = [:]
    /// Paths the user unticked while a "Clean safe items" run was checking; nil when none is running.
    /// A rescan during the run ticks every Safe item again, so these stay out whatever the ticks say.
    private(set) var safeCleanVetoes: Set<String>?
    /// Set while a scan resets the junk ticks itself, so the reset isn't taken for the user unticking.
    private var isResettingJunkTicks = false
    private var browserObservers: [NSObjectProtocol] = []

    @Published var installedApps: [InstalledAppItem] = []
    @Published var orphanedGroups: [OrphanedAppDataGroup] = [] { didSet { diskFindingsCache = nil } }

    /// Every file found at the threshold used for the last scan; `largeFiles` is the subset above the current threshold.
    var allLargeFiles: [LargeFileItem] = []
    private var largeFilesScannedThresholdMB: Int64?
    @Published var largeFiles: [LargeFileItem] = [] { didSet { diskFindingsCache = nil } }
    @Published var selectedLargeFileIDs = Set<String>()

    // MARK: Duplicates
    @Published var duplicateGroups: [DuplicateGroup] = [] { didSet { diskFindingsCache = nil } }
    @Published var selectedDuplicateIDs = Set<String>()
    @Published private(set) var duplicateScannedCount = 0
    @Published private(set) var duplicatePhase = ""
    private var duplicateProgress: ScanProgress?

    // MARK: Space Map
    @Published private(set) var spaceRoot: SpaceNode?
    @Published var spaceCurrent: SpaceNode?
    @Published var spaceTarget: SpaceAnalyzer.ScanTarget?
    @Published private(set) var spaceScannedCount = 0
    @Published private(set) var spaceUnreadableCount = 0
    @Published private(set) var spaceMapIsStale = false
    /// When the current map finished, for Disk's "Scanned 2 minutes ago".
    @Published private(set) var spaceScannedAt: Date?
    /// Bumped whenever the (reference-type) tree is mutated so views redraw.
    @Published private(set) var spaceRevision = 0
    private var spaceProgress: ScanProgress?

    // MARK: Smart Review
    @Published var smartItems: [SmartReviewItem] = []
    @Published var selectedSmartIDs = Set<String>()
    @Published private(set) var isScanningSmart = false
    @Published private(set) var isReviewingSmart = false
    @Published private(set) var hasScannedSmart = false
    @Published private(set) var smartScannedCount = 0
    @Published private(set) var smartReviewedCount = 0
    @Published private(set) var smartReviewTotal = 0
    @Published private(set) var smartModelStatus: SmartModelStatus = SmartReviewModel.status()
    private var smartProgress: ScanProgress?

    // MARK: Undo & banners
    /// Settable so the cleanup tray can publish one record for a multi-section clean.
    @Published var lastUndo: UndoRecord?
    /// Opens the support sheet from the sidebar or the About window.
    @Published var showSupportSheet = false

    @Published var statusBanner: String? {
        didSet {
            // Any other message replaces the "Nothing cleaned" info toast and its Rescan action.
            if statusBanner != Self.nothingCleanedText { statusRescanSections = [] }
            bannerUndo = nil
            scheduleStatusDismiss()
        }
    }
    /// An Undo for the current toast that isn't a cleanup (e.g. "Furl won't scan …"). Set after `statusBanner`.
    @Published var bannerUndo: BannerUndo? {
        didSet { if bannerUndo != nil { scheduleStatusDismiss() } }
    }
    /// Set with the "Nothing cleaned" toast (`showNothingCleaned`): it shows an info icon instead of
    /// the check mark, and a Rescan action that rescans these sections.
    @Published private(set) var statusRescanSections: [SidebarSection] = []
    /// The menu bar's status line after "Clean safe items" left everything alone; nil otherwise.
    @Published var safeCleanNote: String?
    /// The Overview's "You got back…" state after its one-click clean; cleared by Undo or the next full scan.
    @Published var lastSafeClean: SafeCleanSummary?
    /// "Clean safe items" progress for the menu bar button and the main window's progress bar.
    @Published private(set) var safeCleanPhase: SafeCleanPhase?
    enum SafeCleanPhase: Equatable { case checking, cleaning }
    /// Items the latest cleanup left alone because they changed since the scan (read by the tray).
    private(set) var lastSkippedCount = 0
    @Published var errorBanner: String? {
        didSet {
            // Any other warning replaces the one the Rescan action belongs to.
            if errorBanner != errorRescanText {
                errorRescanText = nil
                if !errorRescanSections.isEmpty { errorRescanSections = [] }
            }
        }
    }
    /// Sections the warning bar's Rescan action rescans (`showError(_:rescan:)`); empty hides it.
    @Published private(set) var errorRescanSections: [SidebarSection] = []
    private var errorRescanText: String?
    private var statusDismissTask: Task<Void, Never>?

    /// The Trash ledger (Furl's own Trash items). Set by `observeTrashForLedger(store:)`.
    /// Empty Trash only counts these toward "freed", never the user's own Trash contents.
    weak var trashLedgerStore: AutoSweepStore?

    init() {
        let defaults = UserDefaults.standard
        deletionMode = DeletionMode(rawValue: defaults.string(forKey: Keys.deletionMode) ?? "") ?? .moveToTrash
        discoveredProjectRoots = defaults.stringArray(forKey: Keys.discoveredProjectRoots) ?? []
        extraScanRoots = Self.migrateLegacyProjectRoots(defaults)
        excludedScanRoots = defaults.stringArray(forKey: Keys.excludedScanRoots) ?? []
        excludedScanRootSources = defaults.dictionary(forKey: Keys.excludedScanRootSources) as? [String: String] ?? [:]
        let days = defaults.integer(forKey: Keys.staleDays)
        staleDaysThreshold = days > 0 ? days : 30
        let mb = Int64(defaults.integer(forKey: Keys.largeFileThreshold))
        largeFileThresholdMB = mb > 0 ? mb : 100
        // Auto-scan is on unless the user has explicitly turned it off.
        scanOnLaunch = defaults.object(forKey: Keys.scanOnLaunch) == nil ? true : defaults.bool(forKey: Keys.scanOnLaunch)
        duplicateRoots = defaults.stringArray(forKey: Keys.duplicateRoots) ?? DuplicateScanner.defaultRoots()
        // 0 is a real choice (the "100 KB" option), so only fall back to 1 MB when nothing is saved.
        duplicateMinimumMB = defaults.object(forKey: Keys.duplicateMinMB) == nil
            ? 1 : max(0, Int64(defaults.integer(forKey: Keys.duplicateMinMB)))
        smartIgnoredPaths = Set(defaults.stringArray(forKey: Keys.smartIgnored) ?? [])
        smartUseModel = defaults.object(forKey: Keys.smartUseModel) == nil ? true : defaults.bool(forKey: Keys.smartUseModel)
        StatsLedger.shared.$lifetimeFreedBytes.assign(to: &$lifetimeFreedBytes)
    }

    var isScanningAny: Bool {
        isScanningWorktrees || isScanningJunk || isScanningApps || isScanningLargeFiles || isScanningDuplicates
    }

    var hasScannedAnything: Bool {
        hasScannedWorktrees || hasScannedJunk || hasScannedApps || hasScannedLargeFiles || hasScannedDuplicates
    }

    var totalWorktreeReclaimableBytes: Int64 {
        worktrees.filter(\.canAutoSelect).reduce(0) { $0 + $1.sizeBytes }
    }

    var totalJunkReclaimableBytes: Int64 {
        junkItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalOrphanedAppDataBytes: Int64 {
        orphanedGroups.reduce(0) { $0 + $1.totalSizeBytes }
    }

    var totalLargeFilesBytes: Int64 {
        largeFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalDuplicateReclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    /// Total across sections without double counting: an item inside another counted item
    /// (e.g. node_modules inside a merged worktree) only counts once.
    var totalReclaimableBytes: Int64 {
        var entries: [(path: String, bytes: Int64)] = []
        entries += worktrees.filter(\.canAutoSelect).map { ($0.worktreePath, $0.sizeBytes) }
        entries += junkItems.map { ($0.path, $0.sizeBytes) }
        entries += orphanedGroups.flatMap(\.items).map { ($0.path, $0.sizeBytes) }
        entries.sort { $0.path.count < $1.path.count }

        var counted = Set<String>()
        func isInsideCounted(_ path: String) -> Bool {
            var url = URL(fileURLWithPath: path)
            while url.path != "/" {
                if counted.contains(url.path) { return true }
                url.deleteLastPathComponent()
            }
            return false
        }

        var total: Int64 = 0
        for entry in entries where !isInsideCounted(entry.path) {
            counted.insert(entry.path)
            total += entry.bytes
        }
        for group in duplicateGroups {
            if let sample = group.files.last, isInsideCounted(sample.path) { continue }
            total += group.reclaimableBytes
        }
        return total + trashSizeBytes
    }

    // MARK: - Safe now

    func refreshSafeCleanupPlan() {
        var cache = protectedPathCache
        let plan = Self.safeCleanupPlan(
            junk: junkItems, ticked: selectedJunkIDs,
            isProtected: { path in
                if let known = cache[path] { return known }
                let answer = DeletionService.isProtected(path)
                cache[path] = answer
                return answer
            },
            isBrowserRunning: JunkScanner.browserIsRunning(forCachePath:)
        )
        protectedPathCache = cache
        if plan != safeCleanupPlan { safeCleanupPlan = plan }
    }

    /// A browser opening or quitting changes which browser caches can be moved right now.
    func observeBrowsersForSafePlan() {
        guard browserObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            browserObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.junkItems.contains(where: { $0.category == .browserCaches }) else { return }
                    self.refreshSafeCleanupPlan()
                    self.objectWillChange.send()
                }
            })
        }
    }

    /// Starts (`true`) or ends (`false`) collecting the paths the user unticks during a safe clean.
    func trackSafeCleanVetoes(_ on: Bool) {
        safeCleanVetoes = on ? [] : nil
    }

    private func noteSafeCleanVetoes(removed: Set<String>) {
        guard safeCleanVetoes != nil, !isResettingJunkTicks, !removed.isEmpty else { return }
        for item in junkItems where removed.contains(item.id) {
            safeCleanVetoes?.insert(item.path)
        }
    }

    // MARK: - Disk info

    /// Volume info is cheap; Trash size can be large, so it is computed off the main thread.
    func refreshDiskInfo() {
        diskUsage = DiskInfoService.currentDiskUsage()
        Task {
            let size = await Task.detached(priority: .utility) {
                DiskInfoService.trashSize()
            }.value
            self.trashSizeBytes = size
        }
    }

    // MARK: - Scanning

    func scanAll() async {
        lastSafeClean = nil
        refreshDiskInfo()
        fullScanInFlight = true
        async let wt: Void = scanWorktrees()
        async let jk: Void = scanJunk()
        async let ap: Void = scanApps()
        async let lf: Void = scanLargeFiles()
        async let dp: Void = scanDuplicates()
        _ = await (wt, jk, ap, lf, dp)
        noteScanSectionFinished()
    }

    /// `lastScanDate` marks a completed full scan, so stamp it only once every area is idle and no
    /// queued rescan of one is left. `scanAll` returns at once for areas that are already running
    /// (it only queues a rescan), so stamping at its end let the hero show an empty partial
    /// result as "last result from 1 sec ago".
    private func noteScanSectionFinished() {
        let areas: Set<SidebarSection> = [.worktrees, .junk, .apps, .largeFiles, .duplicates]
        guard fullScanInFlight, !isScanningAny, pendingRescans.isDisjoint(with: areas) else { return }
        fullScanInFlight = false
        lastScanDate = Date()
    }

    // MARK: Live results (canvas: "Results still arriving")

    private func beginStream<P>(_ section: SidebarSection, noun: ScanNoun, progress: ScanProgress = ScanProgress(),
                                totals: @escaping @MainActor () -> (count: Int, bytes: Int64),
                                merge: @escaping @MainActor ([P]) -> Void) -> ScanStream<P> {
        liveProgress[section] = progress
        return ScanStream(progress: progress, noun: noun, totals: totals,
                          publish: { [weak self] in self?.liveScans[section] = $0 },
                          merge: merge)
    }

    /// Shows the finished line for 4 s (the stopped line stays until the next scan).
    private func endStream<P>(_ section: SidebarSection, _ stream: ScanStream<P>) {
        let stopped = stream.progress.isCancelled
        let final = stream.finish(stopped: stopped)
        if liveProgress[section] === stream.progress { liveProgress[section] = nil }
        guard !stopped else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.liveScans[section]?.changedAt == final.changedAt { self?.liveScans[section] = nil }
        }
    }

    /// Stop from the live strip: whatever was found stays on screen.
    func stopScan(_ section: SidebarSection) {
        liveProgress[section]?.cancel()
    }

    /// A stopped scan that found nothing must not read as a finished "nothing found": the area goes back
    /// to unscanned, so its screen offers a fresh scan instead of an empty-state verdict. A stopped scan
    /// that found something keeps its partial results on screen.
    nonisolated static func countsAsScanned(stopped: Bool, foundAny: Bool) -> Bool {
        !stopped || foundAny
    }

    func scanWorktrees() async {
        guard !isScanningWorktrees else {
            pendingRescans.insert(.worktrees)
            return
        }
        defer { runPendingRescan(.worktrees) }
        isScanningWorktrees = true
        worktrees = []
        selectedWorktreeIDs = []
        cleanupStamps.worktrees = [:]
        var offered = Set<String>()
        let stream: ScanStream<([WorktreeItem], [String: CleanupStamp])> = beginStream(
            .worktrees, noun: .worktrees,
            totals: { [unowned self] in (worktrees.count, totalWorktreeReclaimableBytes) }
        ) { [weak self] batches in
            guard let self else { return }
            let known = Set(worktrees.map(\.worktreePath))
            let fresh = batches.flatMap(\.0).filter { !known.contains($0.worktreePath) && !isExcluded($0.worktreePath) }
            for batch in batches { cleanupStamps.worktrees.merge(batch.1) { _, new in new } }
            guard !fresh.isEmpty else { return }
            worktrees = (worktrees + fresh).sorted(by: Self.worktreeOrder)
            for item in fresh where offered.insert(item.id).inserted && item.canAutoSelect {
                selectedWorktreeIDs.insert(item.id)
            }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        progress.setPhase("Looking for git repositories")
        let index = await ScanIndexCache.shared.homeIndex(progress: progress)
        if !progress.isCancelled {
            updateDiscoveredProjects(from: index)
            let roots = projectRoots
            // Every result streams in through `batcher`; the list on screen is the result, so anything
            // the user removed mid-scan stays removed.
            _ = await Task.detached(priority: .userInitiated) {
                ScanIndexContext.$index.withValue(index) {
                    WorktreeScanner.scan(roots: roots, progress: progress) { items in
                        batcher.append((items, CleanupStamp.read(items.filter { !$0.isPrunable }.map(\.worktreePath))))
                    }
                }
            }.value
        }
        stream.flush()
        selectedWorktreeIDs.formIntersection(worktrees.map(\.id))
        endStream(.worktrees, stream)
        cleanupStamps.worktreesDate = Date()
        isScanningWorktrees = false
        hasScannedWorktrees = Self.countsAsScanned(stopped: progress.isCancelled, foundAny: !worktrees.isEmpty)
        CleanupTray.shared.reconcile(.worktrees, listed: Set(worktrees.map(\.id)), completed: !progress.isCancelled)
        noteScanSectionFinished()
        refreshDiskInfo()
    }

    /// Same order as `WorktreeScanner.scan`: removable first, then biggest.
    nonisolated private static func worktreeOrder(_ lhs: WorktreeItem, _ rhs: WorktreeItem) -> Bool {
        if lhs.canAutoSelect != rhs.canAutoSelect { return lhs.canAutoSelect && !rhs.canAutoSelect }
        return lhs.sizeBytes > rhs.sizeBytes
    }

    func scanJunk() async {
        guard !isScanningJunk else {
            pendingRescans.insert(.junk)
            return
        }
        defer { runPendingRescan(.junk) }
        isScanningJunk = true
        // Scans at the lowest toolbar choice, so lowering the days later only re-filters.
        let days = min(staleDaysThreshold, Self.staleDaysScanFloor)
        junkScannedStaleDays = nil
        junkItems = []
        heldBackJunk = []
        isResettingJunkTicks = true
        selectedJunkIDs = []
        isResettingJunkTicks = false
        cleanupStamps.junk = [:]
        var offered = Set<String>()
        let stream: ScanStream<([JunkItem], [String: CleanupStamp])> = beginStream(
            .junk, noun: .items,
            totals: { [unowned self] in (junkItems.count, totalJunkReclaimableBytes) }
        ) { [weak self] batches in
            guard let self else { return }
            let known = Set(junkItems.map(\.id))
            let found = batches.flatMap(\.0).filter { !known.contains($0.id) && !isExcluded($0.path) }
            for batch in batches { cleanupStamps.junk.merge(batch.1) { _, new in new } }
            let threshold = staleDaysThreshold
            let relabeled = found.map { $0.relabeled(staleDays: threshold) }
            heldBackJunk += relabeled.filter { !$0.isListed(staleDays: threshold) }
            let fresh = relabeled.filter { $0.isListed(staleDays: threshold) }
            guard !fresh.isEmpty else { return }
            junkItems = (junkItems + fresh).sorted { $0.sizeBytes > $1.sizeBytes }
            // Safe items are checked as they arrive; a later uncheck by the user sticks.
            for item in fresh where offered.insert(item.id).inserted && item.risk == .safe {
                selectedJunkIDs.insert(item.id)
            }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        progress.setPhase("Looking through your home folder")
        let index = await ScanIndexCache.shared.homeIndex(progress: progress)
        if !progress.isCancelled {
            updateDiscoveredProjects(from: index)
            let roots = projectRoots
            // Every result streams in; the list on screen is the result (see scanWorktrees).
            _ = await Task.detached(priority: .userInitiated) {
                ScanIndexContext.$index.withValue(index) {
                    JunkScanner.scan(projectRoots: roots, staleDays: days, progress: progress) { items in
                        batcher.append((items, CleanupStamp.read(junk: items)))
                    }
                }
            }.value
        }
        stream.flush()
        isResettingJunkTicks = true
        selectedJunkIDs.formIntersection(junkItems.map(\.id))
        isResettingJunkTicks = false
        endStream(.junk, stream)
        junkScannedStaleDays = days
        if staleDaysThreshold < days { pendingRescans.insert(.junk) }
        cleanupStamps.junkDate = Date()
        isScanningJunk = false
        hasScannedJunk = Self.countsAsScanned(stopped: progress.isCancelled, foundAny: !junkItems.isEmpty)
        CleanupTray.shared.reconcile(.junk, listed: Set(junkItems.map(\.id)), completed: !progress.isCancelled)
        noteScanSectionFinished()
        refreshDiskInfo()
    }

    func scanApps() async {
        guard !isScanningApps else {
            pendingRescans.insert(.apps)
            return
        }
        defer { runPendingRescan(.apps) }
        isScanningApps = true
        installedApps = []
        orphanedGroups = []
        cleanupStamps.apps = [:]
        let stream: ScanStream<(AppUninstallerService.ScanSnapshot, [String: CleanupStamp])> = beginStream(
            .apps, noun: .apps,
            totals: { [unowned self] in (installedApps.count, installedApps.reduce(0) { $0 + $1.totalSizeBytes }) }
        ) { [weak self] batches in
            guard let self, let latest = batches.last else { return }
            for batch in batches { cleanupStamps.apps.merge(batch.1) { _, new in new } }
            installedApps = latest.0.installedApps
            if !latest.0.orphanedGroups.isEmpty { orphanedGroups = latest.0.orphanedGroups }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        // On a GCD queue, not the cooperative pool: other scanners block pool threads with
        // synchronous I/O, which made cached rescans wait tens of seconds for a thread.
        let (snapshot, stamps) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = AppUninstallerService.scan(progress: progress) { partial in
                    let paths = partial.installedApps.flatMap { [$0.bundlePath] + $0.associatedData.map(\.path) }
                    batcher.append((partial, CleanupStamp.read(paths)))
                }
                let paths = snapshot.installedApps.flatMap { [$0.bundlePath] + $0.associatedData.map(\.path) }
                    + snapshot.orphanedGroups.flatMap { $0.items.map(\.path) }
                continuation.resume(returning: (snapshot, CleanupStamp.read(paths)))
            }
        }
        stream.flush()
        if !progress.isCancelled {
            // Apps already streamed in; keep that list (an app uninstalled mid-scan stays gone) and add leftovers.
            let shown = Set(installedApps.map(\.id))
            installedApps = snapshot.installedApps.filter { shown.contains($0.id) }
            orphanedGroups = snapshot.orphanedGroups
            cleanupStamps.apps.merge(stamps) { _, new in new }
        }
        endStream(.apps, stream)
        isScanningApps = false
        hasScannedApps = Self.countsAsScanned(stopped: progress.isCancelled,
                                              foundAny: !installedApps.isEmpty || !orphanedGroups.isEmpty)
        // Same keys as `TrayItem.app` and `TrayItem.leftover`.
        CleanupTray.shared.reconcile(
            .apps,
            listed: Set(installedApps.map { "app:" + $0.id } + orphanedGroups.flatMap(\.items).map { "data:" + $0.id }),
            completed: !progress.isCancelled
        )
        noteScanSectionFinished()
        refreshDiskInfo()
    }

    func scanLargeFiles() async {
        guard !isScanningLargeFiles else {
            pendingRescans.insert(.largeFiles)
            return
        }
        defer { runPendingRescan(.largeFiles) }
        isScanningLargeFiles = true
        let thresholdMB = largeFileThresholdMB
        let minBytes = thresholdMB * 1_000_000
        allLargeFiles = []
        largeFiles = []
        largeFilesScannedThresholdMB = nil
        cleanupStamps.largeFiles = [:]
        let stream: ScanStream<([LargeFileItem], [String: CleanupStamp])> = beginStream(
            .largeFiles, noun: .files,
            totals: { [unowned self] in (largeFiles.count, totalLargeFilesBytes) }
        ) { [weak self] batches in
            guard let self else { return }
            let known = Set(allLargeFiles.map(\.id))
            let fresh = batches.flatMap(\.0).filter { !known.contains($0.id) && !isExcluded($0.path) }
            for batch in batches { cleanupStamps.largeFiles.merge(batch.1) { _, new in new } }
            guard !fresh.isEmpty else { return }
            allLargeFiles += fresh
            largeFiles = allLargeFiles.filter { $0.sizeBytes > largeFileThresholdMB * 1_000_000 }
                .sorted { $0.sizeBytes > $1.sizeBytes }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        progress.setPhase("Looking through your home folder")
        let index = await ScanIndexCache.shared.homeIndex(progress: progress)
        if !progress.isCancelled {
            // Every result streams in; the list on screen is the result (see scanWorktrees).
            _ = await Task.detached(priority: .userInitiated) {
                ScanIndexContext.$index.withValue(index) {
                    LargeFilesScanner.scan(minimumBytes: minBytes, progress: progress) { items in
                        batcher.append((items, CleanupStamp.read(items.map(\.path))))
                    }
                }
            }.value
        }
        stream.flush()
        endStream(.largeFiles, stream)
        largeFilesScannedThresholdMB = thresholdMB
        // The threshold may have changed while scanning; filter to whatever is current.
        largeFiles = allLargeFiles.filter { $0.sizeBytes > largeFileThresholdMB * 1_000_000 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        if largeFileThresholdMB < thresholdMB {
            // The threshold was lowered while scanning; these results miss the smaller files.
            pendingRescans.insert(.largeFiles)
        }
        selectedLargeFileIDs.formIntersection(Set(largeFiles.map(\.id)))
        isScanningLargeFiles = false
        hasScannedLargeFiles = Self.countsAsScanned(stopped: progress.isCancelled, foundAny: !largeFiles.isEmpty)
        CleanupTray.shared.reconcile(.largeFiles, listed: Set(largeFiles.map(\.id)), completed: !progress.isCancelled)
        noteScanSectionFinished()
        refreshDiskInfo()
    }

    /// Raising the threshold just filters existing results; lowering it requires a rescan.
    private func applyLargeFileThresholdChange(from oldValue: Int64) {
        guard oldValue != largeFileThresholdMB else { return }
        guard let scanned = largeFilesScannedThresholdMB else {
            // First scan still running: make sure it's redone at the lower threshold.
            if isScanningLargeFiles && largeFileThresholdMB < oldValue { pendingRescans.insert(.largeFiles) }
            return
        }
        if largeFileThresholdMB >= scanned {
            largeFiles = allLargeFiles.filter { $0.sizeBytes > largeFileThresholdMB * 1_000_000 }
            selectedLargeFileIDs.formIntersection(Set(largeFiles.map(\.id)))
        } else {
            Task { await scanLargeFiles() }
        }
    }

    func scanDuplicates() async {
        guard !isScanningDuplicates else {
            pendingRescans.insert(.duplicates)
            return
        }
        defer { runPendingRescan(.duplicates) }
        isScanningDuplicates = true
        let roots = duplicateRoots
        let minBytes = duplicateMinimumBytes
        duplicateGroups = []
        cleanupStamps.duplicates = [:]
        let stream: ScanStream<([DuplicateGroup], [String: CleanupStamp])> = beginStream(
            .duplicates, noun: .groups,
            totals: { [unowned self] in (duplicateGroups.count, totalDuplicateReclaimableBytes) }
        ) { [weak self] batches in
            guard let self else { return }
            let known = Set(duplicateGroups.map(\.id))
            let fresh = batches.flatMap(\.0).filter { !known.contains($0.id) }
                .compactMap { group -> DuplicateGroup? in
                    var group = group
                    group.files.removeAll { isExcluded($0.path) }
                    return group.files.count > 1 ? group : nil
                }
            for batch in batches { cleanupStamps.duplicates.merge(batch.1) { _, new in new } }
            guard !fresh.isEmpty else { return }
            duplicateGroups = (duplicateGroups + fresh).sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        duplicateProgress = progress

        let poller = startPolling(progress) { [weak self] p in
            self?.duplicateScannedCount = p.items
            self?.duplicatePhase = p.phase
        }
        let index = await ScanIndexCache.shared.homeIndex(progress: progress)
        if !progress.isCancelled {
            // Every group streams in; the list on screen is the result (see scanWorktrees).
            _ = await Task.detached(priority: .userInitiated) {
                ScanIndexContext.$index.withValue(index) {
                    DuplicateScanner.scan(roots: roots, minimumBytes: minBytes, progress: progress) { groups in
                        batcher.append((groups, CleanupStamp.read(duplicates: groups)))
                    }
                }
            }.value
        }
        stream.flush()
        poller.cancel()
        endStream(.duplicates, stream)
        // Stopped: the groups confirmed so far stay (each is complete on its own).
        let valid = Set(duplicateGroups.flatMap { $0.files.map(\.id) })
        selectedDuplicateIDs.formIntersection(valid)
        hasScannedDuplicates = Self.countsAsScanned(stopped: progress.isCancelled, foundAny: !duplicateGroups.isEmpty)
        CleanupTray.shared.reconcile(.duplicates, listed: valid, completed: !progress.isCancelled)
        duplicateProgress = nil
        isScanningDuplicates = false
        noteScanSectionFinished()
    }

    /// If a rescan was requested mid-scan, start it now so results reflect the latest state on disk.
    private func runPendingRescan(_ section: SidebarSection) {
        guard pendingRescans.remove(section) != nil else { return }
        Task {
            switch section {
            case .worktrees: await scanWorktrees()
            case .junk: await scanJunk()
            case .apps: await scanApps()
            case .largeFiles: await scanLargeFiles()
            case .duplicates: await scanDuplicates()
            case .smartReview: await scanSmartReview()
            case .dashboard, .disk, .processes, .compress, .activity, .find: break
            }
        }
    }

    func cancelDuplicateScan() {
        duplicateProgress?.cancel()
    }

    func addDuplicateRoot() {
        for path in pickFolders(prompt: "Add Folder") where !duplicateRoots.contains(path) {
            duplicateRoots.append(path)
        }
    }

    func removeDuplicateRoot(_ path: String) {
        duplicateRoots.removeAll { $0 == path }
    }

    /// Selects every file except the one to keep in each group.
    func autoSelectDuplicates(keeping rule: DuplicateKeepRule) {
        var selection = Set<String>()
        for group in duplicateGroups {
            guard let keeper = rule.keeper(in: group.files) else { continue }
            for file in group.files where file.id != keeper.id {
                selection.insert(file.id)
            }
        }
        selectedDuplicateIDs = selection
    }

    // MARK: Space Map

    func scanSpace(target: SpaceAnalyzer.ScanTarget? = nil) async {
        if let target { spaceTarget = target }
        if spaceTarget == nil { spaceTarget = SpaceAnalyzer.availableTargets().first }
        guard let target = spaceTarget, !isScanningSpace else { return }

        isScanningSpace = true
        spaceScannedCount = 0
        spaceUnreadableCount = 0
        let path = target.path
        // A different folder or drive: the old map would be misleading while the new one builds.
        if spaceRoot?.path != path {
            spaceRoot = nil
            spaceCurrent = nil
            cleanupStamps.spaceMap = [:]
            spaceRevision += 1
        }
        // A rescan of the same folder keeps its complete map (drill-in, Remove) until the new one is built.
        let keepsOldMap = spaceRoot != nil
        var preview: [SpaceNode] = []
        // A main-actor box: `totals` reads it and the scan sets it, both on the main actor.
        let built = MainActorBox<SpaceNode>()
        let stream: ScanStream<SpaceNode> = beginStream(
            .disk, noun: .items,
            totals: {
                if let built = built.value { return (built.children.filter { !$0.isAggregate }.count, built.sizeBytes) }
                return (preview.count, preview.reduce(0) { $0 + $1.sizeBytes })
            }
        ) { [weak self] leaves in
            // Walks without the shared index (other drives, "/") show the top-level items as each
            // finishes; they become drillable once the whole map is built.
            guard let self else { return }
            preview += leaves
            guard !keepsOldMap else { return }
            let root = SpaceNode(id: path, name: target.name, path: path, isDirectory: true,
                                 sizeBytes: preview.reduce(0) { $0 + $1.sizeBytes },
                                 itemCount: preview.reduce(0) { $0 + $1.itemCount },
                                 children: preview.sorted { $0.sizeBytes > $1.sizeBytes })
            spaceRoot = root
            spaceCurrent = root
            spaceRevision += 1
        }
        let progress = stream.progress
        let batcher = stream.batcher
        spaceProgress = progress
        let poller = startPolling(progress) { [weak self] p in
            self?.spaceScannedCount = p.items
            self?.spaceUnreadableCount = p.unreadable
        }
        // Folders inside home come from the shared index; "/" and other volumes keep their own walk.
        let home = ScanIndexCache.homePath
        let insideHome = path == home || path.hasPrefix(home + "/")
        if insideHome { progress.setPhase("Looking through your home folder") }
        let index = insideHome ? await ScanIndexCache.shared.homeIndex(progress: progress) : nil
        if !progress.isCancelled {
            progress.setPhase("Mapping \(target.name)")
            let (root, stamps) = await Task.detached(priority: .userInitiated) {
                let tree = ScanIndexContext.$index.withValue(index) {
                    SpaceAnalyzer.scan(rootPath: path, progress: progress) { batcher.append($0) }
                }
                return (tree, progress.isCancelled ? [:] : Self.spaceStamps(tree))
            }.value
            if !progress.isCancelled {
                built.value = root
                spaceRoot = root
                cleanupStamps.spaceMap = stamps
                spaceCurrent = root
                spaceUnreadableCount = progress.unreadable
                spaceMapIsStale = false
                spaceScannedAt = Date()
                spaceRevision += 1
            }
        }
        poller.cancel()
        endStream(.disk, stream)
        if progress.isCancelled, !preview.isEmpty, !keepsOldMap {
            // Stopped mid-walk on a folder with no earlier map: the partial top level stays (leaf copies,
            // no stamps for this folder, so nothing on it can be removed), marked stale so a rescan is offered.
            spaceMapIsStale = true
        }
        spaceProgress = nil
        isScanningSpace = false
    }

    func cancelSpaceScan() {
        spaceProgress?.cancel()
    }

    /// Something under the map changed on disk (e.g. items restored from the Trash).
    func markSpaceMapStale() {
        spaceMapIsStale = true
    }

    func scanCustomSpaceFolder() async {
        guard let path = pickFolders(prompt: "Analyze", multiple: false).first else { return }
        let target = SpaceAnalyzer.ScanTarget(
            id: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            systemImage: "folder"
        )
        await scanSpace(target: target)
    }

    /// Moves a space-map item to the Trash (or deletes it) and updates the tree in place.
    func removeSpaceNode(_ node: SpaceNode) async {
        guard !node.isAggregate else { return }
        let result = await delete([CleanupItem(path: node.path)], stamps: cleanupStamps.spaceMap, context: "Space Map")
        applyDeletionResult(result, label: node.name, section: .disk, itemName: node.name)
        guard result.succeededCount > 0 else { return }

        // Detach and subtract its size from every ancestor.
        if let parent = node.parent {
            parent.children.removeAll { $0 === node }
            var ancestor: SpaceNode? = parent
            while let current = ancestor {
                current.sizeBytes -= node.sizeBytes
                current.itemCount -= node.itemCount
                ancestor = current.parent
            }
        }
        if spaceCurrent === node { spaceCurrent = node.parent }
        spaceRevision += 1
    }

    // MARK: Smart Review

    /// Rule pass over the home folder, then (if enabled and available) the on-device model refines
    /// the strongest candidates batch by batch, updating the list as it goes.
    func scanSmartReview() async {
        guard !isScanningSmart && !isReviewingSmart else {
            pendingRescans.insert(.smartReview)
            return
        }
        defer { runPendingRescan(.smartReview) }

        isScanningSmart = true
        smartScannedCount = 0
        smartReviewedCount = 0
        smartReviewTotal = 0
        smartItems = []
        cleanupStamps.smartReview = [:]
        let stream: ScanStream<([SmartReviewItem], [String: CleanupStamp])> = beginStream(
            .smartReview, noun: .files,
            totals: { [unowned self] in (smartItems.count, smartItems.reduce(0) { $0 + $1.sizeBytes }) }
        ) { [weak self] batches in
            guard let self else { return }
            let known = Set(smartItems.map(\.id))
            let fresh = batches.flatMap(\.0).filter { !known.contains($0.id) && !isExcluded($0.path) }
            for batch in batches { cleanupStamps.smartReview.merge(batch.1) { _, new in new } }
            guard !fresh.isEmpty else { return }
            smartItems = (smartItems + fresh).sorted { ($0.ruleScore, $0.sizeBytes) > ($1.ruleScore, $1.sizeBytes) }
        }
        let progress = stream.progress
        let batcher = stream.batcher
        smartProgress = progress
        liveProgress[.smartReview] = progress
        let poller = startPolling(progress) { [weak self] p in
            self?.smartScannedCount = p.items
        }
        let ignored = smartIgnoredPaths
        // Every candidate streams in (batches of 8 and at each top-level folder); the list on screen is the result.
        _ = await Task.detached(priority: .userInitiated) {
            SmartReviewScanner.scan(ignoredPaths: ignored, progress: progress) { items in
                batcher.append((items, CleanupStamp.read(items.map(\.path))))
            }
        }.value
        poller.cancel()
        stream.flush()
        endStream(.smartReview, stream)
        isScanningSmart = false
        selectedSmartIDs.formIntersection(Set(smartItems.map(\.id)))
        hasScannedSmart = Self.countsAsScanned(stopped: progress.isCancelled, foundAny: !smartItems.isEmpty)
        CleanupTray.shared.reconcile(.smartReview, listed: Set(smartItems.map(\.id)), completed: !progress.isCancelled)

        guard !progress.isCancelled else {
            smartProgress = nil
            return
        }
        smartModelStatus = SmartReviewModel.status()
        if smartUseModel, smartModelStatus == .available {
            await runModelReview(progress: progress)
        }
        smartProgress = nil
    }

    /// The model is the slow part, so it reviews the most promising candidates first and caps the total.
    private func runModelReview(progress: ScanProgress) async {
        let maxReviewed = 240
        let queue = smartItems
            .sorted { ($0.ruleScore, $0.sizeBytes) > ($1.ruleScore, $1.sizeBytes) }
            .prefix(maxReviewed)
        let batches = stride(from: 0, to: queue.count, by: SmartReviewModel.batchSize).map {
            Array(queue[$0..<min($0 + SmartReviewModel.batchSize, queue.count)])
        }
        guard !batches.isEmpty else { return }

        isReviewingSmart = true
        smartReviewTotal = queue.count
        defer { isReviewingSmart = false }

        var failures = 0
        for batch in batches {
            if progress.isCancelled { break }
            let verdicts = await SmartReviewModel.review(batch)
            if verdicts.isEmpty { failures += 1 }
            if !verdicts.isEmpty {
                for index in smartItems.indices {
                    if let verdict = verdicts[smartItems[index].id] {
                        smartItems[index].verdict = verdict
                    }
                }
            }
            smartReviewedCount += batch.count
        }
        if failures == batches.count {
            errorBanner = "The on-device model couldn't review these files. Showing rule-based results instead."
        }
    }

    func cancelSmartReview() {
        smartProgress?.cancel()
    }

    /// Selects everything currently labelled likely useless.
    func selectLikelyUselessSmartItems() {
        selectedSmartIDs = Set(smartItems.filter { $0.verdict.label == .junk }.map(\.id))
    }

    /// "This file matters": hide it now and never suggest it again.
    func ignoreSmartItems(_ ids: Set<String>) {
        let paths = smartItems.filter { ids.contains($0.id) }.map(\.path)
        smartIgnoredPaths.formUnion(paths)
        smartItems.removeAll { ids.contains($0.id) }
        selectedSmartIDs.subtract(ids)
    }

    func resetSmartIgnoredPaths() {
        smartIgnoredPaths = []
    }

    func cleanSelectedSmartItems() async {
        let paths = smartItems.filter { selectedSmartIDs.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let result = await delete(paths.map { CleanupItem(path: $0) }, stamps: cleanupStamps.smartReview,
                                  context: "Smart Review")
        applyDeletionResult(result, label: "file(s)", section: .smartReview)
        smartItems.removeAll { !Self.exists($0.path) }
        selectedSmartIDs.formIntersection(Set(smartItems.map(\.id)))
    }

    // MARK: - Scan folders

    /// Refreshes the discovered project list from the home index (cheap: pure index queries).
    private func updateDiscoveredProjects(from index: FileIndex?) {
        guard let index else { return }
        let found = ProjectRootDiscovery.discover(in: index, excluded: excludedScanRoots)
        hasDiscoveredProjects = true
        if found != discoveredProjectRoots { discoveredProjectRoots = found }
    }

    func addExtraScanRoot() {
        for path in pickFolders(prompt: "Also Scan") { addExtraScanRoot(path: path) }
    }

    func addExtraScanRoot(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if !extraScanRoots.contains(standardized) { extraScanRoots.append(standardized) }
    }

    func removeExtraScanRoot(_ path: String) {
        extraScanRoots.removeAll { $0 == path }
    }

    func addExcludedScanRoot() {
        for path in pickFolders(prompt: "Never Scan") { addExcludedScanRoot(path: path) }
    }

    func addExcludedScanRoot(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if !excludedScanRoots.contains(standardized) { excludedScanRoots.append(standardized) }
    }

    func removeExcludedScanRoot(_ path: String) {
        excludedScanRoots.removeAll { $0 == path }
        excludedScanRootSources[path] = nil
    }

    /// One-time move from the old hand-picked "Project Scan Folders": folders outside home become
    /// "Also scan" entries (discovery can't see them); folders inside home are covered by discovery.
    private static func migrateLegacyProjectRoots(_ defaults: UserDefaults) -> [String] {
        var extras = defaults.stringArray(forKey: Keys.extraScanRoots) ?? []
        guard let legacy = defaults.stringArray(forKey: Keys.projectRoots) else { return extras }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for path in legacy {
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            let insideHome = p == home || p.hasPrefix(home + "/")
            if !insideHome && !extras.contains(p) { extras.append(p) }
        }
        defaults.set(extras, forKey: Keys.extraScanRoots)
        defaults.removeObject(forKey: Keys.projectRoots)
        return extras
    }

    private func pickFolders(prompt: String, multiple: Bool = true) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.standardizedFileURL.path }
    }

    // MARK: - Cleanup Actions

    /// Removes the ticked worktrees. Never forced: a worktree with changes is left alone here (only
    /// `removeWorktreeAnyway` removes one). Merged branches go too only when the user ticked
    /// "Also delete the merged branches" in the confirm; unmerged branches are always kept.
    func cleanSelectedWorktrees(deleteMergedBranches: Bool = false) async {
        let targets = Self.bulkWorktreeTargets(worktrees, selected: selectedWorktreeIDs)
        guard !targets.isEmpty else { return }
        // `git worktree remove` deletes for good (never the Trash), so re-check right before:
        // the folder is unchanged since the scan, HEAD is still the scanned commit (a later
        // `git branch -D` must never drop new commits), and it's still clean.
        await removeWorktrees(targets.map { item in
            var check = CleanupItem(path: item.worktreePath)
            check.worktreeCommit = item.commitHash
            check.requireCleanWorktree = true
            // "Commits stay in each repository" must hold for a worktree with no branch too.
            check.requireHeadOnBranch = item.mergeStatus == .detached
            return (item, check)
        }, force: false, deleteMergedBranches: deleteMergedBranches)
    }

    /// What a bulk remove takes from the ticked IDs: only bulk-selectable rows, so a worktree with
    /// changes (or commits on no branch) is dropped even if its ID is still in the selection.
    nonisolated static func bulkWorktreeTargets(_ worktrees: [WorktreeItem], selected: Set<String>) -> [WorktreeItem] {
        worktrees.filter { selected.contains($0.id) && $0.isBulkSelectable }
    }

    /// What "Remove anyway…" lists; nil when git can't prove it.
    nonisolated static func worktreeChanges(_ item: WorktreeItem) async -> WorktreeChangeSnapshot? {
        await Task.detached(priority: .userInitiated) {
            guard !item.isPrunable, !WorktreeScanner.isSymlink(item.worktreePath) else { return nil }
            return WorktreeChangeSnapshot.take(in: item.worktreePath)
        }.value
    }

    /// "Remove anyway…" on one row, after the second confirm. Right before acting it re-checks that
    /// the folder is unchanged since the scan, HEAD is the scanned commit, and the changes are exactly
    /// `confirmed` (what the confirm listed, file by file). The branch is always kept.
    func removeWorktreeAnyway(_ item: WorktreeItem, confirmed: WorktreeChangeSnapshot) async {
        guard item.canRemoveAnyway, !confirmed.status.isEmpty || item.losesCommitsIfRemoved,
              worktrees.contains(where: { $0.id == item.id }) else { return }
        var check = CleanupItem(path: item.worktreePath)
        check.worktreeCommit = item.commitHash
        check.expectedWorktreeChanges = confirmed
        await removeWorktrees([(item, check)], force: true, deleteMergedBranches: false)
    }

    private func removeWorktrees(_ targets: [(item: WorktreeItem, check: CleanupItem)],
                                 force: Bool, deleteMergedBranches: Bool) async {
        isCleaning = true
        defer { isCleaning = false }

        var removed = 0
        var skipped = 0
        let stamps = cleanupStamps.worktrees
        var removedPaths: [String] = []
        var reclaimed: Int64 = 0
        var errors: [String] = []
        defer { cleanupProgress = nil }

        for (index, target) in targets.enumerated() {
            let item = target.item
            let check = target.check
            cleanupProgress = CleanupProgressInfo(
                title: "Removing worktrees", done: index, total: targets.count, current: item.branchName
            )
            // A missing folder has nothing to check: pruning only drops git's record of it.
            let outcome: Result<WorktreeScanner.RemovalOutcome, Error>? = await Task.detached(priority: .userInitiated) {
                guard item.isPrunable || CleanupRecheck.passes(check, stamps: stamps) else { return nil }
                return WorktreeScanner.removeWorktree(item: item, force: force, deleteLocalBranch: deleteMergedBranches)
            }.value
            guard let outcome else {
                skipped += 1
                continue
            }

            switch outcome {
            case .success(let result):
                removed += 1
                removedPaths.append(item.worktreePath)
                reclaimed += result.reclaimedBytes
                if let warning = result.warning {
                    errors.append(warning)
                }
            case .failure(let err):
                errors.append("\(item.branchName): \(err.localizedDescription)")
            }
        }

        noteSkippedSinceScan(skipped, in: "Git Worktrees")
        lastSkippedCount = skipped
        if removed == 0, skipped > 0, errors.isEmpty {
            showNothingCleaned(rescan: [.worktrees])
        }
        if removed > 0 {
            recordFreed(reclaimed, items: removed, category: .worktrees)
            CommunityStatsReporter.shared.cleanupSucceeded()
            ActivityLog.shared.recordPermanent(section: .worktrees, count: removed, bytes: reclaimed,
                                               detail: "\(removed) worktree(s) removed with git worktree remove",
                                               items: removedPaths, skipped: skipped)
            // WorktreesSimple board: "Removed 4 worktrees, freed 4.2 GB." No Undo: it can't be undone.
            statusBanner = Self.withSkipped("Removed \(removed) \(removed == 1 ? "worktree" : "worktrees"), freed \(FileSizeHelper.formatBytes(reclaimed)).", skipped)
        }
        if !errors.isEmpty {
            errorBanner = errors.joined(separator: "\n")
        }
        await scanWorktrees()
    }

    /// "Clean up missing folders": tells git to forget worktrees whose folder is gone.
    func pruneAllWorktrees() async {
        let missing = Set(worktrees.filter(\.isPrunable).map(\.worktreePath))
        let repos = worktrees.map(\.repoPath)
        await Task.detached(priority: .userInitiated) {
            WorktreeScanner.pruneStaleWorktrees(in: repos)
        }.value
        await scanWorktrees()
        let cleaned = missing.subtracting(worktrees.filter(\.isPrunable).map(\.worktreePath)).count
        statusBanner = Self.missingFoldersMessage(cleaned)
    }

    /// WorktreesSimple board: "Cleaned up 1 missing folder. Git no longer lists it."
    nonisolated static func missingFoldersMessage(_ count: Int) -> String {
        switch count {
        case 0: return "No missing folders to clean up."
        case 1: return "Cleaned up 1 missing folder. Git no longer lists it."
        default: return "Cleaned up \(count) missing folders. Git no longer lists them."
        }
    }

    func cleanSelectedJunk() async {
        let items = junkItems.filter { selectedJunkIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        // JunkScanner.clean handles both plain paths and command-based items (Docker, simulators),
        // which have no real path on disk.
        isCleaning = true
        let mode = deletionMode
        let total = items.count
        let title = mode == .moveToTrash ? "Moving to Trash" : "Deleting"
        let progress = ScanProgress()
        cleanupProgress = CleanupProgressInfo(title: title, done: 0, total: total, current: "")
        let poller = startPolling(progress) { [weak self] p in
            self?.cleanupProgress = CleanupProgressInfo(title: title, done: min(p.items, total), total: total, current: p.phase)
        }
        let stamps = cleanupStamps.junk
        let outcome = await Task.detached(priority: .userInitiated) {
            JunkScanner.clean(items, mode: mode, progress: progress, stamps: stamps)
        }.value
        poller.cancel()
        cleanupProgress = nil
        isCleaning = false
        noteSkippedSinceScan(outcome.result.skippedCount, in: "Caches & Junk")

        // A junk item can span several paths; stats count items, not paths.
        applyDeletionResult(outcome.result, label: "item(s)", section: .junk, statsItems: outcome.cleanedIDs.count)
        // Command-based cleanups can't go to the Trash, so their space is freed now even in Trash mode.
        if mode == .moveToTrash {
            let permanentItems = items.filter { outcome.cleanedIDs.contains($0.id) && $0.isPermanent }
            let permanentBytes = permanentItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let permanentCount = permanentItems.count
            recordFreed(permanentBytes, items: permanentCount, category: .junk)
            ActivityLog.shared.recordPermanent(section: .junk, count: permanentCount, bytes: permanentBytes, detail: "")
            if permanentCount > 0 {
                let trashedCount = outcome.result.succeededCount - permanentCount
                let trashedBytes = outcome.result.reclaimedBytes - permanentBytes
                var parts: [String] = []
                if trashedCount > 0 {
                    parts.append("Moved \(trashedCount) item(s) to Trash (\(FileSizeHelper.formatBytes(trashedBytes)))")
                }
                parts.append("Removed \(permanentCount) item(s) permanently (\(FileSizeHelper.formatBytes(permanentBytes)))")
                statusBanner = Self.withSkipped(parts.joined(separator: " · ") + ".", outcome.result.skippedCount)
            }
        }
        // Drop removed items locally instead of rescanning everything.
        junkItems.removeAll { outcome.cleanedIDs.contains($0.id) }
        selectedJunkIDs.formIntersection(Set(junkItems.map(\.id)))
    }

    func emptyTrash() async {
        isCleaning = true
        cleanupProgress = CleanupProgressInfo(title: "Emptying Trash", done: 0, total: 0, current: "")
        defer {
            isCleaning = false
            cleanupProgress = nil
        }
        // Only Furl's own Trash items count toward "freed": the rest of the Trash is the user's.
        let ledger = trashLedgerStore
        ledger?.pruneLedger()
        let ours = ledger?.ledger ?? []
        let result = await Task.detached(priority: .userInitiated) {
            DeletionService.emptyTrash()
        }.value
        if let ledger, !ours.isEmpty {
            let gone = await Task.detached(priority: .userInitiated) {
                ours.filter { !AppState.pathExists($0.trashPath) }
            }.value
            ledger.removeFromLedger(Set(gone.map(\.trashPath)))
            recordFreed(gone.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }, items: gone.filter { ($0.bytes ?? 0) > 0 }.count,
                        category: .trash)
        }
        if result.reclaimedBytes > 0 || result.succeededCount > 0 {
            ActivityLog.shared.recordEmptyTrash(bytes: result.reclaimedBytes, count: result.succeededCount)
            // Trashed items are gone for good now.
            lastUndo = nil
            statusBanner = "Emptied Trash (\(FileSizeHelper.formatBytes(result.reclaimedBytes)) freed)."
        }
        if !result.errors.isEmpty {
            errorBanner = result.errors.joined(separator: "\n")
        }
        refreshDiskInfo()
    }

    func uninstallApp(_ app: InstalledAppItem, includeDataPaths: [String]) async {
        // The app itself must be the one the scan found (not updated, replaced or moved since);
        // otherwise neither it nor its data is touched, and it isn't quit either.
        let stamps = cleanupStamps.apps
        let bundle = CleanupItem(path: app.bundlePath)
        let bundleUnchanged = await Task.detached(priority: .userInitiated) {
            CleanupRecheck.passes(bundle, stamps: stamps)
        }.value
        guard bundleUnchanged else {
            noteSkippedSinceScan(1 + includeDataPaths.count, in: "Apps & Leftovers (uninstall \(app.name))")
            lastSkippedCount = 1 + includeDataPaths.count
            showNothingCleaned(rescan: [.apps])
            return
        }
        let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleIdentifier }
        if stillRunning {
            cleanupProgress = CleanupProgressInfo(title: "Quitting \(app.name)", done: 0, total: 0, current: "")
            let quit = await AppUninstallerService.quitAppIfRunning(bundleIdentifier: app.bundleIdentifier)
            cleanupProgress = nil
            if !quit {
                ErrorLog.shared.redact(app.name)
                errorBanner = "\(app.name) didn't quit (it may have unsaved changes). Quit it manually and try again."
                return
            }
        }

        // Each data folder is checked on its own. An app Furl just quit may have written its own
        // preferences and caches while quitting, so for those only existence and kind are compared.
        let data = includeDataPaths.map { path -> CleanupItem in
            var item = CleanupItem(path: path)
            item.checkModified = !stillRunning
            return item
        }
        let result = await delete([bundle] + data, stamps: stamps, context: "Apps & Leftovers (uninstall)")
        applyDeletionResult(result, label: "item(s) for \(app.name)", section: .apps, statsItems: 1)
        refreshAppsLocally()
    }

    func clearOrphanedItems(_ items: [AppDataItem], label: String) async {
        let paths = items.map(\.path)
        guard !paths.isEmpty else { return }
        let result = await delete(paths.map { CleanupItem(path: $0) }, stamps: cleanupStamps.apps,
                                  context: "Apps & Leftovers")
        applyDeletionResult(result, label: label, section: .apps)
        refreshAppsLocally()
    }

    /// After removing apps or leftovers, drop what no longer exists instead of re-measuring every app.
    private func refreshAppsLocally() {
        installedApps = installedApps
            .filter { Self.exists($0.bundlePath) }
            .map { app in
                let remaining = app.associatedData.filter { Self.exists($0.path) }
                guard remaining.count != app.associatedData.count else { return app }
                return InstalledAppItem(
                    id: app.id, name: app.name, bundleIdentifier: app.bundleIdentifier,
                    version: app.version, bundlePath: app.bundlePath, appSizeBytes: app.appSizeBytes,
                    associatedData: remaining, isRunning: app.isRunning, isAppleApp: app.isAppleApp,
                    lastOpenedDate: app.lastOpenedDate
                )
            }
        orphanedGroups = orphanedGroups.compactMap { group in
            let remaining = group.items.filter { Self.exists($0.path) }
            guard !remaining.isEmpty else { return nil }
            return OrphanedAppDataGroup(id: group.id, appIdentifier: group.appIdentifier, displayName: group.displayName, items: remaining)
        }
    }

    func cleanSelectedLargeFiles() async {
        let paths = largeFiles.filter { selectedLargeFileIDs.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let result = await delete(paths.map { CleanupItem(path: $0) }, stamps: cleanupStamps.largeFiles,
                                  context: "Large Files")
        applyDeletionResult(result, label: "large file(s)", section: .largeFiles)
        allLargeFiles.removeAll { !Self.exists($0.path) }
        largeFiles.removeAll { !Self.exists($0.path) }
        selectedLargeFileIDs.formIntersection(Set(largeFiles.map(\.id)))
    }

    func cleanSelectedDuplicates() async {
        // Never let a whole group go: if every copy is selected, keep the oldest.
        var plan: [(chosen: [DuplicateFile], kept: [DuplicateFile])] = []
        var protectedCount = 0
        for group in duplicateGroups {
            var chosen = group.files.filter { selectedDuplicateIDs.contains($0.id) }
            if chosen.count == group.files.count, let keeper = DuplicateKeepRule.oldest.keeper(in: group.files) {
                chosen.removeAll { $0.id == keeper.id }
                protectedCount += 1
            }
            guard !chosen.isEmpty else { continue }
            let chosenIDs = Set(chosen.map(\.id))
            plan.append((chosen, group.files.filter { !chosenIDs.contains($0.id) }))
        }
        guard !plan.isEmpty else { return }

        // The copy being kept must itself still be there and unchanged (same size and date), or the
        // "duplicates" removed could be the last good copy. If no kept copy passes, the oldest selected
        // copy that does is kept instead (and counted as skipped).
        let stamps = cleanupStamps.duplicates
        let (paths, keptInstead) = await Task.detached(priority: .userInitiated) { () -> ([String], Int) in
            var paths: [String] = []
            var keptInstead = 0
            for group in plan {
                var chosen = group.chosen
                let keeperOK = group.kept.contains { CleanupRecheck.passes(CleanupItem(path: $0.path), stamps: stamps) }
                if !keeperOK {
                    let byAge = chosen.sorted { ($0.modifiedDate ?? .distantFuture) < ($1.modifiedDate ?? .distantFuture) }
                    guard let substitute = byAge.first(where: { CleanupRecheck.passes(CleanupItem(path: $0.path), stamps: stamps) }) else {
                        keptInstead += chosen.count
                        continue
                    }
                    chosen.removeAll { $0.id == substitute.id }
                    keptInstead += 1
                }
                paths += chosen.map(\.path)
            }
            return (paths, keptInstead)
        }.value
        noteSkippedSinceScan(keptInstead, in: "Duplicates (kept copy changed)")
        guard !paths.isEmpty else {
            lastSkippedCount = keptInstead
            if keptInstead > 0 { showNothingCleaned(rescan: [.duplicates]) }
            return
        }

        let result = await delete(paths.map { CleanupItem(path: $0) }, stamps: stamps, context: "Duplicates")
        applyDeletionResult(result, label: "duplicate file(s)", section: .duplicates, extraSkipped: keptInstead)
        pruneDuplicateGroups()
        if protectedCount > 0 {
            errorBanner = "Kept one copy in \(protectedCount) group(s) where every copy was selected."
        }
    }

    private func pruneDuplicateGroups() {
        duplicateGroups = duplicateGroups.compactMap { group in
            var updated = group
            updated.files = group.files.filter { Self.exists($0.path) }
            return updated.files.count > 1 ? updated : nil
        }
        selectedDuplicateIDs.formIntersection(Set(duplicateGroups.flatMap { $0.files.map(\.id) }))
    }

    // MARK: - Undo

    func undoLastCleanup() async {
        guard let record = lastUndo else { return }
        lastUndo = nil
        isCleaning = true
        cleanupProgress = CleanupProgressInfo(title: "Restoring from Trash", done: 0, total: 0, current: record.label)
        defer { cleanupProgress = nil }
        let items = record.items
        let outcome = await Task.detached(priority: .userInitiated) {
            DeletionService.restore(items)
        }.value
        isCleaning = false

        // Only what came back; anything else stays restorable from History.
        ActivityLog.shared.markRestored(trashed: outcome.restoredItems)
        ActivityLog.shared.refreshRestorable()
        if outcome.restored > 0 {
            // Trashed items never counted toward "freed", so there's nothing to subtract.
            statusBanner = "Restored \(outcome.restored) item(s) from the Trash."
        }
        if !outcome.errors.isEmpty {
            errorBanner = outcome.errors.joined(separator: "\n")
        }
        refreshDiskInfo()

        // Bring the affected section(s) back in sync with what's on disk.
        await rescanAfterRestore(sections: [record.section] + record.extraSections)
    }

    // MARK: - Helpers

    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// The one way the main window's sections remove files. Each item is re-checked against `stamps`
    /// (its scan's `cleanupStamps`) first: every path must still exist, be the same kind and carry the
    /// scan's modification date (and size, for duplicates); an item that fails is skipped whole. Each
    /// path is checked once more right before it moves, which matters most in permanent-delete mode.
    /// Skipped items are counted in `skippedCount` and logged (`noteSkippedSinceScan`).
    private func delete(_ items: [CleanupItem], stamps: [String: CleanupStamp], context: String) async -> CleanupResult {
        isCleaning = true
        let mode = deletionMode
        let total = Set(items.flatMap(\.allPaths)).count
        let title = mode == .moveToTrash ? "Moving to Trash" : "Deleting"
        let progress = ScanProgress()
        cleanupProgress = CleanupProgressInfo(title: title, done: 0, total: total, current: "")
        let poller = startPolling(progress) { [weak self] p in
            self?.cleanupProgress = CleanupProgressInfo(title: title, done: min(p.items, total), total: total, current: p.phase)
        }
        let result = await Task.detached(priority: .userInitiated) { () -> CleanupResult in
            let check = CleanupRecheck.verify(items, stamps: stamps)
            let ignoreModified = Set(check.verified.filter { !$0.checkModified }.flatMap(\.allPaths))
            var result = DeletionService.deletePaths(check.verified.flatMap(\.allPaths), mode: mode, progress: progress,
                                                     expected: stamps, ignoreModified: ignoreModified)
            let late = Set(result.skippedPaths)
            result.skippedCount = check.skipped.count
                + check.verified.filter { $0.allPaths.contains(where: late.contains) }.count
            return result
        }.value
        poller.cancel()
        cleanupProgress = nil
        isCleaning = false
        noteSkippedSinceScan(result.skippedCount, in: context)
        return result
    }

    /// Stamps for every real node of a Space Map tree (aggregates stand for many items and are never removed).
    nonisolated static func spaceStamps(_ root: SpaceNode) -> [String: CleanupStamp] {
        var paths: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            if !node.isAggregate { paths.append(node.path) }
            stack += node.children
        }
        return CleanupStamp.read(paths)
    }

    /// Mirrors a background ScanProgress into published values ~4 times a second.
    private func startPolling(_ progress: ScanProgress, update: @escaping @MainActor (ScanProgress) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                update(progress)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Call wherever space really leaves the disk (permanent deletes, worktree removal,
    /// command-based junk, Furl's own Trash items when emptied or expired). Moving to the
    /// Trash doesn't count until those items are emptied. Each call is one StatsLedger event.
    /// `promptSupport` is false for unattended runs (Auto-Sweep), so the support sheet only ever
    /// follows a cleanup the user just did.
    /// `items` is how many things were removed (a cache folder, an app, a worktree each count as one).
    func recordFreed(_ bytes: Int64, items: Int, category: StatsEvent.Category, promptSupport: Bool = true) {
        guard bytes > 0 else { return }
        sessionFreedBytes += bytes
        StatsLedger.shared.recordDiskFreed(bytes, items: items, category: category)
        if promptSupport {
            SupportStore.shared.recordCleanup(bytes: bytes)
        }
    }

    /// `itemName` is for a single named item (Space Map): the toast names it instead of counting.
    /// `extraSkipped`: items left alone before reaching `delete` (e.g. a duplicate kept because the
    /// copy meant to stay had changed); they count as skipped like `result.skippedCount`.
    /// `statsItems`: how many things the community stats count, when that isn't one per path
    /// (an uninstalled app is one item however many folders it had).
    private func applyDeletionResult(_ result: CleanupResult, label: String, section: SidebarSection,
                                     itemName: String? = nil, extraSkipped: Int = 0, statsItems: Int? = nil) {
        let skipped = result.skippedCount + extraSkipped
        lastSkippedCount = skipped
        if result.succeededCount == 0, skipped > 0, result.errors.isEmpty {
            showNothingCleaned(rescan: [section])
        }
        if result.succeededCount > 0 {
            ActivityLog.shared.recordCleanup(section: section, label: label, result: result, mode: deletionMode,
                                             skipped: skipped)
            let verb = deletionMode == .moveToTrash ? "Moved to Trash" : "Deleted"
            // Moving to Trash doesn't free space until the Trash is emptied.
            if deletionMode == .permanent {
                recordFreed(result.reclaimedBytes, items: statsItems ?? result.succeededCount,
                            category: StatsEvent.Category(section: section))
            }
            CommunityStatsReporter.shared.cleanupSucceeded()
            if !result.trashedItems.isEmpty {
                lastUndo = UndoRecord(
                    label: label,
                    items: result.trashedItems,
                    bytes: result.reclaimedBytes,
                    section: section,
                    date: Date()
                )
            }
            let size = FileSizeHelper.formatBytes(result.reclaimedBytes)
            if let itemName {
                statusBanner = Self.withSkipped(deletionMode == .moveToTrash
                    ? "Moved \u{201C}\(itemName)\u{201D} to the Trash (\(size))."
                    : "Deleted \u{201C}\(itemName)\u{201D} (\(size)).", skipped)
            } else {
                statusBanner = Self.withSkipped("\(verb) \(result.succeededCount) \(label) (\(size)).", skipped)
            }
        }
        if !result.errors.isEmpty {
            errorBanner = result.errors.joined(separator: "\n")
        }
        refreshDiskInfo()
    }

    /// Scan folders feed the worktree and junk scans; refresh them shortly after the list changes.
    private func scheduleProjectRootRescan() {
        guard hasScannedWorktrees || hasScannedJunk || scanOnLaunch else { return }
        rootRescanTask?.cancel()
        rootRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            async let wt: Void = self.scanWorktrees()
            async let jk: Void = self.scanJunk()
            _ = await (wt, jk)
        }
    }

    // MARK: - Skipped since the scan (design copy)

    static let nothingCleanedText = "Nothing cleaned. These items changed since the scan, so Furl left them alone."

    /// Appended to a cleanup toast after the freed text.
    static func skippedSentence(_ count: Int) -> String {
        count == 1 ? "1 item changed since the scan and was left alone."
                   : "\(count) items changed since the scan and were left alone."
    }

    /// `banner` plus the skipped sentence when anything was left alone.
    static func withSkipped(_ banner: String, _ skipped: Int) -> String {
        skipped > 0 ? banner + " " + skippedSentence(skipped) : banner
    }

    /// Everything was left alone: the info toast with a Rescan action, and no History row.
    func showNothingCleaned(rescan sections: [SidebarSection]) {
        statusBanner = Self.nothingCleanedText
        statusRescanSections = sections
    }

    func setLastSkipped(_ count: Int) { lastSkippedCount = count }

    /// A warning with a Rescan action for `sections` (none when empty).
    func showError(_ text: String, rescan sections: [SidebarSection]) {
        errorRescanText = sections.isEmpty ? nil : text
        errorBanner = text
        errorRescanSections = sections
    }

    /// The warning bar's Rescan action.
    func rescanFromError() async {
        let sections = errorRescanSections
        errorBanner = nil
        await rescan(sections)
    }

    func setSafeCleanPhase(_ phase: SafeCleanPhase?) {
        safeCleanPhase = phase
        switch phase {
        case .checking: cleanupProgress = CleanupProgressInfo(title: "Checking…", done: 0, total: 0, current: "")
        case .cleaning: cleanupProgress = CleanupProgressInfo(title: "Cleaning…", done: 0, total: 0, current: "")
        case nil: cleanupProgress = nil
        }
    }

    /// The toast's Rescan action.
    func rescanSkipped() async {
        let sections = statusRescanSections
        statusBanner = nil
        safeCleanNote = nil
        await rescan(sections)
    }

    private func rescan(_ sections: [SidebarSection]) async {
        for section in sections {
            switch section {
            case .worktrees: await scanWorktrees()
            case .disk: await scanSpace()
            default: await rescanAfterRestore(sections: [section])
            }
        }
    }

    private func scheduleStatusDismiss() {
        statusDismissTask?.cancel()
        guard statusBanner != nil else { return }
        // Leave more time when the banner offers Undo.
        let seconds = lastUndo != nil || bannerUndo != nil ? 15 : 6
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.statusBanner = nil
        }
    }
}

/// A value shared by main-actor closures that one of them sets later.
@MainActor
private final class MainActorBox<Value> {
    var value: Value?
}

// MARK: - Disk hand-off

enum DiskViewMode: Hashable, Sendable {
    case big, grew
}

extension AppState {
    /// Opens `section` with its search pre-filled, so it shows only what's under one Disk row.
    /// The section's selection is narrowed to that folder too, so its Clean can't reach items
    /// ticked elsewhere that the filter hides.
    func handOff(to section: SidebarSection, filter: String?) {
        pendingHandoffFilter = filter.map { (section, $0) }
        if let folder = filter {
            switch section {
            case .junk:
                selectedJunkIDs = DiskFindings.narrow(selectedJunkIDs, junkItems, to: folder, id: \.id, path: \.path)
            case .worktrees:
                selectedWorktreeIDs = DiskFindings.narrow(selectedWorktreeIDs, worktrees, to: folder, id: \.id, path: \.worktreePath)
            case .duplicates:
                selectedDuplicateIDs = DiskFindings.narrow(selectedDuplicateIDs, duplicateGroups.flatMap(\.files),
                                                           to: folder, id: \.id, path: \.path)
            case .largeFiles:
                selectedLargeFileIDs = DiskFindings.narrow(selectedLargeFileIDs, largeFiles, to: folder, id: \.id, path: \.path)
            default:
                break
            }
        }
        selectedSection = section
    }

    /// What the other sections found, for Disk rows. Rebuilt only after their results change,
    /// not on every AppState change.
    var diskFindings: DiskFindings {
        if let cached = diskFindingsCache { return cached }
        let built = DiskFindings(state: self)
        diskFindingsCache = built
        return built
    }

    /// The filter a Disk row left for `section`, once.
    func takeHandoffFilter(for section: SidebarSection) -> String? {
        guard let pending = pendingHandoffFilter, pending.section == section else { return nil }
        pendingHandoffFilter = nil
        return pending.text
    }
}

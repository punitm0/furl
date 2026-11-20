import Foundation
import ServiceManagement

// MARK: - Models

/// One thing a run did ("Caches & stale node_modules: 12 items, 3.1 GB").
struct AutoSweepRunPart: Codable, Hashable, Sendable {
    var rule: AutoSweepRule
    var itemCount: Int
    var bytes: Int64
    /// Short human description shown in History.
    var detail: String

    init(rule: AutoSweepRule, itemCount: Int, bytes: Int64, detail: String = "") {
        self.rule = rule
        self.itemCount = itemCount
        self.bytes = bytes
        self.detail = detail
    }
}

/// Where something Furl moved to the Trash went, so it can be put back or expired later.
struct TrashLedgerEntry: Codable, Hashable, Sendable {
    let originalPath: String
    let trashPath: String
    let date: Date
    /// Inode of the item when Furl trashed it. Finder reuses Trash names, so the path alone
    /// can later point at something the user trashed; expiry only removes a matching item.
    let fileID: UInt64?
    /// Size when trashed. Counted as freed (StatsLedger) once the item leaves the Trash for good.
    /// Nil for entries recorded before sizes were kept; those are never counted.
    let bytes: Int64?

    init(originalPath: String, trashPath: String, date: Date, fileID: UInt64? = nil, bytes: Int64? = nil) {
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.date = date
        self.fileID = fileID ?? Self.currentFileID(trashPath)
        self.bytes = bytes
    }

    static func currentFileID(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// True while the item at `trashPath` is still the one Furl put there.
    var isStillOurs: Bool {
        guard let fileID else { return false }
        return Self.currentFileID(trashPath) == fileID
    }

    /// True when the item is back at its original location (Put Back, or Furl's undo).
    var wasRestored: Bool {
        guard let fileID else { return false }
        return Self.currentFileID(originalPath) == fileID
    }

    /// Whether the folder holding `trashPath` can be listed. Without Full Disk Access ~/.Trash can't
    /// be read, and then a missing item proves nothing.
    var trashFolderIsReadable: Bool {
        let folder = URL(fileURLWithPath: trashPath).deletingLastPathComponent().path
        return (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }

    var asTrashedItem: TrashedItem {
        TrashedItem(originalPath: originalPath, trashPath: trashPath, sizeBytes: bytes ?? 0, fileID: fileID)
    }
}

enum AutoSweepRule: String, Codable, CaseIterable, Sendable {
    case caches
    case expireTrash
    case downloads
    case compress
    case processes
    case safeClean

    var title: String {
        switch self {
        case .caches: return "Caches & stale node_modules"
        case .expireTrash: return "Old Furl items in the Trash"
        case .downloads: return "Downloads tidy-up"
        case .compress: return "Compressed cold folders"
        case .processes: return "Leftover dev servers"
        case .safeClean: return "Safe items"
        }
    }
}

/// One History entry: an Auto-Sweep run or a "Clean safe items" from the menu bar.
struct AutoSweepRun: Codable, Identifiable, Hashable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case scheduled = "Auto-Sweep"
        case manual = "Run now"
        case menuBar = "Menu bar"
        case notification = "Notification"
        case shortcuts = "Shortcuts"
        case overview = "Overview"
    }

    var id = UUID()
    var date: Date
    var trigger: Trigger
    var parts: [AutoSweepRunPart]
    /// Items moved to the Trash by this run; restoring them undoes the run.
    var trashed: [TrashLedgerEntry]
    var errors: [String]
    var undone = false
    /// Items left alone because they changed since the scan (History shows "N left alone: …").
    /// Optional so older history files still decode.
    var skippedCount: Int? = nil
    /// History: which rule caused an automatic run ("Why: weekly rule …"). Nil for older runs.
    var why: String? = nil
    /// Ask first: the user approved this run from its notification or Review.
    var approved: Bool? = nil

    /// Disk space only. Stopped processes free memory, which their part reports on its own.
    var totalBytes: Int64 { parts.filter { $0.rule != .processes }.reduce(0) { $0 + $1.bytes } }
    var totalItems: Int { parts.reduce(0) { $0 + $1.itemCount } }
    var canUndo: Bool { !undone && !trashed.isEmpty }

    var summary: String {
        let active = parts.filter { $0.itemCount > 0 }
        guard !active.isEmpty else { return "Nothing needed cleaning" }
        return active.map { "\($0.rule.title): \(FileSizeHelper.formatBytes($0.bytes))" }.joined(separator: " · ")
    }
}

enum AutoSweepFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    var id: String { rawValue }
}

// MARK: - Store

/// Menu bar, Auto-Sweep and alert settings, plus the Auto-Sweep History and the ledger of
/// paths Furl itself moved to the Trash. Settings live in UserDefaults; History and the
/// ledger live in ~/Library/Application Support/Furl as JSON and are never sent anywhere.
@MainActor
final class AutoSweepStore: ObservableObject {
    private enum Keys {
        static let showMenuBarItem = "menuBar.showItem"
        static let showFreeSpace = "menuBar.showFreeSpace"
        static let keepRunning = "menuBar.keepRunning"
        /// Legacy on/off switch. Still written (true only for Automatic) so an older Furl never
        /// runs an Ask first setup by itself.
        static let enabled = "autoSweep.enabled"
        static let mode = "autoSweep.mode"
        static let trustMigrated = "autoSweep.trustMigrated"
        static let approvedInARow = "autoSweep.ask.approvedInARow"
        static let offeredAutomatic = "autoSweep.ask.offeredAutomatic"
        static let suggestionDismissed = "autoSweep.suggestion.dismissedAt"
        static let skipNextRun = "autoSweep.skipNextRun.ids"
        static let skipNextRunDate = "autoSweep.skipNextRun.date"
        static let cachesEnabled = "autoSweep.caches.enabled"
        static let cachesDays = "autoSweep.caches.days"
        static let frequency = "autoSweep.frequency"
        static let weekday = "autoSweep.weekday"
        static let hour = "autoSweep.hour"
        static let minute = "autoSweep.minute"
        static let trashEnabled = "autoSweep.trash.enabled"
        static let trashDays = "autoSweep.trash.days"
        static let downloadsEnabled = "autoSweep.downloads.enabled"
        static let compressEnabled = "autoSweep.compress.enabled"
        static let compressDays = "autoSweep.compress.days"
        static let processesEnabled = "autoSweep.processes.enabled"
        static let processesHours = "autoSweep.processes.hours"
        static let notifySummary = "autoSweep.notifySummary"
        static let lowDiskEnabled = "lowDisk.enabled"
        static let lowDiskGB = "lowDisk.thresholdGB"
        static let lowDiskLastAlert = "lowDisk.lastAlert"
        static let scheduleAnchor = "autoSweep.scheduleAnchor"
        static let lastScheduledRun = "autoSweep.lastScheduledRun"
        static let lastDailyRun = "autoSweep.lastDailyRun"
        static let lastRunDate = "autoSweep.lastRunDate"
        static let lastRunBytes = "autoSweep.lastRunBytes"
    }

    private let defaults: UserDefaults

    // MARK: Menu bar
    @Published var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: Keys.showMenuBarItem) } }
    @Published var showFreeSpaceInMenuBar: Bool { didSet { defaults.set(showFreeSpaceInMenuBar, forKey: Keys.showFreeSpace) } }
    /// Keep Furl alive (menu bar only, no Dock icon) after the main window closes.
    @Published var keepRunningInMenuBar: Bool { didSet { defaults.set(keepRunningInMenuBar, forKey: Keys.keepRunning) } }
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published var launchAtLoginError: String?

    // MARK: Auto-Sweep rules
    /// Off / Ask first / Automatic. Set it through `setMode` from the UI so the menu bar setting follows.
    @Published private(set) var mode: AutoSweepMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            defaults.set(mode == .automatic, forKey: Keys.enabled)
            // Turning it on must not instantly "catch up" on a slot that passed before it was on.
            if mode != .off && oldValue == .off { resetScheduleAnchor() }
            if mode != .askFirst { pendingAsk = nil }
            if mode != oldValue { invalidatePreview() }
        }
    }
    /// Ask first or Automatic: the rules run on their schedule.
    var autoSweepEnabled: Bool { mode != .off }

    /// AutoSweepTrust: picking Ask first or Automatic turns on "Keep running in menu bar" (shown as a
    /// caption with a Change link). Open at login stays a separate choice in General.
    func setMode(_ newMode: AutoSweepMode) {
        if newMode != .off {
            showMenuBarItem = true
            keepRunningInMenuBar = true
        }
        mode = newMode
    }

    /// Ask first approvals in a row, and whether Automatic was offered.
    @Published private(set) var trustLadder: AutoSweepTrustLadder {
        didSet {
            defaults.set(trustLadder.approvedInARow, forKey: Keys.approvedInARow)
            defaults.set(trustLadder.offeredAutomatic, forKey: Keys.offeredAutomatic)
        }
    }

    /// Counts an approved Ask first run. Returns true when Furl should offer Automatic now (once).
    func recordApproval(changed: Bool) -> Bool {
        var ladder = trustLadder
        let offer = ladder.recordApproval(changed: changed)
        trustLadder = ladder
        return offer
    }

    /// The Automatic offer was shown; it isn't made again.
    func markOfferedAutomatic() {
        var ladder = trustLadder
        ladder.markOffered()
        trustLadder = ladder
    }

    /// Today's rule settings, for judging an approved ask again right before it runs.
    var rules: AutoSweepRules {
        AutoSweepRules(cachesEnabled: cachesEnabled, cachesUnusedDays: cachesUnusedDays,
                       stopProcessesEnabled: stopProcessesEnabled, expireTrashEnabled: expireTrashEnabled,
                       expireTrashDays: expireTrashDays, tidyDownloadsEnabled: tidyDownloadsEnabled)
    }

    /// Overview suggestion card: "Not now" hides it until two more manual cleans.
    @Published var suggestionDismissedAt: Date? {
        didSet { defaults.set(suggestionDismissedAt, forKey: Keys.suggestionDismissed) }
    }
    // Every rule change makes the next-run preview stale.
    @Published var cachesEnabled: Bool { didSet { defaults.set(cachesEnabled, forKey: Keys.cachesEnabled); invalidatePreview() } }
    @Published var cachesUnusedDays: Int { didSet { defaults.set(cachesUnusedDays, forKey: Keys.cachesDays); invalidatePreview() } }
    @Published var frequency: AutoSweepFrequency { didSet { defaults.set(frequency.rawValue, forKey: Keys.frequency); resetScheduleAnchor() } }
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    @Published var weekday: Int { didSet { defaults.set(weekday, forKey: Keys.weekday); resetScheduleAnchor() } }
    @Published var hour: Int { didSet { defaults.set(hour, forKey: Keys.hour); resetScheduleAnchor() } }
    @Published var minute: Int { didSet { defaults.set(minute, forKey: Keys.minute); resetScheduleAnchor() } }
    /// Permanent rule, unticked by default (see `AutoSweepMigration.expireTrash`).
    @Published var expireTrashEnabled: Bool { didSet { defaults.set(expireTrashEnabled, forKey: Keys.trashEnabled); invalidatePreview() } }
    @Published var expireTrashDays: Int { didSet { defaults.set(expireTrashDays, forKey: Keys.trashDays); invalidatePreview() } }
    @Published var tidyDownloadsEnabled: Bool { didSet { defaults.set(tidyDownloadsEnabled, forKey: Keys.downloadsEnabled); invalidatePreview() } }
    @Published var compressEnabled: Bool { didSet { defaults.set(compressEnabled, forKey: Keys.compressEnabled) } }
    @Published var compressUnusedDays: Int { didSet { defaults.set(compressUnusedDays, forKey: Keys.compressDays) } }
    @Published var stopProcessesEnabled: Bool { didSet { defaults.set(stopProcessesEnabled, forKey: Keys.processesEnabled); invalidatePreview() } }
    @Published var stopProcessesAfterHours: Int { didSet { defaults.set(stopProcessesAfterHours, forKey: Keys.processesHours); invalidatePreview() } }
    @Published var notifyAfterRun: Bool { didSet { defaults.set(notifyAfterRun, forKey: Keys.notifySummary) } }

    // MARK: Low disk
    @Published var lowDiskAlertEnabled: Bool { didSet { defaults.set(lowDiskAlertEnabled, forKey: Keys.lowDiskEnabled) } }
    @Published var lowDiskThresholdGB: Int { didSet { defaults.set(lowDiskThresholdGB, forKey: Keys.lowDiskGB) } }
    var lowDiskLastAlert: Date? {
        get { defaults.object(forKey: Keys.lowDiskLastAlert) as? Date }
        set { defaults.set(newValue, forKey: Keys.lowDiskLastAlert) }
    }

    // MARK: Run state
    @Published private(set) var history: [AutoSweepRun] = []
    @Published private(set) var ledger: [TrashLedgerEntry] = []
    @Published var isRunning = false
    /// Last time any Auto-Sweep job ran (even if it found nothing), for the menu bar summary.
    @Published private(set) var lastRunDate: Date?
    @Published private(set) var lastRunBytes: Int64 = 0

    // MARK: Next-run preview and Ask first
    /// What the next run would take right now (Settings › Automation and the menu bar).
    @Published var nextRunPreview: AutoSweepPreview?
    @Published var isPreviewing = false
    /// Ask first: the run waiting for Clean or Review. In memory only; after a relaunch the
    /// notification's Clean opens the list instead of acting on an old plan.
    @Published var pendingAsk: AutoSweepPreview?
    /// Review is working out a fresh list (Run now, or Clean on an expired ask).
    @Published var isPreparingReview = false

    /// Forgets an ask older than a day or overtaken by the next slot, so Clean can't act on it.
    func dropExpiredAsk(now: Date = Date()) {
        guard let ask = pendingAsk,
              AutoSweepApproval.isExpired(ask, now: now, nextSlot: nextRun?.date) else { return }
        pendingAsk = nil
    }
    /// Opens the item list sheet in Settings › Automation.
    @Published var listRequest: AutoSweepListRequest?
    /// Rule settings changed since `nextRunPreview` was made.
    private(set) var previewIsStale = true

    func invalidatePreview() {
        previewIsStale = true
    }

    /// When Settings or the menu bar appears: reused for an hour unless a rule changed.
    func previewNeedsRefresh(now: Date = Date()) -> Bool {
        guard autoSweepEnabled else { return false }
        guard let preview = nextRunPreview, !previewIsStale else { return true }
        return now.timeIntervalSince(preview.date) > 3600
    }

    /// On the background tick: only shortly before the next slot, so the menu bar is current
    /// then without a full rescan every hour.
    func previewDueBeforeSlot(now: Date = Date()) -> Bool {
        guard autoSweepEnabled, let next = nextRun else { return false }
        let untilSlot = next.date.timeIntervalSince(now)
        guard untilSlot > 0, untilSlot <= 3600 else { return false }
        guard let preview = nextRunPreview, !previewIsStale else { return true }
        return next.date.timeIntervalSince(preview.date) > 3600
    }

    func setPreview(_ preview: AutoSweepPreview?) {
        nextRunPreview = preview
        previewIsStale = false
    }

    // MARK: See list: items skipped on the next run only

    /// Item ids (paths, or process ids) unticked in See list, and the run they apply to.
    var skippedForNextRun: Set<String> {
        Set(defaults.stringArray(forKey: Keys.skipNextRun) ?? [])
    }

    func setSkippedForNextRun(_ ids: Set<String>, runDate: Date?) {
        if ids.isEmpty || runDate == nil {
            defaults.removeObject(forKey: Keys.skipNextRun)
            defaults.removeObject(forKey: Keys.skipNextRunDate)
        } else {
            defaults.set(Array(ids).sorted(), forKey: Keys.skipNextRun)
            defaults.set(runDate, forKey: Keys.skipNextRunDate)
        }
        objectWillChange.send()
    }

    /// The skips for a run starting now, then forgets them. A run before the one they were set for
    /// (a daily chore before Sunday's caches run, say) gets none and leaves them in place.
    func takeSkips(now: Date = Date()) -> Set<String> {
        guard let date = defaults.object(forKey: Keys.skipNextRunDate) as? Date,
              now >= date.addingTimeInterval(-60) else { return [] }
        let ids = skippedForNextRun
        setSkippedForNextRun([], runDate: nil)
        return ids
    }

    /// "Don’t do this again" on a History row: unticks the rules that caused that run.
    func turnOffRules(of run: AutoSweepRun) {
        for part in run.parts where part.itemCount > 0 {
            switch part.rule {
            case .caches: cachesEnabled = false
            case .expireTrash: expireTrashEnabled = false
            case .downloads: tidyDownloadsEnabled = false
            case .compress: compressEnabled = false
            case .processes: stopProcessesEnabled = false
            case .safeClean: break
            }
        }
    }

    /// Whether any rule of this run is still ticked (the History link only shows then).
    func hasRulesOn(of run: AutoSweepRun) -> Bool {
        run.parts.contains { part in
            guard part.itemCount > 0 else { return false }
            switch part.rule {
            case .caches: return cachesEnabled
            case .expireTrash: return expireTrashEnabled
            case .downloads: return tidyDownloadsEnabled
            case .compress: return compressEnabled
            case .processes: return stopProcessesEnabled
            case .safeClean: return false
            }
        }
    }

    var lastScheduledRun: Date? { defaults.object(forKey: Keys.lastScheduledRun) as? Date }
    var lastDailyRun: Date? { defaults.object(forKey: Keys.lastDailyRun) as? Date }
    private var scheduleAnchor: Date { defaults.object(forKey: Keys.scheduleAnchor) as? Date ?? Date() }

    // MARK: - Hooks other stores connect (Processes, Compress)

    /// Stops dev servers left behind by closed AI-agent sessions that have been idle for at least `hours`.
    /// Return what was stopped (bytes = RAM freed). When nil, the rule is hidden.
    /// `onlyIDs`: Ask first, stop only these (nil = every leftover that's due).
    var stopLeftoverProcesses: (@MainActor (_ idleHours: Int, _ onlyIDs: Set<String>?) async -> AutoSweepRunPart?)? {
        didSet { objectWillChange.send() }
    }
    /// What `stopLeftoverProcesses` would stop now, without stopping anything.
    var previewLeftoverProcesses: (@MainActor (_ idleHours: Int) async -> [AutoSweepPreview.Item])?
    /// Losslessly compresses folders not opened for `days`. When nil, the rule is hidden.
    var compressColdFolders: (@MainActor (_ unusedDays: Int) async -> AutoSweepRunPart?)? {
        didSet { objectWillChange.send() }
    }
    /// Extra rows in the menu bar popover (e.g. "5 leftover dev servers · Stop").
    var menuBarProviders: [any MenuBarExtraProvider] = [] {
        didSet { objectWillChange.send() }
    }

    // MARK: - Init

    init(defaults d: UserDefaults = .standard) {
        defaults = d
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) == nil ? fallback : d.integer(forKey: key) }

        showMenuBarItem = bool(Keys.showMenuBarItem, true)
        showFreeSpaceInMenuBar = bool(Keys.showFreeSpace, true)
        keepRunningInMenuBar = bool(Keys.keepRunning, false)
        let migrated = Self.migrateTrustSettings(d)
        mode = migrated.mode
        trustLadder = AutoSweepTrustLadder(approvedInARow: int(Keys.approvedInARow, 0),
                                           offeredAutomatic: bool(Keys.offeredAutomatic, false))
        suggestionDismissedAt = d.object(forKey: Keys.suggestionDismissed) as? Date
        cachesEnabled = bool(Keys.cachesEnabled, true)
        cachesUnusedDays = int(Keys.cachesDays, 30)
        frequency = AutoSweepFrequency(rawValue: d.string(forKey: Keys.frequency) ?? "") ?? .weekly
        weekday = int(Keys.weekday, 1)
        hour = int(Keys.hour, 9)
        minute = int(Keys.minute, 0)
        expireTrashEnabled = migrated.expireTrash
        expireTrashDays = int(Keys.trashDays, 30)
        tidyDownloadsEnabled = bool(Keys.downloadsEnabled, false)
        compressEnabled = bool(Keys.compressEnabled, false)
        compressUnusedDays = int(Keys.compressDays, 90)
        stopProcessesEnabled = bool(Keys.processesEnabled, false)
        stopProcessesAfterHours = int(Keys.processesHours, 1)
        notifyAfterRun = bool(Keys.notifySummary, true)
        lowDiskAlertEnabled = bool(Keys.lowDiskEnabled, false)
        lowDiskThresholdGB = int(Keys.lowDiskGB, 20)
        lastRunDate = d.object(forKey: Keys.lastRunDate) as? Date
        lastRunBytes = Int64(d.integer(forKey: Keys.lastRunBytes))
        if d.object(forKey: Keys.scheduleAnchor) == nil { d.set(Date(), forKey: Keys.scheduleAnchor) }

        history = Self.load([AutoSweepRun].self, from: Self.historyURL) ?? []
        ledger = Self.load([TrashLedgerEntry].self, from: Self.ledgerURL) ?? []
        pruneLedger()
    }

    /// The trust-ladder settings from saved ones: mode from the old on/off switch, and the Permanent
    /// Trash rule (see `AutoSweepMigration`). The result is saved once, so a later change of
    /// defaults can't flip anyone's choice.
    static func migrateTrustSettings(_ d: UserDefaults) -> (mode: AutoSweepMode, expireTrash: Bool) {
        let legacyEnabled: Bool? = d.object(forKey: Keys.enabled) == nil ? nil : d.bool(forKey: Keys.enabled)
        let storedTrash: Bool? = d.object(forKey: Keys.trashEnabled) == nil ? nil : d.bool(forKey: Keys.trashEnabled)
        let mode = AutoSweepMigration.mode(stored: d.string(forKey: Keys.mode), legacyEnabled: legacyEnabled)
        let expireTrash = AutoSweepMigration.expireTrash(stored: storedTrash, legacyEnabled: legacyEnabled)
        if !d.bool(forKey: Keys.trustMigrated) {
            d.set(mode.rawValue, forKey: Keys.mode)
            d.set(expireTrash, forKey: Keys.trashEnabled)
            d.set(true, forKey: Keys.trustMigrated)
        } else if d.string(forKey: Keys.mode) != mode.rawValue {
            // Turned off by an older build after a downgrade: keep it off from now on.
            d.set(mode.rawValue, forKey: Keys.mode)
        }
        return (mode, expireTrash)
    }

    // MARK: - Schedule

    private var scheduleComponents: DateComponents {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        switch frequency {
        case .daily: break
        case .weekly: comps.weekday = weekday
        case .monthly: comps.day = 1
        }
        return comps
    }

    /// Next time the scheduled (caches) job is due. It may be in the past if the Mac was asleep or off.
    var nextScheduledRun: Date? {
        let after = max(lastScheduledRun ?? .distantPast, scheduleAnchor)
        return Calendar.current.nextDate(after: after, matching: scheduleComponents, matchingPolicy: .nextTime)
    }

    /// The daily chores (Trash expiry, Downloads, Compress, processes) run once a day at the same time of day.
    var nextDailyRun: Date? {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let after = max(lastDailyRun ?? .distantPast, scheduleAnchor)
        return Calendar.current.nextDate(after: after, matching: comps, matchingPolicy: .nextTime)
    }

    var isScheduledRunDue: Bool {
        guard autoSweepEnabled, cachesEnabled, let next = nextScheduledRun else { return false }
        return next <= Date()
    }

    var isDailyRunDue: Bool {
        guard autoSweepEnabled, hasDailyRules, let next = nextDailyRun else { return false }
        return next <= Date()
    }

    var hasDailyRules: Bool {
        expireTrashEnabled || tidyDownloadsEnabled
            || (compressEnabled && compressColdFolders != nil)
            || (stopProcessesEnabled && stopLeftoverProcesses != nil)
    }

    func markScheduledRun(_ date: Date) { defaults.set(date, forKey: Keys.lastScheduledRun); objectWillChange.send() }
    func markDailyRun(_ date: Date) { defaults.set(date, forKey: Keys.lastDailyRun); objectWillChange.send() }

    private func resetScheduleAnchor() {
        defaults.set(Date(), forKey: Keys.scheduleAnchor)
        invalidatePreview()
    }

    /// "next Sunday 9:00" style text for the menu bar and Settings.
    var nextRunDescription: String? {
        guard autoSweepEnabled, let next = nextRun?.date else { return nil }
        return Self.relativeDay(next)
    }

    /// When the next run is due and which rules it runs (both when they fall on the same minute).
    var nextRun: (date: Date, scheduled: Bool, daily: Bool)? {
        guard autoSweepEnabled else { return nil }
        let scheduled = cachesEnabled ? nextScheduledRun : nil
        let daily = hasDailyRules ? nextDailyRun : nil
        guard let next = [scheduled, daily].compactMap({ $0 }).min() else { return nil }
        func same(_ date: Date?) -> Bool { date.map { abs($0.timeIntervalSince(next)) < 60 } ?? false }
        return (next, same(scheduled), same(daily))
    }

    /// "Sunday at 9:00", "today at 9:00" (Settings next-run card).
    static func dayAndTime(_ date: Date) -> String {
        "\(dayName(date)) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// "Sunday", "today", "tomorrow" (menu bar card: "Auto-Sweep Sunday").
    static func dayName(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        let days = abs(cal.dateComponents([.day], from: Date(), to: date).day ?? 99)
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday \(time)" }
        let days = abs(cal.dateComponents([.day], from: Date(), to: date).day ?? 99)
        if days < 7 { return "\(date.formatted(.dateTime.weekday(.wide))) \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    // MARK: - History

    func record(_ run: AutoSweepRun, countsAsAutoSweep: Bool) {
        ledger.append(contentsOf: run.trashed)
        saveLedger()
        if countsAsAutoSweep {
            lastRunDate = run.date
            lastRunBytes = run.totalBytes
            defaults.set(run.date, forKey: Keys.lastRunDate)
            defaults.set(run.totalBytes, forKey: Keys.lastRunBytes)
        }
        // Keep History meaningful: a run that found nothing only updates "last run".
        guard run.totalItems > 0 || !run.errors.isEmpty else { return }
        history.insert(run, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        saveHistory()
    }

    func markUndone(_ id: AutoSweepRun.ID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].undone = true
        saveHistory()
        pruneLedger()
    }

    /// After an Undo: the run is undone only once nothing of it is left in the Trash; otherwise it keeps
    /// just the items that didn't come back, so Undo can be tried again for those.
    func markRestored(_ id: AutoSweepRun.ID, remaining: [TrashLedgerEntry]) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        if remaining.isEmpty {
            history[index].undone = true
        } else {
            history[index].trashed = remaining
        }
        saveHistory()
        pruneLedger()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - Trash ledger

    /// Remember items Furl moved to the Trash (from any section), so "Empty Trash items older
    /// than N days" only ever touches Furl's own items.
    func recordTrashed(_ items: [TrashedItem], date: Date = Date()) {
        let known = Set(ledger.map(\.trashPath))
        let new = items.filter { !known.contains($0.trashPath) }
            .map { TrashLedgerEntry(originalPath: $0.originalPath, trashPath: $0.trashPath, date: date, bytes: $0.sizeBytes) }
        guard !new.isEmpty else { return }
        ledger.append(contentsOf: new)
        saveLedger()
    }

    /// Drop entries whose item has left the Trash. One that was emptied (in Finder, say) rather than
    /// put back really left the disk, so its size is recorded as freed, exactly once, here.
    func pruneLedger() {
        let fm = FileManager.default
        var kept: [TrashLedgerEntry] = []
        var emptiedBytes: Int64 = 0
        var emptiedCount = 0
        for entry in ledger {
            // Gone, or replaced by a different item with the same name: no longer ours.
            let present = (try? fm.attributesOfItem(atPath: entry.trashPath)) != nil && entry.isStillOurs
            if present || !entry.trashFolderIsReadable {
                kept.append(entry)
            } else if !entry.wasRestored {
                emptiedBytes += entry.bytes ?? 0
                if (entry.bytes ?? 0) > 0 { emptiedCount += 1 }
            }
        }
        if kept.count != ledger.count {
            ledger = kept
            saveLedger()
        }
        if emptiedBytes > 0 {
            StatsLedger.shared.recordDiskFreed(emptiedBytes, items: emptiedCount, category: .trash)
        }
    }

    func expiredLedgerEntries(olderThanDays days: Int, now: Date = Date()) -> [TrashLedgerEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return ledger.filter { $0.date <= cutoff }
    }

    func removeFromLedger(_ trashPaths: Set<String>) {
        ledger.removeAll { trashPaths.contains($0.trashPath) }
        saveLedger()
    }

    // MARK: - Launch at login

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            launchAtLoginError = nil
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Persistence

    static var supportDirectory: URL {
        return AppIdentity.supportDirectory
    }

    private static var historyURL: URL { supportDirectory.appendingPathComponent("autosweep-history.json") }
    private static var ledgerURL: URL { supportDirectory.appendingPathComponent("trash-ledger.json") }

    private func saveHistory() { Self.save(history, to: Self.historyURL) }
    private func saveLedger() { Self.save(ledger, to: Self.ledgerURL) }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Settings › Automation item list. `review` lets the user untick items and approve the rest.
enum AutoSweepListRequest: Hashable, Identifiable {
    case seeList
    case review
    var id: Self { self }
}

// MARK: - Menu bar extension point

/// A row in the menu bar popover supplied by another feature (e.g. leftover processes).
struct MenuBarExtraRow: Identifiable {
    enum Tint { case blue, orange, green, gray, red }

    let id: String
    var systemImage: String
    var tint: Tint = .blue
    var title: String
    /// Secondary text after the title, e.g. "3.1 GB RAM".
    var detail: String?
    /// Button title, e.g. "Stop". No button when nil.
    var actionTitle: String?
    /// When set, the popover asks for confirmation with this text before running `action`.
    var confirmation: String?
    var action: (@MainActor () async -> Void)?
}

/// Conform a store (e.g. `ProcessesStore`) to this and append it to
/// `AutoSweepStore.menuBarProviders`. Rows are re-read every few seconds while the popover is open.
@MainActor
protocol MenuBarExtraProvider: AnyObject {
    var menuBarRows: [MenuBarExtraRow] { get }
    /// Called when the popover opens so the provider can refresh cheaply.
    func menuBarWillAppear()
}

extension MenuBarExtraProvider {
    func menuBarWillAppear() {}
}

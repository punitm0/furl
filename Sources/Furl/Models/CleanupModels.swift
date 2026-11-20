import Foundation

/// Sidebar groups, in display order. A group is only shown when it has at least one section.
enum SidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    /// SimplerNav: everything that frees disk space, Compress included.
    case freeUpSpace = "Free up space"
    /// SimplerNav: frees memory and ports, not disk.
    case runningNow = "Running now"
    case explore = "Explore"

    var id: String { rawValue }

    /// The overview group renders without a header (it holds a single item).
    var showsHeader: Bool { self != .overview }

    var sections: [SidebarSection] {
        SidebarSection.allCases.filter { $0.group == self }
    }
}

/// Case order is the sidebar order within each group (and the ⌘1… menu order).
enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Overview"
    case smartReview = "Smart Review"
    case junk = "Caches & Junk"
    case worktrees = "Git Worktrees"
    case duplicates = "Duplicates"
    case largeFiles = "Large Files"
    case apps = "Apps & Leftovers"
    case compress = "Compress"
    case processes = "Processes & Sessions"
    /// What's big and What grew (was Space Map and Snapshots).
    case disk = "Disk"
    case activity = "History"
    case find = "Find"

    var id: String { rawValue }

    /// Also reads names saved before Space Map and Snapshots became Disk (History entries), so
    /// they still resolve, to Disk.
    init?(rawValue: String) {
        switch rawValue {
        case "Overview": self = .dashboard
        case "Smart Review": self = .smartReview
        case "Caches & Junk": self = .junk
        case "Git Worktrees": self = .worktrees
        case "Duplicates": self = .duplicates
        case "Large Files": self = .largeFiles
        case "Apps & Leftovers": self = .apps
        case "Compress": self = .compress
        case "Processes & Sessions": self = .processes
        case "Disk", "Space Map", "Snapshots": self = .disk
        case "History": self = .activity
        case "Find": self = .find
        default: return nil
        }
    }

    var group: SidebarGroup {
        switch self {
        case .dashboard: return .overview
        case .smartReview, .junk, .worktrees, .duplicates, .largeFiles, .apps, .compress: return .freeUpSpace
        case .processes: return .runningNow
        case .disk, .activity, .find: return .explore
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .worktrees: return "arrow.triangle.branch"
        case .junk: return "square.3.layers.3d"
        case .apps: return "app.dashed"
        case .largeFiles: return "doc"
        case .disk: return "internaldrive"
        case .activity: return "clock.arrow.circlepath"
        case .duplicates: return "doc.on.doc"
        case .smartReview: return "sparkles"
        case .processes: return "memorychip"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .find: return "magnifyingglass"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending = "Largest First"
    case sizeAscending = "Smallest First"
    case name = "Name"
    case oldest = "Oldest First"
    case newest = "Newest First"

    var id: String { rawValue }

    func areInIncreasingOrder(
        lhsSize: Int64, rhsSize: Int64,
        lhsName: String, rhsName: String,
        lhsDate: Date?, rhsDate: Date?
    ) -> Bool {
        switch self {
        case .sizeDescending: return lhsSize > rhsSize
        case .sizeAscending: return lhsSize < rhsSize
        case .name: return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        case .oldest: return (lhsDate ?? .distantFuture) < (rhsDate ?? .distantFuture)
        case .newest: return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
        }
    }
}

enum DeletionMode: String, CaseIterable, Identifiable, Sendable {
    case moveToTrash = "Move to Trash"
    case permanent = "Delete Permanently"

    var id: String { rawValue }
}

struct DiskUsageInfo: Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let usedBytes: Int64
    let volumeName: String

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    static let empty = DiskUsageInfo(totalBytes: 0, availableBytes: 0, usedBytes: 0, volumeName: "Macintosh HD")
}

// MARK: - Git Worktrees

enum WorktreeMergeStatus: String, Sendable, Hashable {
    case merged = "Merged"
    case squashMerged = "Squash-Merged"
    case unmerged = "Active"
    case detached = "Detached HEAD"
    case main = "Main Worktree"

    var isSafeToClean: Bool {
        self == .merged || self == .squashMerged
    }
}

struct WorktreeItem: Identifiable, Hashable, Sendable {
    let id: String
    let repoPath: String
    let repoName: String
    let worktreePath: String
    let branchName: String
    let baseBranch: String
    let commitHash: String
    let lastCommitDate: Date?
    let mergeStatus: WorktreeMergeStatus
    let isDirty: Bool
    let isLocked: Bool
    let isPrunable: Bool
    let sizeBytes: Int64
    /// Branch tip is identical to the base branch tip: it's "merged" only because no work was committed yet.
    var pointsAtBaseTip: Bool = false
    /// Files in `git status --porcelain --untracked-files=all` when the scan ran; nil when git couldn't
    /// prove anything (then `isDirty` is true and Furl never offers "Remove anyway…", since it can't
    /// list what would be lost).
    var changedFileCount: Int? = 0
    /// No branch (`.detached`) only: a branch contains HEAD, so removing it loses no commits.
    var headOnBranch: Bool = true

    var canAutoSelect: Bool {
        mergeStatus.isSafeToClean && !isDirty && !isLocked && mergeStatus != .main && !pointsAtBaseTip
    }

    /// Commits made here would be lost: it isn't on a branch and no branch contains its HEAD.
    var losesCommitsIfRemoved: Bool {
        mergeStatus == .detached && !headOnBranch && !isPrunable
    }

    /// Can be ticked for a bulk remove. A worktree with changes, or whose commits are on no branch,
    /// never can: only its own "Remove anyway…" removes it, after a second confirm (WorktreesSimple).
    var isBulkSelectable: Bool {
        mergeStatus != .main && !isDirty && !losesCommitsIfRemoved
    }

    /// Offered "Remove anyway…": has changes Furl could list, or commits on no branch. Never the main
    /// worktree, a missing folder or a locked one (git refuses to remove those).
    var canRemoveAnyway: Bool {
        guard mergeStatus != .main, !isPrunable, !isLocked else { return false }
        if isDirty { return (changedFileCount ?? 0) > 0 }
        return losesCommitsIfRemoved
    }

    /// Its branch would go with "Also delete the merged branches". Unmerged branches are always kept.
    var hasDeletableMergedBranch: Bool {
        mergeStatus.isSafeToClean && branchName != "HEAD" && branchName != baseBranch
    }
}

/// One file in `git status --porcelain -z`, for the "Lose N changed files?" confirm.
struct WorktreeChange: Hashable, Sendable {
    enum Kind: String, Sendable { case changed, new, deleted, renamed }
    let path: String
    let kind: Kind

    /// Parses porcelain v1 `-z` output: NUL-separated "XY path" entries; a rename or copy is followed
    /// by its original path as one more entry. Names are taken verbatim (no quoting, no " -> ").
    static func parse(_ porcelain: String) -> [WorktreeChange] {
        var entries = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        var changes: [WorktreeChange] = []
        while let raw = entries.next() {
            let entry = String(raw)
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            let kind: Kind
            if code.contains("R") || code.contains("C") {
                kind = .renamed
                _ = entries.next()
            } else if code == "??" || code.contains("A") {
                kind = .new
            } else if code.contains("D") {
                kind = .deleted
            } else {
                kind = .changed
            }
            changes.append(WorktreeChange(path: path, kind: kind))
        }
        return changes
    }

    /// Paths from a crafted repo may hold control or bidirectional characters that change how the
    /// confirm reads. Shown as visible \u{…} escapes instead.
    static func displaySafe(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .privateUse || category == .unassigned {
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// What "Remove anyway…" showed: the exact status, plus each listed file's type, size and date.
/// Removal goes ahead only if a fresh snapshot is identical, so nothing unseen is lost.
struct WorktreeChangeSnapshot: Sendable, Equatable {
    let status: String
    let fingerprints: [String: String]

    var changes: [WorktreeChange] { WorktreeChange.parse(status) }
}

// MARK: - Junk & Caches

enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case devArtifacts = "Dev Build & Deps"
    case packageCaches = "Package & Tool Caches"
    case systemCaches = "App & System Caches"
    case logsAndCrash = "Logs & Diagnostics"
    case installers = "Old Installers & Archives"
    case dsStore = ".DS_Store Files"
    case aiModels = "Local AI Models"
    case docker = "Docker"
    case simulators = "iOS Simulators"
    case browserCaches = "Browser Caches"
    case mailAttachments = "Mail Attachments"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .devArtifacts: return "hammer"
        case .packageCaches: return "shippingbox"
        case .systemCaches: return "internaldrive"
        case .logsAndCrash: return "doc.text.magnifyingglass"
        case .installers: return "arrow.down.circle"
        case .dsStore: return "eye.slash"
        case .aiModels: return "cpu"
        case .docker: return "shippingbox.and.arrow.backward"
        case .simulators: return "iphone"
        case .browserCaches: return "globe"
        case .mailAttachments: return "paperclip"
        }
    }
}

enum RiskLevel: String, Sendable, Hashable {
    case safe = "Safe"
    case moderate = "Moderate"
    case review = "Review"
}

struct JunkItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let category: JunkCategory
    let risk: RiskLevel
    let sizeBytes: Int64
    let modifiedDate: Date?
    var reason: String
    /// Set for items cleaned by running a tool (docker, simctl) instead of moving `path` to the Trash.
    /// `path` is then a stable pseudo-path (e.g. "docker://build-cache") that doesn't exist on disk.
    /// Use `JunkScanner.clean(_:mode:progress:)` to clean a mix of both kinds.
    var command: JunkCommand? = nil
    /// More files that belong to this item and go to the Trash together with `path` (e.g. an Ollama model's blobs).
    var extraPaths: [String] = []
    /// When the item was last used, if the tool records it (Ollama, simulator runtimes).
    var lastUsedDate: Date? = nil
    /// Listed only once untouched for the "Dependencies count as unused after" days (small dependency
    /// folders, archives in Downloads). The scan finds them at a lower floor so the toolbar can re-filter.
    var listedOnlyWhenUnused = false
    /// For project build folders: the project's name, so the reason can follow the "unused after" days.
    var projectName: String? = nil

    /// The same item with its reason judged against `staleDays` ("Unused for 41 days in web"), not the scan's floor.
    func relabeled(staleDays: Int, now: Date = Date()) -> JunkItem {
        guard let projectName else { return self }
        let days = modifiedDate.map { Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0 } ?? 0
        var item = self
        item.reason = JunkScanner.devArtifactReason(daysOld: days, staleDays: staleDays, projectName: projectName)
        return item
    }

    /// Whether the list shows this item when dependencies count as unused after `staleDays` days.
    func isListed(staleDays: Int, now: Date = Date()) -> Bool {
        guard listedOnlyWhenUnused else { return true }
        guard let modifiedDate else { return true }
        let days = Calendar.current.dateComponents([.day], from: modifiedDate, to: now).day ?? 0
        return days >= staleDays
    }

    /// Cleaning can't be undone: the tool deletes it directly, it never goes to the Trash.
    var isPermanent: Bool { command != nil }
}

// MARK: - App Uninstaller & Orphaned Data

enum AppDataLocation: String, Sendable, Hashable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case savedState = "Saved State"
    case logs = "Logs"
    case webKit = "WebKit"
    case httpStorages = "HTTP Storages"
}

struct AppDataItem: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let location: AppDataLocation
    let sizeBytes: Int64
    let modifiedDate: Date?
    /// Exact bundle-ID / app-name match. Looser matches (e.g. a sibling app's prefs) aren't preselected.
    var isStrongMatch: Bool = true

    /// Caches, window state and logs: the app makes them again. Settings and app data don't come back.
    var rebuildsItself: Bool {
        switch location {
        case .caches, .savedState, .logs, .webKit, .httpStorages: return true
        case .applicationSupport, .preferences, .containers, .groupContainers: return false
        }
    }

    /// Rated Safe only when it's an exact match and only holds data the app rebuilds.
    var isSafeToRemove: Bool { isStrongMatch && rebuildsItself }
}

struct InstalledAppItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let version: String
    let bundlePath: String
    let appSizeBytes: Int64
    let associatedData: [AppDataItem]
    let isRunning: Bool
    let isAppleApp: Bool
    /// When the app was last opened (Spotlight's kMDItemLastUsedDate); nil when macOS doesn't know.
    var lastOpenedDate: Date? = nil

    var dataSizeBytes: Int64 {
        associatedData.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalSizeBytes: Int64 {
        appSizeBytes + dataSizeBytes
    }
}

struct OrphanedAppDataGroup: Identifiable, Hashable, Sendable {
    let id: String
    let appIdentifier: String
    let displayName: String
    let items: [AppDataItem]

    var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var latestModified: Date? {
        items.compactMap(\.modifiedDate).max()
    }

    /// Every folder matched the removed app's ID exactly. Otherwise the group is Furl's best guess,
    /// shows "Possible match" and is never ticked for the user.
    var isSureMatch: Bool {
        !items.isEmpty && items.allSatisfy(\.isStrongMatch)
    }

    /// "Sketch3" for a sure match; the raw ID for a guess, so the user sees what was matched.
    var shownName: String {
        guard isSureMatch else { return appIdentifier }
        if let cut = displayName.range(of: " (") { return String(displayName[..<cut.lowerBound]) }
        return displayName
    }
}

// MARK: - Large Files

enum LargeFileKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case diskImage = "Disk Images"
    case archive = "Archives"
    case media = "Video & Audio"
    case modelOrData = "Models & Data"
    case other = "Other"

    var id: String { rawValue }
}

struct LargeFileItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let modifiedDate: Date?
    let kind: LargeFileKind
}

// MARK: - Action Result

/// Where a cleaned item went in the Trash, so it can be put back.
struct TrashedItem: Sendable, Hashable {
    let originalPath: String
    let trashPath: String
    /// Size when it was trashed, so the Trash ledger can count it as freed once it's emptied.
    var sizeBytes: Int64 = 0
    /// Inode of the item in the Trash. Finder reuses Trash names, so a restore only moves an item
    /// whose inode still matches (see `DeletionService.restore`). nil for records saved without one.
    var fileID: UInt64? = nil
}

struct CleanupResult: Sendable {
    let succeededCount: Int
    let failedCount: Int
    let reclaimedBytes: Int64
    let errors: [String]
    var trashedItems: [TrashedItem] = []
    /// Paths left alone because they no longer matched the scan (gone, other kind, changed).
    var skippedPaths: [String] = []
    /// Items (not paths) left alone for that reason; set by the caller that knows what an item is.
    var skippedCount = 0
}

/// A cleanup that moved items to the Trash and can be reversed.
struct UndoRecord: Sendable {
    let label: String
    let items: [TrashedItem]
    let bytes: Int64
    let section: SidebarSection
    let date: Date
    /// More sections touched by the same cleanup (the tray); all are rescanned after Undo.
    var extraSections: [SidebarSection] = []
}

// MARK: - Duplicates

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let modifiedDate: Date?
    /// Bytes not shared with APFS clones. 0 means this copy is a clone and removing it frees nothing.
    let privateBytes: Int64

    var isClone: Bool { privateBytes == 0 }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let sizeBytes: Int64
    var files: [DuplicateFile]

    /// Space freed by keeping the copy that costs least to keep (e.g. a clone) and removing the rest.
    var reclaimableBytes: Int64 {
        let privates = files.map(\.privateBytes)
        return privates.reduce(0, +) - (privates.min() ?? 0)
    }
}

enum DuplicateKeepRule: String, CaseIterable, Identifiable, Sendable {
    case oldest = "Keep Oldest"
    case newest = "Keep Newest"
    case shortestPath = "Keep Shortest Path"

    var id: String { rawValue }

    /// The file to keep from a group under this rule.
    func keeper(in files: [DuplicateFile]) -> DuplicateFile? {
        switch self {
        case .oldest:
            return files.min { ($0.modifiedDate ?? .distantFuture) < ($1.modifiedDate ?? .distantFuture) }
        case .newest:
            return files.max { ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast) }
        case .shortestPath:
            return files.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        }
    }
}

// MARK: - Smart Review

enum SmartLabel: String, CaseIterable, Identifiable, Sendable, Hashable {
    case junk = "Likely Useless"
    case maybe = "Maybe"
    case keep = "Keep"

    var id: String { rawValue }
}

enum SmartVerdictSource: String, Sendable, Hashable {
    case model = "On-device AI"
    case rules = "Rules"
}

struct SmartVerdict: Sendable, Hashable {
    let label: SmartLabel
    /// 0–100.
    let confidence: Int
    let reason: String
    let source: SmartVerdictSource
}

/// A file the Smart Review thinks might be clutter, with the facts that led there.
struct SmartReviewItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let createdDate: Date?
    let modifiedDate: Date?
    /// When the file was last opened (Spotlight's kMDItemLastUsedDate). nil = never opened or unknown.
    let lastOpenedDate: Date?
    /// Host the file was downloaded from, if macOS recorded it.
    let downloadedFrom: String?
    /// 0–100 from the rule pass; higher means more likely clutter.
    let ruleScore: Int
    /// Short human-readable facts, e.g. "Not opened in 2 years".
    let signals: [String]
    var verdict: SmartVerdict

    var displayFolder: String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

enum SmartModelStatus: Equatable, Sendable {
    case available
    case unavailable(Reason)

    /// Why Apple's on-device model can't be used. Smart Review falls back to rules in every case.
    enum Reason: String, CaseIterable, Sendable, Hashable {
        /// Intel Mac or otherwise not eligible for Apple Intelligence.
        case deviceNotEligible
        /// Eligible, but Apple Intelligence is turned off in System Settings.
        case appleIntelligenceNotEnabled
        /// Turned on, but macOS is still downloading or preparing the model.
        case modelNotReady
        /// Running macOS older than 26 (or built without the FoundationModels SDK).
        case osTooOld
        /// Apple Intelligence isn't offered for the device language or region.
        case unsupportedLanguage
        /// Unavailable for a reason this build doesn't know about.
        case other

        /// States that can resolve themselves while the app is open, so it's worth re-checking.
        var mayResolveSoon: Bool {
            self == .modelNotReady || self == .appleIntelligenceNotEnabled
        }
    }

    var unavailableReason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Scan progress

/// Thread-safe counter + cancellation flag shared between a background scan and the UI.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _items = 0
    private var _unreadable = 0
    private var _cancelled = false
    private var _phase = ""
    private var _stepsDone = 0
    private var _stepsTotal = 0
    private var _current = ""

    /// Determinate progress for the live strip: `done` of `total` known units (checks, groups, folders).
    /// Leave `total` at 0 while the total is unknown; the strip then shows an indeterminate bar.
    func setSteps(done: Int, total: Int) {
        lock.lock(); _stepsDone = done; _stepsTotal = total; lock.unlock()
    }

    func advanceStep(_ count: Int = 1) {
        lock.lock(); _stepsDone += count; lock.unlock()
    }

    /// The folder or item being looked at right now (shown truncated in the live strip).
    func setCurrent(_ path: String) {
        lock.lock(); _current = path; lock.unlock()
    }

    func addItems(_ count: Int = 1) {
        lock.lock(); _items += count; lock.unlock()
    }

    func addUnreadable() {
        lock.lock(); _unreadable += 1; lock.unlock()
    }

    func setPhase(_ phase: String) {
        lock.lock(); _phase = phase; lock.unlock()
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    var items: Int { lock.lock(); defer { lock.unlock() }; return _items }
    var unreadable: Int { lock.lock(); defer { lock.unlock() }; return _unreadable }
    var phase: String { lock.lock(); defer { lock.unlock() }; return _phase }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }
    /// 0...1 once a total is known, nil while it isn't.
    var fraction: Double? {
        lock.lock(); defer { lock.unlock() }
        guard _stepsTotal > 0 else { return nil }
        return min(1, Double(_stepsDone) / Double(_stepsTotal))
    }
}

/// Collects partial results from a background scanner so the main actor can merge them in batches
/// (see `ScanStream`). Scanners call `append` from any thread; nothing here touches the UI.
final class ScanBatcher<Payload>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Payload] = []

    func append(_ payload: Payload) {
        lock.lock(); pending.append(payload); lock.unlock()
    }

    func drain() -> [Payload] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }
}

// MARK: - Space Map

/// A folder or file in the space map. Built off the main thread, then only touched on the main actor.
final class SpaceNode: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let isPackage: Bool
    /// Stand-in for many small items merged together.
    let isAggregate: Bool
    var sizeBytes: Int64
    var itemCount: Int
    var children: [SpaceNode]
    weak var parent: SpaceNode?

    init(
        id: String, name: String, path: String,
        isDirectory: Bool, isPackage: Bool = false, isAggregate: Bool = false,
        sizeBytes: Int64, itemCount: Int, children: [SpaceNode] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isAggregate = isAggregate
        self.sizeBytes = sizeBytes
        self.itemCount = itemCount
        self.children = children
        for child in children { child.parent = self }
    }

    var canDrillIn: Bool {
        isDirectory && !isAggregate && !children.isEmpty
    }

    /// Chain from the root down to this node.
    var ancestry: [SpaceNode] {
        var chain: [SpaceNode] = [self]
        var current = parent
        while let node = current {
            chain.insert(node, at: 0)
            current = node.parent
        }
        return chain
    }
}

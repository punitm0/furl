import CoreServices
import Foundation

/// Where a Find result / Inspector item came from. Decides how "Remove" is carried out.
enum InspectorSource: String, CaseIterable, Identifiable, Sendable, Hashable {
    case junk = "Caches & Junk"
    case worktree = "Worktrees"
    case largeFile = "Large Files"
    case duplicate = "Duplicates"
    case leftover = "Leftovers"
    case app = "Apps"
    case smartReview = "Smart Review"

    var id: String { rawValue }

    var section: SidebarSection {
        switch self {
        case .junk: return .junk
        case .worktree: return .worktrees
        case .largeFile: return .largeFiles
        case .duplicate: return .duplicates
        case .leftover, .app: return .apps
        case .smartReview: return .smartReview
        }
    }

    var systemImage: String {
        switch self {
        case .leftover: return "tray.full"
        case .app: return "app"
        default: return section.systemImage
        }
    }
}

/// How sure Furl is that removing the item is harmless.
enum InspectorSafety: Sendable, Hashable {
    case safe
    case review
    case caution

    var title: String {
        switch self {
        case .safe: return "Safe to remove"
        case .review: return "Check before removing"
        case .caution: return "Be careful"
        }
    }

    var systemImage: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .review: return "eye"
        case .caution: return "exclamationmark.triangle"
        }
    }
}

/// Everything the Inspector shows about one scan result, independent of which scan found it.
struct InspectorItem: Identifiable, Hashable, Sendable {
    /// `source` + the source item's id, unique across all results.
    let id: String
    let source: InspectorSource
    /// The source item's own id (junk id, worktree id, …) used to route actions.
    let sourceID: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let modifiedDate: Date?
    /// When the item was last used, if known up front (tools, Spotlight). The Inspector looks it up otherwise.
    let lastUsedDate: Date?
    /// Short kind label, e.g. "Dev Build & Deps" or "Disk Image".
    let kind: String
    let whyFlagged: String
    let safety: InspectorSafety
    let safetyNote: String
    let rebuild: String
    /// The path doesn't exist on disk (Docker, simulators) or removal can't go to the Trash.
    let isPermanent: Bool
    /// Path is a real file system location that Finder can reveal.
    let isOnDisk: Bool
    /// "Remove" isn't offered (e.g. the main worktree, Apple apps).
    let canRemove: Bool
    /// Extra words matched by Find (branch, repo, bundle id…).
    let searchExtras: String

    var displayFolder: String {
        guard isOnDisk else { return path }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path.abbreviatingHome
    }

    var displayPath: String { isOnDisk ? path.abbreviatingHome : path }
}

extension String {
    /// Replaces the home folder prefix with "~".
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

// MARK: - Building items from scan results

extension InspectorItem {
    init(junk item: JunkItem) {
        let safety: InspectorSafety
        let note: String
        switch item.risk {
        case .safe:
            safety = .safe
            note = "Rated Safe: nothing you made lives here."
        case .moderate:
            safety = .review
            note = "Rated Moderate: removing it is harmless, but rebuilding it takes time or bandwidth."
        case .review:
            safety = .caution
            note = "Rated Review: it may hold something you want to keep. Have a look first."
        }
        self.init(
            id: "junk:\(item.id)", source: .junk, sourceID: item.id,
            name: item.name, path: item.path, sizeBytes: item.sizeBytes,
            modifiedDate: item.modifiedDate, lastUsedDate: item.lastUsedDate,
            kind: item.category.rawValue,
            whyFlagged: item.reason,
            safety: safety,
            safetyNote: item.isPermanent ? note + " It's removed by its own tool and can't be put back from the Trash." : note,
            rebuild: Self.rebuildText(for: item.category),
            isPermanent: item.isPermanent,
            isOnDisk: item.command == nil,
            canRemove: true,
            searchExtras: item.category.rawValue
        )
    }

    private static func rebuildText(for category: JunkCategory) -> String {
        switch category {
        case .devArtifacts: return "Your next build or package install (npm install, swift build, Xcode) recreates it."
        case .packageCaches: return "The package manager downloads it again the next time it's needed."
        case .systemCaches: return "The app recreates its cache as you use it. The first launch may be a little slower."
        case .logsAndCrash: return "Nothing needs it back. New logs are written as apps run."
        case .installers: return "Nothing. Download it again from its source if you ever need it."
        case .dsStore: return "Finder recreates it the next time you open the folder (window size and icon positions reset)."
        case .aiModels: return "Pull or download the model again. Large models can take a while."
        case .docker: return "Docker rebuilds or pulls it again on the next build or run."
        case .simulators: return "Xcode downloads the runtime again when a project needs it."
        case .browserCaches: return "The browser saves pages and images again as you browse. Sites may load a little slower at first."
        case .mailAttachments: return "Mail opens the attachment from the email again when you need it."
        }
    }

    init(worktree item: WorktreeItem) {
        let why: String
        switch item.mergeStatus {
        case .merged: why = "Branch \(item.branchName) is merged into \(item.baseBranch)."
        case .squashMerged: why = "Branch \(item.branchName) was squash-merged into \(item.baseBranch)."
        case .unmerged: why = "Branch \(item.branchName) has work that isn't in \(item.baseBranch) yet. Listed, not flagged."
        case .detached: why = "Checked out at a commit, not a branch (detached HEAD)."
        case .main: why = "The repository's main working copy. Listed, not flagged."
        }
        let safety: InspectorSafety
        let note: String
        if item.mergeStatus == .main {
            safety = .caution; note = "This is the repository itself. Furl never removes it."
        } else if item.isDirty {
            safety = .caution; note = "Has uncommitted changes, or Furl couldn't check it. Removing it could lose work."
        } else if item.isLocked {
            safety = .caution; note = "The worktree is locked in Git."
        } else if item.pointsAtBaseTip {
            safety = .review; note = "Looks merged only because nothing was committed on it yet. Someone may be about to use it."
        } else if item.canAutoSelect {
            safety = .safe; note = "Clean and merged: every commit is already in \(item.baseBranch)."
        } else {
            safety = .review; note = "Not merged yet. Removing it keeps the branch, but check you're done with it."
        }
        self.init(
            id: "worktree:\(item.id)", source: .worktree, sourceID: item.id,
            name: URL(fileURLWithPath: item.worktreePath).lastPathComponent, path: item.worktreePath,
            sizeBytes: item.sizeBytes, modifiedDate: item.lastCommitDate, lastUsedDate: nil,
            kind: "Git worktree · \(item.mergeStatus.rawValue)",
            whyFlagged: why,
            safety: safety, safetyNote: note,
            rebuild: "Run git worktree add to check the branch out again. Commits stay in \(item.repoName).",
            isPermanent: true, isOnDisk: true,
            canRemove: item.mergeStatus != .main && !item.isDirty && !item.isLocked,
            searchExtras: "\(item.repoName) \(item.branchName)"
        )
    }

    init(largeFile item: LargeFileItem, thresholdMB: Int64) {
        let rebuild: String
        switch item.kind {
        case .diskImage: rebuild = "Nothing. Download the disk image again if you still need it."
        case .archive: rebuild = "Nothing. If you've already extracted it, the extracted files stay."
        case .media: rebuild = "Nothing. This may be your only copy unless it's backed up."
        case .modelOrData: rebuild = "Download or regenerate it from wherever it came from."
        case .all, .other: rebuild = "Nothing rebuilds it automatically."
        }
        self.init(
            id: "large:\(item.id)", source: .largeFile, sourceID: item.id,
            name: item.name, path: item.path, sizeBytes: item.sizeBytes,
            modifiedDate: item.modifiedDate, lastUsedDate: nil,
            kind: item.kind == .all ? "Large file" : item.kind.rawValue,
            whyFlagged: "Bigger than \(FileSizeHelper.formatBytes(thresholdMB * 1_000_000)), your Large Files threshold.",
            safety: .review,
            safetyNote: "Furl can't tell whether you still need it. It's listed because of its size.",
            rebuild: rebuild,
            isPermanent: false, isOnDisk: true, canRemove: true,
            searchExtras: item.kind.rawValue
        )
    }

    init(duplicate file: DuplicateFile, group: DuplicateGroup) {
        let others = group.files.filter { $0.id != file.id }
        let otherList = others.prefix(2).map { $0.path.abbreviatingHome }.joined(separator: ", ")
        let note = file.isClone
            ? "This copy is an APFS clone, so removing it frees almost nothing."
            : "\(others.count) identical cop\(others.count == 1 ? "y stays" : "ies stay"). Furl never removes the last copy."
        self.init(
            id: "dup:\(file.id)", source: .duplicate, sourceID: file.id,
            name: file.name, path: file.path, sizeBytes: file.privateBytes,
            modifiedDate: file.modifiedDate, lastUsedDate: nil,
            kind: "Duplicate · \(group.files.count) copies",
            whyFlagged: "Matches \(others.count) other file\(others.count == 1 ? "" : "s") byte for byte.",
            safety: file.isClone ? .review : .safe,
            safetyNote: note,
            rebuild: others.isEmpty ? "Nothing." : "Nothing needs to: the same file is still at \(otherList).",
            isPermanent: false, isOnDisk: true, canRemove: true,
            searchExtras: ""
        )
    }

    init(leftover item: AppDataItem, group: OrphanedAppDataGroup) {
        self.init(
            id: "leftover:\(item.id)", source: .leftover, sourceID: item.id,
            name: item.name, path: item.path, sizeBytes: item.sizeBytes,
            modifiedDate: item.modifiedDate, lastUsedDate: nil,
            kind: "App leftover · \(item.location.rawValue)",
            whyFlagged: "Belongs to \(group.displayName), which is no longer installed.",
            safety: item.isStrongMatch ? .safe : .review,
            safetyNote: item.isStrongMatch
                ? "Matched exactly by bundle ID, and the app is gone."
                : "Matched loosely by name. It might belong to a related app that's still installed.",
            rebuild: "Recreated if you install \(group.displayName) again (your old settings won't come back).",
            isPermanent: false, isOnDisk: true, canRemove: true,
            searchExtras: "\(group.displayName) \(group.appIdentifier)"
        )
    }

    init(app: InstalledAppItem) {
        let safety: InspectorSafety
        let note: String
        if app.isAppleApp {
            safety = .caution; note = "Part of macOS. Furl doesn't remove Apple apps."
        } else if app.isRunning {
            safety = .review; note = "Running now. Furl asks it to quit before uninstalling."
        } else {
            safety = .review; note = "Only you know if you still use it. Its support files go to the Trash with it."
        }
        self.init(
            id: "app:\(app.id)", source: .app, sourceID: app.id,
            name: app.name, path: app.bundlePath, sizeBytes: app.totalSizeBytes,
            modifiedDate: nil, lastUsedDate: nil,
            kind: app.version.isEmpty ? "App" : "App · version \(app.version)",
            whyFlagged: "Installed app, listed so you can find it. Not flagged. Includes \(FileSizeHelper.formatBytes(app.dataSizeBytes)) of support files.",
            safety: safety, safetyNote: note,
            rebuild: "Reinstall it from the App Store or the developer's website.",
            isPermanent: false, isOnDisk: true,
            canRemove: !app.isAppleApp,
            searchExtras: app.bundleIdentifier
        )
    }

    init(smart item: SmartReviewItem) {
        let safety: InspectorSafety
        switch item.verdict.label {
        case .junk: safety = .safe
        case .maybe: safety = .review
        case .keep: safety = .caution
        }
        var why = item.verdict.reason
        if !item.signals.isEmpty { why += " (" + item.signals.joined(separator: ", ") + ")" }
        self.init(
            id: "smart:\(item.id)", source: .smartReview, sourceID: item.id,
            name: item.name, path: item.path, sizeBytes: item.sizeBytes,
            modifiedDate: item.modifiedDate, lastUsedDate: item.lastOpenedDate,
            kind: "Smart Review · \(item.verdict.label.rawValue)",
            whyFlagged: why,
            safety: safety,
            safetyNote: "\(item.verdict.source.rawValue), \(item.verdict.confidence)% confident.",
            rebuild: item.downloadedFrom.map { "Nothing automatically. It was downloaded from \($0)." }
                ?? "Nothing. It's a file you saved, so make sure you don't need it.",
            isPermanent: false, isOnDisk: true, canRemove: true,
            searchExtras: item.downloadedFrom ?? ""
        )
    }
}

// MARK: - Details read from disk

/// Facts the Inspector reads from disk when it opens an item.
struct InspectorDetails: Sendable, Equatable {
    struct Child: Sendable, Equatable, Identifiable {
        let name: String
        let bytes: Int64
        var id: String { name }
    }

    var exists = true
    var isDirectory = false
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount = 0
    var folderCount = 0
    var modified: Date?
    var lastUsed: Date?
    var largestInside: [Child] = []
    /// Counting stopped early because the folder is huge.
    var isPartial = false

    /// Walks `path` off the main thread. Gives up counting after `limit` entries.
    static func load(path: String, limit: Int = 400_000) -> InspectorDetails {
        var details = InspectorDetails()
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            details.exists = false
            return details
        }
        details.isDirectory = isDir.boolValue
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let topValues = try? url.resourceValues(forKeys: Set(keys + [.contentAccessDateKey]))
        details.modified = topValues?.contentModificationDate
        details.lastUsed = spotlightLastUsed(path)

        guard isDir.boolValue else {
            details.allocatedBytes = Int64(topValues?.totalFileAllocatedSize ?? 0)
            details.logicalBytes = Int64(topValues?.fileSize ?? 0)
            details.fileCount = 1
            return details
        }

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else {
            return details
        }
        let basePathCount = url.standardizedFileURL.pathComponents.count
        var childTotals: [String: Int64] = [:]
        var seen = 0
        for case let item as URL in enumerator {
            seen += 1
            if seen > limit { details.isPartial = true; break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let components = item.standardizedFileURL.pathComponents
            let top = components.count > basePathCount ? components[basePathCount] : item.lastPathComponent
            if values.isDirectory == true {
                details.folderCount += 1
            } else {
                let allocated = Int64(values.totalFileAllocatedSize ?? 0)
                details.fileCount += 1
                details.allocatedBytes += allocated
                details.logicalBytes += Int64(values.fileSize ?? 0)
                childTotals[top, default: 0] += allocated
            }
        }
        details.largestInside = childTotals
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { Child(name: $0.key, bytes: $0.value) }
        return details
    }

    /// Spotlight's last-opened date (local metadata only).
    private static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

import Darwin
import Foundation

/// "Empty Furl's items" (TrashEmpty board): deletes, for good, only what Furl itself moved to the Trash.
/// An item counts as Furl's only while it still matches its record exactly: same place in the Trash,
/// same inode, same kind, same modification date and same size. Anything else is skipped, never
/// deleted. Furl never lists the rest of the Trash.
enum FurlTrash {
    enum Check: Equatable, Sendable {
        /// Still exactly the item Furl put there.
        case matches
        /// Nothing at the recorded place (put back, renamed, or emptied).
        case gone
        /// Something is there but it isn't the item as Furl left it (other file, edited, resized).
        case changed
        /// Can't be confirmed: an old record without a stamp, a path outside a Trash folder, or the
        /// Trash can't be read. Never deleted, and not forgotten either.
        case unconfirmable
    }

    /// Where Trash folders may be. `system` is ~/.Trash and `/Volumes/<name>/.Trashes/<uid>`; tests
    /// pass their own folder.
    struct Folders: Sendable {
        var home: String
        var uid: uid_t
        /// Used instead of the system folders when set (tests).
        var testRoots: Set<String>? = nil

        static var system: Folders {
            Folders(home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path, uid: getuid())
        }

        /// True when `folder` is a Trash folder, and neither it nor its Trash parent is a symlink.
        func isTrashFolder(_ folder: String) -> Bool {
            if let testRoots {
                return testRoots.contains(folder) && FurlTrash.isRealDirectory(folder)
            }
            if folder == home + "/.Trash" {
                return FurlTrash.isRealDirectory(folder)
            }
            // /Volumes/<name>/.Trashes/<uid>
            let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0].isEmpty, parts[1] == "Volumes", !parts[2].isEmpty,
                  parts[3] == ".Trashes", parts[4] == "\(uid)" else { return false }
            let trashes = "/Volumes/\(parts[2])/.Trashes"
            return FurlTrash.isRealDirectory(trashes) && FurlTrash.isRealDirectory(folder)
        }
    }

    /// Whether `entry` is still exactly the item Furl put in the Trash. `deep` also adds up its size
    /// (a walk for folders): a folder's own date doesn't change when something deep inside it does.
    static func check(_ entry: TrashLedgerEntry, deep: Bool, folders: Folders = .system) -> Check {
        guard let fileID = entry.fileID, let stamp = entry.stamp, let bytes = entry.bytes, bytes >= 0 else {
            return .unconfirmable
        }
        let path = entry.trashPath
        // A plain, absolute path whose folder is a Trash folder: no "..", no trailing slash.
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else { return .unconfirmable }
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        guard !name.isEmpty, name != ".", name != "..", folders.isTrashFolder(folder) else { return .unconfirmable }

        // lstat: never follows a symlink.
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT ? .gone : .unconfirmable
        }
        guard UInt64(info.st_ino) == fileID else { return .changed }
        guard let now = CleanupStamp.read(path), now.kind == stamp.kind, now.modified == stamp.modified,
              kind(of: info) == stamp.kind else { return .changed }
        // A symlink can't be edited in place (a new target is a new inode), and its recorded size
        // followed the link, so it isn't compared.
        if deep, stamp.kind != .symlink, FileSizeHelper.directorySize(at: URL(fileURLWithPath: path)) != bytes {
            return .changed
        }
        return .matches
    }

    struct EmptyOutcome: Sendable {
        var deleted: [TrashLedgerEntry] = []
        var bytes: Int64 = 0
        /// Not deleted because they no longer matched (with why).
        var skipped: [(entry: TrashLedgerEntry, check: Check)] = []
        var errors: [String] = []
    }

    /// Deletes each entry that still matches, checked again (fully) right before it goes. Anything
    /// that doesn't match exactly is skipped. A symlink is removed as a link; its target is never touched.
    static func empty(_ entries: [TrashLedgerEntry], folders: Folders = .system,
                      beforeRemove: ((TrashLedgerEntry) -> Void)? = nil) -> EmptyOutcome {
        var outcome = EmptyOutcome()
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.trashPath).inserted {
            let verdict = check(entry, deep: true, folders: folders)
            guard verdict == .matches else {
                outcome.skipped.append((entry, verdict))
                continue
            }
            beforeRemove?(entry)
            // The size walk can take a while: one more quick look right before removing.
            let last = check(entry, deep: false, folders: folders)
            guard last == .matches else {
                outcome.skipped.append((entry, last))
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: entry.trashPath)
                outcome.deleted.append(entry)
                outcome.bytes += entry.bytes ?? 0
            } catch {
                outcome.errors.append("\((entry.trashPath as NSString).lastPathComponent): couldn’t delete it (\(error.localizedDescription))")
            }
        }
        return outcome
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func kind(of info: stat) -> CleanupStamp.Kind {
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        default: return .file
        }
    }
}

/// What the confirm says: how many of Furl's items it found and how many still match.
struct FurlTrashPlan: Sendable {
    /// Every item Furl thinks is in the Trash (what the Overview line counted, plus anything new).
    let total: Int
    /// The ones that still match exactly; only these can be deleted.
    let matched: [TrashLedgerEntry]

    var matchedBytes: Int64 { matched.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) } }
    var notMatchedCount: Int { total - matched.count }
    var isPartial: Bool { matched.count < total }

    /// `candidates` are deduplicated by Trash path and inode; records that can't be confirmed at all
    /// (pre-1.4.0, no stamp) aren't Furl's items as far as this feature is concerned.
    static func make(_ candidates: [TrashLedgerEntry], folders: FurlTrash.Folders = .system) -> FurlTrashPlan {
        var seen = Set<String>()
        var total = 0
        var matched: [TrashLedgerEntry] = []
        for entry in candidates where entry.stamp != nil && entry.fileID != nil {
            guard seen.insert("\(entry.trashPath)\u{0}\(entry.fileID ?? 0)").inserted else { continue }
            total += 1
            if FurlTrash.check(entry, deep: true, folders: folders) == .matches { matched.append(entry) }
        }
        return FurlTrashPlan(total: total, matched: matched)
    }
}

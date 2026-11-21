import AppKit
import Foundation

enum DeletionService {
    /// Paths that must never be removed, no matter what a scanner returns.
    private static var protectedPaths: Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: Set<String> = [
            "/", "/Applications", "/System", "/Library", "/Users", "/usr", "/bin", "/sbin",
            "/private", "/var", "/etc", "/opt", "/Volumes",
            home
        ]
        for sub in [
            "Library", "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Application Support",
            "Library/Containers", "Library/Group Containers", "Library/Developer", "Library/Developer/Xcode",
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", ".Trash"
        ] {
            paths.insert("\(home)/\(sub)")
        }
        return paths
    }

    /// Folders whose contents are never removed either (credentials, keychains, iCloud, system state).
    private static var protectedSubtrees: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db",
            "\(home)/.ssh", "\(home)/.gnupg", "\(home)/.aws", "\(home)/.kube", "\(home)/.config/gh",
            "\(home)/Library/Keychains", "\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage",
            "\(home)/Library/Mail", "\(home)/Library/Messages", "\(home)/Library/Accounts",
            "\(home)/Library/Group Containers/group.com.apple.notes", "\(home)/Library/Photos"
        ]
    }

    /// True for protected folders, anything inside a protected subtree, and any folder that contains one
    /// (trashing `~/.config` would take `~/.config/gh` with it). Compared case-insensitively because APFS
    /// volumes usually are, so `~/.SSH` is the same folder as `~/.ssh`.
    static func isProtected(_ path: String) -> Bool {
        let normalized = fold(URL(fileURLWithPath: path).standardizedFileURL.path)
        if foldedPaths.contains(normalized) { return true }
        if foldedSubtrees.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) { return true }
        let prefix = normalized == "/" ? "/" : normalized + "/"
        return foldedPaths.contains { $0.hasPrefix(prefix) } || foldedSubtrees.contains { $0.hasPrefix(prefix) }
    }

    // Built once: Space Map asks for every row it draws.
    private static let foldedPaths: Set<String> = Set(protectedPaths.map(fold))
    private static let foldedSubtrees: [String] = protectedSubtrees.map(fold)

    private static func fold(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Moves `paths` to the Trash or deletes them. With `expected`, each path is re-checked against its
    /// scan-time stamp immediately before it moves: a path without a stamp, or that no longer matches
    /// (gone, other kind, modified, resized), is left alone and listed in `skippedPaths`. A path inside
    /// one this call already removed is simply gone, not skipped. Paths in `ignoreModified` are compared
    /// by kind (and size, if stamped) only.
    static func deletePaths(_ paths: [String], mode: DeletionMode, progress: ScanProgress? = nil,
                            expected: [String: CleanupStamp]? = nil,
                            ignoreModified: Set<String> = []) -> CleanupResult {
        let fm = FileManager.default
        var succeeded = 0
        var failed = 0
        var reclaimed: Int64 = 0
        var errors: [String] = []
        var trashed: [TrashedItem] = []
        var skipped: [String] = []
        var removed: [String] = []

        for path in Array(Set(paths)).sorted() {
            let url = URL(fileURLWithPath: path)
            progress?.setPhase(url.lastPathComponent)
            defer { progress?.addItems(1) }

            if isProtected(path) {
                failed += 1
                errors.append("\(path): refused — protected system or home folder")
                continue
            }

            // attributesOfItem doesn't follow symlinks, so broken links are still removable.
            let exists = (try? fm.attributesOfItem(atPath: path)) != nil
            if let expected {
                // Sorted, so a parent always comes before what's inside it.
                if !exists, removed.contains(where: { path.hasPrefix($0 + "/") }) { continue }
                guard exists, let stamp = expected[path],
                      stamp.matches(path, checkModified: !ignoreModified.contains(path)) else {
                    skipped.append(path)
                    continue
                }
            }
            guard exists else { continue }

            let size = FileSizeHelper.directorySize(at: url)
            do {
                switch mode {
                case .moveToTrash:
                    var trashedURL: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                    if let trashedPath = (trashedURL as URL?)?.path {
                        trashed.append(TrashedItem(originalPath: path, trashPath: trashedPath, sizeBytes: size,
                                                   fileID: fileID(trashedPath),
                                                   stamp: CleanupStamp.read(trashedPath)))
                    }
                case .permanent:
                    try fm.removeItem(at: url)
                }
                removed.append(path)
                succeeded += 1
                reclaimed += size
            } catch {
                failed += 1
                errors.append("\(url.lastPathComponent): \(friendlyMessage(for: error))")
            }
        }

        return CleanupResult(
            succeededCount: succeeded,
            failedCount: failed,
            reclaimedBytes: reclaimed,
            errors: errors,
            trashedItems: trashed,
            skippedPaths: skipped
        )
    }

    /// Inode of the item at `path` (not following links), the same scheme as `TrashLedgerEntry.fileID`.
    static func fileID(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// True while the item at `item.trashPath` is still the one Furl put there: same inode, or, for
    /// records saved without one, the same size. A record with neither can't be confirmed.
    static func isStillInTrash(_ item: TrashedItem) -> Bool {
        if let id = item.fileID { return fileID(item.trashPath) == id }
        guard item.sizeBytes > 0, (try? FileManager.default.attributesOfItem(atPath: item.trashPath)) != nil else { return false }
        return FileSizeHelper.directorySize(at: URL(fileURLWithPath: item.trashPath)) == item.sizeBytes
    }

    /// Moves trashed items back to where they came from.
    /// `restoredItems` lists exactly what came back, so a partial Undo can keep the rest restorable.
    static func restore(_ items: [TrashedItem]) -> (restored: Int, errors: [String], restoredItems: [TrashedItem]) {
        let fm = FileManager.default
        var restored = 0
        var restoredItems: [TrashedItem] = []
        var errors: [String] = []
        for item in items {
            let name = URL(fileURLWithPath: item.originalPath).lastPathComponent
            // Finder reuses Trash names: only put back the very item Furl trashed. Anything else at
            // that path means ours is no longer in the Trash.
            guard (try? fm.attributesOfItem(atPath: item.trashPath)) != nil, isStillInTrash(item) else {
                errors.append("\(name): no longer in the Trash")
                continue
            }
            if (try? fm.attributesOfItem(atPath: item.originalPath)) != nil {
                errors.append("\(name): something already exists at the original location")
                continue
            }
            do {
                let parent = URL(fileURLWithPath: item.originalPath).deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: item.trashPath, toPath: item.originalPath)
                restored += 1
                restoredItems.append(item)
            } catch {
                errors.append("\(name): \(friendlyMessage(for: error))")
            }
        }
        return (restored, errors, restoredItems)
    }

    static func emptyTrash() -> CleanupResult {
        let fm = FileManager.default
        let trashURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let sizeBefore = FileSizeHelper.directorySize(at: trashURL)

        if let contents = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            var result = CleanupResult(succeededCount: 0, failedCount: 0, reclaimedBytes: 0, errors: [])
            for item in contents {
                do {
                    let size = FileSizeHelper.directorySize(at: item)
                    try fm.removeItem(at: item)
                    result = CleanupResult(
                        succeededCount: result.succeededCount + 1,
                        failedCount: result.failedCount,
                        reclaimedBytes: result.reclaimedBytes + size,
                        errors: result.errors
                    )
                } catch {
                    result = CleanupResult(
                        succeededCount: result.succeededCount,
                        failedCount: result.failedCount + 1,
                        reclaimedBytes: result.reclaimedBytes,
                        errors: result.errors + ["\(item.lastPathComponent): \(friendlyMessage(for: error))"]
                    )
                }
            }
            return result
        }

        // Without Full Disk Access ~/.Trash is unreadable; ask Finder to empty it instead.
        let out = ShellRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Finder\" to empty trash"],
            timeout: 120
        )
        if out.exitCode == 0 {
            return CleanupResult(succeededCount: 1, failedCount: 0, reclaimedBytes: sizeBefore, errors: [])
        }
        let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanupResult(
            succeededCount: 0,
            failedCount: 1,
            reclaimedBytes: 0,
            errors: ["Could not empty Trash. Grant Furl Full Disk Access or Finder automation in System Settings › Privacy & Security. \(msg)"]
        )
    }

    private static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return "permission denied (try granting Full Disk Access in System Settings › Privacy & Security)"
        }
        return error.localizedDescription
    }

    @MainActor
    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @MainActor
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

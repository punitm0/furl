import Darwin
import Foundation

/// An app found in the Trash: what its Info.plist says, already checked.
struct TrashedApp: Sendable, Equatable {
    let bundleID: String
    let name: String
}

/// Rules for the "app dragged to the Trash" offer (LeftoversWhatsNew board).
enum TrashedAppLeftovers {
    /// Board: only if the leftovers add up to 50 MB or more.
    static let minimumBytes: Int64 = 50_000_000
    static let enabledKey = "leftovers.notifyOnTrash"
    static let notifiedKey = "leftovers.notifiedBundleIDs"
    /// Enough to never repeat in practice, without growing forever.
    static let notifiedCap = 500

    /// On by default (board decision).
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Notify only when it's on, the leftovers add up to 50 MB or more, at least one folder is a sure
    /// match, and this app was never offered before.
    static func shouldNotify(items: [AppDataItem], bundleID: String, enabled: Bool,
                             alreadyNotified: Set<String>) -> Bool {
        guard enabled, !alreadyNotified.contains(bundleID.lowercased()) else { return false }
        guard items.contains(where: \.isStrongMatch) else { return false }
        return items.reduce(Int64(0)) { $0 + $1.sizeBytes } >= minimumBytes
    }

    static func notified(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: notifiedKey) ?? []
    }

    static func recordNotified(_ bundleID: String, defaults: UserDefaults = .standard) {
        var list = notified(defaults).filter { $0 != bundleID.lowercased() }
        list.append(bundleID.lowercased())
        defaults.set(Array(list.suffix(notifiedCap)), forKey: notifiedKey)
    }

    /// "Sketch is in the Trash. It left 1.4 GB in your Library. Remove that too?"
    static func body(appName: String, bytes: Int64) -> String {
        "\(appName) is in the Trash. It left \(FileSizeHelper.formatBytes(bytes)) in your Library. Remove that too?"
    }

    /// The leftovers as Removed apps groups, keyed like the Apps scan keys them (folder name in
    /// lower case, without .plist / .savedState), so a later scan finds the same groups. The group
    /// for the app's own ID is named after the app; the rest are possible matches.
    static func groups(from items: [AppDataItem], bundleID: String, appName: String) -> [OrphanedAppDataGroup] {
        let mainKey = bundleID.lowercased()
        var order: [String] = []
        var byKey: [String: [AppDataItem]] = [:]
        for item in items {
            let key = groupKey(item)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { key in
            let members = byKey[key] ?? []
            return OrphanedAppDataGroup(
                id: key, appIdentifier: key,
                displayName: key == mainKey ? appName : key,
                items: members.sorted { $0.sizeBytes > $1.sizeBytes })
        }.sorted { a, b in
            if (a.id == mainKey) != (b.id == mainKey) { return a.id == mainKey }
            return a.totalSizeBytes > b.totalSizeBytes
        }
    }

    static func groupKey(_ item: AppDataItem) -> String {
        var key = item.name
        if item.location == .preferences, key.hasSuffix(".plist") { key = String(key.dropLast(".plist".count)) }
        if item.location == .savedState, key.hasSuffix(".savedState") { key = String(key.dropLast(".savedState".count)) }
        return key.lowercased()
    }

    // MARK: - Reading an app in the Trash

    /// Largest Info.plist read. Real ones are a few KB.
    static let maxPlistBytes = 1_000_000

    /// Reads the bundle ID and name of an app in the Trash. The bundle is untrusted: no symlink is
    /// followed (the .app, Contents and Info.plist must be real), the plist is size-capped, and the ID
    /// and name are checked before use.
    static func readTrashedApp(at appURL: URL) -> TrashedApp? {
        guard appURL.pathExtension.lowercased() == "app",
              isRealDirectory(appURL.path),
              isRealDirectory(appURL.appendingPathComponent("Contents").path) else { return nil }
        let plistPath = appURL.appendingPathComponent("Contents/Info.plist").path
        guard let data = readRegularFile(plistPath, maxBytes: maxPlistBytes),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawID = plist["CFBundleIdentifier"] as? String,
              let bundleID = validBundleID(rawID) else { return nil }
        let fallback = appURL.deletingPathExtension().lastPathComponent
        let name = [plist["CFBundleDisplayName"], plist["CFBundleName"]]
            .compactMap { $0 as? String }
            .compactMap(validName)
            .first ?? validName(fallback) ?? bundleID
        return TrashedApp(bundleID: bundleID, name: name)
    }

    /// Reverse-DNS characters only, as macOS allows in bundle IDs.
    static func validBundleID(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard (3...255).contains(raw.count), raw.allSatisfy(allowed.contains),
              raw.contains("."), !raw.hasPrefix("."), !raw.hasSuffix("."), !raw.contains("..") else { return nil }
        return raw
    }

    /// A short display name with no control characters, or nil.
    static func validName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Opens with O_NOFOLLOW and checks it's a regular file within the cap, then reads it.
    private static func readRegularFile(_ path: String, maxBytes: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size >= 0, st.st_size <= off_t(maxBytes) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }
}

extension AppState {
    /// "Review…" on the trashed-app offer: puts the app's leftovers in Removed apps (replacing any
    /// group with the same key from an earlier scan) and asks Apps & Leftovers to open its confirm.
    /// Stamps are taken now, so the move re-checks against what this confirm lists.
    func reviewTrashedAppLeftovers(_ groups: [OrphanedAppDataGroup], mainID: String,
                                   stamps: [String: CleanupStamp]) {
        guard !groups.isEmpty else { return }
        let ids = Set(groups.map(\.id))
        orphanedGroups = groups + orphanedGroups.filter { !ids.contains($0.id) }
        cleanupStamps.apps.merge(stamps) { _, new in new }
        leftoversReviewID = groups.contains { $0.id == mainID } ? mainID : groups.first?.id
    }
}

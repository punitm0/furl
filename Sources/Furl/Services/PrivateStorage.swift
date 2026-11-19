import Foundation

/// Furl keeps everything it remembers (History, Trash ledger, tray, scan index, stats) in its own
/// folders. None of it is sent anywhere; the only network use is anonymous community totals, which sends
/// totals derived from the stats ledger (see CommunityStatsReporter).
@MainActor
enum PrivateStorage {
    /// Run once at launch, before any store loads: brings over data from the SweepMac era, then makes
    /// the folders owner-only (0700) so other user accounts on the Mac can't read them.
    static func prepare() {
        importLegacyData()
        lockDown()
    }

    static func lockDown() {
        let fm = FileManager.default
        for dir in [AppIdentity.supportDirectory, AppIdentity.cachesDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    // MARK: - SweepMac → Furl

    private static let importedKey = "importedFromSweepMac"

    /// The app used to be called SweepMac (bundle id com.sweepmac.utility). Moves its folders to the
    /// Furl names and copies its settings into Furl's defaults, once. Never overwrites Furl data.
    static func importLegacyData() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: importedKey) else { return }
        let fm = FileManager.default

        let pairs: [(old: URL, new: URL)] = [
            (AppIdentity.supportDirectory.deletingLastPathComponent()
                .appendingPathComponent(AppIdentity.legacyFolderName, isDirectory: true), AppIdentity.supportDirectory),
            (AppIdentity.cachesDirectory.deletingLastPathComponent()
                .appendingPathComponent(AppIdentity.legacyFolderName, isDirectory: true), AppIdentity.cachesDirectory),
        ]
        for (old, new) in pairs where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        // Only the old app's own keys (not the global domain that dictionaryRepresentation mixes in).
        let oldID = AppIdentity.legacyBundleID as CFString
        if let keys = CFPreferencesCopyKeyList(oldID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
           let values = CFPreferencesCopyMultiple(keys as CFArray, oldID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: importedKey)
    }
}

import AppKit
import Combine
import Foundation

/// Full Disk Access status and the "Furl was updated" banner (UpdatePermissions board).
///
/// Furl is ad-hoc signed, so macOS treats every new version as a new app and forgets
/// Full Disk Access. This remembers the last version that ran and the version the user
/// updated to; the Overview banner shows on every launch of that version until Full Disk
/// Access is back on or the user dismisses it for that version (design decision, round 2).
@MainActor
final class FullDiskAccess: ObservableObject {
    static let shared = FullDiskAccess()

    private enum Keys {
        static let lastRunVersion = "fullDiskAccess.lastRunVersion"
        static let dismissedBannerVersion = "fullDiskAccess.dismissedBannerVersion"
        static let updatedToVersion = "fullDiskAccess.updatedToVersion"
        /// Screen → version its limited-results line was hidden for.
        static let limitedLineDismissals = "fullDiskAccess.limitedLineDismissals"
    }

    /// Whether this process can read TCC-protected locations.
    @Published private(set) var isGranted: Bool
    @Published private var dismissedBannerVersion: String?
    @Published private var limitedLineDismissals: [String: String]

    /// CFBundleShortVersionString, or nil when running outside an app bundle (`swift run`).
    let currentVersion: String?
    /// True when this version was reached by an update (not a first install). Stays true on
    /// later launches of the same version.
    let isUpdatedVersion: Bool
    /// The version that ran before this launch; nil on a first install (or outside a bundle).
    let previousRunVersion: String?

    private init() {
        let defaults = UserDefaults.standard
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        currentVersion = version
        let lastRun = defaults.string(forKey: Keys.lastRunVersion)
        previousRunVersion = lastRun
        if let version {
            if lastRun != nil && lastRun != version {
                defaults.set(version, forKey: Keys.updatedToVersion)
            }
            defaults.set(version, forKey: Keys.lastRunVersion)
            isUpdatedVersion = defaults.string(forKey: Keys.updatedToVersion) == version
        } else {
            isUpdatedVersion = false
        }
        dismissedBannerVersion = defaults.string(forKey: Keys.dismissedBannerVersion)
        limitedLineDismissals = defaults.dictionary(forKey: Keys.limitedLineDismissals) as? [String: String] ?? [:]
        isGranted = Self.checkAccess()
    }

    /// Show the Overview banner: this version came from an update, Full Disk Access is off,
    /// and the user hasn't dismissed it for this version.
    var showsUpdateBanner: Bool {
        guard isUpdatedVersion, let currentVersion else { return false }
        return !isGranted && dismissedBannerVersion != currentVersion
    }

    /// The limited-results line (WelcomeAccess board): Full Disk Access is off and the line wasn't
    /// hidden on this screen for this version. On the Overview the update banner wins.
    func showsLimitedLine(on screen: LimitedResultsScreen) -> Bool {
        Self.showsLimitedLine(
            granted: isGranted,
            dismissedForVersion: limitedLineDismissals[screen.rawValue],
            currentVersion: versionKey,
            updateBannerShowing: screen == .overview && showsUpdateBanner
        )
    }

    nonisolated static func showsLimitedLine(
        granted: Bool, dismissedForVersion: String?, currentVersion: String, updateBannerShowing: Bool
    ) -> Bool {
        !granted && !updateBannerShowing && dismissedForVersion != currentVersion
    }

    /// ✕ hides the line on that screen until the next version.
    func dismissLimitedLine(on screen: LimitedResultsScreen) {
        limitedLineDismissals[screen.rawValue] = versionKey
        UserDefaults.standard.set(limitedLineDismissals, forKey: Keys.limitedLineDismissals)
    }

    /// Unbundled runs have no version; they share one key.
    private var versionKey: String { currentVersion ?? "unbundled" }

    func refresh() {
        let granted = Self.checkAccess()
        if granted != isGranted { isGranted = granted }
    }

    func dismissUpdateBanner() {
        guard let currentVersion else { return }
        dismissedBannerVersion = currentVersion
        UserDefaults.standard.set(currentVersion, forKey: Keys.dismissedBannerVersion)
    }

    /// Opens /Applications (or wherever Furl lives) with Furl selected.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Read-only probe of TCC-protected files. Opening a file for reading and closing it
    /// has no side effects. The system TCC database exists on every Mac and is readable only
    /// with Full Disk Access; ~/Library/Safari is the fallback if it can't be found.
    nonisolated static func checkAccess() -> Bool {
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(tccDB, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        if errno != ENOENT { return false }
        let safari = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }

    /// The same probe from a newly started process. macOS applies a fresh Full Disk Access grant
    /// to new processes straight away but to a running app only after it reopens, so "this
    /// process can't read, a new one can" means the switch is on and Furl needs to reopen.
    /// Read-only: `head` reads one byte to /dev/null via a pipe.
    nonisolated static func checkAccessInNewProcess() -> Bool {
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: tccDB) {
            return ShellRunner.run("/usr/bin/head", arguments: ["-c", "1", tccDB], timeout: 5).exitCode == 0
        }
        let safari = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        return ShellRunner.run("/bin/ls", arguments: ["-1", safari], timeout: 5).exitCode == 0
    }
}

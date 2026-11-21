import AppKit
import Foundation

/// "What's new" after an update (LeftoversWhatsNew board): one sentence per change, bundled in the
/// app, shown once per version. Never on a first install, and only once Full Disk Access is sorted
/// out: while the after-update banner shows, it waits for a later launch.
enum WhatsNew {
    struct Notes: Identifiable, Equatable, Sendable {
        let version: String
        let lines: [String]
        var id: String { version }
    }

    static let shownKey = "whatsNew.shownVersion"
    /// A link opened in the browser; Furl itself downloads nothing.
    static let changelogURL = URL(string: "https://getfurl.app/changelog")!

    static let bundled: [Notes] = [
        Notes(version: "1.4.0", lines: [
            "Furl offers to move itself to Applications and ejects the disk image.",
            "First launch is two short screens: two promises and one permission.",
            "Your first scan shows results as each area finishes.",
            "An optional first clean shows Undo working on three safe items.",
            "\u{201C}Empty Furl\u{2019}s Items\u{201D} deletes only what Furl put in the Trash.",
            "Drag an app to the Trash and Furl offers to remove what it left.",
            "Apps & Leftovers lists old Node, Python and Rust versions no project uses.",
            "Merged worktrees start unticked, and two new Shortcuts stop leftover servers and tidy a project.",
            "Closing the window keeps Furl in the menu bar. You can change this in Settings."
        ])
    ]

    /// Notes for this exact version, or else the newest notes of the same major.minor that aren't
    /// newer than it (a 1.4.1 bug-fix release shows 1.4.0's notes to someone coming from 1.3).
    static func notes(for version: String, in all: [Notes] = bundled) -> Notes? {
        if let exact = all.first(where: { $0.version == version }) { return exact }
        let current = components(version)
        guard current.count >= 2 else { return nil }
        return all
            .filter { n in
                let c = components(n.version)
                return c.count >= 2 && c[0] == current[0] && c[1] == current[1] && !isNewer(c, than: current)
            }
            .max { isNewer(components($1.version), than: components($0.version)) }
    }

    enum Decision: Equatable {
        /// Show these notes now.
        case show(Notes)
        /// A first install: remember these notes as seen so they never show.
        case markSeen(String)
        /// Full Disk Access needs sorting out first; ask again on a later launch.
        case wait
        case nothing
    }

    static func decide(currentVersion: String?, isUpdatedVersion: Bool, fdaBannerShowing: Bool,
                       lastShown: String?, notes all: [Notes] = bundled) -> Decision {
        guard let currentVersion, let notes = notes(for: currentVersion, in: all) else { return .nothing }
        guard lastShown != notes.version else { return .nothing }
        guard isUpdatedVersion else { return .markSeen(notes.version) }
        guard !fdaBannerShowing else { return .wait }
        return .show(notes)
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Decides once per launch whether What's new shows, and remembers it was shown.
@MainActor
final class WhatsNewStore: ObservableObject {
    static let shared = WhatsNewStore()

    @Published var pending: WhatsNew.Notes?

    private init() {
        let fda = FullDiskAccess.shared
        let defaults = UserDefaults.standard
        // Evaluated at launch only: macOS applies a Full Disk Access change on the next launch.
        switch WhatsNew.decide(currentVersion: fda.currentVersion, isUpdatedVersion: fda.isUpdatedVersion,
                               fdaBannerShowing: fda.showsUpdateBanner,
                               lastShown: defaults.string(forKey: WhatsNew.shownKey)) {
        case .show(let notes): pending = notes
        case .markSeen(let version): defaults.set(version, forKey: WhatsNew.shownKey)
        case .wait, .nothing: break
        }
    }

    /// Called when the sheet appears, so it's shown once even if Furl quits while it's open.
    func markShown(_ notes: WhatsNew.Notes) {
        UserDefaults.standard.set(notes.version, forKey: WhatsNew.shownKey)
    }

    func openChangelog() {
        NSWorkspace.shared.open(WhatsNew.changelogURL)
    }
}

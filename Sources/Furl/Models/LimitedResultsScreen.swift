import Foundation

/// Screens whose totals are lower without Full Disk Access, with the WelcomeAccess board's line
/// for each. Smart Review, Git Worktrees, Compress and Processes have none: they don't need it.
enum LimitedResultsScreen: String, CaseIterable, Sendable {
    case overview
    case junk
    case apps
    case duplicates
    case largeFiles
    case disk

    var message: String {
        switch self {
        case .overview:
            return "Some folders are hidden from Furl, so these totals may be low."
        case .junk:
            return "Safari and Mail caches are hidden without Full Disk Access, so this list is shorter than it could be."
        case .apps:
            return "Some app data is hidden without Full Disk Access, so app sizes may be low."
        case .duplicates:
            return "Mail and Messages attachments aren’t checked without Full Disk Access."
        case .largeFiles, .disk:
            return "A few folders can’t be read without Full Disk Access, so they’re left out."
        }
    }

    var buttonTitle: String {
        self == .overview ? "Turn On Full Disk Access…" : "Turn On…"
    }
}

import Foundation

/// How an app's footprint is grouped in the Apps screen breakdown.
enum FootprintCategory: String, CaseIterable, Identifiable, Sendable {
    case app = "App"
    case applicationSupport = "Application Support"
    case containers = "Containers"
    case caches = "Caches"
    case logs = "Logs"
    case preferences = "Preferences & saved state"
    case webData = "Web data"

    var id: String { rawValue }

    init(_ location: AppDataLocation) {
        switch location {
        case .applicationSupport: self = .applicationSupport
        case .containers, .groupContainers: self = .containers
        case .caches: self = .caches
        case .logs: self = .logs
        case .preferences, .savedState: self = .preferences
        case .webKit, .httpStorages: self = .webData
        }
    }

    /// Caches and logs are rebuilt by the app; clearing them loses nothing.
    var isRebuildable: Bool { self == .caches || self == .logs }
}

struct FootprintSlice: Identifiable {
    let category: FootprintCategory
    let bytes: Int64
    let items: [AppDataItem]
    var id: String { category.id }
}

extension InstalledAppItem {
    /// App bundle first, then each non-empty Library category, largest first.
    var footprintSlices: [FootprintSlice] {
        let grouped = Dictionary(grouping: associatedData) { FootprintCategory($0.location) }
        let data = grouped.map { category, items in
            FootprintSlice(category: category, bytes: items.reduce(0) { $0 + $1.sizeBytes }, items: items)
        }
        .filter { !$0.items.isEmpty }
        .sorted { $0.bytes > $1.bytes }
        return [FootprintSlice(category: .app, bytes: appSizeBytes, items: [])] + data
    }

    /// Caches and logs that clearly belong to this app (exact matches only).
    var rebuildableItems: [AppDataItem] {
        associatedData.filter { $0.isStrongMatch && FootprintCategory($0.location).isRebuildable }
    }

    var rebuildableBytes: Int64 {
        rebuildableItems.reduce(0) { $0 + $1.sizeBytes }
    }

    /// The app's own date, or `now` while it's running.
    var daysSinceOpened: Int? {
        guard let lastOpenedDate else { return nil }
        return Calendar.current.dateComponents([.day], from: lastOpenedDate, to: Date()).day
    }

    var isUnused90Days: Bool {
        guard !isRunning, let days = daysSinceOpened else { return false }
        return days >= 90
    }

    /// "Used today", "Used 3 days ago", "Not opened in 7 months".
    var lastOpenedDescription: String {
        if isRunning { return "Running now" }
        guard let days = daysSinceOpened else { return "Last opened: unknown" }
        switch days {
        case ..<1: return "Used today"
        case 1: return "Used yesterday"
        case 2..<30: return "Used \(days) days ago"
        case 30..<90: return "Used \(days / 30 == 1 ? "a month" : "\(days / 30) months") ago"
        case 90..<365: return "Not opened in \(days / 30) months"
        default:
            let years = days / 365
            return "Not opened in \(years == 1 ? "a year" : "\(years) years")"
        }
    }

    /// Apple apps are managed by macOS; nothing here touches them.
    var allowsFootprintActions: Bool { !isAppleApp }
}

enum AppFootprintSafety {
    /// Only paths inside ~/Library's app-data folders, or app bundles in /Applications or ~/Applications,
    /// may be removed from the Apps screen. Everything else is dropped before it reaches DeletionService.
    static func isAllowed(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if normalized.hasSuffix(".app") {
            return normalized.hasPrefix("/Applications/") || normalized.hasPrefix("\(home)/Applications/")
        }
        let libraryRoots = [
            "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
            "Library/Group Containers", "Library/Saved Application State", "Library/Logs",
            "Library/WebKit", "Library/HTTPStorages"
        ].map { "\(home)/\($0)/" }
        return libraryRoots.contains { normalized.hasPrefix($0) && normalized.count > $0.count }
    }

    /// Keeps allowed paths and drops any path already covered by another one in the list
    /// (e.g. a container's Caches folder when the whole container goes).
    static func sanitize(_ paths: [String]) -> [String] {
        let allowed = Array(Set(paths.filter(isAllowed))).sorted()
        return allowed.filter { path in
            !allowed.contains { other in other != path && path.hasPrefix(other + "/") }
        }
    }
}

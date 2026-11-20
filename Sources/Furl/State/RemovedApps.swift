import Foundation

/// Rules for the "Removed apps" group on Apps & Leftovers (AppsOneList board): what "Select sure
/// matches" ticks, and what the confirm says before anything moves.
enum RemovedApps {
    /// Folders "Select sure matches" ticks: only folders of a sure group that the app rebuilds
    /// (WhySafe rates them Safe). Settings, app support files and containers can hold documents, so
    /// they stay for the user to tick, and nothing from a guess is ever ticked.
    static func sureItemIDs(in groups: [OrphanedAppDataGroup]) -> Set<String> {
        Set(groups.filter(\.isSureMatch).flatMap(\.items)
            .filter { WhySafe.leftoverTier($0) == .safe }.map(\.id))
    }

    /// Auto-ticked folders that no longer qualify after a rescan (gone, now a guess, or no longer Safe).
    static func staleAutoTicks(_ autoTicked: Set<String>, in groups: [OrphanedAppDataGroup]) -> Set<String> {
        autoTicked.subtracting(sureItemIDs(in: groups))
    }

    /// "App Support, Caches, Logs, Settings": the kinds of folder ticked for one app, in plain words.
    static func folderKinds(_ items: [AppDataItem]) -> String {
        var seen: [String] = []
        for item in items {
            let kind = plainKind(item.location)
            if !seen.contains(kind) { seen.append(kind) }
        }
        return seen.joined(separator: ", ")
    }

    static func plainKind(_ location: AppDataLocation) -> String {
        switch location {
        case .applicationSupport: return "App Support"
        case .preferences: return "Settings"
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .containers, .groupContainers: return "Containers"
        case .savedState: return "Saved windows"
        case .webKit, .httpStorages: return "Web data"
        }
    }

    /// "3 removed apps ticked", for the bar under the group.
    static func tickedSummary(appCount: Int) -> String {
        appCount == 1 ? "1 removed app ticked" : "\(appCount) removed apps ticked"
    }

    /// The ticked folders, grouped by removed app, in list order. Built from the current groups, so a
    /// folder that's gone since it was ticked is left out.
    static func ticked(_ ids: Set<String>, in groups: [OrphanedAppDataGroup]) -> [(group: OrphanedAppDataGroup, items: [AppDataItem])] {
        groups.compactMap { group in
            let items = group.items.filter { ids.contains($0.id) }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// "Last used 2 months ago · 4 folders" for a sure match, "Furl's best guess · 1 folder" for a guess.
    static func rowSubtitle(_ group: OrphanedAppDataGroup, now: Date = Date()) -> String {
        let folders = group.items.count == 1 ? "1 folder" : "\(group.items.count) folders"
        guard group.isSureMatch else { return "Furl\u{2019}s best guess · \(folders)" }
        guard let date = group.latestModified else { return folders }
        return "Last used \(relative(date, now: now)) · \(folders)"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// One line in a confirm: a folder (one app) or an app (several).
    struct Line: Identifiable, Equatable {
        let id: String
        let name: String
        let bytes: Int64
        /// A second, quieter line: the folder kinds for an app in a multi-app confirm.
        var detail: String? = nil
    }

    /// What a removed-apps confirm says. Lists every folder or app with its size and says where it goes.
    struct Confirm: Equatable {
        let title: String
        let message: String
        let lines: [Line]
        let button: String
        let paths: [String]
        let totalBytes: Int64
    }

    static let guessLine = "check that no app you still use needs it."

    static func confirm(for picks: [(group: OrphanedAppDataGroup, items: [AppDataItem])],
                        toTrash: Bool) -> Confirm? {
        guard !picks.isEmpty else { return nil }
        let items = picks.flatMap(\.items)
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = FileSizeHelper.formatBytes(total)
        let guesses = picks.filter { !$0.group.isSureMatch }.count
        let button = toTrash ? "Move to Trash (\(size))" : "Delete (\(size))"
        let paths = items.map(\.path)

        if picks.count == 1, let pick = picks.first {
            let name = pick.group.shownName
            let one = pick.items.count == 1
            let what = one ? "This folder" : "These \(pick.items.count) folders"
            let fate = toTrash
                ? (one ? "goes to the Trash, so you can undo." : "go to the Trash, so you can undo.")
                : (one ? "is deleted for good. This can\u{2019}t be undone." : "are deleted for good. This can\u{2019}t be undone.")
            let lines = pick.items.map { item in
                Line(id: item.id, name: "\(item.location.rawValue)/\(URL(fileURLWithPath: item.path).lastPathComponent)",
                     bytes: item.sizeBytes)
            }
            let message = pick.group.isSureMatch
                ? "\(name) was removed. \(what) \(fate)"
                : "\(what) \(fate) This is Furl\u{2019}s best guess: \(guessLine)"
            return Confirm(
                title: toTrash ? "Move \(possessive(name)) data to the Trash?" : "Delete \(possessive(name)) data permanently?",
                message: message, lines: lines, button: button, paths: paths, totalBytes: total)
        }

        var message = toTrash ? "It all goes to the Trash, so you can undo." : "It\u{2019}s deleted for good. This can\u{2019}t be undone."
        if guesses == 1 {
            message += " One is Furl\u{2019}s best guess: \(guessLine)"
        } else if guesses > 1 {
            let who = guesses == picks.count ? "All of them" : "Some"
            message += " \(who) are Furl\u{2019}s best guesses: check that no app you still use needs them."
        }
        let lines = picks.map { pick in
            Line(id: pick.group.id,
                 name: pick.group.isSureMatch ? pick.group.shownName : "\(pick.group.shownName) · guess",
                 bytes: pick.items.reduce(Int64(0)) { $0 + $1.sizeBytes },
                 detail: folderKinds(pick.items))
        }
        let title = toTrash
            ? "Move data from \(picks.count) removed apps to the Trash?"
            : "Delete data from \(picks.count) removed apps permanently?"
        return Confirm(title: title, message: message, lines: lines, button: button, paths: paths, totalBytes: total)
    }

    /// The uninstall confirm: the app and each ticked folder with its size, and where they go.
    /// `appOnly` is the same without the folders, offered as the second choice when folders are ticked.
    static func uninstall(_ app: InstalledAppItem, data: [AppDataItem], toTrash: Bool) -> Confirm {
        let total = app.appSizeBytes + data.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = FileSizeHelper.formatBytes(total)
        var lines = [Line(id: app.bundlePath, name: "\(app.name).app", bytes: app.appSizeBytes)]
        lines += data.map { item in
            Line(id: item.id, name: "\(item.location.rawValue)/\(URL(fileURLWithPath: item.path).lastPathComponent)",
                 bytes: item.sizeBytes)
        }
        let what = data.isEmpty ? "\(app.name).app"
            : "\(app.name).app and \(data.count == 1 ? "1 folder" : "\(data.count) folders")"
        var parts: [String] = []
        if app.isRunning { parts.append("\(app.name) is running and will be quit first.") }
        parts.append(toTrash ? "\(what) go to the Trash, so you can undo."
                             : "\(what) are deleted for good. This can\u{2019}t be undone.")
        if data.contains(where: { !$0.isStrongMatch }) {
            parts.append("A ticked folder is Furl\u{2019}s best guess: \(guessLine)")
        }
        if app.associatedData.contains(where: { !$0.isStrongMatch && !data.contains($0) }) {
            parts.append("Folders marked \u{201C}Possible match\u{201D} stay unless you tick them.")
        }
        return Confirm(
            title: "Uninstall \(app.name)?",
            message: parts.joined(separator: " "),
            lines: lines,
            button: toTrash ? "Move to Trash (\(size))" : "Delete (\(size))",
            paths: [app.bundlePath] + data.map(\.path),
            totalBytes: total)
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? "\(name)\u{2019}" : "\(name)\u{2019}s"
    }
}

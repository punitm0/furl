import AppKit
import CoreServices
import Foundation

enum AppUninstallerService {
    struct ScanSnapshot: Sendable {
        let installedApps: [InstalledAppItem]
        let orphanedGroups: [OrphanedAppDataGroup]
    }

    private static let appleAndSystemAllowlistPrefixes: [String] = [
        "com.apple.",
        "group.com.apple.",
        "com.google.Keystone",
        "org.homebrew.",
        "com.openssh.",
        "loginwindow",
        "CrashReporter",
        "DiagnosticReports",
        "MobileSync",
        "Knowledge",
        "AddressBook",
        "CallHistoryDB",
        "CloudDocs",
        "CoreFollowUp",
        "DiskImages",
        "Dock",
        "FileProvider",
        "GeoServices",
        "HomeKit",
        "iCloud",
        "IdentityServices",
        "Mail",
        "Messages",
        "Metadata",
        "PassKit",
        "Safari",
        "Siri",
        "Spotlight",
        "SyncServices",
        "Ubiquity",
        "Caches",
        "Preferences",
        "TemporaryItems",
        "ByHost",
        "Audio",
        "ColorSync",
        "Fonts",
        "Keychains",
        "LaunchAgents",
        "Services",
        "Spelling",
        "Voices",
        "Workflows"
    ]

    /// One app bundle found on disk, before anything is measured.
    private struct BundleCandidate: Sendable {
        let url: URL
        let isSystem: Bool
        let bundleID: String
        let name: String
        let version: String
    }

    /// One top-level entry in a ~/Library location, listed once per scan and shared by every app.
    private struct LibraryEntry: Sendable {
        let url: URL
        let name: String
        let lower: String
        let location: AppDataLocation
    }

    /// A Library entry matched to an app, plus nested caches inside sandbox containers.
    private struct MatchedEntry: Sendable {
        let url: URL
        let name: String
        let location: AppDataLocation
        let isStrong: Bool
        /// Set for `Containers/<id>/Data/Library/Caches`; its size is carved out of the container's.
        let parentContainer: String?
    }

    /// Scans every app's full footprint (bundle + ~/Library data) and leftovers of deleted apps.
    /// ~/Library is listed once, folders are sized in parallel, and sizes are cached between scans.
    /// `emit` gets the installed apps as soon as they're sized, before leftovers are sized.
    static func scan(progress: ScanProgress? = nil, emit: ((ScanSnapshot) -> Void)? = nil) -> ScanSnapshot {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        progress?.setSteps(done: 0, total: 3)
        progress?.setPhase("Listing apps")

        let candidates = listAppBundles(home: home)
        let index = buildLibraryIndex(home: home)

        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )

        var installedBundleIDs = Set<String>()
        var installedAppNames = Set<String>()
        for c in candidates {
            if !c.bundleID.isEmpty { installedBundleIDs.insert(c.bundleID.lowercased()) }
            installedAppNames.insert(c.name.lowercased())
            installedAppNames.insert(c.url.deletingPathExtension().lastPathComponent.lowercased())
        }
        // Anything currently running (menu-bar helpers, apps outside /Applications) is clearly still installed.
        for runningID in runningBundleIDs {
            installedBundleIDs.insert(runningID.lowercased())
        }

        // /System/Applications are SIP-protected; they only feed the "is installed" sets above.
        let userApps = candidates.filter { !$0.isSystem }

        // Matching is pure string work; do it per app in parallel.
        let matchesBox = ConcurrentResults<[MatchedEntry]>(count: userApps.count, initial: [])
        let lastUsedBox = ConcurrentResults<Date?>(count: userApps.count, initial: nil)
        DispatchQueue.concurrentPerform(iterations: userApps.count) { i in
            let app = userApps[i]
            matchesBox.set(i, matchEntries(index: index, bundleID: app.bundleID, appName: app.name))
            lastUsedBox.set(i, lastUsedDate(atPath: app.url.path))
        }
        let matches = matchesBox.values
        let lastUsed = lastUsedBox.values

        let orphanEntries = index.filter { entry in
            // Group Containers are too often shared across suites/CLI tools for auto-orphan detection.
            guard entry.location != .groupContainers else { return false }
            guard !isProtectedLibraryEntry(entry.name) else { return false }
            let key = normalizeIdentifier(entry.name, location: entry.location)
            guard !key.isEmpty else { return false }
            return !matchesAnyInstalled(key, rawName: entry.name, bundleIDs: installedBundleIDs, appNames: installedAppNames)
        }

        // Apps and their data first (so the list can show), then leftovers.
        progress?.advanceStep()
        progress?.setPhase("Sizing apps and their data")
        var pathsToSize = userApps.map(\.url.path)
        pathsToSize += matches.flatMap { $0.map(\.url.path) }
        var sizes = FootprintSizeCache.shared.sizes(for: pathsToSize)

        var installedApps: [InstalledAppItem] = []
        installedApps.reserveCapacity(userApps.count)
        for (i, app) in userApps.enumerated() {
            let nestedByParent = Dictionary(grouping: matches[i].filter { $0.parentContainer != nil }, by: { $0.parentContainer! })
            let associated: [AppDataItem] = matches[i].map { entry in
                var size = sizes[entry.url.path] ?? 0
                if entry.parentContainer == nil, let nested = nestedByParent[entry.url.path] {
                    size -= nested.reduce(0) { $0 + (sizes[$1.url.path] ?? 0) }
                }
                return AppDataItem(
                    id: entry.url.path,
                    path: entry.url.path,
                    name: entry.name,
                    location: entry.location,
                    sizeBytes: max(0, size),
                    modifiedDate: FileSizeHelper.modifiedDate(at: entry.url),
                    isStrongMatch: entry.isStrong
                )
            }.sorted { $0.sizeBytes > $1.sizeBytes }

            let isRunning = !app.bundleID.isEmpty && runningBundleIDs.contains(app.bundleID)
            installedApps.append(InstalledAppItem(
                id: app.url.path,
                name: app.name,
                bundleIdentifier: app.bundleID.isEmpty ? app.url.deletingPathExtension().lastPathComponent : app.bundleID,
                version: app.version,
                bundlePath: app.url.path,
                appSizeBytes: sizes[app.url.path] ?? 0,
                associatedData: associated,
                isRunning: isRunning,
                isAppleApp: app.bundleID.hasPrefix("com.apple."),
                lastOpenedDate: isRunning ? Date() : lastUsed[i]
            ))
        }

        let sortedApps = installedApps.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
        emit?(ScanSnapshot(installedApps: sortedApps, orphanedGroups: []))
        progress?.advanceStep()
        if progress?.isCancelled == true { return ScanSnapshot(installedApps: sortedApps, orphanedGroups: []) }
        progress?.setPhase("Sizing leftovers of deleted apps")
        sizes.merge(FootprintSizeCache.shared.sizes(for: orphanEntries.map(\.url.path))) { current, _ in current }

        var grouped: [String: [AppDataItem]] = [:]
        for entry in orphanEntries {
            let size = sizes[entry.url.path] ?? 0
            // Skip tiny empty folders/plists (< 64 KB) to keep signal-to-noise high
            if size < 65_536 { continue }
            let key = normalizeIdentifier(entry.name, location: entry.location)
            grouped[key, default: []].append(AppDataItem(
                id: entry.url.path,
                path: entry.url.path,
                name: entry.name,
                location: entry.location,
                sizeBytes: size,
                modifiedDate: FileSizeHelper.modifiedDate(at: entry.url),
                isStrongMatch: isSureLeftover(key: key, installedBundleIDs: installedBundleIDs,
                                              installedAppNames: installedAppNames)
            ))
        }
        let orphaned = grouped.map { key, items in
            OrphanedAppDataGroup(
                id: key,
                appIdentifier: key,
                displayName: prettifyIdentifier(key),
                items: items.sorted { $0.sizeBytes > $1.sizeBytes }
            )
        }

        progress?.advanceStep()
        return ScanSnapshot(
            installedApps: sortedApps,
            orphanedGroups: orphaned.sorted { $0.totalSizeBytes > $1.totalSizeBytes }
        )
    }

    private static func listAppBundles(home: String) -> [BundleCandidate] {
        let fm = FileManager.default
        let appDirs = [
            "/Applications",
            "\(home)/Applications",
            "/System/Applications"
        ]

        var bundles: [(url: URL, isSystem: Bool)] = []
        for dir in appDirs {
            let dirURL = URL(fileURLWithPath: dir)
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                if child.pathExtension.lowercased() == "app" {
                    bundles.append((child, dir.hasPrefix("/System")))
                } else {
                    // Check one level deeper for folders like /Applications/Utilities
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue,
                       let sub = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for item in sub where item.pathExtension.lowercased() == "app" {
                            bundles.append((item, dir.hasPrefix("/System")))
                        }
                    }
                }
            }
        }

        return bundles.map { bundleURL, isSystem in
            let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            let bundleID = (plist?["CFBundleIdentifier"] as? String) ?? ""
            let name = (plist?["CFBundleDisplayName"] as? String)
                ?? (plist?["CFBundleName"] as? String)
                ?? bundleURL.deletingPathExtension().lastPathComponent
            let version = (plist?["CFBundleShortVersionString"] as? String) ?? "—"
            return BundleCandidate(url: bundleURL, isSystem: isSystem, bundleID: bundleID, name: name, version: version)
        }
    }

    private static func libraryLocations() -> [(location: AppDataLocation, relativePath: String)] {
        [
            (.applicationSupport, "Library/Application Support"),
            (.caches, "Library/Caches"),
            (.preferences, "Library/Preferences"),
            (.containers, "Library/Containers"),
            (.groupContainers, "Library/Group Containers"),
            (.savedState, "Library/Saved Application State"),
            (.logs, "Library/Logs"),
            (.webKit, "Library/WebKit"),
            (.httpStorages, "Library/HTTPStorages")
        ]
    }

    private static func buildLibraryIndex(home: String) -> [LibraryEntry] {
        let fm = FileManager.default
        var entries: [LibraryEntry] = []
        for (location, relPath) in libraryLocations() {
            let dirURL = URL(fileURLWithPath: home).appendingPathComponent(relPath)
            guard let children = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                entries.append(LibraryEntry(url: child, name: name, lower: name.lowercased(), location: location))
            }
        }
        return entries
    }

    private static func matchEntries(index: [LibraryEntry], bundleID: String, appName: String) -> [MatchedEntry] {
        let fm = FileManager.default
        let lowerBundle = bundleID.lowercased()
        let lowerName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [MatchedEntry] = []
        var seen = Set<String>()

        // A short or shallow ID ("com.app") would prefix-match other vendors' folders, so only exact names count.
        let allowLooseBundleMatch = isSpecificBundleID(lowerBundle)

        for entry in index {
            let lowerEntry = entry.lower
            let matchesBundle = !lowerBundle.isEmpty && (
                lowerEntry == lowerBundle ||
                lowerEntry == "\(lowerBundle).plist" ||
                lowerEntry == "\(lowerBundle).savedstate" ||
                (allowLooseBundleMatch && lowerEntry.hasPrefix("\(lowerBundle).")) ||
                (allowLooseBundleMatch && entry.location == .groupContainers && lowerEntry.contains(lowerBundle))
            )
            let matchesName = lowerName.count >= 3 && (
                lowerEntry == lowerName ||
                lowerEntry == "\(lowerName).plist"
            )
            guard matchesBundle || matchesName, seen.insert(entry.url.path).inserted else { continue }

            // Only bundle-ID matches are pre-selected. A display name like "Notes" or "Mail" can belong to
            // another app's folder, so name matches are listed for the user to choose.
            let isStrong = !lowerBundle.isEmpty && (
                lowerEntry == lowerBundle ||
                lowerEntry == "\(lowerBundle).plist" ||
                lowerEntry == "\(lowerBundle).savedstate"
            )

            result.append(MatchedEntry(url: entry.url, name: entry.name, location: entry.location, isStrong: isStrong, parentContainer: nil))

            // Sandboxed apps keep their caches inside the container; surface them so they can be cleared alone.
            if entry.location == .containers {
                let nested = entry.url.appendingPathComponent("Data/Library/Caches")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue {
                    result.append(MatchedEntry(
                        url: nested,
                        name: "\(entry.name) › Caches",
                        location: .caches,
                        isStrong: isStrong,
                        parentContainer: entry.url.path
                    ))
                }
            }
        }
        return result
    }

    /// True when a bundle ID is specific enough to match folders that merely start with or contain it:
    /// at least three dot-separated parts and 10 characters, like "com.vendor.app".
    static func isSpecificBundleID(_ bundleID: String) -> Bool {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        return bundleID.count >= 10 && parts.count >= 3 && !parts.contains(where: \.isEmpty)
    }

    /// Spotlight's "last opened" date for a bundle. Nil when Spotlight hasn't recorded one.
    static func lastUsedDate(atPath path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private static func isProtectedLibraryEntry(_ name: String) -> Bool {
        let lower = name.lowercased()
        for prefix in appleAndSystemAllowlistPrefixes {
            if lower.hasPrefix(prefix.lowercased()) || lower == prefix.lowercased() {
                return true
            }
        }
        // Protect common CLI/dev tool directories in Application Support / Caches
        let devAllowlist: Set<String> = [
            "homebrew", "pip", "pnpm", "yarn", "npm", "uv", "cocoapods",
            "org.swift.swiftpm", "claude", "cursor", "vscode", "code",
            "google", "mozilla", "jetbrains", "docker", "raycast", "1password"
        ]
        if devAllowlist.contains(lower) { return true }
        return false
    }

    private static func normalizeIdentifier(_ name: String, location: AppDataLocation) -> String {
        var key = name
        if location == .preferences, key.hasSuffix(".plist") {
            key = String(key.dropLast(".plist".count))
        }
        if location == .savedState, key.hasSuffix(".savedState") {
            key = String(key.dropLast(".savedState".count))
        }
        return key.lowercased()
    }

    private static func matchesAnyInstalled(
        _ key: String,
        rawName: String,
        bundleIDs: Set<String>,
        appNames: Set<String>
    ) -> Bool {
        if bundleIDs.contains(key) || appNames.contains(key) {
            return true
        }
        for bid in bundleIDs {
            if key.hasPrefix("\(bid).") || bid.hasPrefix("\(key).") {
                return true
            }
            let components = bid.split(separator: ".").map(String.init)
            if let lastComponent = components.last, lastComponent == key {
                return true
            }
            // Vendor folders like "Microsoft" or "Adobe" belong to any installed app from that vendor.
            if components.dropFirst().dropLast().contains(key) {
                return true
            }
        }
        for appName in appNames where appName.count >= 4 {
            if key.contains(appName) || rawName.lowercased().contains(appName) {
                return true
            }
        }
        return false
    }

    /// Words that mark a folder as a helper or shared part rather than one app's own data.
    private static let sharedPartWords: Set<String> = [
        "helper", "helpers", "agent", "daemon", "shared", "common", "framework", "frameworks",
        "plugin", "plugins", "extension", "extensions", "electron", "updater", "update", "sparkle",
        "squirrel", "shipit", "crashpad", "crashreporter", "launcher", "service", "services",
        "login", "loginitem", "group"
    ]
    /// Reverse-DNS parts that say nothing about which app a folder belongs to.
    private static let domainWords: Set<String> = [
        "com", "org", "net", "io", "us", "co", "uk", "de", "app", "dev", "ai", "me", "inc"
    ]

    /// A leftover group is a sure match only when its name is a full app ID (like
    /// `com.bohemiancoding.sketch3` or `zoom.us`), it doesn't look like a helper or shared part, and
    /// no installed app shares a maker, name part or name with it. Furl only sees apps in the
    /// Applications folders and running ones, so CLI tools and apps on other drives can still use it;
    /// that's why even sure matches only auto-tick folders the app rebuilds. Anything else is Furl's
    /// best guess and is never ticked for the user.
    static func isSureLeftover(key: String, installedBundleIDs: Set<String>,
                               installedAppNames: Set<String> = []) -> Bool {
        let parts = key.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard parts.allSatisfy({ $0.allSatisfy(allowed.contains) }) else { return false }
        let words = parts.flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) }
        guard !words.contains(where: sharedPartWords.contains) else { return false }
        let nameParts = Set(parts.filter { !domainWords.contains($0) })
        guard !nameParts.isEmpty else { return false }
        for bundleID in installedBundleIDs {
            let installedParts = bundleID.lowercased().split(separator: ".").map(String.init)
            if installedParts.contains(where: nameParts.contains) { return false }
        }
        // An installed app named like a part of the ID ("Sketch" for com.vendor.sketch).
        let squashedNames = Set(installedAppNames.map { $0.lowercased().filter { !$0.isWhitespace } })
        if nameParts.contains(where: squashedNames.contains) { return false }
        return true
    }

    private static func prettifyIdentifier(_ key: String) -> String {
        let parts = key.split(separator: ".")
        if parts.count >= 3, let last = parts.last {
            return String(last).capitalized + " (\(key))"
        }
        return key.capitalized
    }

    /// Asks the app to quit and waits (up to `timeout`) for it to exit. Returns true if it is no longer running.
    @MainActor
    static func quitAppIfRunning(bundleIdentifier: String, timeout: Duration = .seconds(6)) async -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !apps.isEmpty else { return true }
        for app in apps {
            app.terminate()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return apps.allSatisfy(\.isTerminated)
    }
}

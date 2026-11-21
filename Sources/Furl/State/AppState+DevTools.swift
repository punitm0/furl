import Foundation

/// Apps & Leftovers › Developer tools (DevTools board): old language versions, Homebrew and global packages.
extension AppState {
    func scanDevTools() async {
        guard !isScanningDevTools else { return }
        isScanningDevTools = true
        defer { isScanningDevTools = false }
        // On a first launch the project list comes from the full scan's index. Wait for it, so no
        // version looks unused only because Furl hasn't seen the projects yet.
        var waited = 0
        while discoveredProjectRoots.isEmpty && !hasDiscoveredProjects && isScanningAny && waited < 600 {
            try? await Task.sleep(for: .seconds(1))
            waited += 1
        }
        let projectsKnown = hasDiscoveredProjects || !discoveredProjectRoots.isEmpty
        let roots = projectRoots
        let kept = keptDevVersions
        var snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: DevToolsScanner.scan(projectRoots: roots, kept: kept))
            }
        }
        if !projectsKnown {
            for i in snapshot.versions.indices where snapshot.versions[i].isRemovable {
                snapshot.versions[i].status = .unsure(project: "", file: "")
            }
        }
        devTools = snapshot
        cleanupStamps.devTools = CleanupStamp.read(snapshot.versions.filter(\.goesToTrash).map(\.path))
        hasScannedDevTools = true
    }

    /// "Always keep Node 16" from Why?, and its way back.
    func setKeep(_ version: DevVersion, _ keep: Bool) {
        if keep { keptDevVersions.insert(version.keepKey) } else { keptDevVersions.remove(version.keepKey) }
        devTools.versions = devTools.versions.map { v in
            guard v.keepKey == version.keepKey else { return v }
            var copy = v
            if keep, copy.status == .unused { copy.status = .kept }
            if !keep, copy.status == .kept { copy.status = .unused }
            return copy
        }.sorted(by: DevToolsScanner.versionOrder)
    }

    /// Removes the ticked rows. Version folders go the way every section's files go (the Trash, with
    /// Undo, unless the user picked permanent delete); rustup toolchains, Homebrew packages and global
    /// packages are removed by their own tool, for good. Everything is re-checked first.
    func removeDevTools(versions: [DevVersion], leaves: [BrewLeaf], packages: [GlobalPackage]) async {
        guard !isCleaning else { return }
        let roots = projectRoots
        let kept = keptDevVersions
        let folders = versions.filter(\.goesToTrash)
        let toolchains = versions.filter { !$0.goesToTrash }
        var messages: [String] = []
        var errors: [String] = []

        if !folders.isEmpty {
            let check = await Task.detached(priority: .userInitiated) {
                DevToolsRemover.recheckVersions(folders, projectRoots: roots, kept: kept)
            }.value
            noteSkippedSinceScan(check.skipped, in: "Developer tools")
            if !check.ok.isEmpty {
                let result = await delete(check.ok.map { CleanupItem(path: $0.path) }, stamps: cleanupStamps.devTools,
                                          context: "Developer tools")
                applyDeletionResult(result, label: "old version(s)", section: .apps, extraSkipped: check.skipped)
                let gone = check.ok.filter { !DevToolsScanner.fileExistsNoFollow($0.path) }
                if !gone.isEmpty {
                    let names = DevToolsCopy.list(gone.map(\.displayName))
                    let size = FileSizeHelper.formatBytes(result.reclaimedBytes)
                    messages.append(deletionMode == .moveToTrash ? "Moved \(names) to the Trash. \(size)."
                                                                : "Deleted \(names). Freed \(size).")
                }
            }
        }

        isCleaning = true
        let prefix = devTools.brewPrefix
        let permanent = await Task.detached(priority: .userInitiated) { () -> DevToolsRemover.Outcome in
            var total = DevToolsRemover.Outcome()
            func add(_ o: DevToolsRemover.Outcome) {
                total.removedNames += o.removedNames
                total.removedPaths += o.removedPaths
                total.freedBytes += o.freedBytes
                total.skipped += o.skipped
                total.errors += o.errors
            }
            if !toolchains.isEmpty {
                let check = DevToolsRemover.recheckVersions(toolchains, projectRoots: roots, kept: kept)
                total.skipped += check.skipped
                add(DevToolsRemover.uninstallToolchains(check.ok))
            }
            if !leaves.isEmpty, let prefix {
                add(DevToolsRemover.brewUninstall(leaves, prefix: prefix, projectRoots: roots))
            }
            if !packages.isEmpty { add(DevToolsRemover.uninstallPackages(packages)) }
            return total
        }.value
        isCleaning = false
        errors += permanent.errors
        noteSkippedSinceScan(permanent.skipped, in: "Developer tools")
        if !permanent.removedNames.isEmpty {
            recordPermanentDevRemoval(permanent, detail: "removed with each tool’s own uninstall")
            let names = DevToolsCopy.list(permanent.removedNames)
            messages.append("Removed \(names) for good. Freed \(FileSizeHelper.formatBytes(permanent.freedBytes)).")
        }
        finishDevRemoval(messages: messages, errors: errors)
    }

    /// "Clean Up Older Versions…": `brew cleanup` for those formulae.
    func cleanUpOldHomebrew(_ items: [BrewOldVersions]) async {
        guard !isCleaning, let prefix = devTools.brewPrefix, !items.isEmpty else { return }
        isCleaning = true
        let outcome = await Task.detached(priority: .userInitiated) {
            DevToolsRemover.brewCleanup(items, prefix: prefix)
        }.value
        isCleaning = false
        noteSkippedSinceScan(outcome.skipped, in: "Developer tools")
        var messages: [String] = []
        if !outcome.removedNames.isEmpty {
            recordPermanentDevRemoval(outcome, detail: "older Homebrew versions removed with brew cleanup")
            let count = outcome.removedNames.count
            messages.append("Removed \(count) older Homebrew \(count == 1 ? "version" : "versions"). Freed \(FileSizeHelper.formatBytes(outcome.freedBytes)).")
        }
        finishDevRemoval(messages: messages, errors: outcome.errors)
    }

    private func recordPermanentDevRemoval(_ outcome: DevToolsRemover.Outcome, detail: String) {
        recordFreed(outcome.freedBytes, items: outcome.removedNames.count, category: StatsEvent.Category(section: .apps))
        CommunityStatsReporter.shared.cleanupSucceeded()
        ActivityLog.shared.recordPermanent(section: .apps, count: outcome.removedNames.count, bytes: outcome.freedBytes,
                                           detail: "\(outcome.removedNames.count) \(detail)",
                                           items: outcome.removedPaths, skipped: outcome.skipped)
    }

    private func finishDevRemoval(messages: [String], errors: [String]) {
        if !messages.isEmpty { statusBanner = messages.joined(separator: " ") }
        if !errors.isEmpty { errorBanner = errors.joined(separator: "\n") }
        refreshDiskInfo()
        Task { await scanDevTools() }
    }
}

enum DevToolsCopy {
    /// "Node 16.20.2", "Node 16.20.2 and Python 3.9.18", "3 items".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) items"
        }
    }

    /// "2 years ago", "14 months ago", "3 days ago".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        if days < 1 { return "today" }
        if days < 60 { return days == 1 ? "yesterday" : "\(days) days ago" }
        let months = days / 30
        if months < 24 { return "\(months) months ago" }
        return "\(days / 365) years ago"
    }
}

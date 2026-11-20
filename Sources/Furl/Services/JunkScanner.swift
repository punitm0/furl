import AppKit
import Foundation

/// A tool invocation that cleans a junk item the tool owns (Docker data, simulator runtimes).
/// These never go through the Trash, so they can't be undone.
struct JunkCommand: Sendable, Hashable {
    let executable: String
    let arguments: [String]

    /// e.g. "docker builder prune -f", for confirmations and tooltips.
    var displayString: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

enum JunkScanner {
    /// `includeToolItems: false` skips Docker and Simulator items: they run external tools
    /// (Docker may talk to a remote engine) and are only ever offered in the main window.
    /// `emit` gets each check's items as soon as that check finishes (results still arriving);
    /// the return value is the whole, sorted list. `progress` counts checks done of all checks and
    /// stops between checks once cancelled.
    static func scan(projectRoots: [String], staleDays: Int = 30, includeToolItems: Bool = true,
                     progress: ScanProgress? = nil, emit: (([JunkItem]) -> Void)? = nil) -> [JunkItem] {
        var items: [JunkItem] = []
        var pkgCachePaths = Set<String>()
        var steps: [(String, () -> [JunkItem])] = [
            // Quick, fixed-location checks first so results arrive in seconds; the two walks of the
            // project folders (build folders, .DS_Store) go last.
            ("Checking package manager caches", {
                let found = scanPackageCaches()
                pkgCachePaths = Set(found.map(\.path))
                return found
            }),
            ("Checking app caches and logs", { scanSystemCachesAndLogs(excludingPaths: pkgCachePaths) }),
            ("Checking old installers", { scanOldInstallers(staleDays: staleDays) }),
            ("Checking local AI models", { scanLocalAIModels() }),
            ("Checking browser caches", { scanBrowserCaches() }),
            ("Checking Mail attachments", { scanMailAttachments() }),
            ("Checking project build folders", { scanDevArtifacts(in: projectRoots, staleDays: staleDays) }),
            ("Checking .DS_Store files", { scanDSStore(in: projectRoots) })
        ]
        if includeToolItems {
            steps.insert(("Checking Docker", { scanDocker() }), at: steps.count - 2)
            steps.insert(("Checking Simulators", { scanSimulators() }), at: steps.count - 2)
        }
        progress?.setSteps(done: 0, total: steps.count)
        for (title, step) in steps {
            if progress?.isCancelled == true { break }
            progress?.setPhase(title)
            let found = step().filter { $0.sizeBytes > 0 }
            items.append(contentsOf: found)
            if !found.isEmpty { emit?(found) }
            progress?.advanceStep()
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanDevArtifacts(in roots: [String], staleDays: Int) -> [JunkItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var items: [JunkItem] = []

        // Fixed Xcode / Simulator locations
        let fixedTargets: [(path: String, name: String, risk: RiskLevel, reason: String)] = [
            ("\(home)/Library/Developer/Xcode/DerivedData", "Xcode build files · DerivedData", .safe, "Rebuilt automatically by Xcode when needed"),
            ("\(home)/Library/Developer/Xcode/iOS DeviceSupport", "Xcode iOS DeviceSupport", .moderate, "Debug symbols for older iOS devices"),
            ("\(home)/Library/Developer/Xcode/Archives", "Xcode Archives", .review, "Old app archive builds (.xcarchive)"),
            ("\(home)/Library/Developer/CoreSimulator/Caches", "CoreSimulator Caches", .safe, "Cached simulator runtime data")
        ]

        for target in fixedTargets where fm.fileExists(atPath: target.path) {
            let url = URL(fileURLWithPath: target.path)
            let size = FileSizeHelper.directorySize(at: url)
            if size > 10_000_000 { // > 10 MB
                items.append(JunkItem(
                    id: target.path,
                    name: target.name,
                    path: target.path,
                    category: .devArtifacts,
                    risk: target.risk,
                    sizeBytes: size,
                    modifiedDate: FileSizeHelper.modifiedDate(at: url),
                    reason: target.reason
                ))
            }
        }

        // Walk project roots for node_modules, .next, .turbo, dist, .venv, target, __pycache__
        let heavyDirs: Set<String> = [
            "node_modules", ".next", ".turbo", ".nuxt", ".parcel-cache",
            ".venv", "venv", "target", "__pycache__", ".pytest_cache"
        ]

        var seen = Set<String>()
        // Roots covered by the shared index: candidate folders come from it (already sized), no walk.
        let index = ScanIndexContext.index
        var walkRoots: [String] = []
        var candidates: [URL] = []
        if let index {
            let indexedRoots = roots.filter { index.covers($0) && index.dirID(forPath: $0) != nil }
            walkRoots = roots.filter { !indexedRoots.contains($0) }
            if !indexedRoots.isEmpty {
                let inRoots = index.inclusionMask(roots: indexedRoots)
                // Mirrors the walk: never inside .git/Library/.Trash, packages, or another heavy folder.
                let blocked = index.exclusionMask { id, record in
                    guard record.parent >= 0 else { return false }
                    let parentName = index.dirName(record.parent)
                    return record.flags.contains(.package)
                        || [".git", "Library", ".Trash"].contains(index.dirName(id))
                        || heavyDirs.contains(parentName) && record.parent != FileIndex.rootID
                }
                for id in index.directories(named: heavyDirs) where inRoots[Int(id)] && !blocked[Int(id)] {
                    candidates.append(URL(fileURLWithPath: index.path(ofDir: id)))
                }
            }
        } else {
            walkRoots = roots
        }
        for url in candidates {
            let name = url.lastPathComponent
            guard isGenuineArtifactDir(url, name: name) else { continue }
            if let item = devArtifactItem(url: url, name: name, staleDays: staleDays, seen: &seen) { items.append(item) }
        }

        for root in walkRoots {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      vals.isDirectory == true,
                      vals.isSymbolicLink != true else { continue }

                if name == ".git" || name == "Library" || name == ".Trash" {
                    enumerator.skipDescendants()
                    continue
                }

                if heavyDirs.contains(name) {
                    enumerator.skipDescendants()
                    guard isGenuineArtifactDir(url, name: name) else { continue }
                    if let item = devArtifactItem(url: url, name: name, staleDays: staleDays, seen: &seen) { items.append(item) }
                }
            }
        }

        return items
    }

    private static func devArtifactItem(url: URL, name: String, staleDays: Int, seen: inout Set<String>) -> JunkItem? {
        let path = url.path
        guard seen.insert(path).inserted else { return nil }

        let daysOld = FileSizeHelper.daysSinceModified(at: url) ?? 0
        let size = FileSizeHelper.directorySize(at: url)
        // Small dependency folders only count once unused; big ones are always worth showing.
        let gated = (name == "node_modules" || name == ".venv" || name == "venv") && size < 200_000_000
        if gated && daysOld < staleDays {
            return nil
        }
        guard size > 5_000_000 else { return nil }

        let parentName = url.deletingLastPathComponent().lastPathComponent
        let risk: RiskLevel = (name == ".next" || name == ".turbo" || name == "__pycache__" || name == ".pytest_cache") ? .safe : .moderate
        let reason = devArtifactReason(daysOld: daysOld, staleDays: staleDays, projectName: parentName)

        return JunkItem(
            id: path,
            name: "\(parentName)/\(name)",
            path: path,
            category: .devArtifacts,
            risk: risk,
            sizeBytes: size,
            modifiedDate: FileSizeHelper.modifiedDate(at: url),
            reason: reason,
            listedOnlyWhenUnused: gated,
            projectName: parentName
        )
    }

    static func devArtifactReason(daysOld: Int, staleDays: Int, projectName: String) -> String {
        daysOld >= staleDays
            ? "Unused for \(daysOld) days in \(projectName)"
            : "Build/dependency folder in \(projectName) (reinstallable)"
    }

    /// Avoid false positives for generic folder names like `target` or `venv`.
    private static func isGenuineArtifactDir(_ url: URL, name: String) -> Bool {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        switch name {
        case "target":
            // Rust (Cargo), Maven, sbt build output
            return ["Cargo.toml", "pom.xml", "build.sbt"].contains {
                fm.fileExists(atPath: parent.appendingPathComponent($0).path)
            }
        case "venv", ".venv":
            return fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
        default:
            return true
        }
    }

    private static func scanPackageCaches() -> [JunkItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates: [(path: String, name: String, reason: String)] = [
            ("\(home)/Library/Caches/Homebrew", "Homebrew Cache", "Downloaded formula & cask installers"),
            ("\(home)/.npm", "npm Cache", "Cached npm tarballs and metadata"),
            ("\(home)/Library/Caches/pnpm", "pnpm Cache", "Cached pnpm packages"),
            ("\(home)/Library/Caches/Yarn", "Yarn Cache", "Cached Yarn packages"),
            ("\(home)/Library/Caches/pip", "pip Cache", "Cached Python wheels"),
            ("\(home)/.cache/pip", "pip Cache (~/.cache)", "Cached Python wheels"),
            ("\(home)/.cache/uv", "uv Cache", "Cached uv Python packages"),
            ("\(home)/Library/Caches/org.swift.swiftpm", "SwiftPM Cache", "Cached Swift Package Manager repositories"),
            ("\(home)/Library/Caches/CocoaPods", "CocoaPods Cache", "Cached CocoaPods specs and pods"),
            ("\(home)/.gradle/caches", "Gradle Cache", "Downloaded Gradle dependencies & build cache"),
            ("\(home)/.cargo/registry/cache", "Cargo Registry Cache", "Downloaded Rust crate archives"),
            ("\(home)/Library/Caches/go-build", "Go Build Cache", "Compiled Go build artifacts"),
            ("\(home)/.bun/install/cache", "Bun Cache", "Cached Bun packages"),
            ("\(home)/Library/Caches/ms-playwright", "Playwright Browsers", "Downloaded browser binaries for Playwright")
            // Chrome and Safari caches moved to Browser caches (scanBrowserCaches), one row per browser.
        ]

        var items: [JunkItem] = []
        for entry in candidates where fm.fileExists(atPath: entry.path) {
            let url = URL(fileURLWithPath: entry.path)
            let size = FileSizeHelper.directorySize(at: url)
            if size > 10_000_000 {
                items.append(JunkItem(
                    id: entry.path,
                    name: entry.name,
                    path: entry.path,
                    category: .packageCaches,
                    risk: .safe,
                    sizeBytes: size,
                    modifiedDate: FileSizeHelper.modifiedDate(at: url),
                    reason: entry.reason
                ))
            }
        }
        return items
    }

    private static func scanSystemCachesAndLogs(excludingPaths: Set<String>) -> [JunkItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var items: [JunkItem] = []

        let protectedCachePrefixes = [
            "com.apple.", "CloudKit", "FamilyCircle", "GeoServices", "PassKit"
        ]
        let skipCacheFolderNames: Set<String> = [
            "Homebrew", "pnpm", "Yarn", "pip", "org.swift.swiftpm", "CocoaPods", "Google",
            "go-build", "ms-playwright",
            // Browser cache roots: only their Cache folders are offered, under Browser caches.
            "BraveSoftware", "Microsoft Edge", "Arc", "company.thebrowser.Browser", "Firefox"
        ]

        let cachesURL = URL(fileURLWithPath: "\(home)/Library/Caches")
        if let children = try? fm.contentsOfDirectory(at: cachesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in children {
                let name = child.lastPathComponent
                if protectedCachePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
                if skipCacheFolderNames.contains(name) { continue }
                if excludingPaths.contains(child.path) || excludingPaths.contains(where: { $0.hasPrefix(child.path + "/") }) {
                    continue
                }
                let size = FileSizeHelper.directorySize(at: child)
                if size > 50_000_000 { // > 50 MB
                    items.append(JunkItem(
                        id: child.path,
                        name: name,
                        path: child.path,
                        category: .systemCaches,
                        risk: .safe,
                        sizeBytes: size,
                        modifiedDate: FileSizeHelper.modifiedDate(at: child),
                        reason: "Application cache folder"
                    ))
                }
            }
        }

        // Scan individual children of ~/Library/Logs so we never double-count DiagnosticReports or delete the ~/Library/Logs root folder
        let logsURL = URL(fileURLWithPath: "\(home)/Library/Logs")
        if let logChildren = try? fm.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in logChildren {
                let size = FileSizeHelper.directorySize(at: child)
                guard size > 5_000_000 else { continue }
                let isDiag = child.lastPathComponent == "DiagnosticReports"
                items.append(JunkItem(
                    id: child.path,
                    name: isDiag ? "Crash & Diagnostic Reports" : "Logs: \(child.lastPathComponent)",
                    path: child.path,
                    category: .logsAndCrash,
                    risk: .safe,
                    sizeBytes: size,
                    modifiedDate: FileSizeHelper.modifiedDate(at: child),
                    reason: isDiag ? "Old macOS app crash reports" : "Application log folder"
                ))
            }
        }

        return items
    }

    private static func scanOldInstallers(staleDays: Int) -> [JunkItem] {
        let fm = FileManager.default
        let downloadsURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard let children = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let installerExts: Set<String> = ["dmg", "pkg", "iso", "mpkg"]
        let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "xz"]

        var items: [JunkItem] = []
        for child in children {
            let ext = child.pathExtension.lowercased()
            let isInstaller = installerExts.contains(ext)
            let isArchive = archiveExts.contains(ext)
            guard isInstaller || isArchive else { continue }

            let days = FileSizeHelper.daysSinceModified(at: child) ?? 0
            let threshold = isInstaller ? min(7, staleDays) : staleDays
            guard days >= threshold else { continue }

            let size = FileSizeHelper.directorySize(at: child)
            guard size > 5_000_000 else { continue }

            // Only plain installer images are Safe; an encrypted or writable image, or any .iso, may be
            // a vault or a backup, so it waits for review.
            let plainInstaller = ext == "pkg" || ext == "mpkg"
                || (ext == "dmg" && DiskImageCheck.isPlainInstallerImage(child))
            items.append(JunkItem(
                id: child.path,
                name: child.lastPathComponent,
                path: child.path,
                category: .installers,
                risk: plainInstaller ? .safe : .review,
                sizeBytes: size,
                modifiedDate: FileSizeHelper.modifiedDate(at: child),
                reason: plainInstaller ? "Installer image (\(days)d old)"
                    : (isInstaller ? "Disk image (\(days)d old); check it isn't a backup" : "Old archive in Downloads (\(days)d old)"),
                listedOnlyWhenUnused: isArchive
            ))
        }

        return items
    }

    private static func scanDSStore(in roots: [String]) -> [JunkItem] {
        let fm = FileManager.default
        var dsPaths: [String] = []
        var walkRoots = roots
        if let index = ScanIndexContext.index {
            let indexedRoots = roots.filter { index.covers($0) && index.dirID(forPath: $0) != nil }
            walkRoots = roots.filter { !indexedRoots.contains($0) }
            if !indexedRoots.isEmpty {
                let inRoots = index.inclusionMask(roots: indexedRoots)
                let blocked = index.exclusionMask { id, record in
                    record.mode != .indexed || ["node_modules", ".git", ".venv", "Library", ".Trash"].contains(index.dirName(id))
                }
                for file in index.files where inRoots[Int(file.dir)] && !blocked[Int(file.dir)] && index.name(file.name) == ".DS_Store" {
                    dsPaths.append(index.path(of: file))
                }
            }
        }

        for root in walkRoots {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == "node_modules" || name == ".git" || name == ".venv" || name == "Library" || name == ".Trash" {
                    enumerator.skipDescendants()
                    continue
                }
                if url.lastPathComponent == ".DS_Store" {
                    dsPaths.append(url.path)
                }
            }
        }

        return dsPaths.prefix(200).map { path in
            let url = URL(fileURLWithPath: path)
            return JunkItem(
                id: path,
                name: "\(url.deletingLastPathComponent().lastPathComponent)/.DS_Store",
                path: path,
                category: .dsStore,
                risk: .safe,
                sizeBytes: max(4096, FileSizeHelper.singleFileSize(at: url)),
                modifiedDate: FileSizeHelper.modifiedDate(at: url),
                reason: "Finder folder metadata file"
            )
        }
    }
}


// MARK: - Cleaning

extension JunkScanner {
    /// Cleans a mix of file-based and command-based junk items.
    /// File items (plus their `extraPaths`) go through `DeletionService` with `mode`; command items run their tool
    /// and are always permanent. Returns the merged result and the ids of items that are now gone.
    /// With `stamps` (the scan's `CleanupStamp`s), every file item is re-checked first and each path
    /// again right before it moves; items that changed since the scan are left alone and counted in
    /// `result.skippedCount`. Command items have no file to stamp and keep their own re-checks below.
    static func clean(_ items: [JunkItem], mode: DeletionMode, progress: ScanProgress? = nil,
                      stamps: [String: CleanupStamp]? = nil) -> (result: CleanupResult, cleanedIDs: Set<String>) {
        // Re-check right before cleaning: a browser opened since the scan is using its cache now.
        let liveBrowserItems = items.filter { $0.category == .browserCaches && browserIsRunning(forCachePath: $0.path) }
        let liveIDs = Set(liveBrowserItems.map(\.id))
        let fileItems = items.filter { $0.command == nil && !liveIDs.contains($0.id) }
        let commandItems = items.filter { $0.command != nil }

        var cleaned = Set<String>()
        var fileResult = CleanupResult(succeededCount: 0, failedCount: 0, reclaimedBytes: 0, errors: [])
        var skippedItems = 0
        if !fileItems.isEmpty {
            var toClean = fileItems
            if let stamps {
                let checks = fileItems.map { item -> CleanupItem in
                    var check = CleanupItem(path: item.path, allPaths: [item.path] + item.extraPaths)
                    check.isBrowserCache = item.category == .browserCaches
                    return check
                }
                let passed = Set(CleanupRecheck.verify(checks, stamps: stamps).verified.map(\.path))
                toClean = fileItems.filter { passed.contains($0.path) }
                skippedItems = fileItems.count - toClean.count
            }
            let paths = toClean.flatMap { [$0.path] + $0.extraPaths }
            if !paths.isEmpty {
                fileResult = DeletionService.deletePaths(paths, mode: mode, progress: progress, expected: stamps)
            }
            let late = Set(fileResult.skippedPaths)
            skippedItems += toClean.filter { ([$0.path] + $0.extraPaths).contains(where: late.contains) }.count
            for item in fileItems where (try? FileManager.default.attributesOfItem(atPath: item.path)) == nil {
                cleaned.insert(item.id)
            }
        }

        var succeeded = 0
        var failed = liveBrowserItems.count
        var reclaimed: Int64 = 0
        var errors: [String] = liveBrowserItems.map { "\($0.name): skipped, the browser is open. Quit it and clean again." }
        for item in commandItems {
            guard let command = item.command else { continue }
            // Re-check right before pruning: the Docker context may have been switched to a remote engine.
            if item.category == .docker, !dockerEngineIsLocal(command.executable) {
                failed += 1
                errors.append("\(item.name): skipped, Docker points at a remote engine")
                continue
            }
            progress?.setPhase(item.name)
            defer { progress?.addItems(1) }
            let output = ShellRunner.run(command.executable, arguments: command.arguments, timeout: 900)
            if output.exitCode == 0 {
                succeeded += 1
                reclaimed += item.sizeBytes
                cleaned.insert(item.id)
            } else {
                failed += 1
                let detail = (output.stderr.isEmpty ? output.stdout : output.stderr)
                    .split(separator: "\n").first.map(String.init) ?? "exit code \(output.exitCode)"
                errors.append("\(item.name): \(detail)")
            }
        }

        let merged = CleanupResult(
            succeededCount: fileResult.succeededCount + succeeded,
            failedCount: fileResult.failedCount + failed,
            reclaimedBytes: fileResult.reclaimedBytes + reclaimed,
            errors: fileResult.errors + errors,
            trashedItems: fileResult.trashedItems,
            skippedPaths: fileResult.skippedPaths,
            skippedCount: skippedItems
        )
        return (merged, cleaned)
    }
}

// MARK: - Local AI models

extension JunkScanner {
    /// Ollama models (per model:tag), Hugging Face hub repos and LM Studio models. Always risk `.review`:
    /// they're big, slow to download again, and only the user knows which ones they still use.
    static func scanLocalAIModels() -> [JunkItem] {
        scanOllama() + scanHuggingFace() + scanLMStudio()
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// A manifest layer digest Furl will turn into a blob path: exactly "sha256:" and 64 lowercase hex digits.
    static func isValidOllamaDigest(_ digest: String) -> Bool {
        digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func scanOllama() -> [JunkItem] {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let custom = env["OLLAMA_MODELS"] ?? ""
        let root = custom.isEmpty ? "\(home)/.ollama/models" : custom
        let manifestsURL = URL(fileURLWithPath: root).appendingPathComponent("manifests")
        let blobsURL = URL(fileURLWithPath: root).appendingPathComponent("blobs")
        guard fm.fileExists(atPath: manifestsURL.path),
              let enumerator = fm.enumerator(at: manifestsURL, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }

        struct Manifest {
            let url: URL
            let name: String
            let blobs: [(path: String, isWeights: Bool)]
        }

        var manifests: [Manifest] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            var layers = (json["layers"] as? [[String: Any]]) ?? []
            if let config = json["config"] as? [String: Any] { layers.append(config) }
            let blobs: [(String, Bool)] = layers.compactMap { layer in
                // Only well-formed digests: a crafted manifest could otherwise point a blob path anywhere
                // ("../../Documents"), and removing the model would delete it.
                guard let digest = layer["digest"] as? String, isValidOllamaDigest(digest) else { return nil }
                let file = digest.replacingOccurrences(of: ":", with: "-")
                let isWeights = (layer["mediaType"] as? String)?.hasSuffix(".model") == true
                return (blobsURL.appendingPathComponent(file).path, isWeights)
            }

            // manifests/<host>/<namespace>/<model>/<tag>
            let parts = url.path.dropFirst(manifestsURL.path.count + 1).split(separator: "/").map(String.init)
            guard parts.count >= 4 else { continue }
            let (host, namespace, model, tag) = (parts[0], parts[1], parts[2], parts[3])
            let base = host == "registry.ollama.ai"
                ? (namespace == "library" ? model : "\(namespace)/\(model)")
                : "\(host)/\(namespace)/\(model)"
            manifests.append(Manifest(url: url, name: "\(base):\(tag)", blobs: blobs))
        }

        // Blobs can be shared between tags (e.g. llama3:latest and llama3:8b). Only blobs no other model uses
        // are removed with a model, so removing one never breaks another.
        var refCount: [String: Int] = [:]
        for manifest in manifests {
            for blob in Set(manifest.blobs.map(\.path)) { refCount[blob, default: 0] += 1 }
        }

        return manifests.compactMap { manifest in
            let unique = Array(Set(manifest.blobs.map(\.path))).filter { refCount[$0] == 1 && fm.fileExists(atPath: $0) }.sorted()
            let size = unique.reduce(Int64(0)) { $0 + FileSizeHelper.singleFileSize(at: URL(fileURLWithPath: $1)) }
            guard size > 0 else { return nil }

            let downloaded = FileSizeHelper.modifiedDate(at: manifest.url)
            // Ollama doesn't log runs, but loading a model reads its weights, which updates the access date.
            let lastUsed = manifest.blobs.filter(\.isWeights)
                .compactMap { try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate }
                .max()
            let reason: String
            if let lastUsed, lastUsed > (downloaded ?? .distantPast).addingTimeInterval(60) {
                reason = "Last run \(ago(lastUsed))"
            } else if let downloaded {
                reason = "Downloaded \(ago(downloaded)), no run recorded since"
            } else {
                reason = "Ollama model"
            }
            return JunkItem(
                id: manifest.url.path,
                name: "Ollama · \(manifest.name)",
                path: manifest.url.path,
                category: .aiModels,
                risk: .review,
                sizeBytes: size,
                modifiedDate: downloaded,
                reason: reason + " · download again with ollama pull",
                extraPaths: unique,
                lastUsedDate: lastUsed
            )
        }
    }

    private static func scanHuggingFace() -> [JunkItem] {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        let hub: String = value("HF_HUB_CACHE") ?? value("HUGGINGFACE_HUB_CACHE")
            ?? value("HF_HOME").map { "\($0)/hub" } ?? "\(home)/.cache/huggingface/hub"
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: hub), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { url in
            // models--org--name, datasets--org--name, spaces--org--name
            let parts = url.lastPathComponent.components(separatedBy: "--")
            guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]) else { return nil }
            let size = FileSizeHelper.directorySize(at: url)
            guard size > 10_000_000 else { return nil }
            let repo = parts.dropFirst().joined(separator: "/")
            let kind = parts[0] == "models" ? "" : " (\(parts[0].dropLast()))"
            let modified = FileSizeHelper.modifiedDate(at: url)
            return JunkItem(
                id: url.path,
                name: "Hugging Face · \(repo)\(kind)",
                path: url.path,
                category: .aiModels,
                risk: .review,
                sizeBytes: size,
                modifiedDate: modified,
                reason: (modified.map { "Updated \(ago($0))" } ?? "Hub cache") + " · downloads again on next use"
            )
        }
    }

    private static func scanLMStudio() -> [JunkItem] {
        let fm = FileManager.default
        var items: [JunkItem] = []
        for root in ["\(home)/.lmstudio/models", "\(home)/.cache/lm-studio/models"] {
            guard let publishers = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for publisher in publishers {
                guard let models = try? fm.contentsOfDirectory(
                    at: publisher, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for model in models where (try? model.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let size = FileSizeHelper.directorySize(at: model)
                    guard size > 10_000_000 else { continue }
                    let modified = FileSizeHelper.modifiedDate(at: model)
                    items.append(JunkItem(
                        id: model.path,
                        name: "LM Studio · \(publisher.lastPathComponent)/\(model.lastPathComponent)",
                        path: model.path,
                        category: .aiModels,
                        risk: .review,
                        sizeBytes: size,
                        modifiedDate: modified,
                        reason: (modified.map { "Downloaded \(ago($0))" } ?? "LM Studio model") + " · download again in LM Studio"
                    ))
                }
            }
        }
        return items
    }

    static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Docker

extension JunkScanner {
    /// Dangling images, stopped containers and build cache, read from the docker CLI. Cleaned with docker's own
    /// prune commands (the data lives inside Docker's VM disk, not as files Furl could trash), so these are
    /// permanent and risk `.review`. Nothing is listed when the CLI is missing or the daemon isn't running.
    static func scanDocker() -> [JunkItem] {
        guard let docker = dockerPath(), dockerEngineIsLocal(docker) else { return [] }
        // Fails fast when Docker Desktop / the daemon isn't running.
        let info = ShellRunner.run(docker, arguments: ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
        guard info.exitCode == 0 else { return [] }

        var reclaimable: [String: Int64] = [:]
        let df = ShellRunner.run(docker, arguments: ["system", "df", "--format", "{{json .}}"], timeout: 30)
        for line in df.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["Type"] as? String,
                  let value = json["Reclaimable"] as? String
            else { continue }
            reclaimable[type] = parseDockerSize(value)
        }

        let note = " · Docker Desktop hands the space back to macOS shortly after"
        var items: [JunkItem] = []

        let dangling = ShellRunner.run(docker, arguments: ["image", "ls", "--filter", "dangling=true", "--format", "{{.Size}}"], timeout: 30)
        let danglingSizes = dangling.exitCode == 0 ? dangling.stdout.split(separator: "\n").map { parseDockerSize(String($0)) } : []
        if !danglingSizes.isEmpty {
            items.append(dockerItem(
                key: "dangling-images",
                name: "\(danglingSizes.count) untagged Docker image\(danglingSizes.count == 1 ? "" : "s")",
                size: danglingSizes.reduce(0, +),
                reason: "Untagged image layers left behind by rebuilds" + note,
                command: JunkCommand(executable: docker, arguments: ["image", "prune", "-f"])
            ))
        }

        let stopped = ShellRunner.run(docker, arguments: ["ps", "-a", "-q", "--filter", "status=exited", "--filter", "status=created"], timeout: 30)
        let stoppedCount = stopped.exitCode == 0 ? stopped.stdout.split(separator: "\n").count : 0
        if stoppedCount > 0 {
            items.append(dockerItem(
                key: "stopped-containers",
                name: "Docker · \(stoppedCount) stopped container\(stoppedCount == 1 ? "" : "s")",
                size: max(reclaimable["Containers"] ?? 0, 4096),
                reason: "Removes stopped containers and their changes; named volumes are kept" + note,
                command: JunkCommand(executable: docker, arguments: ["container", "prune", "-f"])
            ))
        }

        if let cache = reclaimable["Build Cache"], cache > 0 {
            items.append(dockerItem(
                key: "build-cache",
                name: "Docker · build cache",
                size: cache,
                reason: "Unused build layers; the next build is slower once" + note,
                command: JunkCommand(executable: docker, arguments: ["builder", "prune", "-f"])
            ))
        }
        return items
    }

    private static func dockerItem(key: String, name: String, size: Int64, reason: String, command: JunkCommand) -> JunkItem {
        JunkItem(
            id: "docker://\(key)",
            name: name,
            path: "docker://\(key)",
            category: .docker,
            risk: .review,
            sizeBytes: size,
            modifiedDate: nil,
            reason: reason,
            command: command
        )
    }

    /// True only when the docker CLI talks to an engine on this Mac (a unix socket). Furl never prunes a
    /// remote engine (DOCKER_HOST or a context pointing at tcp:// or ssh://), and doesn't touch the network.
    static func dockerEngineIsLocal(_ docker: String) -> Bool {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], !host.isEmpty {
            return host.hasPrefix("unix://")
        }
        let r = ShellRunner.run(docker, arguments: ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: 8)
        guard r.exitCode == 0 else { return false }
        let endpoint = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return endpoint.hasPrefix("unix://")
    }

    private static func dockerPath() -> String? {
        let fm = FileManager.default
        for candidate in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Parses docker's human sizes ("8.981GB", "16.38kB (1%)", "0B"). Docker uses decimal units.
    static func parseDockerSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let number = token.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return 0 }
        let unit = token.dropFirst(number.count).uppercased()
        let multiplier: Double
        switch unit {
        case "KB": multiplier = 1e3
        case "MB": multiplier = 1e6
        case "GB": multiplier = 1e9
        case "TB": multiplier = 1e12
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }
}

// MARK: - iOS Simulators

extension JunkScanner {
    /// Old simulator runtimes (every deletable runtime except the newest per platform) and devices whose runtime
    /// is gone. Both are removed with simctl, so they're permanent and never auto-selected.
    static func scanSimulators() -> [JunkItem] {
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return [] }
        var items: [JunkItem] = []

        // Unavailable devices
        let devices = ShellRunner.run(xcrun, arguments: ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
        if devices.exitCode == 0,
           let data = devices.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            let udids = byRuntime.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
            if !udids.isEmpty {
                let devicesDir = "\(home)/Library/Developer/CoreSimulator/Devices"
                let size = udids.reduce(Int64(0)) { $0 + FileSizeHelper.directorySize(at: URL(fileURLWithPath: "\(devicesDir)/\($1)")) }
                items.append(JunkItem(
                    id: "simctl://unavailable-devices",
                    name: "\(udids.count) unavailable simulator device\(udids.count == 1 ? "" : "s")",
                    path: "simctl://unavailable-devices",
                    category: .simulators,
                    risk: .moderate,
                    sizeBytes: max(size, 4096),
                    modifiedDate: nil,
                    reason: "Simulators whose iOS runtime is no longer installed; they can't boot",
                    command: JunkCommand(executable: xcrun, arguments: ["simctl", "delete", "unavailable"])
                ))
            }
        }

        // Old runtimes
        let runtimes = ShellRunner.run(xcrun, arguments: ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard runtimes.exitCode == 0,
              let data = runtimes.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return items }

        struct Runtime {
            let identifier: String
            let platform: String
            let version: String
            let size: Int64
            let lastUsed: Date?
        }
        let iso = ISO8601DateFormatter()
        let all: [Runtime] = json.values.compactMap { entry in
            guard entry["deletable"] as? Bool == true,
                  let identifier = entry["identifier"] as? String,
                  let version = entry["version"] as? String
            else { return nil }
            let platform = (entry["platformIdentifier"] as? String) ?? "unknown"
            let size = (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let lastUsed = (entry["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
            return Runtime(identifier: identifier, platform: platform, version: version, size: size, lastUsed: lastUsed)
        }

        func versionParts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        func isNewer(_ a: String, than b: String) -> Bool {
            let (x, y) = (versionParts(a), versionParts(b))
            for i in 0..<max(x.count, y.count) {
                let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
                if l != r { return l > r }
            }
            return false
        }

        for (platform, group) in Dictionary(grouping: all, by: \.platform) {
            guard let newest = group.max(by: { isNewer($1.version, than: $0.version) }) else { continue }
            let osName = platformName(platform)
            for runtime in group where runtime.identifier != newest.identifier && runtime.size > 0 {
                let used = runtime.lastUsed.map { "last used \(ago($0))" } ?? "no recent use recorded"
                items.append(JunkItem(
                    id: "simruntime://\(runtime.identifier)",
                    name: "\(osName) \(runtime.version) Simulator runtime",
                    path: "simruntime://\(runtime.identifier)",
                    category: .simulators,
                    risk: .review,
                    sizeBytes: runtime.size,
                    modifiedDate: runtime.lastUsed,
                    reason: "Older than \(osName) \(newest.version), \(used) · reinstall from Xcode › Settings › Components",
                    command: JunkCommand(executable: xcrun, arguments: ["simctl", "runtime", "delete", runtime.identifier]),
                    lastUsedDate: runtime.lastUsed
                ))
            }
        }
        return items
    }

    private static func platformName(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: return "Simulator"
        }
    }
}

// MARK: - Browser caches

extension JunkScanner {
    /// A browser whose cache folders Furl offers. Only folders that hold the web cache are listed:
    /// never history, cookies, passwords, sessions, local storage, IndexedDB or extensions.
    struct BrowserCacheSource: Sendable {
        enum Layout: Sendable {
            /// Fixed cache folders (Safari).
            case folders([String])
            /// Chromium "User Data" roots: each profile's Cache, Code Cache and GPUCache.
            case chromium(roots: [String])
            /// Firefox profile roots: each profile's cache2.
            case firefox(roots: [String])
        }

        let name: String
        let bundleIDs: [String]
        let layout: Layout

        /// The roots this browser's cache paths live under, for matching a path back to its browser.
        var roots: [String] {
            switch layout {
            case .folders(let paths): return paths
            case .chromium(let roots), .firefox(let roots): return roots
            }
        }
    }

    /// Per-profile folder names Chromium uses for disposable caches.
    static let chromiumCacheFolderNames = ["Cache", "Code Cache", "GPUCache"]

    static func browserCacheSources(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [BrowserCacheSource] {
        let caches = "\(home)/Library/Caches"
        let support = "\(home)/Library/Application Support"
        func chromium(_ vendorPath: String) -> [String] {
            ["\(caches)/\(vendorPath)", "\(support)/\(vendorPath)"]
        }
        return [
            BrowserCacheSource(name: "Safari", bundleIDs: ["com.apple.Safari"],
                               // Newer Safari keeps its cache inside its sandbox container (Library/Caches only).
                               layout: .folders(["\(caches)/com.apple.Safari",
                                                 "\(home)/Library/Containers/com.apple.Safari/Data/Library/Caches"])),
            BrowserCacheSource(name: "Google Chrome", bundleIDs: ["com.google.Chrome"],
                               layout: .chromium(roots: chromium("Google/Chrome"))),
            BrowserCacheSource(name: "Brave", bundleIDs: ["com.brave.Browser"],
                               layout: .chromium(roots: chromium("BraveSoftware/Brave-Browser"))),
            BrowserCacheSource(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"],
                               layout: .chromium(roots: chromium("Microsoft Edge"))),
            BrowserCacheSource(name: "Arc", bundleIDs: ["company.thebrowser.Browser"],
                               layout: .chromium(roots: chromium("Arc/User Data"))),
            BrowserCacheSource(name: "Firefox", bundleIDs: ["org.mozilla.firefox"],
                               layout: .firefox(roots: ["\(caches)/Firefox/Profiles"]))
        ]
    }

    /// The cache folders that exist for `source`, read-only. Chromium and Firefox profiles are the
    /// direct subfolders of each root; only the named cache folders inside a profile are returned.
    static func cachePaths(for source: BrowserCacheSource) -> [String] {
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        func profiles(in root: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .map { "\(root)/\($0)" }
                .filter(isDirectory)
        }
        switch source.layout {
        case .folders(let paths):
            return paths.filter(isDirectory)
        case .chromium(let roots):
            return roots.flatMap { root in
                profiles(in: root).flatMap { profile in
                    chromiumCacheFolderNames.map { "\(profile)/\($0)" }.filter(isDirectory)
                }
            }
        case .firefox(let roots):
            return roots.flatMap { root in profiles(in: root).map { "\($0)/cache2" }.filter(isDirectory) }
        }
    }

    /// True when `path` is one of the cache folders this category may remove: a Safari cache folder,
    /// a Chromium profile's Cache/Code Cache/GPUCache, or a Firefox profile's cache2.
    static func isBrowserCachePath(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let standard = url.path
        let parent = url.deletingLastPathComponent().deletingLastPathComponent().path
        for source in browserCacheSources(home: home) {
            switch source.layout {
            case .folders(let paths):
                if paths.contains(standard) { return true }
            case .chromium(let roots):
                if roots.contains(parent), chromiumCacheFolderNames.contains(url.lastPathComponent) { return true }
            case .firefox(let roots):
                if roots.contains(parent), url.lastPathComponent == "cache2" { return true }
            }
        }
        return false
    }

    /// The browser that owns a cache path from this category, if any.
    static func browserSource(forCachePath path: String) -> BrowserCacheSource? {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return browserCacheSources().first { source in
            source.roots.contains { standard == $0 || standard.hasPrefix($0 + "/") }
        }
    }

    static func isRunning(_ source: BrowserCacheSource) -> Bool {
        source.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    static func browserIsRunning(forCachePath path: String) -> Bool {
        browserSource(forCachePath: path).map(isRunning) ?? false
    }

    /// One row per browser with its cache folders (first folder is `path`, the rest go to the Trash with it).
    /// A browser that's open is skipped: removing a cache it's writing to can upset it.
    static func scanBrowserCaches() -> [JunkItem] {
        browserCacheSources().compactMap { source in
            let paths = cachePaths(for: source).filter { isBrowserCachePath($0) }
            guard let first = paths.first, !isRunning(source) else { return nil }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let size = urls.reduce(Int64(0)) { $0 + FileSizeHelper.directorySize(at: $1) }
            guard size > 10_000_000 else { return nil }
            let profileCount = source.layout.isFolders ? 1 : Set(urls.map { $0.deletingLastPathComponent().lastPathComponent }).count
            let profiles = profileCount > 1 ? " in \(profileCount) profiles" : ""
            return JunkItem(
                id: first,
                name: source.name,
                path: first,
                category: .browserCaches,
                risk: .safe,
                sizeBytes: size,
                modifiedDate: urls.compactMap { FileSizeHelper.modifiedDate(at: $0) }.max(),
                reason: "Cached pages and images\(profiles) · history, logins and cookies are kept",
                extraPaths: Array(paths.dropFirst())
            )
        }
    }
}

private extension JunkScanner.BrowserCacheSource.Layout {
    var isFolders: Bool {
        if case .folders = self { return true }
        return false
    }
}

// MARK: - Mail attachments

extension JunkScanner {
    /// Folders where Mail keeps copies of attachments you opened. The originals stay in the messages.
    static func mailDownloadsPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            "\(home)/Library/Mail Downloads" // older macOS
        ]
    }

    /// The mailboxes. Nothing at or under this path is ever offered.
    static func isInsideMailStore(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let store = "\(home)/Library/Mail"
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard == store || standard.hasPrefix(store + "/")
    }

    /// Mail's container is protected by macOS: without Full Disk Access it can't be listed,
    /// so the folder is skipped and the category doesn't appear.
    static func scanMailAttachments() -> [JunkItem] {
        let fm = FileManager.default
        return mailDownloadsPaths().compactMap { path in
            guard !isInsideMailStore(path),
                  let children = try? fm.contentsOfDirectory(atPath: path), !children.isEmpty
            else { return nil }
            let url = URL(fileURLWithPath: path)
            let size = FileSizeHelper.directorySize(at: url)
            guard size > 5_000_000 else { return nil }
            return JunkItem(
                id: path,
                name: "Mail Downloads",
                path: path,
                category: .mailAttachments,
                risk: .review,
                sizeBytes: size,
                modifiedDate: FileSizeHelper.modifiedDate(at: url),
                reason: "Copies of attachments you opened in Mail · the emails keep the originals"
            )
        }
    }
}

import CoreServices
import Foundation

/// First pass of Smart Review: walks the home folder and scores each file with cheap, explainable rules.
/// Files that look like possible clutter come back with a rule verdict; the on-device model can refine them later.
enum SmartReviewScanner {
    /// Files below this size aren't worth reviewing one by one...
    static let minimumBytes: Int64 = 512 * 1024
    /// ...except in Downloads and on the Desktop, where small leftovers pile up.
    static let minimumBytesInDropZones: Int64 = 32 * 1024
    /// Only files scoring at least this much are returned.
    static let minimumScore = 25

    private static let skipTopLevel: Set<String> = ["Library", ".Trash", "Applications"]
    /// Dev artifacts are handled by Caches & Junk / Worktrees; their contents aren't individual decisions.
    private static let skipDirs: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "DerivedData", ".build", "build", "dist", "target",
        ".next", ".turbo", "Pods", "__pycache__", ".gradle", ".cache", "Photos Library.photoslibrary",
        "Music", "Movies/TV", "Pictures/Photo Booth Library",
        // Go's module and build caches: hundreds of thousands of source files, none of them a personal decision.
        "go/pkg"
    ]
    /// A folder holding one of these is a code project. Smart Review leaves projects alone (Worktrees and
    /// Caches & Junk cover them), so its archives, images and videos aren't mistaken for forgotten files.
    private static let projectMarkers = [
        ".git", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "Podfile", "pubspec.yaml"
    ]

    private static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
    private static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2"]
    private static let videoAudioExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wav", "aif", "aiff"]
    private static let partialExts: Set<String> = ["crdownload", "part", "partial", "download", "tmp", "temp", "opdownload"]
    static let personalExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "raw", "cr2", "nef", "arw", "dng", "gif", "tiff",
        "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "ppt", "pptx",
        "psd", "ai", "sketch", "fig", "mp4", "mov"
    ]
    /// Source and config files belong to projects; whether a project is still needed isn't a per-file call.
    private static let codeExts: Set<String> = [
        "yaml", "yml", "json", "lock", "toml", "xml", "plist", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "py", "rb", "go", "rs", "swift", "java", "kt", "c", "h", "cpp", "hpp", "m", "cs", "php", "sh",
        "css", "scss", "html", "vue", "svelte", "sql", "map", "wasm", "o", "a", "dylib", "so", "class", "jar"
    ]
    private static let documentExts: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "ppt", "pptx",
        "txt", "md", "rtf", "csv", "psd", "ai", "sketch", "fig", "heic", "raw", "cr2", "nef", "arw", "dng"
    ]

    /// `emit` gets candidates in small batches as they're found (results still arriving).
    static func scan(ignoredPaths: Set<String>, progress: ScanProgress,
                     emit: (([SmartReviewItem]) -> Void)? = nil) -> [SmartReviewItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let installedApps = installedAppNames()
        let now = Date()

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey
        ]

        guard let topChildren = try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SmartReviewItem] = []
        progress.setPhase("Looking through your files")

        var emitted = 0
        func flush() {
            guard results.count > emitted else { return }
            emit?(Array(results[emitted...]))
            emitted = results.count
        }
        func consider(_ url: URL, _ vals: URLResourceValues) {
            progress.addItems()
            let size = Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
            let top = url.path.dropFirst(home.path.count + 1).split(separator: "/").first
            let floor = (top == "Downloads" || top == "Desktop") ? minimumBytesInDropZones : minimumBytes
            guard size >= floor, !ignoredPaths.contains(url.path) else { return }
            if let item = evaluate(
                url: url, size: size,
                created: vals.creationDate, modified: vals.contentModificationDate,
                home: home, installedApps: installedApps, now: now
            ) {
                results.append(item)
                if results.count - emitted >= 8 { flush() }
            }
        }
        progress.setSteps(done: 0, total: topChildren.count)

        for child in topChildren {
            defer { flush(); progress.advanceStep() }
            if progress.isCancelled { break }
            progress.setCurrent(child.path)
            if skipTopLevel.contains(child.lastPathComponent) { continue }
            guard let vals = try? child.resourceValues(forKeys: Set(keys)), vals.isSymbolicLink != true else { continue }

            if vals.isRegularFile == true {
                consider(child, vals)
                continue
            }
            // A project cloned straight into home (~/myapp) must be skipped here: the enumerator
            // below only checks the folders it finds inside, never this top-level one.
            if vals.isDirectory == true, isCodeProject(child) { continue }
            guard vals.isDirectory == true, vals.isPackage != true,
                  let enumerator = fm.enumerator(
                    at: child,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in progress.addUnreadable(); return true }
                  ) else { continue }

            for case let url as URL in enumerator {
                if progress.isCancelled { break }
                let relative = String(url.path.dropFirst(home.path.count + 1))
                if skipDirs.contains(url.lastPathComponent) || skipDirs.contains(relative) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let fvals = try? url.resourceValues(forKeys: Set(keys)),
                      fvals.isSymbolicLink != true else { continue }
                if fvals.isDirectory == true {
                    if isCodeProject(url) { enumerator.skipDescendants() }
                    continue
                }
                guard fvals.isRegularFile == true else { continue }
                consider(url, fvals)
            }
        }

        return results.sorted { ($0.ruleScore, $0.sizeBytes) > ($1.ruleScore, $1.sizeBytes) }
    }

    // MARK: - Rules

    private static func evaluate(
        url: URL, size: Int64, created: Date?, modified: Date?,
        home: URL, installedApps: Set<String>, now: Date
    ) -> SmartReviewItem? {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        let relative = String(url.path.dropFirst(home.path.count + 1))
        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""

        var score = 0
        var signals: [String] = []
        func add(_ points: Int, _ signal: String) {
            score += points
            signals.append(signal)
        }

        // Fetch Spotlight metadata once: last opened date + download source.
        let meta = spotlightMetadata(for: url)
        let lastOpened = meta.lastUsed
        let reference = lastOpened ?? modified ?? created
        let daysSinceUse = reference.map { now.timeIntervalSince($0) / 86_400 } ?? 0
        let ageDays = created.map { now.timeIntervalSince($0) / 86_400 } ?? daysSinceUse

        if codeExts.contains(ext) { return nil }

        // Recently touched files are almost never clutter.
        if let modified, now.timeIntervalSince(modified) < 14 * 86_400 { return nil }
        if let lastOpened, now.timeIntervalSince(lastOpened) < 14 * 86_400 { return nil }

        // What kind of file it is.
        if partialExts.contains(ext) {
            add(60, "Unfinished or temporary download")
        } else if installerExts.contains(ext) {
            if let app = matchingInstalledApp(base, installedApps) {
                add(50, "Installer for \(app), which is already installed")
            } else {
                add(35, "Installer or disk image")
            }
        } else if archiveExts.contains(ext) {
            // Only when the folder beside it really holds the archive's contents (names and size).
            if let sibling = ArchiveExtractionCheck.extractedFolder(for: url),
               ArchiveExtractionCheck.isExtracted(archive: url, timeout: 20) {
                add(45, "Already extracted to “\(sibling.lastPathComponent)” next to it")
            } else if topFolder == "Downloads" {
                add(15, "Downloaded archive")
            } else {
                // Elsewhere an archive is usually a backup or a hand-off; only its age makes the case below.
                add(10, "Archive")
            }
        } else if ext == "log" || lower.hasSuffix(".log.1") || ext == "trace" {
            add(35, "Log file")
        } else if lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("cleanshot") {
            if ageDays > 30 { add(30, "Old screenshot") }
        } else if lower.hasPrefix("screen recording") {
            add(ageDays > 14 ? 35 : 15, "Screen recording")
        } else if lower.hasPrefix("whatsapp image") || lower.hasPrefix("whatsapp video") {
            add(15, "Saved chat media")
        } else if videoAudioExts.contains(ext) && size >= 200_000_000 {
            add(10, "Large video or audio file")
        }

        // Names that hint at leftovers.
        if lower.range(of: #"(\(\d+\)|[ _-]copy( \d+)?)(\.[a-z0-9]+)?$"#, options: .regularExpression) != nil {
            add(20, "Looks like a duplicate copy")
        } else if lower.range(of: #"(^|[ _.-])(old|bak|backup|tmp|temp|untitled|test)([ _.-]|\d|$)"#, options: .regularExpression) != nil {
            add(15, "Name suggests a temporary or old version")
        }
        if ext == "bak" || lower.hasSuffix("~") { add(30, "Backup file") }

        // Where it lives.
        switch topFolder {
        case "Downloads": add(15, "In Downloads")
        case "Desktop": add(5, "Loose on the Desktop")
        case "Documents": score -= 15
        default: break
        }

        // How long since it was used. Downloads and the Desktop are where things land and get forgotten,
        // so a file there that was never opened counts after a month; elsewhere after six.
        let inDropZone = topFolder == "Downloads" || topFolder == "Desktop"
        if lastOpened == nil && meta.indexed && ageDays > (inDropZone ? 30 : 180) {
            add(inDropZone ? 25 : 20, "Never opened since it arrived \(ageText(ageDays)) ago")
        } else if daysSinceUse > 730 {
            add(30, "Not used in \(ageText(daysSinceUse))")
        } else if daysSinceUse > 365 {
            add(25, "Not used in \(ageText(daysSinceUse))")
        } else if daysSinceUse > 180 {
            add(20, "Not used in \(ageText(daysSinceUse))")
        }

        if size >= 1_000_000_000 { add(10, "Over 1 GB") }

        // Personal documents and photos need a much stronger case.
        // A PDF in Downloads is more often a one-off receipt or manual than a document someone filed.
        if documentExts.contains(ext) { score -= topFolder == "Downloads" ? 10 : 15 }
        if topFolder == "Pictures" && !lower.hasPrefix("screenshot") { score -= 20 }

        score = max(0, min(100, score))
        guard score >= minimumScore else { return nil }

        return SmartReviewItem(
            id: url.path,
            name: name,
            path: url.path,
            sizeBytes: size,
            createdDate: created,
            modifiedDate: modified,
            lastOpenedDate: lastOpened,
            downloadedFrom: meta.source,
            ruleScore: score,
            signals: signals,
            verdict: ruleVerdict(score: score, signals: signals)
        )
    }

    static func ruleVerdict(score: Int, signals: [String]) -> SmartVerdict {
        let label: SmartLabel = score >= 60 ? .junk : (score >= 30 ? .maybe : .keep)
        let reason = signals.prefix(2).joined(separator: "; ")
        return SmartVerdict(label: label, confidence: score, reason: reason.isEmpty ? "Matched cleanup rules" : reason, source: .rules)
    }

    // MARK: - Helpers

    private static func isCodeProject(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return projectMarkers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private struct SpotlightMeta {
        var lastUsed: Date?
        var source: String?
        /// Whether Spotlight knows the file at all; without it "never opened" can't be trusted.
        var indexed: Bool
    }

    private static func spotlightMetadata(for url: URL) -> SpotlightMeta {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return SpotlightMeta(lastUsed: nil, source: nil, indexed: false)
        }
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let indexed = MDItemCopyAttribute(item, kMDItemContentType) != nil
        var source: String?
        if let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
            source = froms.lazy.compactMap { URL(string: $0)?.host }.first
        }
        return SpotlightMeta(lastUsed: lastUsed, source: source, indexed: indexed)
    }

    private static func installedAppNames() -> Set<String> {
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var names = Set<String>()
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                names.insert(String(entry.dropLast(4)))
            }
        }
        return names
    }

    /// "Docker-4.30-arm64" → "Docker" when Docker.app is installed.
    private static func matchingInstalledApp(_ installerBase: String, _ apps: Set<String>) -> String? {
        let normalized = installerBase.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        guard normalized.count >= 3 else { return nil }
        return apps
            .filter { app in
                let a = app.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
                return a.count >= 3 && normalized.hasPrefix(a)
            }
            .max { $0.count < $1.count }
    }

    static func ageText(_ days: Double) -> String {
        if days >= 730 { return "\(Int(days / 365)) years" }
        if days >= 365 { return "a year" }
        if days >= 60 { return "\(Int(days / 30)) months" }
        return "\(Int(days)) days"
    }
}

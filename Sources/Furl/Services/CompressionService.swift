import CoreServices
import Darwin
import Foundation

/// Lossless compression of the user's files. Offline only: everything runs with built-in macOS frameworks and tools,
/// plus optional Homebrew tools when they're installed. Originals are only replaced after the output is verified,
/// and they go to the Trash (or are deleted, if the user chose that) so a run can be undone.
enum CompressionService {
    // MARK: - Configuration

    static let minimumFileBytes: Int64 = 16 * 1024
    static let minimumFolderBytes: Int64 = 20 * 1024 * 1024
    static let minimumCompressibleFolderBytes: Int64 = 8 * 1024 * 1024
    static let maximumArchiveBytes: Int64 = 1 << 30

    private static let imageExtensions: Set<String> = ["png", "gif", "tif", "tiff"]
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif"]
    private static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff"]
    private static let archiveExtensions: Set<String> = ["zip", "docx", "xlsx", "pptx", "key", "pages", "numbers"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "3gp", "mpg", "mpeg", "mts", "m2ts"]
    private static let lossyAudioExtensions: Set<String> = ["mp3", "aac", "m4a", "ogg", "opus", "wma", "m4b", "flac", "alac"]
    private static let compressedExtensions: Set<String> = ["webp", "avif", "jxl", "7z", "rar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "dmg", "xip", "pkg", "jar", "apk", "ipa", "epub", "odt", "ods", "odp"]
    /// Content that LZFSE won't shrink; excluded when estimating folder savings.
    private static let incompressibleExtensions: Set<String> = videoExtensions
        .union(lossyAudioExtensions).union(compressedExtensions).union(jpegExtensions)
        .union(["png", "gif", "zip", "docx", "xlsx", "pptx", "key", "pages", "numbers", "pdf", "mp3"])
    /// Libraries whose apps expect to manage every byte themselves.
    private static let blockedPackages: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "imovielibrary", "fcpbundle", "logicx", "sparsebundle", "sparseimage", "vmwarevm", "pvm", "utm"]
    private static let suppressFileCandidatesInside: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", "build", ".build"]

    // MARK: - Scan

    /// - Parameters:
    ///   - root: folder to scan instead of the home folder (tests); `includeApps` adds /Applications and ~/Applications.
    static func scan(
        options: CompressOptions,
        progress: CompressProgress?,
        root: String? = nil,
        includeApps: Bool = true,
        tools detectedTools: CompressTools? = nil,
        emit: ((CompressScanResult) -> Void)? = nil
    ) -> CompressScanResult {
        let tools = detectedTools ?? CompressTools.detect()
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let home = root ?? realHome
        let cutoff = options.cutoffDate
        var collector = ScanCollector(cutoff: cutoff, tools: tools, uid: getuid())

        progress?.setPhase("Looking through your home folder")
        // Results still arriving: a snapshot about once a second while walking, then one per measured ratio.
        walkHome(home, collector: &collector, progress: progress,
                 onTick: emit.map { emit in { emit(partialResult($0, ratios: [:], tools: tools, options: options)) } })

        if includeApps, progress?.isCancelled != true {
            progress?.setPhase("Checking apps")
            for dir in ["/Applications", realHome + "/Applications"] {
                scanApps(in: dir, collector: &collector, progress: progress)
            }
        }

        var ratios: [CompressCategory: Double] = [:]
        if progress?.isCancelled != true {
            progress?.setPhase("Measuring savings on a sample")
            emit?(partialResult(collector, ratios: [:], tools: tools, options: options))
            let snapshot = collector
            ratios = measureSampleRatios(candidates: collector.candidates, folderSamples: collector.folderSamples, tools: tools, options: options, progress: progress,
                                         onRatio: emit.map { emit in { emit(partialResult(snapshot, ratios: $0, tools: tools, options: options)) } })
        }

        return CompressScanResult(
            candidates: collector.candidates,
            skipped: collector.skipGroups.values.sorted { $0.bytes > $1.bytes },
            sampleRatios: ratios,
            tools: tools,
            minDaysUsedForFolders: options.minDaysUnused,
            scannedAt: Date(),
            toolFiles: collector.toolFiles
        )
    }

    /// Below this many PNGs the PNG helpers aren't worth recommending.
    static let minimumPNGsToRecommend = 20

    /// Files a missing tool would handle, counted with the same age filter as everything else.
    static func toolFinds(_ scan: CompressScanResult, options: CompressOptions) -> [OptionalTool: ToolFind] {
        let cutoff = options.cutoffDate
        var finds: [OptionalTool: ToolFind] = [:]
        let nouns: [OptionalTool: String] = [.qpdf: "PDF", .gifsicle: "GIF", .jpegTurbo: "JPEG"]
        for (tool, files) in scan.toolFiles {
            let kept = files.filter { !options.onlyUnused || ($0.lastUsed ?? .distantPast) < cutoff }
            guard !kept.isEmpty else { continue }
            finds[tool] = ToolFind(count: kept.count, bytes: kept.reduce(0) { $0 + $1.bytes }, noun: nouns[tool] ?? "file")
        }
        // PNGs still compress without oxipng/zopflipng (ImageIO), so those two are only "better", not "unlocks".
        if scan.tools.oxipng == nil || scan.tools.zopflipng == nil {
            var all = options
            all.enabledCategories = [.images]
            let pngs = eligibleCandidates(scan, options: all).filter { $0.path.lowercased().hasSuffix(".png") }
            if pngs.count >= minimumPNGsToRecommend {
                let find = ToolFind(count: pngs.count, bytes: pngs.reduce(0) { $0 + $1.sizeBytes }, noun: "PNG")
                if scan.tools.oxipng == nil { finds[.oxipng] = find }
                if scan.tools.zopflipng == nil { finds[.zopfli] = find }
            }
        }
        return finds
    }

    private struct DirAgg {
        let path: String
        let level: Int
        var newest: Date
        var allocated: Int64 = 0
        var compressible: Int64 = 0
        var files = 0
        var blocked = false
        var suppressFiles: Bool
        var folderCandidates: [CompressCandidate] = []
    }

    private struct ScanCollector {
        let cutoff: Date
        let tools: CompressTools
        let uid: uid_t
        var candidates: [CompressCandidate] = []
        var skipGroups: [String: CompressSkipGroup] = [:]
        var folderSamples: [String] = []
        var sampleCounter = 0
        /// Files skipped only because a tool is missing, per tool (feeds the Recommended tools card).
        var toolFiles: [OptionalTool: [ToolFile]] = [:]

        mutating func needsTool(_ tool: OptionalTool, reason: String, st: stat, bytes: Int64) {
            toolFiles[tool, default: []].append(ToolFile(lastUsed: CompressionFS.lastUsed(st), bytes: bytes))
            skip(reason, bytes: bytes)
        }

        mutating func skip(_ reason: String, bytes: Int64) {
            skipGroups[reason, default: CompressSkipGroup(reason: reason, count: 0, bytes: 0)].count += 1
            skipGroups[reason]?.bytes += bytes
        }

        /// Keeps a spread-out reservoir of files to sample for the folder estimate.
        mutating func offerFolderSample(_ path: String) {
            sampleCounter += 1
            if folderSamples.count < 60 {
                folderSamples.append(path)
            } else if Int.random(in: 0..<sampleCounter) < 60 {
                folderSamples[Int.random(in: 0..<60)] = path
            }
        }
    }

    private static func walkHome(_ home: String, collector: inout ScanCollector, progress: CompressProgress?,
                                 onTick: ((ScanCollector) -> Void)? = nil) {
        var lastTick = Date()
        home.withCString { cRoot in
            let dup = strdup(cRoot)
            defer { free(dup) }
            var roots: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }

            var stack: [DirAgg] = []
            var visited = 0
            while let entry = fts_read(fts) {
                if progress?.isCancelled == true { break }
                if let onTick, visited % 2_000 == 0, Date().timeIntervalSince(lastTick) >= 1 {
                    lastTick = Date()
                    onTick(collector)
                }
                let info = Int32(entry.pointee.fts_info)
                let level = Int(entry.pointee.fts_level)
                let path = String(cString: entry.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                visited += 1
                if visited % 2_000 == 0 { progress?.setPhase("Looking through \(name)") }

                switch info {
                case FTS_D:
                    guard let st = entry.pointee.fts_statp?.pointee else { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    if level == 1, name == "Library" || name == ".Trash" || name == "Applications" || name.hasPrefix(".") {
                        fts_set(fts, entry, FTS_SKIP); continue
                    }
                    if ext == "app", level > 0 {
                        // Apps are handled in their own pass; one sitting in a project folder blocks that folder.
                        if !stack.isEmpty { stack[stack.count - 1].blocked = true }
                        fts_set(fts, entry, FTS_SKIP); continue
                    }
                    if blockedPackages.contains(ext) {
                        if !stack.isEmpty { stack[stack.count - 1].blocked = true }
                        fts_set(fts, entry, FTS_SKIP); continue
                    }
                    if st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag) != 0 {
                        if !stack.isEmpty { stack[stack.count - 1].blocked = true }
                        fts_set(fts, entry, FTS_SKIP); continue
                    }
                    let parentSuppress = stack.last?.suppressFiles ?? false
                    let suppress = parentSuppress || suppressFileCandidatesInside.contains(name) || (level > 1 && name.hasPrefix("."))
                        || ["rtfd", "xcodeproj", "xcworkspace", "bundle", "framework", "plugin"].contains(ext)
                    var agg = DirAgg(path: path, level: level, newest: CompressionFS.lastUsed(st), suppressFiles: suppress)
                    if st.st_uid != collector.uid { agg.blocked = true }
                    stack.append(agg)

                case FTS_DP:
                    guard var agg = stack.popLast() else { continue }
                    if (2...5).contains(agg.level), !agg.blocked, agg.newest < collector.cutoff,
                       agg.allocated >= minimumFolderBytes, agg.compressible >= minimumCompressibleFolderBytes,
                       !DeletionService.isProtected(agg.path) {
                        agg.folderCandidates = [CompressCandidate(
                            path: agg.path, category: .folders, sizeBytes: agg.allocated,
                            compressibleBytes: agg.compressible, lastUsed: agg.newest, isApp: false, fileCount: agg.files
                        )]
                    }
                    if stack.isEmpty {
                        collector.candidates.append(contentsOf: agg.folderCandidates)
                    } else {
                        var parent = stack.removeLast()
                        parent.newest = max(parent.newest, agg.newest)
                        parent.allocated += agg.allocated
                        parent.compressible += agg.compressible
                        parent.files += agg.files
                        parent.blocked = parent.blocked || agg.blocked
                        parent.folderCandidates.append(contentsOf: agg.folderCandidates)
                        stack.append(parent)
                    }

                case FTS_F:
                    guard let st = entry.pointee.fts_statp?.pointee, !stack.isEmpty else { continue }
                    progress?.advance()
                    let allocated = CompressionFS.allocatedBytes(st)
                    let ext = (name as NSString).pathExtension.lowercased()
                    let top = stack.count - 1
                    stack[top].newest = max(stack[top].newest, CompressionFS.lastUsed(st))
                    stack[top].allocated += allocated
                    stack[top].files += 1
                    let flags = st.st_flags
                    if flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag) != 0 || st.st_nlink > 1 || st.st_uid != collector.uid {
                        stack[top].blocked = true
                    }
                    let alreadyCompressed = flags & CompressionFS.compressedFlag != 0
                    if !alreadyCompressed, st.st_size >= 4_096, !incompressibleExtensions.contains(ext) {
                        stack[top].compressible += allocated
                        if st.st_size <= 64 * 1024 * 1024 { collector.offerFolderSample(path) }
                    }
                    if level == 1 || !stack[top].suppressFiles {
                        classifyFile(path: path, ext: ext, st: st, allocated: allocated, collector: &collector)
                    }

                case FTS_SL, FTS_SLNONE:
                    if let st = entry.pointee.fts_statp?.pointee, !stack.isEmpty {
                        stack[stack.count - 1].newest = max(stack[stack.count - 1].newest, CompressionFS.date(st.st_mtimespec))
                    }

                default:
                    continue
                }
            }
        }
    }

    private static func classifyFile(path: String, ext: String, st: stat, allocated: Int64, collector: inout ScanCollector) {
        guard Int64(st.st_size) >= minimumFileBytes, !name(path).hasPrefix(".") else { return }
        let category: CompressCategory
        if imageExtensions.contains(ext) {
            if ext == "gif", collector.tools.gifsicle == nil {
                collector.needsTool(.gifsicle, reason: "GIFs: need gifsicle to optimise them", st: st, bytes: allocated); return
            }
            category = .images
        } else if ext == "heic" || ext == "heif" {
            collector.skip("HEIC photos: no verified lossless way to shrink them", bytes: allocated); return
        } else if jpegExtensions.contains(ext) {
            if collector.tools.jpegtran == nil {
                collector.needsTool(.jpegTurbo, reason: "JPEGs: need jpegtran to optimise them losslessly", st: st, bytes: allocated); return
            }
            category = .jpeg
        } else if ext == "pdf" {
            if collector.tools.qpdf == nil {
                collector.needsTool(.qpdf, reason: "PDFs: need qpdf to optimise them losslessly", st: st, bytes: allocated); return
            }
            category = .pdfs
        } else if audioExtensions.contains(ext) {
            category = .audio
        } else if archiveExtensions.contains(ext) {
            guard Int64(st.st_size) <= maximumArchiveBytes else {
                collector.skip("Archives over 1 GB", bytes: allocated); return
            }
            category = .archives
        } else if videoExtensions.contains(ext) {
            collector.skip("Videos: making them smaller means losing quality", bytes: allocated); return
        } else if lossyAudioExtensions.contains(ext) {
            collector.skip("MP3, AAC & FLAC audio: already compressed", bytes: allocated); return
        } else if compressedExtensions.contains(ext) {
            collector.skip("Already-compressed files (DMG, 7z, WebP…)", bytes: allocated); return
        } else {
            return
        }
        if st.st_flags & CompressionFS.datalessFlag != 0 {
            collector.skip("iCloud files that aren't downloaded to this Mac", bytes: allocated); return
        }
        if st.st_nlink > 1 {
            collector.skip("Hard-linked files", bytes: allocated); return
        }
        if st.st_flags & (CompressionFS.compressedFlag | CompressionFS.restrictedFlag | CompressionFS.immutableFlags) != 0 || st.st_uid != collector.uid {
            collector.skip("Locked, system-protected or other users' files", bytes: allocated); return
        }
        collector.candidates.append(CompressCandidate(
            path: path, category: category, sizeBytes: allocated, compressibleBytes: allocated,
            lastUsed: CompressionFS.lastUsed(st), isApp: false, fileCount: 1
        ))
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func scanApps(in directory: String, collector: inout ScanCollector, progress: CompressProgress?) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasSuffix(".app") {
            if progress?.isCancelled == true { return }
            let path = (directory as NSString).appendingPathComponent(entry)
            guard let st = CompressionFS.lstatInfo(path), CompressionFS.isDirectory(st) else { continue }
            progress?.setPhase("Checking \(entry)")

            let bundleID = Bundle(path: path)?.bundleIdentifier ?? ""
            if bundleID.hasPrefix("com.apple.") || st.st_flags & CompressionFS.restrictedFlag != 0 {
                continue // Apple's own apps are already compressed or SIP-protected.
            }
            let used = lastOpened(path) ?? CompressionFS.lastUsed(st)
            if used >= collector.cutoff { continue }
            let receipt = (path as NSString).appendingPathComponent("Contents/_MASReceipt")
            if fm.fileExists(atPath: receipt) || access(path, W_OK) != 0 || access(directory, W_OK) != 0 {
                let size = CompressionFS.allocatedBytes(atPath: path)
                collector.skip("Apps from the App Store or installed for all users (need admin rights)", bytes: size)
                continue
            }

            var allocated: Int64 = 0
            var compressible: Int64 = 0
            var files = 0
            var blocked = false
            CompressionFS.walk(path) { _, entry in
                guard !CompressionFS.isDirectory(entry) else { return true }
                let bytes = CompressionFS.allocatedBytes(entry)
                allocated += bytes
                files += 1
                if entry.st_uid != collector.uid || entry.st_nlink > 1 && CompressionFS.isRegular(entry)
                    || entry.st_flags & CompressionFS.restrictedFlag != 0 {
                    blocked = true
                }
                if CompressionFS.isRegular(entry), entry.st_flags & CompressionFS.compressedFlag == 0, entry.st_size >= 4_096 {
                    compressible += bytes
                }
                return true
            }
            if blocked {
                collector.skip("Apps from the App Store or installed for all users (need admin rights)", bytes: allocated)
                continue
            }
            guard allocated >= minimumFolderBytes, compressible >= minimumCompressibleFolderBytes else { continue }
            collector.candidates.append(CompressCandidate(
                path: path, category: .folders, sizeBytes: allocated, compressibleBytes: compressible,
                lastUsed: used, isApp: true, fileCount: files
            ))
        }
    }

    /// When Spotlight last saw the item opened.
    static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Estimates

    private static let fallbackRatios: [CompressCategory: Double] = [
        .folders: 0.6, .images: 0.85, .pdfs: 0.85, .jpeg: 0.93, .audio: 0.6, .archives: 0.9
    ]

    /// Runs the real compressors on a handful of files per category (into temp, never replacing anything) and
    /// returns output/input ratios. Folders are estimated by LZFSE-compressing sampled files in memory.
    static func measureSampleRatios(
        candidates: [CompressCandidate],
        folderSamples: [String],
        tools: CompressTools,
        options: CompressOptions,
        progress: CompressProgress?,
        onRatio: (([CompressCategory: Double]) -> Void)? = nil
    ) -> [CompressCategory: Double] {
        var ratios: [CompressCategory: Double] = [:]

        var before: Int64 = 0
        var after: Int64 = 0
        for path in folderSamples.prefix(60) {
            if progress?.isCancelled == true { return ratios }
            guard let st = CompressionFS.lstatInfo(path),
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 2 << 20)) ?? Data()
            guard !prefix.isEmpty else { continue }
            let scale = Double(st.st_size) / Double(prefix.count)
            let estimate = CompressionFS.estimateDecmpfsBytes(prefix)
            let allocated = CompressionFS.allocatedBytes(st)
            before += allocated
            after += min(allocated, Int64(Double(estimate) * scale))
        }
        ratios[.folders] = before > 0 ? Double(after) / Double(before) : fallbackRatios[.folders]
        onRatio?(ratios)

        for category in CompressCategory.allCases where category != .folders {
            let pool = candidates.filter { $0.category == category && $0.sizeBytes <= 30 * 1024 * 1024 }
                .sorted { $0.sizeBytes < $1.sizeBytes }
            guard !pool.isEmpty else { continue }
            // Spread samples across the size range.
            let picks = Swift.min(4, pool.count)
            let sample = (0..<picks).map { pool[($0 * (pool.count - 1)) / Swift.max(1, picks - 1)] }
            var inBytes: Int64 = 0
            var outBytes: Int64 = 0
            for candidate in Set(sample) {
                if progress?.isCancelled == true { return ratios }
                progress?.setPhase("Trying \(candidate.name)")
                guard let work = makeWorkDirectory(near: candidate.path) else { continue }
                defer { try? FileManager.default.removeItem(atPath: work) }
                let original = CompressionFS.allocatedBytes(atPath: candidate.path)
                switch CompressionEngines.run(candidate: candidate, workDir: work, tools: tools, options: options, progress: progress) {
                case .ready(let output, _, _):
                    inBytes += original
                    outBytes += Swift.min(original, CompressionFS.allocatedBytes(atPath: output))
                case .notSmaller, .reject:
                    inBytes += original
                    outBytes += original
                case .skip, .fail:
                    continue
                }
            }
            ratios[category] = inBytes > 0 ? Double(outBytes) / Double(inBytes) : fallbackRatios[category]
            onRatio?(ratios)
        }
        return ratios
    }

    /// Candidates the run would touch with these options.
    static func eligibleCandidates(_ scan: CompressScanResult, options: CompressOptions) -> [CompressCandidate] {
        let cutoff = options.cutoffDate
        return scan.candidates.filter { candidate in
            guard options.enabledCategories.contains(candidate.category) else { return false }
            if candidate.category == .folders || !options.onlyUnused { return true }
            return (candidate.lastUsed ?? .distantPast) < cutoff
        }
    }

    static func summaries(_ scan: CompressScanResult, options: CompressOptions) -> [CompressCategorySummary] {
        var all = options
        all.enabledCategories = Set(CompressCategory.allCases)
        let eligible = eligibleCandidates(scan, options: all)
        return CompressCategory.allCases.map { category in
            let items = eligible.filter { $0.category == category }
            let ratio = scan.sampleRatios[category] ?? fallbackRatios[category] ?? 1
            let compressible = items.reduce(Int64(0)) { $0 + $1.compressibleBytes }
            let folders = items.filter { !$0.isApp }.count
            let apps = items.count - folders
            var summary = CompressCategorySummary(
                category: category,
                count: items.count,
                bytes: items.reduce(0) { $0 + $1.sizeBytes },
                estimatedSavings: Int64(Double(compressible) * max(0, 1 - ratio)),
                method: method(for: category, tools: scan.tools),
                available: true,
                note: nil
            )
            switch category {
            case .folders:
                summary.note = apps > 0 ? "\(folders) folders, \(apps) apps" : nil
            case .pdfs where scan.tools.qpdf == nil:
                summary.available = false
                summary.note = "Needs qpdf"
            case .jpeg where scan.tools.jpegtran == nil:
                summary.available = false
                summary.note = "Needs jpegtran"
            case .audio:
                summary.note = "Changes .wav/.aiff to .m4a"
            default:
                break
            }
            return summary
        }
    }

    static func method(for category: CompressCategory, tools: CompressTools) -> String {
        switch category {
        case .folders: return "LZFSE"
        case .images: return tools.oxipng != nil ? "oxipng" : tools.zopflipng != nil ? "Zopfli" : "ImageIO"
        case .pdfs: return tools.qpdf != nil ? "Object streams" : "Needs qpdf"
        case .jpeg: return tools.jpegtran != nil ? "Lossless optimise" : "Needs jpegtran"
        case .audio: return "ALAC"
        case .archives: return "Repack"
        }
    }

    // MARK: - Run

    private static let runOrder: [CompressCategory] = [.archives, .images, .jpeg, .pdfs, .audio, .folders]

    static func run(
        candidates: [CompressCandidate],
        tools: CompressTools,
        options: CompressOptions,
        progress: CompressProgress?
    ) -> CompressRunResult {
        var result = CompressRunResult(startedAt: Date(), originalsKeptInTrash: options.keepOriginalsInTrash)
        let ordered = candidates.sorted {
            let a = runOrder.firstIndex(of: $0.category) ?? 0
            let b = runOrder.firstIndex(of: $1.category) ?? 0
            return a != b ? a < b : $0.path < $1.path
        }
        progress?.setTotal(ordered.count)
        progress?.setPhase("Checking which files are in use")
        let openFiles = CompressionFS.openFiles()

        for candidate in ordered {
            if progress?.isCancelled == true { result.wasCancelled = true; break }
            progress?.setPhase(candidate.name)
            let item = process(candidate, tools: tools, options: options, openFiles: openFiles, progress: progress)
            result.items.append(item)
            progress?.advance(saved: item.savedBytes)
        }
        result.finishedAt = Date()
        return result
    }

    /// Compresses, verifies and swaps in one item. The original is never modified in place.
    static func process(
        _ candidate: CompressCandidate,
        tools: CompressTools,
        options: CompressOptions,
        openFiles: Set<String>,
        progress: CompressProgress?
    ) -> CompressItemResult {
        let path = candidate.path
        func outcome(_ status: CompressItemStatus, _ message: String, original: Int64 = 0, new: Int64 = 0, undo: CompressUndoRecord? = nil) -> CompressItemResult {
            CompressItemResult(path: path, category: candidate.category, status: status, originalBytes: original, newBytes: new, message: message, undo: undo)
        }

        guard let st = CompressionFS.lstatInfo(path) else { return outcome(.skipped, "No longer exists") }
        let isFolder = candidate.category == .folders
        guard isFolder ? CompressionFS.isDirectory(st) : CompressionFS.isRegular(st) else { return outcome(.skipped, "Changed since the scan") }
        if DeletionService.isProtected(path) || path.hasPrefix("/System/") { return outcome(.skipped, "Protected location") }
        if st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag) != 0 { return outcome(.skipped, "iCloud-only or system-protected") }
        if !isFolder, st.st_nlink > 1 { return outcome(.skipped, "Hard-linked") }
        // The lsof snapshot is from the start of the run; check again now, for this item.
        if CompressionFS.isInUse(path, isDirectory: isFolder, openFiles: openFiles)
            || CompressionFS.isOpenNow(path, isDirectory: isFolder) {
            return outcome(.skipped, "Currently open in another app")
        }
        if !isFolder, options.onlyUnused, let opened = lastOpened(path), opened >= options.cutoffDate {
            return outcome(.skipped, "Opened in the last \(options.minDaysUnused) days")
        }

        guard let work = makeWorkDirectory(near: path) else { return outcome(.failed, "Couldn't create a working folder on this disk") }
        defer { try? FileManager.default.removeItem(atPath: work) }

        let originalBytes = CompressionFS.allocatedBytes(atPath: path)
        switch CompressionEngines.run(candidate: candidate, workDir: work, tools: tools, options: options, progress: progress) {
        case .skip(let why): return outcome(.skipped, why, original: originalBytes, new: originalBytes)
        case .notSmaller(let why): return outcome(.notSmaller, why, original: originalBytes, new: originalBytes)
        case .reject(let why): return outcome(.rejected, why, original: originalBytes, new: originalBytes)
        case .fail(let why): return outcome(.failed, why, original: originalBytes, new: originalBytes)
        case .ready(let output, let destination, let note):
            let newBytes = CompressionFS.allocatedBytes(atPath: output)
            let logicalSmaller = isFolder || (CompressionFS.lstatInfo(output).map { $0.st_size < st.st_size } ?? false)
            guard newBytes < originalBytes, logicalSmaller else {
                return outcome(.notSmaller, "Not smaller on disk", original: originalBytes, new: originalBytes)
            }
            // Re-check the original didn't change while we worked on it.
            if !CompressionFS.unchanged(path, since: st) {
                return outcome(.skipped, "Changed while compressing", original: originalBytes, new: originalBytes)
            }
            // And once more right before the swap: an app may have opened it while we worked.
            if CompressionFS.isOpenNow(path, isDirectory: isFolder) {
                return outcome(.skipped, "Currently open in another app", original: originalBytes, new: originalBytes)
            }
            // A folder's own date only moves when its direct entries change, so compare the whole tree again:
            // a file edited deep inside since verification would otherwise be swapped back to the old copy.
            if isFolder, CompressionFS.treeDifference(original: path, copy: output) != nil {
                return outcome(.skipped, "Changed while compressing", original: originalBytes, new: originalBytes)
            }
            if !isFolder { CompressionFS.copyMetadata(from: path, to: output) }
            do {
                let undo = try swap(original: path, replacement: output, destination: destination, keepOriginal: options.keepOriginalsInTrash)
                return outcome(.compressed, note, original: originalBytes, new: newBytes, undo: undo)
            } catch {
                return outcome(.failed, "Couldn't replace the original: \(friendlyMessage(error))", original: originalBytes, new: originalBytes)
            }
        }
    }

    /// A private temporary folder on the same volume as `path`, so swaps are renames, not copies.
    static func makeWorkDirectory(near path: String) -> String? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true) {
            return dir.path
        }
        return nil
    }

    /// Moves the original out of the way (to the Trash, or deletes it) and moves the verified replacement in.
    /// If anything fails after the original moved, it is put back.
    static func swap(original: String, replacement: String, destination: String, keepOriginal: Bool) throws -> CompressUndoRecord {
        let fm = FileManager.default
        if destination != original, fm.fileExists(atPath: destination) {
            throw CocoaError(.fileWriteFileExists)
        }
        if keepOriginal {
            var trashed: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: &trashed)
            guard let trashPath = (trashed as URL?)?.path else { throw CocoaError(.fileWriteUnknown) }
            do {
                try fm.moveItem(atPath: replacement, toPath: destination)
            } catch {
                try? fm.moveItem(atPath: trashPath, toPath: original)
                throw error
            }
            return CompressUndoRecord(originalPath: original, trashPath: trashPath, newPath: destination,
                                      trashFileID: DeletionService.fileID(trashPath),
                                      newStamp: CleanupStamp.read(destination, includeSize: true))
        }

        // No Trash: park the original next to it, move the replacement in, then delete the parked original.
        let parent = (original as NSString).deletingLastPathComponent
        let parked = (parent as NSString).appendingPathComponent(".sweepmac-original-\(UUID().uuidString)")
        try fm.moveItem(atPath: original, toPath: parked)
        do {
            try fm.moveItem(atPath: replacement, toPath: destination)
        } catch {
            try? fm.moveItem(atPath: parked, toPath: original)
            throw error
        }
        try? fm.removeItem(atPath: parked)
        return CompressUndoRecord(originalPath: original, trashPath: nil, newPath: destination)
    }

    private static func friendlyMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return "permission denied"
        }
        return error.localizedDescription
    }

    // MARK: - Undo

    /// Puts originals back from the Trash and moves the compressed copies to the Trash.
    ///
    /// Nothing moves unless it's safe: the item in the Trash must be the original Furl put there (same
    /// inode), the original location must be free (or hold only the unchanged replacement), and a
    /// replacement is only trashed while it's unchanged since the swap. A replacement the user changed
    /// at a different path is left where it is and the original still comes back. If the final move
    /// fails, the replacement is put back.
    static func undo(_ records: [CompressUndoRecord]) -> (restored: Int, errors: [String]) {
        undoEach(records).reduce(into: (restored: 0, errors: [String]())) { total, outcome in
            if let error = outcome.error { total.errors.append(error) } else { total.restored += 1 }
        }
    }

    /// Same as `undo(_:)`, one outcome per record (nil error = restored), so callers can keep the
    /// records that didn't come back.
    static func undoEach(_ records: [CompressUndoRecord]) -> [(record: CompressUndoRecord, error: String?)] {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }
        var outcomes: [(record: CompressUndoRecord, error: String?)] = []
        for record in records.reversed() {
            let name = (record.originalPath as NSString).lastPathComponent
            func fail(_ message: String) { outcomes.append((record, "\(name): \(message)")) }
            guard let trashPath = record.trashPath else {
                fail("the original was deleted, not kept in the Trash")
                continue
            }
            // Finder reuses Trash names; without a recorded inode the item can't be confirmed as ours.
            guard exists(trashPath), let id = record.trashFileID, DeletionService.fileID(trashPath) == id else {
                fail("the original is no longer in the Trash")
                continue
            }
            let samePath = record.newPath == record.originalPath
            let replacementThere = exists(record.newPath)
            let replacementUnchanged = replacementThere
                && record.newStamp.map { $0.matches(record.newPath) } == true
            if samePath {
                // The replacement sits at the original location: only an unchanged one may go.
                if replacementThere && !replacementUnchanged {
                    fail("something already exists at the original location")
                    continue
                }
            } else if exists(record.originalPath) {
                // Check before anything moves.
                fail("something already exists at the original location")
                continue
            }
            var trashedReplacement: String?
            do {
                if replacementThere && replacementUnchanged {
                    var trashed: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: record.newPath), resultingItemURL: &trashed)
                    trashedReplacement = (trashed as URL?)?.path
                }
                try fm.moveItem(atPath: trashPath, toPath: record.originalPath)
                outcomes.append((record, nil))
            } catch {
                if let back = trashedReplacement, !exists(record.newPath) {
                    try? fm.moveItem(atPath: back, toPath: record.newPath)
                }
                fail(friendlyMessage(error))
            }
        }
        return outcomes
    }
}

// MARK: - Results still arriving

extension CompressionService {
    /// What the scan has found so far, for the screen to show while it keeps going. `sampleRatios`
    /// holds only the categories measured so far; the rest read "Measuring…".
    private static func partialResult(_ collector: ScanCollector, ratios: [CompressCategory: Double],
                                          tools: CompressTools, options: CompressOptions) -> CompressScanResult {
        CompressScanResult(
            candidates: collector.candidates,
            skipped: collector.skipGroups.values.sorted { $0.bytes > $1.bytes },
            sampleRatios: ratios,
            tools: tools,
            minDaysUsedForFolders: options.minDaysUnused,
            scannedAt: Date(),
            toolFiles: collector.toolFiles
        )
    }
}

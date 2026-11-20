import AVFoundation
import Darwin
import Foundation

/// Lossy Shrink mode: re-encodes photos, videos and PDF images at a lower quality. Offline, built-in frameworks only.
/// Originals always go to the Trash and undo uses the same records and code as lossless Compress.
enum ShrinkService {
    // MARK: - Scan

    static let skippedTopLevel: Set<String> = ["Library", ".Trash", "Applications"]
    static let photoLibraryExtensions: Set<String> = ["photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary"]
    /// Packages owned by apps that track every byte (editing inside them breaks the app's database).
    static let blockedPackages: Set<String> = ["musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
                                                        "sparsebundle", "app", "photoslibrary", "photolibrary",
                                                        "migratedphotolibrary", "aplibrary", "rtfd", "bundle"]
    static let suppressedFolders: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", ".build"]

    /// Folder names that sync to a cloud service even outside ~/Library/CloudStorage.
    private static let cloudFolderNames: [String] = ["Dropbox", "Google Drive", "My Drive", "OneDrive", "Box", "pCloud Drive", "iCloud Drive"]

    static func defaultRoots() -> [String] {
        [FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path]
    }

    /// `emit` gets what's been found so far about once a second while walking (results still
    /// arriving). Those snapshots don't know yet which files are open; the final result does.
    static func scan(roots: [String], progress: CompressProgress?,
                     emit: ((ShrinkScanResult) -> Void)? = nil) -> ShrinkScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let uid = getuid()
        var found: [(path: String, kind: ShrinkKind, st: stat)] = []
        var photoLibraries: [String] = []
        var partial: [ShrinkCandidate] = []
        var lastEmit = Date()
        func emitIfDue() {
            guard let emit, Date().timeIntervalSince(lastEmit) >= 1, found.count > partial.count else { return }
            lastEmit = Date()
            partial += found[partial.count...].map { item in
                ShrinkCandidate(
                    path: item.path, kind: item.kind,
                    sizeBytes: CompressionFS.allocatedBytes(item.st), logicalSize: Int64(item.st.st_size),
                    modified: CompressionFS.date(item.st.st_mtimespec),
                    isCloudSynced: isCloudSynced(item.path, home: home),
                    isOpen: false, alreadyShrunk: hasShrunkMarker(item.path)
                )
            }
            emit(ShrinkScanResult(roots: roots, candidates: partial, photoLibraries: photoLibraries, scannedAt: Date()))
        }

        for root in roots {
            if progress?.isCancelled == true { break }
            progress?.setPhase("Looking through \((root as NSString).lastPathComponent)")
            let rootIsHome = root == home
            CompressionFS.walk(root) { path, st in
                if progress?.isCancelled == true { return false }
                let name = (path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                if CompressionFS.isDirectory(st) {
                    if path == root { return true }
                    let parent = (path as NSString).deletingLastPathComponent
                    if rootIsHome, parent == root, skippedTopLevel.contains(name) || name.hasPrefix(".") { return false }
                    if photoLibraryExtensions.contains(ext) { photoLibraries.append(path); return false }
                    if blockedPackages.contains(ext) || suppressedFolders.contains(name) || name.hasPrefix(".") { return false }
                    if st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag) != 0 { return false }
                    return true
                }
                guard CompressionFS.isRegular(st), !name.hasPrefix("."), let kind = ShrinkEngines.kind(forExtension: ext) else { return true }
                progress?.advance()
                guard Int64(st.st_size) >= kind.minimumBytes,
                      st.st_nlink == 1, st.st_uid == uid,
                      st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag | CompressionFS.immutableFlags | CompressionFS.compressedFlag) == 0 else {
                    return true
                }
                found.append((path, kind, st))
                emitIfDue()
                return true
            }
        }

        progress?.setPhase("Checking which files are open or synced")
        let openFiles = CompressionFS.openFiles()
        let candidates: [ShrinkCandidate] = found.map { item in
            ShrinkCandidate(
                path: item.path,
                kind: item.kind,
                sizeBytes: CompressionFS.allocatedBytes(item.st),
                logicalSize: Int64(item.st.st_size),
                modified: CompressionFS.date(item.st.st_mtimespec),
                isCloudSynced: isCloudSynced(item.path, home: home),
                isOpen: openFiles.contains(item.path),
                alreadyShrunk: hasShrunkMarker(item.path)
            )
        }
        return ShrinkScanResult(roots: roots, candidates: candidates, photoLibraries: photoLibraries, scannedAt: Date())
    }

    static func isCloudSynced(_ path: String, home: String) -> Bool {
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") { return true }
        for name in cloudFolderNames where path.hasPrefix(home + "/" + name + "/") { return true }
        // Desktop & Documents in iCloud, and anything else iCloud manages.
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }

    static func hasShrunkMarker(_ path: String) -> Bool {
        getxattr(path, ShrinkEngines.shrunkMarker, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    // MARK: - Eligibility

    /// Why a candidate won't be shrunk with these options, or nil if it will.
    static func skipReason(_ candidate: ShrinkCandidate, options: ShrinkOptions) -> ShrinkSkipReason? {
        if candidate.alreadyShrunk { return .alreadyShrunk }
        if candidate.isOpen { return .openInApp }
        let allowed = options.isAllowed(candidate.path)
        if candidate.isCloudSynced, !allowed { return .cloudSynced }
        if candidate.modified >= options.recentCutoff, !allowed { return .recentlyModified }
        return nil
    }

    static func eligible(_ scan: ShrinkScanResult, options: ShrinkOptions) -> [ShrinkCandidate] {
        scan.candidates.filter {
            options.kinds.contains($0.kind) && $0.kind.missingToolNote(options.tools) == nil && skipReason($0, options: options) == nil
        }
    }

    static func skipGroups(_ scan: ShrinkScanResult, options: ShrinkOptions) -> [ShrinkSkipGroup] {
        var groups: [String: ShrinkSkipGroup] = [:]
        for candidate in scan.candidates where options.kinds.contains(candidate.kind) {
            guard let reason = skipReason(candidate, options: options) else { continue }
            let key = reason.rawValue + "|" + candidate.folder
            groups[key, default: ShrinkSkipGroup(folder: candidate.folder, reason: reason, count: 0, bytes: 0)].count += 1
            groups[key]?.bytes += candidate.sizeBytes
        }
        for library in scan.photoLibraries {
            groups["lib|" + library] = ShrinkSkipGroup(folder: library, reason: .photosLibrary, count: 1, bytes: 0)
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Preview

    /// Encodes one item into a temporary folder (never replacing anything) and compares it with the original.
    static func preview(_ candidate: ShrinkCandidate, options: ShrinkOptions) async -> ShrinkPreview {
        let signature = options.encodeSignature
        func failed(_ message: String) -> ShrinkPreview {
            ShrinkPreview(candidate: candidate, signature: signature, before: nil, after: nil, beforeDetail: nil, afterDetail: nil,
                          originalBytes: candidate.logicalSize, newBytes: candidate.logicalSize, isProjected: false,
                          quality: ShrinkQuality(psnr: nil), note: "", problem: message)
        }
        guard let work = CompressionService.makeWorkDirectory(near: candidate.path) else { return failed("Couldn't create a working folder") }
        defer { try? FileManager.default.removeItem(atPath: work) }

        switch candidate.kind {
        case .photos, .png:
            let result = candidate.kind == .png
                ? ShrinkEngines.shrinkPNG(candidate.path, workDir: work, options: options)
                : ShrinkEngines.shrinkPhoto(candidate.path, workDir: work, options: options)
            guard case .ready(let out, _, let note) = result else {
                if case .skip(let why) = result { return failed(why) }
                if case .fail(let why) = result { return failed(why) }
                return failed("Couldn't encode this photo")
            }
            let newBytes = logicalSize(out)
            let longSide = Int(ShrinkEngines.photoPixelSize(candidate.path).map { max($0.width, $0.height) } ?? 4096)
            let fullBefore = ShrinkEngines.photoImage(candidate.path, maxSide: longSide)
            let fullAfter = ShrinkEngines.photoImage(out, maxSide: longSide)
            var quality = ShrinkQuality(psnr: nil)
            var crops: (CGImage?, CGImage?) = (nil, nil)
            if let a = fullBefore, let b = fullAfter {
                quality = ShrinkQuality(psnr: ShrinkEngines.psnr(a, b))
                crops = ShrinkEngines.centreCrops(a, b)
            }
            return ShrinkPreview(
                candidate: candidate, signature: signature,
                before: fullBefore.flatMap { fit($0, 1400) }, after: fullAfter.flatMap { fit($0, 1400) },
                beforeDetail: crops.0, afterDetail: crops.1,
                originalBytes: candidate.logicalSize, newBytes: newBytes, isProjected: false, quality: quality, note: note,
                problem: sizeProblem(original: candidate.logicalSize, new: newBytes, options: options)
            )

        case .pdfs:
            let result = ShrinkEngines.shrinkPDF(candidate.path, workDir: work, options: options)
            guard case .ready(let out, _, let note) = result else {
                if case .skip(let why) = result { return failed(why) }
                if case .fail(let why) = result { return failed(why) }
                return failed("Couldn't process this PDF")
            }
            let newBytes = logicalSize(out)
            let a = ShrinkEngines.pdfPageImage(candidate.path, longSide: 2000)
            let b = ShrinkEngines.pdfPageImage(out, longSide: 2000)
            let quality = (a != nil && b != nil) ? ShrinkQuality(psnr: ShrinkEngines.psnr(a!, b!)) : ShrinkQuality(psnr: nil)
            let crops = (a != nil && b != nil) ? ShrinkEngines.centreCrops(a!, b!) : (nil, nil)
            return ShrinkPreview(
                candidate: candidate, signature: signature,
                before: a.flatMap { fit($0, 1400) }, after: b.flatMap { fit($0, 1400) },
                beforeDetail: crops.0, afterDetail: crops.1,
                originalBytes: candidate.logicalSize, newBytes: newBytes, isProjected: false, quality: quality,
                note: note + " · first page shown",
                problem: sizeProblem(original: candidate.logicalSize, new: newBytes, options: options)
            )

        case .videos:
            guard let duration = await ShrinkEngines.videoDuration(candidate.path), duration > 0 else { return failed("Couldn't read the video") }
            // Encode a short clip from the middle and project the full size from it.
            let clip = min(duration, 8)
            let start = max(0, duration / 2 - clip / 2)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: clip, preferredTimescale: 600))
            let result = await ShrinkEngines.shrinkVideo(candidate.path, workDir: work, options: options, segment: duration > clip + 1 ? range : nil)
            guard case .ready(let out, _, let note) = result else {
                if case .skip(let why) = result { return failed(why) }
                if case .fail(let why) = result { return failed(why) }
                return failed("Couldn't encode this video")
            }
            let clipBytes = logicalSize(out)
            let projected = duration > clip + 1 ? Int64(Double(clipBytes) * duration / clip) : clipBytes
            let a = await ShrinkEngines.videoFrame(candidate.path, at: start + clip / 2, maxSide: 4096)
            let b = await ShrinkEngines.videoFrame(out, at: duration > clip + 1 ? clip / 2 : start + clip / 2, maxSide: 4096)
            let quality = (a != nil && b != nil) ? ShrinkQuality(psnr: ShrinkEngines.psnr(a!, b!)) : ShrinkQuality(psnr: nil)
            let crops = (a != nil && b != nil) ? ShrinkEngines.centreCrops(a!, b!) : (nil, nil)
            return ShrinkPreview(
                candidate: candidate, signature: signature,
                before: a.flatMap { fit($0, 1400) }, after: b.flatMap { fit($0, 1400) },
                beforeDetail: crops.0, afterDetail: crops.1,
                originalBytes: candidate.logicalSize, newBytes: min(candidate.logicalSize, projected),
                isProjected: duration > clip + 1, quality: quality,
                note: note + (duration > clip + 1 ? " · size projected from an \(Int(clip))-second clip" : ""),
                problem: sizeProblem(original: candidate.logicalSize, new: projected, options: options)
            )
        }
    }

    private static func fit(_ image: CGImage, _ maxSide: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        return ShrinkEngines.resample(image, width: image.width * maxSide / longSide, height: image.height * maxSide / longSide)
    }

    private static func sizeProblem(original: Int64, new: Int64, options: ShrinkOptions) -> String? {
        guard original > 0 else { return nil }
        let saved = 1 - Double(new) / Double(original)
        if saved < options.minimumSavingsFraction {
            return "Only \(Int((max(0, saved) * 100).rounded()))% smaller, so the original would be kept (needs \(Int(options.minimumSavingsFraction * 100))%)."
        }
        return nil
    }

    static func logicalSize(_ path: String) -> Int64 {
        CompressionFS.lstatInfo(path).map { Int64($0.st_size) } ?? 0
    }

    // MARK: - Estimate

    /// Encodes a few items per kind and returns output/input ratios (items that wouldn't pass the 15% rule count as 1.0).
    static func sampleRatios(_ candidates: [ShrinkCandidate], options: ShrinkOptions, progress: CompressProgress?) async -> [ShrinkKind: Double] {
        var ratios: [ShrinkKind: Double] = [:]
        for kind in ShrinkKind.allCases where options.kinds.contains(kind) {
            let pool = candidates.filter { $0.kind == kind }.sorted { $0.logicalSize < $1.logicalSize }
            guard !pool.isEmpty else { continue }
            let picks = min(kind == .videos ? 2 : 4, pool.count)
            let sample = Set((0..<picks).map { pool[($0 * (pool.count - 1)) / max(1, picks - 1)] })
            var inBytes: Int64 = 0, outBytes: Int64 = 0
            for candidate in sample {
                if progress?.isCancelled == true { return ratios }
                progress?.setPhase("Trying \(candidate.name)")
                let preview = await preview(candidate, options: options)
                inBytes += preview.originalBytes
                outBytes += preview.problem == nil ? preview.newBytes : preview.originalBytes
            }
            if inBytes > 0 { ratios[kind] = Double(outBytes) / Double(inBytes) }
        }
        return ratios
    }

    // MARK: - Run

    static func run(_ candidates: [ShrinkCandidate], options: ShrinkOptions, progress: CompressProgress?) async -> ShrinkRunResult {
        var result = ShrinkRunResult(startedAt: Date())
        result.removedPhotoDetails = options.stripPhotoMetadata
        progress?.setTotal(candidates.count)
        progress?.setPhase("Checking which files are in use")
        let openFiles = CompressionFS.openFiles()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for candidate in candidates.sorted(by: { $0.path < $1.path }) {
            if progress?.isCancelled == true { result.wasCancelled = true; break }
            progress?.setPhase(candidate.name)
            let item = await process(candidate, options: options, openFiles: openFiles, home: home)
            result.items.append(item)
            progress?.advance(saved: item.savedBytes)
        }
        result.finishedAt = Date()
        return result
    }

    static func process(_ candidate: ShrinkCandidate, options: ShrinkOptions, openFiles: Set<String>, home: String) async -> ShrinkItemResult {
        let path = candidate.path
        func outcome(_ status: ShrinkItemStatus, _ message: String, original: Int64 = 0, new: Int64 = 0, undo: CompressUndoRecord? = nil) -> ShrinkItemResult {
            ShrinkItemResult(path: path, kind: candidate.kind, status: status, originalBytes: original, newBytes: new, message: message, undo: undo)
        }

        // Re-check everything the scan saw; files change.
        guard let st = CompressionFS.lstatInfo(path), CompressionFS.isRegular(st) else { return outcome(.skipped, "No longer exists") }
        if DeletionService.isProtected(path) { return outcome(.skipped, "Protected location") }
        if st.st_nlink > 1 || st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag | CompressionFS.immutableFlags) != 0 {
            return outcome(.skipped, "Locked, hard-linked or iCloud-only")
        }
        // The lsof snapshot is from the start of the run; check again now, for this file.
        if openFiles.contains(path) || CompressionFS.isOpenNow(path, isDirectory: false) {
            return outcome(.skipped, "Open in another app")
        }
        if hasShrunkMarker(path) { return outcome(.skipped, "Already shrunk once") }
        let allowed = options.isAllowed(path)
        if !allowed, isCloudSynced(path, home: home) { return outcome(.skipped, "Cloud-synced folder (not allowed)") }
        if !allowed, CompressionFS.date(st.st_mtimespec) >= options.recentCutoff { return outcome(.skipped, "Changed in the last \(options.recentDays) days") }

        guard let work = CompressionService.makeWorkDirectory(near: path) else { return outcome(.failed, "Couldn't create a working folder on this disk") }
        defer { try? FileManager.default.removeItem(atPath: work) }

        let engine: ShrinkEngineResult
        switch candidate.kind {
        case .photos: engine = ShrinkEngines.shrinkPhoto(path, workDir: work, options: options)
        case .png: engine = ShrinkEngines.shrinkPNG(path, workDir: work, options: options)
        case .videos: engine = await ShrinkEngines.shrinkVideo(path, workDir: work, options: options)
        case .pdfs: engine = ShrinkEngines.shrinkPDF(path, workDir: work, options: options)
        }
        let done = finish(engine, path: path, st: st, minimumSavingsFraction: options.minimumSavingsFraction)
        return outcome(done.status, done.message, original: done.original, new: done.new, undo: done.undo)
    }

    /// Applies the size rule, keeps tags and dates, marks the file as shrunk, and swaps it in (original to the Trash).
    /// Shared with Format suggestions.
    static func finish(_ engine: ShrinkEngineResult, path: String, st: stat, minimumSavingsFraction: Double)
        -> (status: ShrinkItemStatus, message: String, original: Int64, new: Int64, undo: CompressUndoRecord?) {
        let originalBytes = CompressionFS.allocatedBytes(st)
        switch engine {
        case .skip(let why): return (.skipped, why, originalBytes, originalBytes, nil)
        case .fail(let why): return (.failed, why, originalBytes, originalBytes, nil)
        case .ready(let output, let destination, let note):
            let newBytes = CompressionFS.allocatedBytes(atPath: output)
            let newLogical = logicalSize(output)
            let threshold = 1 - minimumSavingsFraction
            guard Double(newLogical) <= Double(st.st_size) * threshold, Double(newBytes) <= Double(originalBytes) * threshold else {
                let pct = st.st_size > 0 ? Int(((1 - Double(newLogical) / Double(st.st_size)) * 100).rounded()) : 0
                return (.keptOriginal, "Only \(max(0, pct))% smaller; kept the original", originalBytes, originalBytes, nil)
            }
            if !CompressionFS.unchanged(path, since: st) {
                return (.skipped, "Changed while converting", originalBytes, originalBytes, nil)
            }
            // Right before the swap: an app may have opened it while it was converting.
            if CompressionFS.isOpenNow(path, isDirectory: false) {
                return (.skipped, "Open in another app", originalBytes, originalBytes, nil)
            }
            // Finder tags, comments, permissions, creation and modification dates.
            CompressionFS.copyMetadata(from: path, to: output)
            let marker = Data(note.utf8)
            _ = marker.withUnsafeBytes { setxattr(output, ShrinkEngines.shrunkMarker, $0.baseAddress, marker.count, 0, XATTR_NOFOLLOW) }
            // setxattr can bump nothing but ctime; re-apply the dates to be safe.
            try? FileManager.default.setAttributes([
                .creationDate: CompressionFS.date(st.st_birthtimespec),
                .modificationDate: CompressionFS.date(st.st_mtimespec)
            ], ofItemAtPath: output)
            do {
                let undo = try CompressionService.swap(original: path, replacement: output, destination: destination, keepOriginal: true)
                return (.shrunk, note, originalBytes, newBytes, undo)
            } catch {
                return (.failed, "Couldn't replace the original: \(error.localizedDescription)", originalBytes, originalBytes, nil)
            }
        }
    }
}

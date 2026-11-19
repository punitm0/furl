import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Format suggestions: files that would be much smaller in another format. Nothing converts until the user picks it.
// Reuses Shrink's skip list, encoders and `ShrinkService.finish` (15% rule, metadata, dates, Trash + compress undo).

enum FormatConversion: String, CaseIterable, Identifiable, Sendable, Hashable {
    case movToHEVC, gifToHEVC, pngToHEIC, rawImageToLossless, pcmToALAC, jpegToHEIC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movToHEVC: "Videos → HEVC"
        case .gifToHEVC: "Animated GIFs → HEVC video"
        case .pngToHEIC: "Screenshots and PNG photos → HEIC"
        case .rawImageToLossless: "BMP and uncompressed TIFF → PNG / LZW TIFF"
        case .pcmToALAC: "WAV and AIFF → Apple Lossless"
        case .jpegToHEIC: "Older JPEG photos → HEIC"
        }
    }

    var systemImage: String {
        switch self {
        case .movToHEVC: "film"
        case .gifToHEVC: "play.rectangle"
        case .pngToHEIC: "camera.viewfinder"
        case .rawImageToLossless: "photo"
        case .pcmToALAC: "waveform"
        case .jpegToHEIC: "photo.on.rectangle"
        }
    }

    var isLossless: Bool { self == .rawImageToLossless || self == .pcmToALAC }

    /// Shown next to HEIC/HEVC results.
    var compatibilityNote: String? {
        switch self {
        case .movToHEVC, .gifToHEVC:
            "HEVC plays on Macs and iPhones from 2017 on. Some Windows PCs, older TVs and web uploaders can't play it."
                + (self == .gifToHEVC ? " A video doesn't loop by itself and can't be pasted where only GIFs work." : "")
        case .pngToHEIC, .jpegToHEIC:
            "HEIC opens on Macs and iPhones from 2017 on. Some Windows apps and websites can't open it."
        default: nil
        }
    }

    /// Lossy screenshots must save at least 30% to be worth suggesting; everything else 15%.
    var minimumSavingsFraction: Double { self == .pngToHEIC ? 0.30 : 0.15 }

    var minimumBytes: Int64 {
        switch self {
        case .movToHEVC: 20_000_000
        case .gifToHEVC: 500_000
        case .pngToHEIC: 500_000
        case .rawImageToLossless: 1_000_000
        case .pcmToALAC: 5_000_000
        case .jpegToHEIC: 500_000
        }
    }

    static func forExtension(_ ext: String) -> FormatConversion? {
        switch ext {
        case "mov": .movToHEVC
        case "gif": .gifToHEVC
        case "png": .pngToHEIC
        case "bmp", "tif", "tiff": .rawImageToLossless
        case "wav", "wave", "aif", "aiff": .pcmToALAC
        case "jpg", "jpeg": .jpegToHEIC
        default: nil
        }
    }
}

struct FormatSuggestion: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let conversion: FormatConversion
    let sizeBytes: Int64
    let estimatedBytes: Int64
    /// What the result would be, e.g. "HEIC at 75% quality".
    let note: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var estimatedSavings: Int64 { max(0, sizeBytes - estimatedBytes) }
    var savingsFraction: Double { sizeBytes > 0 ? Double(estimatedSavings) / Double(sizeBytes) : 0 }
}

enum FormatSkipReason: String, CaseIterable, Sendable {
    case project, cloudSynced, recentlyModified, openInApp, photosLibrary, alreadyConverted, notWorthIt, unsuitable

    var label: String {
        switch self {
        case .project: "Inside a project or Git repo (a new extension would break references)"
        case .cloudSynced: "In a cloud-synced folder"
        case .recentlyModified: "Changed recently"
        case .openInApp: "Open in another app"
        case .photosLibrary: "Photos library"
        case .alreadyConverted: "Already converted or shrunk"
        case .notWorthIt: "Wouldn't save enough"
        case .unsuitable: "Not a good fit (transparency, flat colours, already compressed)"
        }
    }
}

struct FormatScanResult: Sendable {
    var suggestions: [FormatSuggestion] = []
    var skipped: [FormatSkipReason: Int] = [:]
    var scannedAt = Date()

    var totalSavings: Int64 { suggestions.reduce(0) { $0 + $1.estimatedSavings } }
    func suggestions(_ conversion: FormatConversion) -> [FormatSuggestion] { suggestions.filter { $0.conversion == conversion } }
}

struct FormatItemResult: Identifiable, Sendable, Hashable {
    let id = UUID()
    let path: String
    let conversion: FormatConversion
    let status: ShrinkItemStatus
    let originalBytes: Int64
    let newBytes: Int64
    let message: String
    let undo: CompressUndoRecord?

    var savedBytes: Int64 { status == .shrunk ? max(0, originalBytes - newBytes) : 0 }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct FormatRunResult: Sendable {
    var items: [FormatItemResult] = []
    var wasCancelled = false
    var savedBytes: Int64 { items.reduce(0) { $0 + $1.savedBytes } }
    func count(_ status: ShrinkItemStatus) -> Int { items.filter { $0.status == status }.count }
    var undoRecords: [CompressUndoRecord] { items.compactMap(\.undo) }
}

enum FormatService {
    /// Files or folders whose presence in an ancestor folder marks a project.
    static let projectMarkers: Set<String> = [".git", "package.json", "Package.swift", "Podfile", "Cargo.toml", "go.mod",
                                              "pyproject.toml", "requirements.txt", "Gemfile", "pom.xml", "build.gradle",
                                              "Makefile", "CMakeLists.txt", ".hg", ".svn"]
    static let projectExtensions: Set<String> = ["xcodeproj", "xcworkspace", "fcpbundle", "fcpproject", "prproj", "aep",
                                                 "drp", "logicx", "band", "imovielibrary", "sketch", "fig", "psd", "afdesign"]
    /// JPEGs younger than this are left alone ("older photos" only).
    static let jpegMinimumAge: TimeInterval = 365 * 86_400

    // MARK: - Scan

    static func scan(roots: [String], options: ShrinkOptions, progress: CompressProgress?) async -> FormatScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let uid = getuid()
        var result = FormatScanResult()
        var found: [(path: String, conversion: FormatConversion, st: stat)] = []

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
                    if rootIsHome, parent == root, ShrinkService.skippedTopLevel.contains(name) || name.hasPrefix(".") { return false }
                    if ShrinkService.photoLibraryExtensions.contains(ext) { result.skipped[.photosLibrary, default: 0] += 1; return false }
                    if ShrinkService.blockedPackages.contains(ext) || projectExtensions.contains(ext)
                        || ShrinkService.suppressedFolders.contains(name) || name.hasPrefix(".") { return false }
                    if st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag) != 0 { return false }
                    return true
                }
                guard CompressionFS.isRegular(st), !name.hasPrefix("."), let conversion = FormatConversion.forExtension(ext) else { return true }
                progress?.advance()
                guard Int64(st.st_size) >= conversion.minimumBytes, st.st_nlink == 1, st.st_uid == uid,
                      st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag | CompressionFS.immutableFlags | CompressionFS.compressedFlag) == 0
                else { return true }
                found.append((path, conversion, st))
                return true
            }
        }

        progress?.setPhase("Checking which files are open, synced or in projects")
        let openFiles = CompressionFS.openFiles()
        var projectCache: [String: Bool] = [:]
        var pending: [(path: String, conversion: FormatConversion, st: stat)] = []
        for item in found {
            let allowed = options.isAllowed(item.path)
            let modified = CompressionFS.date(item.st.st_mtimespec)
            let reason: FormatSkipReason? =
                isInProject(item.path, home: home, cache: &projectCache) ? .project
                : openFiles.contains(item.path) ? .openInApp
                : ShrinkService.hasShrunkMarker(item.path) ? .alreadyConverted
                : (!allowed && ShrinkService.isCloudSynced(item.path, home: home)) ? .cloudSynced
                : (!allowed && modified >= options.recentCutoff) ? .recentlyModified
                : (item.conversion == .jpegToHEIC && modified > Date().addingTimeInterval(-jpegMinimumAge)) ? .recentlyModified
                : nil
            if let reason { result.skipped[reason, default: 0] += 1 } else { pending.append(item) }
        }

        // Test-encode each one into a temporary folder to estimate the saving (videos: an 8-second clip).
        progress?.setTotal(pending.count)
        for item in pending {
            if progress?.isCancelled == true { break }
            progress?.setPhase("Trying \((item.path as NSString).lastPathComponent)")
            guard let work = CompressionService.makeWorkDirectory(near: item.path) else { continue }
            defer { try? FileManager.default.removeItem(atPath: work) }
            let size = CompressionFS.allocatedBytes(item.st)
            let logical = Int64(item.st.st_size)
            switch await encode(item.path, conversion: item.conversion, workDir: work, estimate: true) {
            case .skip, .fail:
                result.skipped[.unsuitable, default: 0] += 1
            case .ready(let output, _, let note):
                var ratio = Double(ShrinkService.logicalSize(output)) / Double(max(1, logical))
                if item.conversion == .movToHEVC, let full = await ShrinkEngines.videoDuration(item.path), full > 0,
                   let clip = await ShrinkEngines.videoDuration(output), clip > 0 {
                    ratio = Double(ShrinkService.logicalSize(output)) / clip * full / Double(max(1, logical))
                }
                if 1 - ratio < item.conversion.minimumSavingsFraction {
                    result.skipped[.notWorthIt, default: 0] += 1
                } else {
                    result.suggestions.append(FormatSuggestion(path: item.path, conversion: item.conversion, sizeBytes: size,
                                                               estimatedBytes: Int64(Double(size) * ratio), note: note))
                }
            }
            progress?.advance()
        }
        result.suggestions.sort { $0.estimatedSavings > $1.estimatedSavings }
        result.scannedAt = Date()
        return result
    }

    /// True if any folder between the file and the home folder holds a project marker.
    static func isInProject(_ path: String, home: String, cache: inout [String: Bool]) -> Bool {
        var dir = (path as NSString).deletingLastPathComponent
        var visited: [String] = []
        var answer = false
        while dir.count > 1, dir != home, dir != "/" {
            if let known = cache[dir] { answer = known; break }
            visited.append(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if names.contains(where: { projectMarkers.contains($0) || projectExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                answer = true
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for folder in visited { cache[folder] = answer }
        return answer
    }

    // MARK: - Convert

    static func convert(_ suggestions: [FormatSuggestion], options: ShrinkOptions, progress: CompressProgress?) async -> FormatRunResult {
        var result = FormatRunResult()
        progress?.setTotal(suggestions.count)
        let openFiles = CompressionFS.openFiles()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var projectCache: [String: Bool] = [:]
        for suggestion in suggestions.sorted(by: { $0.path < $1.path }) {
            if progress?.isCancelled == true { result.wasCancelled = true; break }
            progress?.setPhase(suggestion.name)
            let path = suggestion.path
            func item(_ status: ShrinkItemStatus, _ message: String, _ original: Int64 = 0, _ new: Int64 = 0, _ undo: CompressUndoRecord? = nil) -> FormatItemResult {
                FormatItemResult(path: path, conversion: suggestion.conversion, status: status, originalBytes: original, newBytes: new, message: message, undo: undo)
            }
            let outcome: FormatItemResult
            if let st = CompressionFS.lstatInfo(path), CompressionFS.isRegular(st) {
                let allowed = options.isAllowed(path)
                if DeletionService.isProtected(path) || st.st_nlink > 1
                    || st.st_flags & (CompressionFS.datalessFlag | CompressionFS.restrictedFlag | CompressionFS.immutableFlags) != 0 {
                    outcome = item(.skipped, "Locked, protected or iCloud-only")
                } else if openFiles.contains(path) || CompressionFS.isOpenNow(path, isDirectory: false) {
                    outcome = item(.skipped, "Open in another app")
                } else if ShrinkService.hasShrunkMarker(path) || isInProject(path, home: home, cache: &projectCache) {
                    outcome = item(.skipped, "Already converted, or inside a project")
                } else if !allowed, ShrinkService.isCloudSynced(path, home: home) || CompressionFS.date(st.st_mtimespec) >= options.recentCutoff {
                    outcome = item(.skipped, "Cloud-synced or changed recently")
                } else if let work = CompressionService.makeWorkDirectory(near: path) {
                    defer { try? FileManager.default.removeItem(atPath: work) }
                    let engine = await encode(path, conversion: suggestion.conversion, workDir: work, estimate: false)
                    let done = ShrinkService.finish(engine, path: path, st: st, minimumSavingsFraction: 0.15)
                    outcome = item(done.status, done.message, done.original, done.new, done.undo)
                } else {
                    outcome = item(.failed, "Couldn't create a working folder on this disk")
                }
            } else {
                outcome = item(.skipped, "No longer exists")
            }
            result.items.append(outcome)
            progress?.advance(saved: outcome.savedBytes)
        }
        return result
    }

    // MARK: - Encoders

    static func encode(_ path: String, conversion: FormatConversion, workDir: String, estimate: Bool) async -> ShrinkEngineResult {
        var heic = ShrinkOptions()
        heic.imageFormat = .heic
        switch conversion {
        case .movToHEVC:
            guard let codec = await videoCodec(path) else { return .skip("No video track") }
            let proRes: Set<String> = ["apcn", "apch", "apcs", "apco", "ap4h", "ap4x"]
            guard codec == "avc1" || proRes.contains(codec) else { return .skip("Only H.264 and ProRes videos are suggested") }
            let clip = estimate ? CMTimeRange(start: .zero, duration: CMTime(seconds: 8, preferredTimescale: 600)) : nil
            return await ShrinkEngines.shrinkVideo(path, workDir: workDir, options: heic, segment: clip)
        case .jpegToHEIC:
            return ShrinkEngines.shrinkPhoto(path, workDir: workDir, options: heic)
        case .pngToHEIC:
            return pngToHEIC(path, workDir: workDir, quality: heic.imageQuality)
        case .rawImageToLossless:
            return losslessImage(path, workDir: workDir)
        case .pcmToALAC:
            switch CompressionEngines.convertToAppleLossless(path, workDir: workDir) {
            case .ready(let output, let destination, let note): return .ready(output: output, destination: destination, note: note)
            case .notSmaller(let why), .skip(let why): return .skip(why)
            case .reject(let why), .fail(let why): return .fail(why)
            }
        case .gifToHEVC:
            return await gifToHEVC(path, workDir: workDir)
        }
    }

    private static func videoCodec(_ path: String) async -> String? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description).bigEndian
        return withUnsafeBytes(of: code) { String(bytes: $0, encoding: .ascii) }
    }

    private static func renamed(_ path: String, ext: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension(ext).path
    }

    private static func workPath(_ workDir: String, _ destination: String) -> String {
        (workDir as NSString).appendingPathComponent((destination as NSString).lastPathComponent)
    }

    /// Small RGBA sample of an image: whether it has see-through pixels and how many distinct colours it uses.
    static func sampleTraits(_ image: CGImage) -> (transparent: Bool, colours: Int) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return (true, 0) }
        var transparent = false
        var colours = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i + 3] < 250 { transparent = true }
            colours.insert(UInt32(pixels[i] >> 3) << 10 | UInt32(pixels[i + 1] >> 3) << 5 | UInt32(pixels[i + 2] >> 3))
        }
        return (transparent, colours.count)
    }

    private static func isScreenshot(_ path: String, props: [CFString: Any]) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot") { return true }
        let comment = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String
        return comment == "Screenshot"
    }

    static func pngToHEIC(_ path: String, workDir: String, quality: Double) -> ShrinkEngineResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .skip("Not a single-image PNG") }
        let traits = sampleTraits(image)
        if traits.transparent { return .skip("Has transparency") }
        if !isScreenshot(path, props: props), traits.colours < 512 { return .skip("Looks like a graphic with flat colours") }
        let destination = renamed(path, ext: "heic")
        if FileManager.default.fileExists(atPath: destination) { return .skip("A .heic with the same name already exists") }
        let out = workPath(workDir, destination)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return .fail("This Mac can't write HEIC")
        }
        CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return .fail("Couldn't write HEIC") }
        var expected = props
        expected.removeValue(forKey: kCGImagePropertyProfileName)
        if let problem = ShrinkEngines.photoMetadataProblem(original: expected, output: out) { return .skip("Metadata couldn't be kept: \(problem)") }
        return .ready(output: out, destination: destination, note: "HEIC at \(Int((quality * 100).rounded()))% quality (lossy)")
    }

    /// BMP → PNG, uncompressed TIFF → LZW TIFF. Every pixel is checked against the original.
    static func losslessImage(_ path: String, workDir: String) -> ShrinkEngineResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .skip("Couldn't read the image") }
        let ext = (path as NSString).pathExtension.lowercased()
        let isTIFF = ext != "bmp"
        if isTIFF {
            let compression = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int ?? 1
            guard compression == 1 else { return .skip("TIFF is already compressed") }
        }
        let destination = isTIFF ? path : renamed(path, ext: "png")
        if destination != path, FileManager.default.fileExists(atPath: destination) { return .skip("A .png with the same name already exists") }
        let out = workPath(workDir, destination)
        let type: UTType = isTIFF ? .tiff : .png
        let count = CGImageSourceGetCount(source)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, type.identifier as CFString, count, nil) else {
            return .fail("Couldn't create the output")
        }
        for index in 0..<count {
            let extra: [CFString: Any] = isTIFF ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [:]
            CGImageDestinationAddImageFromSource(dest, source, index, extra as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return .fail("Couldn't write the output") }
        if let problem = ImageVerifier.difference(path, out) { return .fail("Pixels changed: \(problem)") }
        return .ready(output: out, destination: destination,
                      note: isTIFF ? "LZW TIFF, every pixel identical (lossless)" : "PNG, every pixel identical (lossless)")
    }

    /// Animated GIF → HEVC .mp4 with the GIF's frame timing.
    static func gifToHEVC(_ path: String, workDir: String) async -> ShrinkEngineResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return .skip("Couldn't read the GIF") }
        let count = CGImageSourceGetCount(source)
        guard count > 1, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .skip("Not animated") }
        if sampleTraits(first).transparent { return .skip("Has transparency, which video can't keep") }
        let destination = renamed(path, ext: "mp4")
        if FileManager.default.fileExists(atPath: destination) { return .skip("A .mp4 with the same name already exists") }
        let out = workPath(workDir, destination)
        let width = (first.width + 1) & ~1, height = (first.height + 1) & ~1
        guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4) else { return .fail("Couldn't create the video") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.75]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { return .fail("HEVC isn't available") }
        writer.add(input)
        guard writer.startWriting() else { return .fail("Couldn't start the encoder") }
        writer.startSession(atSourceTime: .zero)
        var time = 0.0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil), let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(frame, in: CGRect(x: 0, y: height - frame.height, width: frame.width, height: frame.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += gifDelay(source, index)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { return .fail("The encoder failed: \(writer.error?.localizedDescription ?? "unknown")") }
        return .ready(output: out, destination: destination, note: "HEVC video, \(count) frames, same timing (lossy)")
    }

    private static func gifDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let gif = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.02 ? 0.1 : delay // browsers treat tiny delays as 0.1 s
    }
}

import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Outcome of running one format's compressor. `.ready` outputs have already passed verification.
enum CompressEngineResult: Sendable {
    /// Verified output at `output`; it should end up at `destination` (equal to the original path unless the type changed).
    case ready(output: String, destination: String, note: String)
    case notSmaller(String)
    case skip(String)
    case reject(String)
    case fail(String)
}

/// Per-format lossless compressors. Each one writes into `workDir`, verifies its own output against the original,
/// and never touches the original file.
enum CompressionEngines {
    // MARK: - Dispatch

    static func run(
        candidate: CompressCandidate,
        workDir: String,
        tools: CompressTools,
        options: CompressOptions,
        progress: CompressProgress?
    ) -> CompressEngineResult {
        switch candidate.category {
        case .folders:
            return compressFolder(candidate.path, workDir: workDir, isApp: candidate.isApp, progress: progress)
        case .images:
            return optimizeImage(candidate.path, workDir: workDir, tools: tools)
        case .jpeg:
            return optimizeJPEG(candidate.path, workDir: workDir, tools: tools)
        case .pdfs:
            return optimizePDF(candidate.path, workDir: workDir, tools: tools)
        case .audio:
            return convertToAppleLossless(candidate.path, workDir: workDir)
        case .archives:
            return repackArchive(candidate.path, workDir: workDir, tools: tools, progress: progress)
        }
    }

    private static func outputPath(_ workDir: String, for input: String, suffix: String = "") -> String {
        let url = URL(fileURLWithPath: input)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return (workDir as NSString).appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
    }

    private static func fileSize(_ path: String) -> Int64 {
        CompressionFS.lstatInfo(path).map { Int64($0.st_size) } ?? 0
    }

    // MARK: - Folders & apps (APFS transparent compression)

    static func compressFolder(_ path: String, workDir: String, isApp: Bool, progress: CompressProgress?) -> CompressEngineResult {
        let clone = (workDir as NSString).appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        // An APFS clone costs no space; we compress the clone's files and swap it in only after verification.
        guard clonefile(path, clone, 0) == 0 else {
            return .fail("Couldn't make a working copy (\(String(cString: strerror(errno))))")
        }
        // A new item takes its parent folder's group; give the clone's top folder the original's owner and dates.
        if let st = CompressionFS.lstatInfo(path) {
            lchown(clone, st.st_uid, st.st_gid)
            chmod(clone, st.st_mode & 0o7777)
            var times = [st.st_atimespec, st.st_mtimespec]
            utimensat(AT_FDCWD, clone, &times, AT_SYMLINK_NOFOLLOW)
        }

        var compressedFiles = 0
        var failure: String?
        CompressionFS.walk(clone) { filePath, st in
            if failure != nil || progress?.isCancelled == true { return false }
            // Clones of some items (e.g. symlinks) take the working folder's group; match the original's.
            if let original = CompressionFS.lstatInfo(path + filePath.dropFirst(clone.count)),
               original.st_uid != st.st_uid || original.st_gid != st.st_gid {
                lchown(filePath, original.st_uid, original.st_gid)
            }
            guard CompressionFS.isRegular(st) else { return true }
            switch CompressionFS.compressInPlace(filePath) {
            case .compressed: compressedFiles += 1
            case .notWorthIt, .unsupported: break
            case .failed(let why): failure = "\(URL(fileURLWithPath: filePath).lastPathComponent): \(why)"
            }
            return true
        }
        if progress?.isCancelled == true { return .skip("Cancelled") }
        if let failure { return .fail(failure) }
        guard compressedFiles > 0 else { return .notSmaller("Nothing in it compresses further") }

        if let st = CompressionFS.lstatInfo(path) {
            var times = [st.st_atimespec, st.st_mtimespec]
            utimensat(AT_FDCWD, clone, &times, AT_SYMLINK_NOFOLLOW)
        }
        if let difference = CompressionFS.treeDifference(original: path, copy: clone) {
            return .reject("Verification failed: \(difference)")
        }
        if isApp, codesignValid(path), !codesignValid(clone) {
            return .reject("Code signature no longer verifies")
        }
        return .ready(output: clone, destination: path, note: "\(compressedFiles.formatted()) files compressed with LZFSE")
    }

    static func codesignValid(_ path: String) -> Bool {
        ShellRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", path], timeout: 300).exitCode == 0
    }

    // MARK: - PNG / GIF / TIFF

    /// Lossless keeps every metadata chunk: removing photo details belongs to Shrink, which already rewrites photos.
    static func optimizeImage(_ path: String, workDir: String, tools: CompressTools) -> CompressEngineResult {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete else {
            return .skip("Couldn't read the image")
        }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0 else { return .skip("Couldn't read the image") }

        var outputs: [(path: String, tool: String)] = []
        switch ext {
        case "png":
            guard frames == 1 else { return .skip("Animated PNG") }
            if let oxipng = tools.oxipng {
                let out = outputPath(workDir, for: path, suffix: ".oxipng")
                let args = ["-o", "4", "-q", "--out", out, path]
                if ShellRunner.run(oxipng, arguments: args, timeout: 600).exitCode == 0 { outputs.append((out, "oxipng")) }
            }
            if let zopfli = tools.zopflipng {
                let out = outputPath(workDir, for: path, suffix: ".zopfli")
                let keep = "tEXt,zTXt,iTXt,gAMA,cHRM,iCCP,sRGB,pHYs,sBIT,bKGD,hIST,sPLT,tIME,eXIf"
                let r = ShellRunner.run(zopfli, arguments: ["-y", "--keepchunks=\(keep)", path, out], timeout: 900)
                if r.exitCode == 0 { outputs.append((out, "Zopfli")) }
            }
            let out = outputPath(workDir, for: path, suffix: ".imageio")
            if reencodeWithImageIO(source: source, to: out, type: UTType.png, tiffLZW: false) {
                outputs.append((out, "ImageIO"))
            }
        case "tif", "tiff":
            let out = outputPath(workDir, for: path, suffix: ".imageio")
            if reencodeWithImageIO(source: source, to: out, type: UTType.tiff, tiffLZW: true) {
                outputs.append((out, "LZW"))
            }
        case "gif":
            guard let gifsicle = tools.gifsicle else { return .skip("Needs gifsicle (brew install gifsicle)") }
            let out = outputPath(workDir, for: path, suffix: ".gifsicle")
            if ShellRunner.run(gifsicle, arguments: ["-O3", "--no-warnings", path, "-o", out], timeout: 600).exitCode == 0 {
                outputs.append((out, "gifsicle"))
            }
        default:
            return .skip("Unsupported image type")
        }
        return pickSmallestVerified(original: path, outputs: outputs, checkGIFTiming: ext == "gif")
    }

    private static func pickSmallestVerified(original: String, outputs: [(path: String, tool: String)], checkGIFTiming: Bool = false) -> CompressEngineResult {
        guard !outputs.isEmpty else { return .fail("The encoder didn't produce a file") }
        let originalSize = fileSize(original)
        var lastRejection: String?
        for candidate in outputs.sorted(by: { fileSize($0.path) < fileSize($1.path) }) {
            guard fileSize(candidate.path) < originalSize else { break }
            if let problem = ImageVerifier.difference(original, candidate.path, checkGIFTiming: checkGIFTiming) {
                lastRejection = "\(candidate.tool) output rejected: \(problem)"
                continue
            }
            return .ready(output: candidate.path, destination: original, note: "Pixel-identical (\(candidate.tool))")
        }
        if let lastRejection { return .reject(lastRejection) }
        return .notSmaller("Already as small as it gets")
    }

    private static func reencodeWithImageIO(source: CGImageSource, to out: String, type: UTType, tiffLZW: Bool) -> Bool {
        let count = CGImageSourceGetCount(source)
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, type.identifier as CFString, count, nil) else {
            return false
        }
        for index in 0..<count {
            var props: [CFString: Any] = [:]
            if tiffLZW {
                props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            }
            if type == .png {
                props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: 0x00F8] // all filters
            }
            CGImageDestinationAddImageFromSource(dest, source, index, props as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - JPEG

    static func optimizeJPEG(_ path: String, workDir: String, tools: CompressTools) -> CompressEngineResult {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "heic" || ext == "heif" { return .skip("HEIC has no verified lossless optimiser") }
        guard let jpegtran = tools.jpegtran else { return .skip("Needs jpegtran (brew install jpeg-turbo)") }
        let out = outputPath(workDir, for: path, suffix: ".jpegtran")
        let result = ShellRunner.run(jpegtran, arguments: ["-copy", "all", "-optimize", "-progressive", "-outfile", out, path], timeout: 300)
        guard result.exitCode == 0 else { return .fail("jpegtran: \(result.stderr.prefix(120))") }
        return pickSmallestVerified(original: path, outputs: [(out, "jpegtran")])
    }

    // MARK: - PDF

    static func optimizePDF(_ path: String, workDir: String, tools: CompressTools) -> CompressEngineResult {
        guard let qpdf = tools.qpdf else { return .skip("Needs qpdf (brew install qpdf)") }
        if ShellRunner.run(qpdf, arguments: ["--is-encrypted", path], timeout: 60).exitCode == 0 {
            return .skip("Encrypted PDF")
        }
        if fileContains(path, ascii: "/ByteRange") { return .skip("Digitally signed PDF (rewriting would break the signature)") }

        let out = outputPath(workDir, for: path, suffix: ".qpdf")
        let result = ShellRunner.run(qpdf, arguments: [
            "--object-streams=generate", "--recompress-flate", "--compression-level=9", "--compress-streams=y",
            path, out
        ], timeout: 900)
        guard result.exitCode == 0 else { return .fail("qpdf couldn't rebuild it cleanly") }
        guard fileSize(out) < fileSize(path) else { return .notSmaller("Already well packed") }
        guard ShellRunner.run(qpdf, arguments: ["--check", out], timeout: 600).exitCode == 0 else {
            return .reject("Rebuilt PDF failed qpdf --check")
        }
        if let problem = PDFVerifier.difference(path, out) { return .reject("Verification failed: \(problem)") }
        return .ready(output: out, destination: path, note: "Same pages and text (qpdf)")
    }

    static func fileContains(_ path: String, ascii needle: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        return data.range(of: Data(needle.utf8)) != nil
    }

    // MARK: - WAV / AIFF → Apple Lossless

    static func convertToAppleLossless(_ path: String, workDir: String) -> CompressEngineResult {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return .skip("Couldn't read the audio") }
        let asbd = file.fileFormat.streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return .skip("Not plain PCM audio") }
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 { return .skip("32-bit float audio can't be stored as ALAC losslessly") }
        guard [16, 20, 24].contains(Int(asbd.mBitsPerChannel)) else {
            return .skip("\(asbd.mBitsPerChannel)-bit audio isn't supported")
        }
        let destination = url.deletingPathExtension().appendingPathExtension("m4a").path
        if FileManager.default.fileExists(atPath: destination) { return .skip("A .m4a with the same name already exists") }

        let out = (workDir as NSString).appendingPathComponent(URL(fileURLWithPath: destination).lastPathComponent)
        let flag = asbd.mBitsPerChannel == 16 ? "1" : asbd.mBitsPerChannel == 20 ? "2" : "3" // ALAC source-bit-depth flags
        let result = ShellRunner.run("/usr/bin/afconvert", arguments: ["-f", "m4af", "-d", "alac/\(flag)", path, out], timeout: 1_800)
        guard result.exitCode == 0 else { return .fail("afconvert: \(result.stderr.prefix(120))") }
        guard fileSize(out) < fileSize(path) else { return .notSmaller("Apple Lossless wasn't smaller") }
        if let problem = AudioVerifier.difference(path, out) { return .reject("Verification failed: \(problem)") }
        return .ready(output: out, destination: destination, note: "Every sample identical (Apple Lossless .m4a)")
    }

    // MARK: - Office / iWork / ZIP

    static func repackArchive(_ path: String, workDir: String, tools: CompressTools, progress: CompressProgress?) -> CompressEngineResult {
        if let problem = ZipInspector.unsupportedReason(path) { return .skip(problem) }
        let listing = ShellRunner.run("/usr/bin/zipinfo", arguments: ["-1", path], timeout: 120)
        guard listing.exitCode == 0 else { return .skip("Not a readable ZIP archive") }
        let names = listing.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !names.isEmpty else { return .skip("Empty archive") }
        if names.first == "mimetype" { return .skip("Needs an uncompressed first entry (EPUB/ODF)") }
        if names.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("-") || $0.contains("../") || $0.contains("\\") }) {
            return .skip("Unusual entry names")
        }
        if names.reduce(0, { $0 + $1.utf8.count + 1 }) > 200_000 { return .skip("Too many entries") }

        let fm = FileManager.default
        let extracted = (workDir as NSString).appendingPathComponent("extracted")
        let originalsOfImages = (workDir as NSString).appendingPathComponent("original-images")
        let recheck = (workDir as NSString).appendingPathComponent("recheck")
        let imageWork = (workDir as NSString).appendingPathComponent("image-work")
        for dir in [extracted, originalsOfImages, recheck, imageWork] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let unzip = ShellRunner.run("/usr/bin/unzip", arguments: ["-qq", "-P", "", "-o", path, "-d", extracted], timeout: 1_800)
        guard unzip.exitCode == 0 else {
            return unzip.stderr.localizedCaseInsensitiveContains("password")
                ? .skip("Password-protected archive") : .skip("Couldn't extract it cleanly")
        }

        // Losslessly shrink embedded PNGs, keeping the originals aside for the pixel check below.
        var recompressedImages: [String] = []
        for name in names where name.lowercased().hasSuffix(".png") {
            if progress?.isCancelled == true { return .skip("Cancelled") }
            let inner = (extracted as NSString).appendingPathComponent(name)
            guard let st = CompressionFS.lstatInfo(inner), CompressionFS.isRegular(st), st.st_size > 4_096 else { continue }
            let work = (imageWork as NSString).appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
            if case .ready(let output, _, _) = optimizeImage(inner, workDir: work, tools: tools) {
                let saved = (originalsOfImages as NSString).appendingPathComponent(name)
                try? fm.createDirectory(atPath: (saved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                do {
                    try fm.moveItem(atPath: inner, toPath: saved)
                    try fm.moveItem(atPath: output, toPath: inner)
                    CompressionFS.copyMetadata(from: saved, to: inner)
                    recompressedImages.append(name)
                } catch {
                    if !fm.fileExists(atPath: inner) { try? fm.moveItem(atPath: saved, toPath: inner) }
                }
            }
        }

        let out = (workDir as NSString).appendingPathComponent("repacked." + URL(fileURLWithPath: path).pathExtension)
        let zip = ShellRunner.run(
            "/usr/bin/zip", arguments: ["-q", "-X", "-9", "-y", "-nw", out] + names,
            workingDirectory: extracted, timeout: 1_800
        )
        guard zip.exitCode == 0 else { return .fail("zip: \(zip.stderr.prefix(120))") }
        guard fileSize(out) < fileSize(path) else { return .notSmaller("Already packed tightly") }

        if let problem = ZipInspector.repackDifference(
            names: names, extracted: extracted, repacked: out, recheckDir: recheck,
            recompressedImages: recompressedImages, originalImagesDir: originalsOfImages
        ) {
            return .reject(problem)
        }
        let note = recompressedImages.isEmpty
            ? "Every entry byte-identical"
            : "Every entry identical; \(recompressedImages.count) images pixel-identical"
        return .ready(output: out, destination: path, note: note)
    }
}

// MARK: - ZIP inspection

enum ZipInspector {

    /// Verifies a repacked archive against the original's extraction: same entries in the same order, a clean
    /// `unzip -t`, and every entry byte-identical (recompressed PNGs pixel-identical to their originals).
    static func repackDifference(
        names: [String], extracted: String, repacked out: String, recheckDir recheck: String,
        recompressedImages: [String], originalImagesDir originalsOfImages: String
    ) -> String? {
        let newListing = ShellRunner.run("/usr/bin/zipinfo", arguments: ["-1", out], timeout: 120)
        guard newListing.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) == names else {
            return "Entry list changed"
        }
        guard ShellRunner.run("/usr/bin/unzip", arguments: ["-tqq", out], timeout: 1_800).exitCode == 0 else {
            return "Repacked archive failed unzip -t"
        }
        try? FileManager.default.createDirectory(atPath: recheck, withIntermediateDirectories: true)
        guard ShellRunner.run("/usr/bin/unzip", arguments: ["-qq", "-o", out, "-d", recheck], timeout: 1_800).exitCode == 0 else {
            return "Repacked archive didn't extract"
        }
        for name in names where !name.hasSuffix("/") {
            let a = (extracted as NSString).appendingPathComponent(name)
            let b = (recheck as NSString).appendingPathComponent(name)
            guard let sa = CompressionFS.lstatInfo(a), let sb = CompressionFS.lstatInfo(b) else { return "Missing \(name)" }
            if (sa.st_mode & S_IFMT) != (sb.st_mode & S_IFMT) { return "Entry type changed: \(name)" }
            if CompressionFS.isSymlink(sa) {
                guard CompressionFS.symlinkTarget(a) == CompressionFS.symlinkTarget(b) else { return "Link changed: \(name)" }
            } else if !CompressionFS.filesEqual(a, b) {
                return "Content changed: \(name)"
            }
        }
        for name in recompressedImages {
            let original = (originalsOfImages as NSString).appendingPathComponent(name)
            let repacked = (recheck as NSString).appendingPathComponent(name)
            if let problem = ImageVerifier.difference(original, repacked) { return "\(name): \(problem)" }
        }
        return nil
    }
    /// Rejects archives with things a plain repack would drop: self-extractor stubs, archive comments.
    static func unsupportedReason(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "Couldn't read it" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head == Data([0x50, 0x4B, 0x03, 0x04]) else {
            return "Not a plain ZIP archive"
        }
        guard let end = try? handle.seekToEnd() else { return "Couldn't read it" }
        let tailLength = min(end, 65_557)
        try? handle.seek(toOffset: end - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return "Truncated archive" }
        let bytes = [UInt8](tail)
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                let commentLength = Int(bytes[index + 20]) | Int(bytes[index + 21]) << 8
                return commentLength > 0 ? "Archive has a comment that a repack would drop" : nil
            }
            index -= 1
        }
        return "Couldn't find the archive directory"
    }
}

// MARK: - Image verification

enum ImageVerifier {
    /// nil when both files decode to exactly the same pixels in every frame; otherwise the reason they differ.
    static func difference(_ a: String, _ b: String, checkGIFTiming: Bool = false) -> String? {
        guard let sa = CGImageSourceCreateWithURL(URL(fileURLWithPath: a) as CFURL, nil),
              let sb = CGImageSourceCreateWithURL(URL(fileURLWithPath: b) as CFURL, nil) else {
            return "couldn't decode"
        }
        let count = CGImageSourceGetCount(sa)
        guard count > 0, count == CGImageSourceGetCount(sb) else { return "frame count changed" }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        for index in 0..<count {
            guard let ia = CGImageSourceCreateImageAtIndex(sa, index, options),
                  let ib = CGImageSourceCreateImageAtIndex(sb, index, options) else {
                return "couldn't decode frame \(index)"
            }
            if let problem = pixelDifference(ia, ib) { return count > 1 ? "frame \(index): \(problem)" : problem }
            if checkGIFTiming, gifDelay(sa, index) != gifDelay(sb, index) { return "frame \(index) timing changed" }
        }
        if checkGIFTiming, gifLoopCount(sa) != gifLoopCount(sb) { return "loop count changed" }
        return nil
    }

    private static func gifDelay(_ source: CGImageSource, _ index: Int) -> Double? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double
    }

    private static func gifLoopCount(_ source: CGImageSource) -> Int? {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return gif?[kCGImagePropertyGIFLoopCount] as? Int
    }

    private static func effectiveSpace(_ image: CGImage) -> CGColorSpace? {
        guard let space = image.colorSpace else { return nil }
        if space.model == .indexed, let base = space.baseColorSpace { return base }
        return space
    }

    private static func sameSpace(_ a: CGColorSpace?, _ b: CGColorSpace?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            if CFEqual(x, y) { return true }
            if let dx = x.copyICCData() as Data?, let dy = y.copyICCData() as Data? { return dx == dy }
            return x.name != nil && x.name == y.name
        default: return false
        }
    }

    static func pixelDifference(_ a: CGImage, _ b: CGImage) -> String? {
        guard a.width == b.width, a.height == b.height else { return "dimensions changed" }
        let spaceA = effectiveSpace(a)
        guard sameSpace(spaceA, effectiveSpace(b)) else { return "colour space changed" }
        if a.bitsPerComponent > 16 || b.bitsPerComponent > 16 {
            // Floating-point images: only accept a byte-identical decode.
            return rawRows(a) == rawRows(b) && a.bitmapInfo == b.bitmapInfo ? nil : "pixels differ"
        }
        let bits = max(a.bitsPerComponent, b.bitsPerComponent) > 8 ? 16 : 8
        guard let space = spaceA ?? CGColorSpace(name: CGColorSpace.sRGB) else { return "no colour space" }
        guard let pa = canonicalPixels(a, space: space, bits: bits),
              let pb = canonicalPixels(b, space: space, bits: bits) else {
            return "couldn't convert pixels for comparison"
        }
        return pa == pb ? nil : "pixels differ"
    }

    /// Decodes into unpremultiplied RGBA/GA in a fixed layout so differently-encoded files can be compared exactly.
    private static func canonicalPixels(_ image: CGImage, space: CGColorSpace, bits: Int) -> Data? {
        let components = space.numberOfComponents
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if bits == 16 { info.insert(.byteOrder16Little) }
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: bits,
            bitsPerPixel: bits * (components + 1),
            colorSpace: space,
            bitmapInfo: info
        ) else { return nil }
        guard let buffer = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { buffer.free() }
        let rowBytes = image.width * bits * (components + 1) / 8
        var data = Data(capacity: rowBytes * image.height)
        guard let base = buffer.data else { return nil }
        for row in 0..<Int(buffer.height) {
            data.append(base.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: UInt8.self), count: rowBytes)
        }
        return data
    }

    private static func rawRows(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let rowBytes = image.width * image.bitsPerPixel / 8
        var out = Data(capacity: rowBytes * image.height)
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            guard start + rowBytes <= data.count else { return nil }
            out.append(data[start..<(start + rowBytes)])
        }
        return out
    }
}

// MARK: - PDF verification

enum PDFVerifier {
    static func difference(_ a: String, _ b: String) -> String? {
        guard let da = PDFDocument(url: URL(fileURLWithPath: a)), let db = PDFDocument(url: URL(fileURLWithPath: b)) else {
            return "couldn't open"
        }
        guard da.pageCount == db.pageCount else { return "page count changed" }
        guard da.isEncrypted == db.isEncrypted else { return "encryption changed" }
        for index in 0..<da.pageCount {
            let ta = da.page(at: index)?.string ?? ""
            let tb = db.page(at: index)?.string ?? ""
            if ta != tb { return "text on page \(index + 1) changed" }
            let ba = da.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            let bb = db.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            if ba != bb { return "page \(index + 1) size changed" }
        }
        return nil
    }
}

// MARK: - Audio verification

enum AudioVerifier {
    /// Decodes both files and compares every sample. Valid for integer PCM up to 24 bits (exact in Float32).
    static func difference(_ a: String, _ b: String) -> String? {
        guard let fa = try? AVAudioFile(forReading: URL(fileURLWithPath: a)),
              let fb = try? AVAudioFile(forReading: URL(fileURLWithPath: b)) else {
            return "couldn't open"
        }
        let format = fa.processingFormat
        guard format.sampleRate == fb.processingFormat.sampleRate else { return "sample rate changed" }
        guard format.channelCount == fb.processingFormat.channelCount else { return "channel count changed" }
        guard fa.length == fb.length else { return "length changed" }
        let chunk: AVAudioFrameCount = 65_536
        guard let ba = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let bb = AVAudioPCMBuffer(pcmFormat: fb.processingFormat, frameCapacity: chunk) else {
            return "out of memory"
        }
        while fa.framePosition < fa.length {
            do {
                try fa.read(into: ba, frameCount: chunk)
                try fb.read(into: bb, frameCount: chunk)
            } catch {
                return "decode error"
            }
            guard ba.frameLength == bb.frameLength, ba.frameLength > 0 else { return "length changed" }
            guard let ca = ba.floatChannelData, let cb = bb.floatChannelData else { return "unexpected sample format" }
            let bytes = Int(ba.frameLength) * MemoryLayout<Float>.size
            for channel in 0..<Int(format.channelCount) where memcmp(ca[channel], cb[channel], bytes) != 0 {
                return "samples differ"
            }
        }
        return nil
    }
}

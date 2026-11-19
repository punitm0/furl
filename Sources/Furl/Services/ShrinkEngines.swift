import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// Outcome of one lossy re-encode. `.ready` means the file was written and its metadata kept; size rules are applied
/// by the caller. Nothing here is verified as identical, because it isn't: these encoders lower quality on purpose.
enum ShrinkEngineResult: Sendable {
    case ready(output: String, destination: String, note: String)
    case skip(String)
    case fail(String)
}

/// Lossy encoders for Shrink mode. Each writes into `workDir` and never touches the original.
enum ShrinkEngines {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let pdfExtensions: Set<String> = ["pdf"]
    static let pngExtensions: Set<String> = ["png"]

    /// Extended attribute written on every shrunk file, so a second pass doesn't stack quality loss.
    static let shrunkMarker = "com.sweepmac.shrunk"

    static func kind(forExtension ext: String) -> ShrinkKind? {
        if photoExtensions.contains(ext) { return .photos }
        if pngExtensions.contains(ext) { return .png }
        if videoExtensions.contains(ext) { return .videos }
        if pdfExtensions.contains(ext) { return .pdfs }
        return nil
    }

    /// Where the result ends up. Equal to `path` unless a JPEG becomes HEIC.
    static func destination(for path: String, kind: ShrinkKind, options: ShrinkOptions) -> String {
        guard kind == .photos, options.imageFormat == .heic else { return path }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ext == "heic" || ext == "heif" { return path }
        return url.deletingPathExtension().appendingPathExtension("heic").path
    }

    private static func workOutput(_ workDir: String, destination: String) -> String {
        (workDir as NSString).appendingPathComponent(URL(fileURLWithPath: destination).lastPathComponent)
    }

    // MARK: - Photos

    static func shrinkPhoto(_ path: String, workDir: String, options: ShrinkOptions) -> ShrinkEngineResult {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String? else {
            return .skip("Couldn't read the image")
        }
        let isJPEG = UTType(sourceType)?.conforms(to: .jpeg) == true
        let isHEIC = UTType(sourceType).map { $0.conforms(to: .heic) || $0.conforms(to: .heif) } ?? false
        guard isJPEG || isHEIC else { return .skip("Not a JPEG or HEIC image") }
        guard CGImageSourceGetCount(source) == 1 else { return .skip("Contains several images (burst or sequence)") }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return .skip("Couldn't read the image size")
        }

        let destination = destination(for: path, kind: .photos, options: options)
        if destination != path, FileManager.default.fileExists(atPath: destination) {
            return .skip("A .heic with the same name already exists")
        }
        let outType: UTType = (options.imageFormat == .heic || isHEIC) ? .heic : .jpeg
        let out = workOutput(workDir, destination: destination)
        let quality = min(0.95, max(0.3, options.imageQuality))
        let longSide = max(width, height)
        let wantsResize = options.maxImageDimension.map { longSide > $0 } ?? false

        // JPEG staying JPEG: also try MozJPEG when installed, and keep whichever file is smaller.
        // Its quality scale is harsher than ImageIO's, so `mozJPEGQuality` maps the slider to about the same detail (by PSNR).
        // Skipped when resizing (cjpeg would need a raw-pixel intermediate) and for photos with a gain map or depth data,
        // which cjpeg would drop.
        let mozOut = (workDir as NSString).appendingPathComponent("mozjpeg-" + (out as NSString).lastPathComponent)
        var haveMoz = false
        if outType == .jpeg, isJPEG, !wantsResize, let cjpeg = options.tools.mozjpeg,
           !auxiliaryTypes.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) {
            haveMoz = mozJPEG(cjpeg, source: source, path: path, out: mozOut, workDir: workDir, quality: quality) == .ok
                && photoMetadataProblem(original: props, output: mozOut) == nil
            if !haveMoz { try? FileManager.default.removeItem(atPath: mozOut) }
        }
        defer { try? FileManager.default.removeItem(atPath: mozOut) }

        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, outType.identifier as CFString, 1, nil) else {
            return .fail("This Mac can't write \(outType == .heic ? "HEIC" : "JPEG")")
        }

        var resized = false
        if let maxSide = options.maxImageDimension, longSide > maxSide {
            // Resize without baking in the orientation, so the EXIF orientation tag stays valid.
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return .fail("Couldn't resize")
            }
            var meta = props
            meta[kCGImagePropertyPixelWidth] = image.width
            meta[kCGImagePropertyPixelHeight] = image.height
            if var exif = meta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                meta[kCGImagePropertyExifDictionary] = exif
            }
            meta.removeValue(forKey: kCGImagePropertyFileSize)
            meta[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(dest, image, meta as CFDictionary)
            resized = true
        } else {
            let destProps: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImageFromSource(dest, source, 0, destProps as CFDictionary)
        }
        // HDR gain maps, depth and portrait mattes. Without them HDR photos look flat and Portrait edits stop working.
        // They are stored at their own (smaller) resolution, so they stay valid after a resize.
        for type in auxiliaryTypes {
            if let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(dest, type, aux)
            }
        }
        guard CGImageDestinationFinalize(dest) else { return .fail("Couldn't write the new image") }

        let imageIOProblem = photoMetadataProblem(original: props, output: out)
        if haveMoz, imageIOProblem != nil || fileSize(mozOut) < fileSize(out) {
            try? FileManager.default.removeItem(atPath: out)
            guard (try? FileManager.default.moveItem(atPath: mozOut, toPath: out)) != nil else { return .fail("Couldn't write the new image") }
            return .ready(output: out, destination: destination, note: "JPEG (MozJPEG) at \(Int((quality * 100).rounded()))% quality")
        }
        if let problem = imageIOProblem {
            return .skip("Metadata couldn't be kept: \(problem)")
        }
        var note = "\(outType == .heic ? "HEIC" : "JPEG") at \(Int((quality * 100).rounded()))% quality"
        if resized { note += ", resized to \(options.maxImageDimension ?? 0) px" }
        return .ready(output: out, destination: destination, note: note)
    }

    private static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? .max
    }

    private static var auxiliaryTypes: [CFString] {
        var types: [CFString] = [
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte
        ]
        if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return types
    }

    /// Makes sure the location, camera data, orientation and colour profile survived the re-encode.
    static func photoMetadataProblem(original: [CFString: Any], output: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: output) as CFURL, nil),
              let new = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return "couldn't read the result"
        }
        if let gps = original[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            guard let newGPS = new[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                  (newGPS[kCGImagePropertyGPSLatitude] as? Double) == (gps[kCGImagePropertyGPSLatitude] as? Double),
                  (newGPS[kCGImagePropertyGPSLongitude] as? Double) == (gps[kCGImagePropertyGPSLongitude] as? Double) else {
                return "location"
            }
        }
        if let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let newExif = new[kCGImagePropertyExifDictionary] as? [CFString: Any]
            if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               (newExif?[kCGImagePropertyExifDateTimeOriginal] as? String) != taken {
                return "date taken"
            }
        }
        if let make = (original[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String,
           ((new[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String) != make {
            return "camera"
        }
        let oldOrientation = original[kCGImagePropertyOrientation] as? Int ?? 1
        let newOrientation = new[kCGImagePropertyOrientation] as? Int ?? 1
        if oldOrientation != newOrientation { return "orientation" }
        if let profile = original[kCGImagePropertyProfileName] as? String,
           (new[kCGImagePropertyProfileName] as? String) != profile {
            return "colour profile"
        }
        return nil
    }

    private enum ToolOutcome { case ok, failed }

    /// cjpeg q that gives about the same PSNR as ImageIO at `quality` (measured: ImageIO 0.60 ≈ cjpeg 82, 0.75 ≈ 92).
    static func mozJPEGQuality(_ quality: Double) -> Int { min(95, max(30, Int((40 + quality * 70).rounded()))) }

    /// Re-encodes a JPEG with MozJPEG's cjpeg, then puts the original EXIF/GPS/XMP back without re-encoding.
    private static func mozJPEG(_ cjpeg: String, source: CGImageSource, path: String, out: String, workDir: String, quality: Double) -> ToolOutcome {
        let raw = (workDir as NSString).appendingPathComponent("mozjpeg-raw.jpg")
        defer { try? FileManager.default.removeItem(atPath: raw) }
        var args = ["-quality", "\(mozJPEGQuality(quality))", "-optimize", "-progressive"]
        // cjpeg doesn't copy the colour profile from a JPEG input, so hand it over explicitly.
        let iccPath = (workDir as NSString).appendingPathComponent("profile.icc")
        defer { try? FileManager.default.removeItem(atPath: iccPath) }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let icc = image.colorSpace?.copyICCData() as Data?,
           (try? icc.write(to: URL(fileURLWithPath: iccPath))) != nil {
            args += ["-icc", iccPath]
        }
        args += ["-outfile", raw, path]
        let result = ShellRunner.run(cjpeg, arguments: args, timeout: 300)
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: raw),
              let encoded = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw) as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return .failed
        }
        // Copies the MozJPEG image data as is and merges in the original metadata.
        var copyOptions: [CFString: Any] = [kCGImageDestinationMergeMetadata: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            copyOptions[kCGImageDestinationMetadata] = metadata
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, encoded, copyOptions as CFDictionary, &error) else {
            error?.release()
            return .failed
        }
        return .ok
    }

    // MARK: - PNG (pngquant)

    /// Lossy PNG: reduces the image to a palette of up to 256 colours with pngquant (external, never bundled).
    static func shrinkPNG(_ path: String, workDir: String, options: ShrinkOptions) -> ShrinkEngineResult {
        guard let pngquant = options.tools.pngquant else { return .skip("Needs pngquant (brew install pngquant)") }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .png) == true else {
            return .skip("Not a PNG image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        if CGImageSourceGetCount(source) > 1 || png?[kCGImagePropertyAPNGLoopCount] != nil {
            return .skip("Animated PNG")
        }
        let top = Int((min(0.95, max(0.3, options.imageQuality)) * 100).rounded())
        let bottom = max(0, top - 20)
        let out = workOutput(workDir, destination: path)
        // No --strip: pngquant keeps the colour profile and text chunks. It exits 98/99 when the result
        // would be larger or below the minimum quality; then the original simply stays.
        let result = ShellRunner.run(pngquant, arguments: [
            "--quality=\(bottom)-\(top)", "--skip-if-larger", "--speed", "3", "--force", "--output", out, "--", path
        ], timeout: 300)
        switch result.exitCode {
        case 0: break
        case 98: return .skip("pngquant couldn't make it smaller")
        case 99: return .skip("Would drop below the minimum quality (\(bottom)%)")
        default: return .fail("pngquant failed: \(result.stderr.prefix(120))")
        }
        guard FileManager.default.fileExists(atPath: out) else { return .fail("pngquant produced no file") }
        // pngquant colour-manages any embedded profile into sRGB (measured: Display P3 content matches after
        // conversion; only colours outside sRGB are clipped). So an sRGB result is expected, not a lost profile.
        var expected = props
        let profile = props[kCGImagePropertyProfileName] as? String
        let converted = profile.map { !$0.localizedCaseInsensitiveContains("sRGB") } ?? false
        expected.removeValue(forKey: kCGImagePropertyProfileName)
        if let problem = photoMetadataProblem(original: expected, output: out) {
            return .skip("Metadata couldn't be kept: \(problem)")
        }
        var note = "PNG palette (pngquant), quality \(bottom)–\(top)"
        if converted, let profile { note += ", colours converted from \(profile) to sRGB" }
        return .ready(output: out, destination: path, note: note)
    }

    // MARK: - Videos

    private static func isHEVC(_ codec: FourCharCode) -> Bool {
        codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha || codec == FourCharCode(0x6865_7631) // 'hev1'
    }

    /// Re-encodes to HEVC. With `segment`, only that part is encoded (used for previews and estimates).
    static func shrinkVideo(_ path: String, workDir: String, options: ShrinkOptions, segment: CMTimeRange? = nil) async -> ShrinkEngineResult {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isExportable) else { return .skip("This video can't be re-encoded") }
            if try await asset.load(.hasProtectedContent) { return .skip("Copy-protected video") }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .skip("No video track") }
            let (size, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let shown = size.applying(transform)
            let longSide = max(abs(shown.width), abs(shown.height))
            let codec = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0

            let downscales = options.videoPreset.maxLongSide.map { longSide > $0 + 1 } ?? false
            if isHEVC(codec), !downscales { return .skip("Already HEVC at this size") }
            let preset: String
            switch options.videoPreset {
            case .uhd4K where downscales: preset = AVAssetExportPresetHEVC3840x2160
            case .hd1080 where downscales: preset = AVAssetExportPresetHEVC1920x1080
            default: preset = AVAssetExportPresetHEVCHighestQuality
            }

            let ext = url.pathExtension.lowercased()
            let fileType: AVFileType = ext == "mp4" ? .mp4 : ext == "m4v" ? .m4v : .mov
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                return .skip("HEVC encoding isn't available for this video")
            }
            guard session.supportedFileTypes.contains(fileType) else { return .skip("Can't write HEVC into .\(ext)") }
            // Keep the recording date, location and other QuickTime metadata.
            session.metadata = try await asset.load(.metadata)
            session.shouldOptimizeForNetworkUse = false
            if let segment { session.timeRange = segment }

            let out = workOutput(workDir, destination: path)
            try await export(session, to: URL(fileURLWithPath: out), as: fileType)
            guard FileManager.default.fileExists(atPath: out) else { return .fail("The encoder produced no file") }
            if segment == nil, let problem = await videoProblem(original: asset, output: out) {
                return .fail("Result looked wrong: \(problem)")
            }
            let label = options.videoPreset == .highest || !downscales ? "HEVC, original size" : options.videoPreset.title
            return .ready(output: out, destination: path, note: label)
        } catch {
            return .fail("Encoding failed: \(error.localizedDescription)")
        }
    }

    static func export(_ session: AVAssetExportSession, to url: URL, as type: AVFileType) async throws {
        if #available(macOS 15.0, *) {
            try await session.export(to: url, as: type)
        } else {
            nonisolated(unsafe) let legacy = session
            legacy.outputURL = url
            legacy.outputFileType = type
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                legacy.exportAsynchronously { done.resume() }
            }
            if legacy.status != .completed {
                throw legacy.error ?? CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// Duration and track layout must match; metadata items must survive.
    private static func videoProblem(original: AVAsset, output: String) async -> String? {
        let new = AVURLAsset(url: URL(fileURLWithPath: output))
        guard let d1 = try? await original.load(.duration), let d2 = try? await new.load(.duration) else {
            return "couldn't read it back"
        }
        if abs(d1.seconds - d2.seconds) > 0.5 { return "length changed" }
        let a1 = (try? await original.loadTracks(withMediaType: .audio).count) ?? 0
        let a2 = (try? await new.loadTracks(withMediaType: .audio).count) ?? 0
        if a1 != a2 { return "audio tracks changed" }
        let m1 = (try? await original.load(.metadata).count) ?? 0
        let m2 = (try? await new.load(.metadata).count) ?? 0
        if m2 < m1 { return "metadata was dropped" }
        return nil
    }

    static func videoDuration(_ path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        return try? await asset.load(.duration).seconds
    }

    static func videoFrame(_ path: String, at seconds: Double, maxSide: CGFloat = 1600) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: - PDFs

    /// Image resolution PDFs are downsampled to (dots per inch at the size the image is shown on the page).
    static let pdfImageResolution = 200

    static func shrinkPDF(_ path: String, workDir: String, options: ShrinkOptions) -> ShrinkEngineResult {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else { return .skip("Couldn't open the PDF") }
        if document.isEncrypted || document.isLocked { return .skip("Encrypted PDF") }
        if CompressionEngines.fileContains(path, ascii: "/ByteRange") { return .skip("Signed PDF (re-saving would break the signature)") }
        if CompressionEngines.fileContains(path, ascii: "/AcroForm") { return .skip("PDF with form fields") }
        let quality = min(0.95, max(0.3, options.imageQuality))
        // The same mechanism as Preview's "Reduce File Size", with gentler settings: only images change.
        let filterProperties: [String: Any] = [
            "Name": "Furl Shrink",
            "FilterType": 1,
            "Domains": ["Applications": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": pdfImageResolution,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 3000,
                            "ImageSizeMin": 0
                        ]
                    ]
                ]
            ]
        ]
        guard let filter = QuartzFilter(properties: filterProperties) else { return .fail("Couldn't set up the PDF filter") }
        let out = workOutput(workDir, destination: path)
        guard document.write(to: URL(fileURLWithPath: out), withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            return .fail("Couldn't write the PDF")
        }
        // Text, page count and page sizes must not change; only image quality may.
        if let problem = PDFVerifier.difference(path, out) { return .skip("Rejected: \(problem)") }
        return .ready(output: out, destination: path,
                      note: "Images re-saved as JPEG at \(Int((quality * 100).rounded()))%, up to \(pdfImageResolution) dpi")
    }

    // MARK: - Previews and quality

    /// Fitted rendering of a photo with its orientation applied.
    static func photoImage(_ path: String, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func photoPixelSize(_ path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// First page of a PDF, rendered on white.
    static func pdfPageImage(_ path: String, longSide: CGFloat) -> CGImage? {
        guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = longSide / max(box.width, box.height)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// The same centre square from both images, scaled to the smaller one's resolution.
    static func centreCrops(_ a: CGImage, _ b: CGImage, side: Int = 520) -> (CGImage?, CGImage?) {
        // Bring the larger image down to the smaller one's size first so the crops cover the same area.
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard let ra = resample(a, width: w, height: h), let rb = resample(b, width: w, height: h) else { return (nil, nil) }
        let s = min(side, w, h)
        let rect = CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)
        return (ra.cropping(to: rect), rb.cropping(to: rect))
    }

    static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width, image.height == height { return image }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// PSNR between two renderings, compared at the smaller one's size (at most `maxSide` on the long side).
    static func psnr(_ a: CGImage, _ b: CGImage, maxSide: Int = 2048) -> Double? {
        var w = min(a.width, b.width), h = min(a.height, b.height)
        let longSide = max(w, h)
        if longSide > maxSide {
            w = w * maxSide / longSide
            h = h * maxSide / longSide
        }
        guard w > 8, h > 8, let pa = rgba(a, w, h), let pb = rgba(b, w, h) else { return nil }
        var sum: Double = 0
        var count = 0
        pa.withUnsafeBytes { ra in
            pb.withUnsafeBytes { rb in
                let x = ra.bindMemory(to: UInt8.self), y = rb.bindMemory(to: UInt8.self)
                var i = 0
                while i < x.count {
                    for c in 0..<3 {
                        let d = Double(Int(x[i + c]) - Int(y[i + c]))
                        sum += d * d
                    }
                    count += 3
                    i += 4
                }
            }
        }
        guard count > 0 else { return nil }
        let mse = sum / Double(count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    private static func rgba(_ image: CGImage, _ w: Int, _ h: Int) -> Data? {
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }
}

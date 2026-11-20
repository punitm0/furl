import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Furl

/// Lossless promises identical files, so it must never remove photo details. Removing them is a Shrink option.
final class PhotoMetadataTests: XCTestCase {
    private let latitude = 51.5
    private let make = "TestCam"
    private let taken = "2024:05:01 10:00:00"
    private let city = "Testville"
    private let orientation = 6

    // MARK: Lossless

    func testLosslessKeepsLocationAndCameraDetails() throws {
        let dir = try TempDir()
        let path = dir.file("photo.tiff")
        try writeImage(path, type: .tiff, noisy: false, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1, kCGImagePropertyTIFFMake: make]
        ])
        let work = dir.file("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let candidate = CompressCandidate(path: path, category: .images, sizeBytes: 1, compressibleBytes: 1,
                                          lastUsed: nil, isApp: false, fileCount: 1)

        let result = CompressionEngines.run(candidate: candidate, workDir: work, tools: .none,
                                            options: CompressOptions(), progress: nil)
        guard case .ready(let output, _, _) = result else { return XCTFail("Expected a compressed TIFF, got \(result)") }

        let props = try properties(output)
        XCTAssertEqual((props[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double, latitude)
        XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, make)
        XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String, taken)
    }

    // MARK: Shrink

    func testShrinkKeepsPhotoDetailsByDefault() throws {
        XCTAssertFalse(ShrinkOptions().stripPhotoMetadata, "Removing photo details must be off by default")
        let (props, _) = try shrunk(strip: false)
        XCTAssertEqual((props[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double, latitude)
        XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, make)
        XCTAssertEqual((props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity] as? String, city)
    }

    func testShrinkRemovesLocationAndCameraWhenAsked() throws {
        let (props, xmp) = try shrunk(strip: true)
        assertDetailsGone(props, xmp)
        // Date taken, orientation and colour profile are not location or camera details, so they stay.
        XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String, taken)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, orientation)
        XCTAssertEqual(props[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1")
    }

    func testShrinkRemovesDetailsWhenResizing() throws {
        let (props, xmp) = try shrunk(strip: true, maxSide: 64)
        assertDetailsGone(props, xmp)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, orientation)
    }

    func testShrinkRemovesXMPPlaceNames() throws {
        let dir = try TempDir()
        let path = dir.file("xmp.jpg")
        try writeImage(path, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        // Rewrite with XMP-only place names (no IPTC block), as editors like Lightroom write them.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let meta = try XCTUnwrap(CGImageMetadataCreateMutableCopy(try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "photoshop:City" as CFString, city as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "Iptc4xmpCore:Location" as CFString, "Old Town" as CFString))
        let tagged = dir.file("tagged.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: tagged) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        XCTAssertTrue(CGImageDestinationCopyImageSource(dest, source, [kCGImageDestinationMetadata: meta] as CFDictionary, nil))
        let check = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: tagged) as CFURL, nil)), 0, nil))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(check, nil, "photoshop:City" as CFString), "fixture should carry XMP City")

        let work = dir.file("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        var options = ShrinkOptions()
        options.imageQuality = 0.5
        options.stripPhotoMetadata = true
        let result = ShrinkEngines.shrinkPhoto(tagged, workDir: work, options: options)
        guard case .ready(let output, _, _) = result else { return XCTFail("Expected a shrunk photo, got \(result)") }
        let out = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: output) as CFURL, nil))
        assertDetailsGone(try properties(output), CGImageSourceCopyMetadataAtIndex(out, 0, nil))
    }

    func testPreviewQualityNumberSitsBehindHow() {
        let quality = ShrinkQuality(psnr: 40.84)
        XCTAssertEqual(quality.label, "Very close")
        XCTAssertEqual(quality.howText(note: "HEIC at 72% quality"),
                       "Measured at 40.8 dB (PSNR). Above 40 dB most people can’t tell the two apart. HEIC at 72% quality.")
        XCTAssertEqual(ShrinkQuality(psnr: nil).howText(note: ""), "")
    }

    // MARK: Helpers

    private func assertDetailsGone(_ props: [CFString: Any], _ xmp: CGImageMetadata?,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertTrue(gps?.isEmpty ?? true, "Location should be gone: \(String(describing: gps))", file: file, line: line)
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake], file: file, line: line)
        XCTAssertNil((props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity],
                     "IPTC City should be gone", file: file, line: line)
        if let xmp {
            for path in ShrinkEngines.placeXMPPaths {
                XCTAssertNil(CGImageMetadataCopyTagWithPath(xmp, nil, path as CFString), "\(path) should be gone", file: file, line: line)
            }
        }
    }

    private func shrunk(strip: Bool, maxSide: Int? = nil) throws -> ([CFString: Any], CGImageMetadata?) {
        let dir = try TempDir()
        let path = dir.file("photo.jpg")
        try writeImage(path, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFOrientation: orientation],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: city, kCGImagePropertyIPTCCountryPrimaryLocationName: "Testland"]
        ])
        let work = dir.file("work")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        var options = ShrinkOptions()
        options.imageQuality = 0.5
        options.stripPhotoMetadata = strip
        options.maxImageDimension = maxSide
        let result = ShrinkEngines.shrinkPhoto(path, workDir: work, options: options)
        guard case .ready(let output, _, _) = result else {
            XCTFail("Expected a shrunk photo, got \(result)")
            throw CocoaError(.fileWriteUnknown)
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: output) as CFURL, nil))
        return (try properties(output), CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    /// A 160×120 image with location, camera and date. Noisy gives lossy encoders something to save; flat
    /// gives lossless ones something to save.
    private func writeImage(_ path: String, type: UTType, noisy: Bool = true, properties extra: [CFString: Any]) throws {
        let width = 160, height = 120
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 7
        for i in stride(from: 0, to: noisy ? pixels.count : 0, by: 4) {
            for c in 0..<3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i + c] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                 type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: latitude, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken]
        ]
        props.merge(extra) { _, new in new }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func properties(_ path: String) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}

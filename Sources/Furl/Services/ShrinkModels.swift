import CoreGraphics
import Foundation

// Lossy "Shrink" mode for the Compress section. Everything here LOWERS QUALITY on purpose, so it is opt-in,
// never labelled lossless, and kept apart from the lossless types in CompressionModels.swift.

// MARK: - Kinds

enum ShrinkKind: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case photos
    case png
    case videos
    case pdfs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Photos (JPEG & HEIC)"
        case .png: return "PNG images"
        case .videos: return "Videos (to HEVC)"
        case .pdfs: return "Images inside PDFs"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "camera"
        case .png: return "photo"
        case .videos: return "film"
        case .pdfs: return "doc.richtext"
        }
    }

    var unitName: String {
        switch self {
        case .photos: return "photos"
        case .png: return "PNGs"
        case .videos: return "videos"
        case .pdfs: return "PDFs"
        }
    }

    func count(_ n: Int) -> String {
        let singular: String
        switch self {
        case .photos: singular = "photo"
        case .png: singular = "PNG"
        case .videos: singular = "video"
        case .pdfs: singular = "PDF"
        }
        return "\(n.formatted()) \(n == 1 ? singular : unitName)"
    }

    /// Smallest file worth re-encoding.
    var minimumBytes: Int64 {
        switch self {
        case .photos: return 300 * 1024
        case .png: return 100 * 1024
        case .videos: return 20 * 1024 * 1024
        case .pdfs: return 2 * 1024 * 1024
        }
    }

    var enabledByDefault: Bool { self == .photos || self == .videos }

    /// Shown when the kind needs a tool that isn't installed.
    func missingToolNote(_ tools: ShrinkTools) -> String? {
        self == .png && tools.pngquant == nil ? "Needs pngquant (brew install pngquant)" : nil
    }
}

// MARK: - Optional Homebrew tools

/// Optional command-line encoders. Never bundled (pngquant is GPL); only run if the user installed them.
struct ShrinkTools: Sendable, Equatable {
    /// Lossy PNG palette quantiser. Required for the PNG kind.
    var pngquant: String?
    /// MozJPEG's `cjpeg` (keg-only in Homebrew). Used instead of ImageIO when the result stays JPEG.
    var mozjpeg: String?

    static let none = ShrinkTools()

    static func detect() -> ShrinkTools {
        let fm = FileManager.default
        func first(_ paths: [String]) -> String? { paths.first { fm.isExecutableFile(atPath: $0) } }
        return ShrinkTools(
            pngquant: first(["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"]) ?? ShellRunner.which("pngquant"),
            // Plain `cjpeg` on the PATH is usually libjpeg(-turbo), not MozJPEG, so only the mozjpeg keg counts.
            mozjpeg: first(["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"])
        )
    }
}

// MARK: - Settings

enum ShrinkImageFormat: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// JPEG stays JPEG, HEIC stays HEIC.
    case keep
    /// Everything becomes HEIC (smaller; the extension changes for JPEGs).
    case heic

    var id: String { rawValue }
    var title: String { self == .keep ? "Same format" : "HEIC" }
}

enum ShrinkVideoPreset: String, CaseIterable, Identifiable, Sendable, Hashable {
    case highest
    case uhd4K
    case hd1080

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highest: return "HEVC, original size"
        case .uhd4K: return "HEVC, up to 4K"
        case .hd1080: return "HEVC, up to 1080p"
        }
    }

    /// The longest side this preset allows, or nil for "keep the resolution".
    var maxLongSide: CGFloat? {
        switch self {
        case .highest: return nil
        case .uhd4K: return 3840
        case .hd1080: return 1920
        }
    }
}

struct ShrinkOptions: Sendable, Equatable {
    /// Master switch. Off by default; turning it on shows the quality warning.
    var enabled = false
    var kinds: Set<ShrinkKind> = Set(ShrinkKind.allCases.filter(\.enabledByDefault))

    /// HEIC / JPEG quality, 0.4…0.95.
    var imageQuality: Double = 0.75
    var imageFormat: ShrinkImageFormat = .keep
    /// Longest side in pixels; nil keeps the original resolution.
    var maxImageDimension: Int? = nil

    var videoPreset: ShrinkVideoPreset = .highest

    /// Removes where and with what each photo was taken (GPS, camera and lens). Off by default.
    var stripPhotoMetadata = false

    /// Detected at scan time.
    var tools: ShrinkTools = .none

    /// Files changed within this many days are skipped unless their folder is allowed.
    var recentDays: Int = 30
    /// A result is kept only if it is at least this much smaller. Otherwise the original stays.
    var minimumSavingsFraction: Double = 0.15
    /// Folders the user allowed despite being cloud-synced or recently changed (path prefixes).
    var allowedFolders: Set<String> = []

    var recentCutoff: Date { Date().addingTimeInterval(-Double(max(0, recentDays)) * 86_400) }

    func isAllowed(_ path: String) -> Bool {
        allowedFolders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The settings that change what an encode produces (used to tell when an estimate or preview is stale).
    var encodeSignature: String {
        "\(imageQuality)|\(imageFormat.rawValue)|\(maxImageDimension ?? 0)|\(videoPreset.rawValue)|\(stripPhotoMetadata)|\(tools.pngquant != nil)|\(tools.mozjpeg != nil)"
    }
}

// MARK: - Scan

struct ShrinkCandidate: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let kind: ShrinkKind
    /// Bytes on disk.
    let sizeBytes: Int64
    let logicalSize: Int64
    let modified: Date
    /// In iCloud Drive, Dropbox, Google Drive, OneDrive… (another device may hold its own copy).
    let isCloudSynced: Bool
    /// Held open by another process when the scan ran.
    let isOpen: Bool
    /// Furl already shrank this file; doing it again stacks quality loss.
    let alreadyShrunk: Bool

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

enum ShrinkSkipReason: String, Sendable, Hashable, CaseIterable {
    case photosLibrary
    case cloudSynced
    case openInApp
    case recentlyModified
    case alreadyShrunk

    var title: String {
        switch self {
        case .photosLibrary: return "Photos library: never touched (editing it directly would corrupt the library)"
        case .cloudSynced: return "Synced with iCloud, Dropbox, Google Drive or OneDrive"
        case .openInApp: return "Open in another app right now"
        case .recentlyModified: return "Changed recently"
        case .alreadyShrunk: return "Already shrunk by Furl (again would lose more quality)"
        }
    }

    /// Whether "Allow this folder" can override it.
    var allowable: Bool { self == .cloudSynced || self == .recentlyModified }
}

/// Skipped files grouped by folder and reason, so the user can allow one folder at a time.
struct ShrinkSkipGroup: Identifiable, Sendable, Hashable {
    var id: String { reason.rawValue + "|" + folder }
    let folder: String
    let reason: ShrinkSkipReason
    var count: Int
    var bytes: Int64
}

struct ShrinkScanResult: Sendable {
    var roots: [String]
    var candidates: [ShrinkCandidate]
    /// Photos libraries found (never shrunk, listed so the user knows why).
    var photoLibraries: [String]
    var scannedAt: Date
}

// MARK: - Preview

/// Rough, honest description of how much a result differs from the original.
struct ShrinkQuality: Sendable, Hashable {
    /// Peak signal-to-noise ratio of a downscaled comparison, in dB (higher is closer). Nil if it couldn't be measured.
    let psnr: Double?

    var label: String {
        guard let psnr else { return "Not measured" }
        switch psnr {
        case 42...: return "Hard to tell apart"
        case 37..<42: return "Very close"
        case 32..<37: return "Some visible loss up close"
        default: return "Noticeable loss"
        }
    }

    /// What sits behind "How ▸" in the preview: the measured number, what it means, and how the file was encoded.
    func howText(note: String) -> String {
        var parts: [String] = []
        if let psnr {
            if psnr.isInfinite {
                parts.append("The pixels are identical to the original.")
            } else {
                parts.append(String(format: "Measured at %.1f dB (PSNR).", psnr))
                parts.append("Above 40 dB most people can’t tell the two apart.")
            }
        }
        // Notes read like "HEIC at 72% quality" or "Images re-saved as JPEG at 70%…"; shown as one sentence.
        if !note.isEmpty { parts.append(note.prefix(1).uppercased() + note.dropFirst() + ".") }
        return parts.joined(separator: " ")
    }

    /// 0…1 for a meter.
    var score: Double {
        guard let psnr else { return 0 }
        if psnr.isInfinite { return 1 }
        return min(1, max(0, (psnr - 25) / 22))
    }
}

struct ShrinkPreview: Sendable, Identifiable {
    var id: String { candidate.path + "|" + signature }
    let candidate: ShrinkCandidate
    let signature: String
    /// Whole picture, fitted (first page for PDFs, a middle frame for videos).
    let before: CGImage?
    let after: CGImage?
    /// The same centre crop at full resolution, so artefacts are visible.
    let beforeDetail: CGImage?
    let afterDetail: CGImage?
    let originalBytes: Int64
    /// Real size for photos and PDFs; projected from a short sample for videos.
    let newBytes: Int64
    let isProjected: Bool
    let quality: ShrinkQuality
    let note: String
    /// Set when this item would be skipped or kept as is.
    let problem: String?

    var savedFraction: Double {
        originalBytes > 0 ? max(0, 1 - Double(newBytes) / Double(originalBytes)) : 0
    }
}

// MARK: - Run

enum ShrinkItemStatus: String, Sendable, Hashable {
    /// Re-encoded (lossy) and swapped in; the original is in the Trash.
    case shrunk
    /// Result wasn't meaningfully smaller; original kept untouched.
    case keptOriginal
    case skipped
    case failed
}

struct ShrinkItemResult: Identifiable, Sendable, Hashable {
    let id = UUID()
    let path: String
    let kind: ShrinkKind
    let status: ShrinkItemStatus
    let originalBytes: Int64
    let newBytes: Int64
    let message: String
    let undo: CompressUndoRecord?

    var savedBytes: Int64 { status == .shrunk ? max(0, originalBytes - newBytes) : 0 }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct ShrinkRunResult: Sendable {
    var items: [ShrinkItemResult] = []
    var startedAt = Date()
    var finishedAt = Date()
    var wasCancelled = false
    /// "Also remove photo location and camera details" was on for this run.
    var removedPhotoDetails = false

    var savedBytes: Int64 { items.reduce(0) { $0 + $1.savedBytes } }
    /// Photos replaced by a shrunk copy, and so stripped when `removedPhotoDetails` is on.
    var shrunkPhotoCount: Int { items.filter { $0.kind == .photos && $0.status == .shrunk }.count }
    var unshrunkPhotoCount: Int { items.filter { $0.kind == .photos && $0.status != .shrunk }.count }
    var originalBytesOfShrunk: Int64 { items.filter { $0.status == .shrunk }.reduce(0) { $0 + $1.originalBytes } }
    func count(_ status: ShrinkItemStatus) -> Int { items.filter { $0.status == status }.count }
    /// Undone with the same mechanism as lossless runs: `CompressionService.undo(_:)`.
    var undoRecords: [CompressUndoRecord] { items.compactMap(\.undo) }
}

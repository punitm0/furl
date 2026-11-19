import Foundation

// MARK: - Categories

enum CompressCategory: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case folders
    case images
    case pdfs
    case jpeg
    case audio
    case archives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folders: return "Folders & apps"
        case .images: return "PNG, GIF, TIFF"
        case .pdfs: return "PDFs"
        case .jpeg: return "JPEG & HEIC"
        case .audio: return "WAV & AIFF audio"
        case .archives: return "Office, iWork & ZIP"
        }
    }

    var summary: String {
        switch self {
        case .folders:
            return "APFS transparent compression for old projects and apps you rarely open. They still open normally; macOS unpacks them as they're read."
        case .images:
            return "Re-encodes with a stronger compressor. Every pixel is checked to be identical before the original is replaced."
        case .pdfs:
            return "Rebuilds the file, shares repeated objects and packs pages tighter. Page count and text are checked to be identical. Signed and encrypted PDFs are left alone."
        case .jpeg:
            return "Optimises how the image data is stored without decoding it, so quality can't drop. HEIC is left alone: there's no verified lossless path for it."
        case .audio:
            return "Converts to Apple Lossless (.m4a): the same sound, every sample checked, at about half the size. Off by default because the file type changes."
        case .archives:
            return "Word, PowerPoint, Keynote and ZIP files are archives inside. Repacks them at maximum compression and shrinks the PNGs inside losslessly."
        }
    }

    var systemImage: String {
        switch self {
        case .folders: return "folder"
        case .images: return "photo"
        case .pdfs: return "doc.richtext"
        case .jpeg: return "camera"
        case .audio: return "waveform"
        case .archives: return "doc.zipper"
        }
    }

    /// Noun used in "LZFSE · 214 folders".
    var unitName: String {
        switch self {
        case .folders: return "folders"
        case .images: return "images"
        case .pdfs: return "PDFs"
        case .jpeg: return "photos"
        case .audio: return "recordings"
        case .archives: return "files"
        }
    }

    var enabledByDefault: Bool { self != .audio }

    /// True when running this category changes the file's type/extension.
    var changesFileType: Bool { self == .audio }
}

// MARK: - Options

struct CompressOptions: Sendable, Equatable {
    /// Only touch files and folders not opened or changed in this many days. Folders and apps always use it.
    var minDaysUnused: Int = 60
    /// When false, the age filter is skipped for individual files (folders and apps still require it).
    var onlyUnused: Bool = true
    /// Move originals to the Trash (undoable) instead of deleting them once the copy is verified.
    var keepOriginalsInTrash: Bool = true
    /// Removes GPS and camera EXIF data from photos. NOT lossless for metadata; pixels are still verified.
    var stripPhotoMetadata: Bool = false
    var enabledCategories: Set<CompressCategory> = Set(CompressCategory.allCases.filter(\.enabledByDefault))

    var cutoffDate: Date {
        Date().addingTimeInterval(-Double(max(0, minDaysUnused)) * 86_400)
    }
}

// MARK: - Optional Homebrew tools

/// Paths to optional third-party tools. Everything works without them; they only unlock more formats or better ratios.
struct CompressTools: Sendable, Equatable {
    var oxipng: String?
    var zopflipng: String?
    var gifsicle: String?
    var jpegtran: String?
    var qpdf: String?

    static let none = CompressTools()

    static func detect() -> CompressTools {
        func find(_ name: String, extra: [String] = []) -> String? {
            let fm = FileManager.default
            for path in extra where fm.isExecutableFile(atPath: path) { return path }
            return ShellRunner.which(name)
        }
        return CompressTools(
            oxipng: find("oxipng"),
            zopflipng: find("zopflipng"),
            gifsicle: find("gifsicle"),
            jpegtran: find("jpegtran", extra: [
                "/opt/homebrew/opt/jpeg-turbo/bin/jpegtran", "/usr/local/opt/jpeg-turbo/bin/jpegtran",
                "/opt/homebrew/opt/mozjpeg/bin/jpegtran", "/usr/local/opt/mozjpeg/bin/jpegtran"
            ]),
            qpdf: find("qpdf")
        )
    }

    var installedNames: [String] {
        [("oxipng", oxipng), ("zopflipng", zopflipng), ("gifsicle", gifsicle), ("jpegtran", jpegtran), ("qpdf", qpdf)]
            .compactMap { $0.1 == nil ? nil : $0.0 }
    }
}

// MARK: - Scan results

struct CompressCandidate: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let category: CompressCategory
    /// Bytes on disk (allocated blocks) right now.
    let sizeBytes: Int64
    /// Bytes that look compressible (folders only; equals sizeBytes for files).
    let compressibleBytes: Int64
    /// Latest of modified / accessed / last-opened.
    let lastUsed: Date?
    let isApp: Bool
    let fileCount: Int

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A group of files Furl deliberately leaves alone, with the reason shown to the user.
struct CompressSkipGroup: Identifiable, Sendable, Hashable {
    var id: String { reason }
    let reason: String
    var count: Int
    var bytes: Int64
}

struct CompressCategorySummary: Identifiable, Sendable, Hashable {
    var id: CompressCategory { category }
    let category: CompressCategory
    var count: Int
    var bytes: Int64
    var estimatedSavings: Int64
    /// "Zopfli", "LZFSE", "Object streams"…
    var method: String
    /// False when the category needs a tool that isn't installed.
    var available: Bool
    var note: String?
}

struct CompressScanResult: Sendable {
    var candidates: [CompressCandidate]
    var skipped: [CompressSkipGroup]
    /// Measured ratio (output/input) per category from real sample runs; 1.0 means no savings expected.
    var sampleRatios: [CompressCategory: Double]
    var tools: CompressTools
    var minDaysUsedForFolders: Int
    var scannedAt: Date
    /// Files skipped because a tool is missing, per tool.
    var toolFiles: [OptionalTool: [ToolFile]] = [:]
}

/// One file a missing tool would have handled (only what the age filter needs).
struct ToolFile: Sendable, Hashable {
    let lastUsed: Date?
    let bytes: Int64
}

// MARK: - Run results

enum CompressItemStatus: String, Sendable, Hashable {
    /// Verified and swapped in.
    case compressed
    /// Verified but not smaller; original kept untouched.
    case notSmaller
    /// Not attempted (in use, iCloud-only, missing tool…).
    case skipped
    /// Output failed verification and was thrown away; original untouched.
    case rejected
    /// Something went wrong; original untouched.
    case failed
}

/// What was replaced, so it can be undone.
struct CompressUndoRecord: Sendable, Hashable {
    /// Where the original lived (and the compressed copy now lives, unless the extension changed).
    let originalPath: String
    /// Original's location in the Trash; nil if originals were deleted.
    let trashPath: String?
    /// Path of the compressed replacement (differs from originalPath when the type changed, e.g. .wav → .m4a).
    let newPath: String
    /// Inode of the original in the Trash: Finder reuses Trash names, so Undo only moves a match back.
    var trashFileID: UInt64? = nil
    /// The replacement as it was right after the swap (kind, modification date, size). Undo leaves a
    /// replacement that changed since then alone.
    var newStamp: CleanupStamp? = nil
}

struct CompressItemResult: Identifiable, Sendable, Hashable {
    let id = UUID()
    let path: String
    let category: CompressCategory
    let status: CompressItemStatus
    let originalBytes: Int64
    let newBytes: Int64
    let message: String
    let undo: CompressUndoRecord?

    var savedBytes: Int64 { status == .compressed ? max(0, originalBytes - newBytes) : 0 }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct CompressRunResult: Sendable {
    var items: [CompressItemResult] = []
    var startedAt = Date()
    var finishedAt = Date()
    var wasCancelled = false
    var originalsKeptInTrash = true

    var savedBytes: Int64 { items.reduce(0) { $0 + $1.savedBytes } }
    func count(_ status: CompressItemStatus) -> Int { items.filter { $0.status == status }.count }
    var undoRecords: [CompressUndoRecord] { items.compactMap(\.undo) }

    /// Same shape the rest of the app uses for undoable cleanups.
    /// Note: `DeletionService.restore` can't restore these on its own because the compressed copy occupies the
    /// original path — use `CompressionService.undo(_:)` / `CompressStore.undoLastRun()`.
    var trashedItems: [TrashedItem] {
        undoRecords.compactMap { record in
            record.trashPath.map { TrashedItem(originalPath: record.originalPath, trashPath: $0) }
        }
    }

    func savedBytes(for category: CompressCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.savedBytes }
    }
}

// MARK: - Progress

/// Thread-safe progress shared between the worker and the UI poller.
final class CompressProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    private var _done = 0
    private var _saved: Int64 = 0
    private var _phase = ""
    private var _cancelled = false

    func setTotal(_ total: Int) { lock.lock(); _total = total; lock.unlock() }
    func advance(saved: Int64 = 0) { lock.lock(); _done += 1; _saved += saved; lock.unlock() }
    func setPhase(_ phase: String) { lock.lock(); _phase = phase; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
    var done: Int { lock.lock(); defer { lock.unlock() }; return _done }
    var saved: Int64 { lock.lock(); defer { lock.unlock() }; return _saved }
    var phase: String { lock.lock(); defer { lock.unlock() }; return _phase }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var fraction: Double { let t = total; return t == 0 ? 0 : min(1, Double(done) / Double(t)) }
}

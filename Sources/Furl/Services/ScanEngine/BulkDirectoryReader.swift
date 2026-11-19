import Darwin
import Foundation
import UniformTypeIdentifiers

/// One directory entry as returned by `getattrlistbulk`. Plain values only, so it is cheap to copy.
/// The entry name is handed to the callback separately as raw UTF-8 bytes to avoid a `String` per file.
struct BulkEntry {
    enum Kind: UInt8 { case file = 1, directory = 2, symlink = 5, other = 0 }

    var kind: Kind = .other
    var fileID: UInt64 = 0
    var linkCount: UInt32 = 1
    /// Data-fork length (what `URLResourceValues.fileSize` reports).
    var logicalSize: Int64 = 0
    /// All forks, allocated blocks (what `URLResourceValues.totalFileAllocatedSize` reports).
    var allocatedSize: Int64 = 0
    /// APFS bytes not shared with clones; -1 when the volume doesn't report it (non-APFS).
    var privateSize: Int64 = -1
    /// Seconds since 1970.
    var modified: Int64 = 0
    var accessed: Int64 = 0
    var created: Int64 = 0
    /// BSD `st_flags` (UF_HIDDEN, SF_DATALESS, ...).
    var bsdFlags: UInt32 = 0
    /// Finder flags (kHasBundle etc.), host byte order.
    var finderFlags: UInt16 = 0
    var isMountPoint = false
    /// `ATTR_CMNEXT_EXT_FLAGS` (bit 0x1 = may share blocks with a clone); 0 when not requested/returned.
    var extFlags: UInt64 = 0
    /// Per-entry error from the kernel (e.g. EACCES on an individual item); attributes may be partial.
    var error: UInt32 = 0

    /// What deleting this file actually frees, exactly as `FileSizeHelper.reclaimableFileSize` computes it:
    /// hard-linked files free nothing until every link is gone; APFS clones only free their private bytes.
    var reclaimableSize: Int64 {
        if linkCount > 1 { return 0 }
        if privateSize >= 0 { return privateSize }
        return allocatedSize > 0 ? allocatedSize : logicalSize
    }

    /// Size as Finder shows it (clones counted in full). Matches `FileSizeHelper.singleFileSize`.
    var displaySize: Int64 { allocatedSize > 0 ? allocatedSize : logicalSize }

    var isHiddenFlag: Bool { bsdFlags & UInt32(UF_HIDDEN) != 0 }
    var isDataless: Bool { bsdFlags & UInt32(SF_DATALESS) != 0 }
}

/// Reads whole directories with `getattrlistbulk(2)`: one syscall returns names, types, sizes, dates and
/// APFS private sizes for dozens of entries, instead of `readdir` + a `stat`/`getattrlist` per file.
///
/// Not thread-safe: each worker owns one reader (and its buffer).
final class BulkDirectoryReader {
    enum ReadError: Error, Equatable {
        case open(Int32)
        case read(Int32)
    }

    /// Benchmarking switch only: skip ATTR_CMNEXT_PRIVATESIZE to measure its cost. Never turn off in the app —
    /// reclaimable sizes would then overstate clones.
    nonisolated(unsafe) static var requestPrivateSize = true
    /// Benchmarking/validation switch: also request ATTR_CMNEXT_EXT_FLAGS.
    nonisolated(unsafe) static var requestExtFlags = false

    private let bufferSize: Int
    private let buffer: UnsafeMutableRawPointer
    /// Volumes (st_dev) that rejected FSOPT_ATTR_CMN_EXTENDED; we stop asking them for private sizes.
    private var volumesWithoutExtended = Set<dev_t>()

    init(bufferSize: Int = 256 * 1024) {
        self.bufferSize = bufferSize
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit { buffer.deallocate() }

    private static let commonAttrs: UInt32 =
        UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_ERROR) |
        UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME) |
        UInt32(ATTR_CMN_ACCTIME) | UInt32(ATTR_CMN_FNDRINFO) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID)
    private static let dirAttrs: UInt32 = UInt32(ATTR_DIR_MOUNTSTATUS)
    private static let fileAttrs: UInt32 =
        UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH)
    private static let extendedAttrs: UInt32 = UInt32(ATTR_CMNEXT_PRIVATESIZE)

    /// Calls `body` for every entry of the directory at `path` (excluding `.` and `..`).
    /// `name` is only valid during the call.
    @discardableResult
    func read(path: String, _ body: (inout BulkEntry, UnsafeRawBufferPointer) -> Void) -> Result<Int, ReadError> {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.open(errno)) }
        defer { close(fd) }
        return read(fd: fd, body)
    }

    func read(fd: Int32, _ body: (inout BulkEntry, UnsafeRawBufferPointer) -> Void) -> Result<Int, ReadError> {
        var st = stat()
        let device: dev_t = fstat(fd, &st) == 0 ? st.st_dev : 0
        var useExtended = Self.requestPrivateSize && !volumesWithoutExtended.contains(device)

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = Self.commonAttrs
        attrs.dirattr = Self.dirAttrs
        attrs.fileattr = Self.fileAttrs

        var total = 0
        var first = true
        while true {
            attrs.forkattr = useExtended ? Self.extendedAttrs : 0
            if Self.requestExtFlags { attrs.forkattr |= UInt32(ATTR_CMNEXT_EXT_FLAGS) }
            if !Self.requestPrivateSize && Self.requestExtFlags { useExtended = true; attrs.forkattr = UInt32(ATTR_CMNEXT_EXT_FLAGS) }
            let options = UInt64(useExtended ? FSOPT_ATTR_CMN_EXTENDED : 0) | UInt64(FSOPT_NOFOLLOW)
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, options)
            if count < 0 {
                let err = errno
                // Some non-APFS file systems reject the extended-attribute option outright; retry without it.
                if first && useExtended && (err == EINVAL || err == ENOTSUP) {
                    useExtended = false
                    volumesWithoutExtended.insert(device)
                    continue
                }
                if err == EINTR { continue }
                return total > 0 ? .success(total) : .failure(.read(err))
            }
            first = false
            if count == 0 { break }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                guard length > 0 else { break }
                Self.parse(entryAt: cursor, length: length, body)
                cursor += length
            }
            total += Int(count)
        }
        return .success(total)
    }

    /// Attribute layout (getattrlist(2)): u_int32 length, attribute_set_t returned, then ATTR_CMN_ERROR if
    /// returned, then every other returned attribute in bit order — common, dir, file, fork/extended.
    /// Values are 4-byte aligned, so 8-byte fields are read unaligned.
    @inline(__always)
    private static func parse(
        entryAt start: UnsafeRawPointer,
        length: Int,
        _ body: (inout BulkEntry, UnsafeRawBufferPointer) -> Void
    ) {
        var p = start + 4
        let common = p.loadUnaligned(as: UInt32.self)
        // vol at +4 is never returned for bulk reads.
        let dir = p.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let file = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let fork = p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        p += 20

        var entry = BulkEntry()
        var name = UnsafeRawBufferPointer(start: nil, count: 0)

        if common & UInt32(ATTR_CMN_ERROR) != 0 {
            entry.error = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & UInt32(ATTR_CMN_NAME) != 0 {
            let offset = Int(p.loadUnaligned(as: Int32.self))
            let len = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            // attr_length includes the trailing NUL; the offset is relative to the attrreference itself.
            let nameStart = p + offset
            if len > 1, offset > 0, start.distance(to: nameStart) + len <= length {
                name = UnsafeRawBufferPointer(start: nameStart, count: len - 1)
            }
            p += 8
        }
        if common & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            let type = p.loadUnaligned(as: UInt32.self)
            entry.kind = BulkEntry.Kind(rawValue: UInt8(truncatingIfNeeded: type)) ?? .other
            if type != UInt32(VREG.rawValue) && type != UInt32(VDIR.rawValue) && type != UInt32(VLNK.rawValue) {
                entry.kind = .other
            }
            p += 4
        }
        if common & UInt32(ATTR_CMN_CRTIME) != 0 {
            entry.created = Int64(p.loadUnaligned(as: Int.self))
            p += 16
        }
        if common & UInt32(ATTR_CMN_MODTIME) != 0 {
            entry.modified = Int64(p.loadUnaligned(as: Int.self))
            p += 16
        }
        if common & UInt32(ATTR_CMN_ACCTIME) != 0 {
            entry.accessed = Int64(p.loadUnaligned(as: Int.self))
            p += 16
        }
        if common & UInt32(ATTR_CMN_FNDRINFO) != 0 {
            // FileInfo.fdFlags / FolderInfo.frFlags live at byte 8, big-endian.
            entry.finderFlags = UInt16(bigEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            p += 32
        }
        if common & UInt32(ATTR_CMN_FLAGS) != 0 {
            entry.bsdFlags = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & UInt32(ATTR_CMN_FILEID) != 0 {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        if dir & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
            entry.isMountPoint = p.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            p += 4
        }
        if file & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if file & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        if file & UInt32(ATTR_FILE_DATALENGTH) != 0 {
            entry.logicalSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        if fork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 {
            entry.privateSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        if fork & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            entry.extFlags = p.loadUnaligned(as: UInt64.self)
            p += 8
        }

        guard name.count > 0 else { return }
        body(&entry, name)
    }
}

// MARK: - Name helpers

extension UnsafeRawBufferPointer {
    /// Decodes a file-system name (UTF-8, no terminator).
    var fileName: String { String(decoding: self, as: UTF8.self) }

    @inline(__always)
    func equals(_ ascii: StaticString) -> Bool {
        guard ascii.utf8CodeUnitCount == count else { return false }
        return memcmp(baseAddress, ascii.utf8Start, count) == 0
    }

    @inline(__always)
    var startsWithDot: Bool { count > 0 && self[0] == UInt8(ascii: ".") }
}

// MARK: - Package detection

/// Decides whether a directory is a package (bundle) that Finder shows as one item — the cheap equivalent of
/// `URLResourceValues.isPackage` (which asks Launch Services per item).
enum PackageDetector {
    /// Finder's kHasBundle bit.
    static let hasBundleFlag: UInt16 = 0x2000

    private static let knownPackageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "qlgenerator", "mdimporter",
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "theater", "logicx", "band", "xcodeproj", "xcworkspace", "playground",
        "xcarchive", "pages", "numbers", "key", "rtfd", "pkg", "mpkg", "dSYM", "sparsebundle", "saver",
        "prefPane", "wdgt", "docset", "nib", "storyboardc", "momd", "mlmodelc", "vmwarevm", "pvm", "utm", "abbu"
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func isPackage(name: UnsafeRawBufferPointer, finderFlags: UInt16) -> Bool {
        if finderFlags & hasBundleFlag != 0 { return true }
        // Find the extension without allocating unless there is one.
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return false }
        let ext = String(decoding: UnsafeRawBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self)
        return isPackage(extension: ext)
    }

    static func isPackage(extension ext: String) -> Bool {
        if knownPackageExtensions.contains(ext) { return true }
        lock.lock()
        if let cached = cache[ext] { lock.unlock(); return cached }
        lock.unlock()
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        lock.lock(); cache[ext] = result; lock.unlock()
        return result
    }
}

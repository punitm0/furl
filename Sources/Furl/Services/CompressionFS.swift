import Compression
import Darwin
import Foundation

/// Low-level file system helpers for the Compress feature: on-disk sizes, byte-exact comparisons,
/// metadata copying and APFS transparent (decmpfs / LZFSE) compression.
enum CompressionFS {
    static let compressedFlag = UInt32(UF_COMPRESSED)
    static let datalessFlag: UInt32 = 0x4000_0000 // SF_DATALESS: iCloud placeholder whose data isn't on this Mac
    static let restrictedFlag = UInt32(SF_RESTRICTED) // SIP-protected
    static let immutableFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

    // MARK: stat helpers

    static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func isRegular(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFREG }
    static func isDirectory(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }
    static func isSymlink(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFLNK }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
    }

    /// When the entry's content last changed. Access times are deliberately ignored: Spotlight, Quick Look,
    /// backups and our own scans read files and would make everything look recently used. "Opened" comes from
    /// Spotlight's last-used date instead (see `CompressionService.lastOpened`).
    static func lastUsed(_ st: stat) -> Date {
        date(st.st_mtimespec)
    }

    /// Bytes actually allocated on disk (what `du` reports). For decmpfs-compressed files this is the compressed size.
    static func allocatedBytes(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }

    /// Allocated bytes of a file or a whole folder tree.
    static func allocatedBytes(atPath path: String) -> Int64 {
        guard let st = lstatInfo(path) else { return 0 }
        if !isDirectory(st) { return allocatedBytes(st) }
        var total: Int64 = 0
        walk(path) { _, entry in
            if !isDirectory(entry) { total += allocatedBytes(entry) }
            return true
        }
        return total
    }

    /// Physical (no symlink following) pre-order walk using fts. `visit` returns false to skip a directory's contents.
    static func walk(_ root: String, visit: (String, stat) -> Bool) {
        root.withCString { cRoot in
            let dup = strdup(cRoot)
            defer { free(dup) }
            var paths: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }
                guard let statPtr = entry.pointee.fts_statp else { continue }
                let path = String(cString: entry.pointee.fts_path)
                if !visit(path, statPtr.pointee), info == FTS_D {
                    fts_set(fts, entry, FTS_SKIP)
                }
            }
        }
    }

    // MARK: comparisons

    /// Byte-for-byte comparison of two regular files (reads through decmpfs transparently).
    static func filesEqual(_ a: String, _ b: String) -> Bool {
        guard let ha = FileHandle(forReadingAtPath: a), let hb = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        let chunk = 1 << 20
        while true {
            let da = (try? ha.read(upToCount: chunk)) ?? Data()
            let db = (try? hb.read(upToCount: chunk)) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    /// System-managed attributes that aren't part of a file's content and can't be copied by user processes
    /// (`com.apple.macl` is a sandbox access cache macOS adds when items pass through the Trash).
    static let ignoredXattrs: Set<String> = ["com.apple.macl"]

    static func xattrs(_ path: String, options: Int32 = XATTR_NOFOLLOW) -> [String: Data] {
        let size = listxattr(path, nil, 0, options)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &names, size, options)
        guard got > 0 else { return [:] }
        var result: [String: Data] = [:]
        let bytes = names.prefix(got).split(separator: 0, omittingEmptySubsequences: true)
        for nameBytes in bytes {
            let name = String(decoding: nameBytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if ignoredXattrs.contains(name) { continue }
            let len = getxattr(path, name, nil, 0, 0, options)
            guard len >= 0 else { continue }
            var value = Data(count: len)
            if len > 0 {
                _ = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, options) }
            }
            result[name] = value
        }
        return result
    }

    static func symlinkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// True if `path` is still the item `before` described: same inode, type, size and modification time to the
    /// nanosecond. A save within the same second as the scan keeps `tv_sec`, so seconds alone aren't enough.
    static func unchanged(_ path: String, since before: stat) -> Bool {
        guard let now = lstatInfo(path) else { return false }
        return now.st_ino == before.st_ino && now.st_dev == before.st_dev
            && (now.st_mode & S_IFMT) == (before.st_mode & S_IFMT)
            && now.st_size == before.st_size
            && now.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && now.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    }

    /// Compares two folder trees: same entries, types, permissions, owners, modification dates, flags (ignoring the
    /// compression flag), symlink targets, extended attributes and file contents. Returns nil if identical, else why not.
    static func treeDifference(original: String, copy: String) -> String? {
        var originalCount = 0
        var difference: String?
        walk(original) { path, a in
            if difference != nil { return false }
            originalCount += 1
            let rel = String(path.dropFirst(original.count))
            let other = copy + rel
            guard let b = lstatInfo(other) else { difference = "missing \(rel)"; return false }
            if (a.st_mode & S_IFMT) != (b.st_mode & S_IFMT) { difference = "type changed: \(rel)"; return false }
            if (a.st_mode & 0o7777) != (b.st_mode & 0o7777) { difference = "permissions changed: \(rel)"; return false }
            if a.st_uid != b.st_uid || a.st_gid != b.st_gid { difference = "owner changed: \(rel)"; return false }
            if (a.st_flags & ~compressedFlag) != (b.st_flags & ~compressedFlag) { difference = "flags changed: \(rel)"; return false }
            if isSymlink(a) {
                if symlinkTarget(path) != symlinkTarget(other) { difference = "link changed: \(rel)"; return false }
                return true
            }
            if !isDirectory(a) {
                if a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec {
                    difference = "date changed: \(rel)"; return false
                }
                if a.st_size != b.st_size { difference = "size changed: \(rel)"; return false }
                if isRegular(a), !filesEqual(path, other) { difference = "content changed: \(rel)"; return false }
            }
            if xattrs(path) != xattrs(other) { difference = "extended attributes changed: \(rel)"; return false }
            return true
        }
        if let difference { return difference }
        var copyCount = 0
        walk(copy) { _, _ in copyCount += 1; return true }
        return copyCount == originalCount ? nil : "copy has \(copyCount - originalCount) extra items"
    }

    // MARK: metadata

    /// Copies extended attributes (Finder tags, comments, where-from…), ACL, permissions and dates from one file to another.
    static func copyMetadata(from source: String, to destination: String) {
        _ = copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        guard let st = lstatInfo(source) else { return }
        lchown(destination, st.st_uid, st.st_gid) // best effort: only succeeds for groups the user belongs to
        chmod(destination, st.st_mode & 0o7777)
        let attrs: [FileAttributeKey: Any] = [
            .creationDate: date(st.st_birthtimespec),
            .modificationDate: date(st.st_mtimespec)
        ]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: destination)
    }

    /// Paths currently held open by any process this user can see (`lsof`). Empty on failure.
    static func openFiles() -> Set<String> {
        let result = ShellRunner.run("/usr/sbin/lsof", arguments: ["-n", "-P", "-w", "-Fn"], timeout: 45)
        guard !result.stdout.isEmpty else { return [] }
        var set = Set<String>()
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("n/") {
            set.insert(String(line.dropFirst()))
        }
        return set
    }

    static func isInUse(_ path: String, isDirectory: Bool, openFiles: Set<String>) -> Bool {
        // lsof lists resolved paths; check the resolved form of `path` too.
        var forms: Set<String> = [path]
        if let resolved = realpath(path, nil) {
            forms.insert(String(cString: resolved))
            free(resolved)
        }
        if !forms.isDisjoint(with: openFiles) { return true }
        guard isDirectory else { return false }
        let prefixes = forms.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return openFiles.contains { open in prefixes.contains { open.hasPrefix($0) } }
    }

    /// Live re-check, right now, whether any process this user can see has `path` open (for a folder:
    /// anything inside it, or a process working in it). Uses libproc, no subprocess: about 15 ms for a
    /// full pass, so it can run before each file and again just before the original is replaced.
    /// Memory-mapped files without an open descriptor aren't listed here; the `openFiles()` snapshot
    /// taken at the start of a run (lsof) covers those.
    static func isOpenNow(_ path: String, isDirectory: Bool) -> Bool {
        // libproc reports resolved paths (/private/tmp, not /tmp; no symlinked folders), so compare
        // against the resolved form of `path` as well as the path as given.
        var forms: Set<String> = [path]
        if let resolved = realpath(path, nil) {
            forms.insert(String(cString: resolved))
            free(resolved)
        }
        let prefixes = forms.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func matches(_ candidate: String) -> Bool {
            forms.contains(candidate) || (isDirectory && prefixes.contains { candidate.hasPrefix($0) })
        }
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return false }
        var pids = [Int32](repeating: 0, count: Int(estimated) + 64)
        let listed = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard listed > 0 else { return false }
        let me = getpid()
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for pid in pids.prefix(Int(listed)) where pid > 0 && pid != me {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if bytes > 0 {
                var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdStride + 8)
                let got = fds.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                }
                if got > 0 {
                    for fd in fds.prefix(Int(got) / fdStride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                        var info = vnode_fdinfowithpath()
                        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, vnodeSize) == vnodeSize else { continue }
                        let open = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                        }
                        if matches(open) { return true }
                    }
                }
            }
            if isDirectory {
                var cwd = proc_vnodepathinfo()
                let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
                if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, size) == size {
                    let dir = withUnsafeBytes(of: &cwd.pvi_cdir.vip_path) { raw in
                        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                    }
                    if matches(dir) { return true }
                }
            }
        }
        return false
    }

    // MARK: APFS transparent compression (decmpfs, LZFSE)

    enum DecmpfsOutcome: Equatable {
        case compressed(savedBytes: Int64)
        case notWorthIt
        case unsupported(String)
        case failed(String)
    }

    private static let blockSize = 65_536
    private static let inlineLimit = 3_802 // max decmpfs xattr payload that stays inline
    private static let maxFileSize = 512 * 1024 * 1024
    private static let decmpfsMagic: UInt32 = 0x636D_7066 // 'cmpf'
    private static let typeLZFSEInline: UInt32 = 11
    private static let typeLZFSEResource: UInt32 = 12

    /// Estimated on-disk bytes after LZFSE decmpfs compression, without touching the file. nil if unreadable.
    static func estimateDecmpfsBytes(_ data: Data) -> Int64 {
        let blocks = lzfseBlocks(data)
        return decmpfsAllocated(blocks: blocks)
    }

    private static func lzfseBlocks(_ data: Data) -> [Data] {
        let count = (data.count + blockSize - 1) / blockSize
        let capacity = blockSize + 4_096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        var blocks: [Data] = []
        blocks.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<count {
                let start = index * blockSize
                let length = min(blockSize, data.count - start)
                let written = compression_encode_buffer(dst, capacity, base + start, length, nil, COMPRESSION_LZFSE)
                guard written > 0 else { blocks.removeAll(); return }
                blocks.append(Data(bytes: dst, count: written))
            }
        }
        return blocks
    }

    private static func decmpfsAllocated(blocks: [Data]) -> Int64 {
        guard !blocks.isEmpty else { return Int64.max }
        if blocks.count == 1, blocks[0].count + 16 <= inlineLimit { return 0 }
        let rsrc = (blocks.count + 1) * 4 + blocks.reduce(0) { $0 + $1.count }
        return Int64((rsrc + 4_095) / 4_096 * 4_096)
    }

    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    /// Compresses one regular file in place with APFS transparent compression. Only call on a disposable clone:
    /// the file is unreadable between truncation and setting the flag. Content is read back and compared before returning.
    static func compressInPlace(_ path: String) -> DecmpfsOutcome {
        guard let st = lstatInfo(path), isRegular(st) else { return .unsupported("not a regular file") }
        if st.st_size == 0 { return .notWorthIt }
        if st.st_size > maxFileSize { return .unsupported("too large") }
        if st.st_nlink > 1 { return .unsupported("hard-linked") }
        if st.st_flags & (compressedFlag | datalessFlag | restrictedFlag | immutableFlags) != 0 { return .unsupported("flags") }
        if st.st_uid != getuid() { return .unsupported("owned by another user") }
        let existing = listxattrNames(path, options: XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION)
        if existing.contains("com.apple.ResourceFork") || existing.contains("com.apple.decmpfs") {
            return .unsupported("has a resource fork")
        }

        guard let data = FileManager.default.contents(atPath: path), data.count == Int(st.st_size) else {
            return .failed("couldn't read")
        }
        let blocks = lzfseBlocks(data)
        let newAllocated = decmpfsAllocated(blocks: blocks)
        let oldAllocated = allocatedBytes(st)
        guard newAllocated < oldAllocated else { return .notWorthIt }

        let originalMode = st.st_mode & 0o7777
        if originalMode & S_IWUSR == 0 { chmod(path, originalMode | S_IWUSR) }
        defer { chmod(path, originalMode) }

        var header = le32(decmpfsMagic)
        if blocks.count == 1, blocks[0].count + 16 <= inlineLimit {
            header.append(le32(typeLZFSEInline))
            header.append(le64(UInt64(data.count)))
            header.append(blocks[0])
        } else {
            var rsrc = Data()
            var offset = UInt32((blocks.count + 1) * 4)
            rsrc.append(le32(offset))
            for block in blocks {
                offset += UInt32(block.count)
                rsrc.append(le32(offset))
            }
            for block in blocks { rsrc.append(block) }
            let wrote = rsrc.withUnsafeBytes {
                setxattr(path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard wrote == 0 else { return .failed("resource fork: \(String(cString: strerror(errno)))") }
            header.append(le32(typeLZFSEResource))
            header.append(le64(UInt64(data.count)))
        }
        let wroteHeader = header.withUnsafeBytes {
            setxattr(path, "com.apple.decmpfs", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard wroteHeader == 0 else { return .failed("decmpfs: \(String(cString: strerror(errno)))") }
        guard truncate(path, 0) == 0 else { return .failed("truncate failed") }
        guard chflags(path, st.st_flags | compressedFlag) == 0 else { return .failed("couldn't set compressed flag") }

        var times = [st.st_atimespec, st.st_mtimespec]
        utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)

        guard let readBack = FileManager.default.contents(atPath: path), readBack == data else {
            return .failed("read-back mismatch")
        }
        let after = lstatInfo(path).map(allocatedBytes) ?? oldAllocated
        return .compressed(savedBytes: max(0, oldAllocated - after))
    }

    static func listxattrNames(_ path: String, options: Int32) -> Set<String> {
        let size = listxattr(path, nil, 0, options)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &names, size, options)
        guard got > 0 else { return [] }
        return Set(names.prefix(got).split(separator: 0, omittingEmptySubsequences: true).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        })
    }
}

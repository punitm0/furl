import Darwin
import Foundation

enum FileSizeHelper {
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// Bytes this file occupies that are NOT shared with APFS clones — i.e. what deleting it actually frees.
    /// pnpm, Finder "Duplicate" and `cp -c` create clones whose allocated size massively overstates real usage.
    /// Returns nil if the volume doesn't support the attribute (non-APFS), so callers can fall back.
    static func privateSize(atPath path: String) -> Int64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = getattrlist(path, &attrs, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            // Layout: u_int32 length, attribute_set_t {common, vol, dir, file, fork}, then off_t private size.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }

    /// Space that removing this file or folder would free (clone- and hard-link-aware).
    static func directorySize(at url: URL) -> Int64 {
        // Inside a scan that has the shared index, answer from it (same clone/hard-link rules, no walk).
        if let index = ScanIndexContext.index, index.covers(url.path),
           let size = index.reclaimableSize(ofPath: url.path) {
            return size
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            return reclaimableFileSize(at: url, linkCount: nil)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey, .linkCountKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += reclaimableFileSize(at: fileURL, linkCount: values.linkCount, values: values)
            }
        }
        return total
    }

    private static func reclaimableFileSize(at url: URL, linkCount: Int?, values: URLResourceValues? = nil) -> Int64 {
        // A hard-linked file isn't freed until every link is gone; don't promise that space.
        if let linkCount, linkCount > 1 { return 0 }
        if let priv = privateSize(atPath: url.path) { return priv }
        let vals = values ?? (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]))
        return Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
    }

    /// Size on disk as Finder reports it (clones counted in full).
    static func singleFileSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    static func modifiedDate(at url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    static func daysSinceModified(at url: URL) -> Int? {
        guard let date = modifiedDate(at: url) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
}

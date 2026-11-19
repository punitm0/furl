import Foundation

/// Decides whether an archive is really "already unzipped": the folder next to it must hold what the
/// archive lists: top-level names, every listed folder and file at its path, and the sizes. Anything less (no listing, a password, a timeout,
/// a missing name, a folder that's smaller than the archive's contents) leaves the archive alone.
enum ArchiveExtractionCheck {
    /// The archive's contents, from `bsdtar -tv` (handles zip, tar and its compressed forms, 7z, rar).
    struct Listing: Sendable, Equatable {
        /// First path component of every entry, ignoring macOS metadata (`__MACOSX`, `._*`, `.DS_Store`).
        var topLevel: Set<String> = []
        /// Second-level names under each top-level folder (to match Archive Utility's "one folder" layout).
        var children: [String: Set<String>] = [:]
        /// Total uncompressed bytes of regular files, by top-level name.
        var bytes: [String: Int64] = [:]
        /// Every regular file by its path inside the archive, with its uncompressed size.
        var files: [String: Int64] = [:]
        /// Every folder the archive lists explicitly, by its path inside the archive.
        var dirs: Set<String> = []
        var totalBytes: Int64 { bytes.values.reduce(0, +) }
    }

    /// The folder next to `archive` that extracting it would have made (`Foo.zip` → `Foo`,
    /// `Foo.tar.gz` → `Foo`), or nil if there isn't one.
    static func extractedFolder(for archive: URL) -> URL? {
        var base = archive.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        guard base.lastPathComponent != archive.lastPathComponent else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return base
    }

    /// True only when the folder next to the archive holds every top-level item the archive lists and at
    /// least as many bytes. Runs `bsdtar`, so call it off the main thread.
    static func isExtracted(archive: URL, timeout: TimeInterval = 60) -> Bool {
        guard let folder = extractedFolder(for: archive),
              let listing = list(archive: archive, timeout: timeout),
              !listing.topLevel.isEmpty else { return false }
        return matches(listing: listing, folder: folder)
    }

    /// Compares a listing with a folder on disk. Two layouts count:
    /// - the archive holds one folder named like the archive (`Foo/…`): its children must be in `Foo`
    ///   (Archive Utility and `unzip` both give `Foo/` then);
    /// - otherwise every top-level item must be in `Foo` (Archive Utility wraps loose items in a folder).
    /// Beyond the names, the whole tree must be there: every folder the archive lists, and every file at
    /// its path as a regular file. Files whose size still matches must add up to 99% of the archive's
    /// bytes, so a same-named folder that merely shares common entries (src, README) never passes.
    static func matches(listing: Listing, folder: URL) -> Bool {
        let name = folder.lastPathComponent
        let names: Set<String>
        let expectedBytes: Int64
        let root: URL
        let stripTop: Bool
        if listing.topLevel == [name], let children = listing.children[name], !children.isEmpty {
            // Archive Utility puts `Foo.zip` holding `Foo/` at `Foo/`; some tools nest it as `Foo/Foo/`.
            let nested = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue,
               !present(children, in: folder) {
                root = nested
            } else {
                root = folder
            }
            names = children
            expectedBytes = listing.bytes[name] ?? 0
            stripTop = true
        } else {
            root = folder
            names = listing.topLevel
            expectedBytes = listing.totalBytes
            stripTop = false
        }
        guard present(names, in: root) else { return false }
        // Sizes: the folder may have gained files since, but must not hold less than the archive.
        // A 1% allowance covers how tools count sparse files and symlinks differently.
        let onDisk = logicalBytes(of: root, limitedTo: names)
        guard Double(onDisk) >= Double(expectedBytes) * 0.99 else { return false }
        return treeMatches(listing, root: root, stripTop: stripTop, expectedBytes: expectedBytes)
    }

    /// Every listed folder exists as a folder and every listed file exists as a regular file at the same
    /// relative path; files with an unchanged size cover at least 99% of `expectedBytes`.
    private static func treeMatches(_ listing: Listing, root: URL, stripTop: Bool, expectedBytes: Int64) -> Bool {
        let fm = FileManager.default
        func diskPath(_ archivePath: String) -> String? {
            var parts = archivePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if stripTop { parts.removeFirst() }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(root) { $0.appendingPathComponent($1) }.path
        }
        for dir in listing.dirs {
            guard let path = diskPath(dir) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        }
        var sameSizeBytes: Int64 = 0
        for (file, size) in listing.files {
            guard let path = diskPath(file),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { return false }
            if (attrs[.size] as? NSNumber)?.int64Value == size { sameSizeBytes += size }
        }
        return Double(sameSizeBytes) >= Double(expectedBytes) * 0.99
    }

    // MARK: - Listing

    static func list(archive: URL, timeout: TimeInterval) -> Listing? {
        // Reading an iCloud placeholder would download the whole archive.
        var info = stat()
        if lstat(archive.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
        let result = ShellRunner.run("/usr/bin/bsdtar", arguments: ["-tvf", archive.path], timeout: timeout)
        guard result.exitCode == 0, !result.timedOut, !result.stdout.isEmpty else { return nil }
        return parse(verboseListing: result.stdout)
    }

    /// Parses `bsdtar -tv` lines: `mode links owner group size month day time-or-year name`.
    static func parse(verboseListing text: String) -> Listing? {
        var listing = Listing()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let mode = fields[0].first, let size = Int64(fields[4]) else { return nil }
            var path = String(fields[8])
            if mode == "l", let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
            if mode == "h", let link = path.range(of: " link to ") { path = String(path[..<link.lowerBound]) }
            if path.hasPrefix("./") { path.removeFirst(2) }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let top = parts.first, !parts.contains(where: isMetadata) else { continue }
            listing.topLevel.insert(top)
            if parts.count > 1 { listing.children[top, default: []].insert(parts[1]) }
            let relative = parts.joined(separator: "/")
            if mode == "-" {
                listing.bytes[top, default: 0] += size
                listing.files[relative] = size
            } else if mode == "d" {
                listing.dirs.insert(relative)
            }
        }
        return listing
    }

    private static func isMetadata(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    // MARK: - Disk side

    private static func present(_ names: Set<String>, in folder: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        // APFS is usually case-insensitive and stores names decomposed; compare loosely.
        let onDisk = Set(entries.map(normalized))
        return names.allSatisfy { onDisk.contains(normalized($0)) }
    }

    private static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Sum of regular-file sizes (logical, not allocated) of the listed items inside `folder`.
    private static func logicalBytes(of folder: URL, limitedTo names: Set<String>) -> Int64 {
        let fm = FileManager.default
        let wanted = Set(names.map(normalized))
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        for entry in entries where wanted.contains(normalized(entry.lastPathComponent)) {
            let values = try? entry.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
                continue
            }
            guard values?.isDirectory == true,
                  let walker = fm.enumerator(at: entry, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

enum DiskImageCheck {
    /// A disk image can be a vault or a backup, not just an installer. Only unencrypted, read-only
    /// compressed images (the formats apps ship in) count; anything hdiutil can't read is left alone.
    static func isPlainInstallerImage(_ url: URL) -> Bool {
        let encrypted = ShellRunner.run("/usr/bin/hdiutil", arguments: ["isencrypted", url.path], timeout: 20)
        guard encrypted.exitCode == 0, encrypted.stdout.contains("encrypted: NO") else { return false }
        let info = ShellRunner.run("/usr/bin/hdiutil", arguments: ["imageinfo", "-plist", url.path], timeout: 20)
        guard info.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil) as? [String: Any],
              let format = plist["Format"] as? String else { return false }
        return ["UDZO", "ULFO", "ULMO", "UDBZ", "UDCO", "UDRO"].contains(format)
    }
}

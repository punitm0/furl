import CryptoKit
import Foundation

enum DuplicateScanner {
    static func defaultRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static let skipDirectoryNames: Set<String> = [
        "node_modules", ".git", "Library", ".venv", "venv", "DerivedData", ".Trash", ".next", "target", "build", "dist"
    ]

    private struct Candidate {
        let path: String
        let size: Int64
        let modified: Date?
    }

    /// `emit` gets groups as soon as they're confirmed (results still arriving), from any thread.
    static func scan(roots: [String], minimumBytes: Int64, progress: ScanProgress? = nil,
                     emit: (@Sendable ([DuplicateGroup]) -> Void)? = nil) -> [DuplicateGroup] {
        progress?.setPhase("Listing files")
        let bySize: [Int64: [Candidate]]
        if let index = ScanIndexContext.index, !roots.isEmpty, roots.allSatisfy({ index.covers($0) }),
           minimumBytes >= RetainRule.default.minBytes {
            bySize = collectFiles(from: index, roots: roots, minimumBytes: minimumBytes, progress: progress)
        } else {
            bySize = collectFiles(roots: roots, minimumBytes: minimumBytes, progress: progress)
        }
        if progress?.isCancelled == true { return [] }

        let sizeGroups = bySize.values.filter { $0.count > 1 }
        progress?.setPhase("Comparing \(sizeGroups.reduce(0) { $0 + $1.count }) candidates")

        let lock = NSLock()
        nonisolated(unsafe) var groups: [DuplicateGroup] = []
        let work = Array(sizeGroups)
        progress?.setSteps(done: 0, total: work.count)

        DispatchQueue.concurrentPerform(iterations: work.count) { index in
            if progress?.isCancelled == true { return }
            let found = confirmDuplicates(in: work[index])
            progress?.advanceStep()
            if !found.isEmpty {
                lock.lock()
                groups.append(contentsOf: found)
                lock.unlock()
                // Groups made only of APFS clones share storage already (filtered below too).
                let worth = found.filter { $0.reclaimableBytes > 0 }
                if !worth.isEmpty { emit?(worth) }
            }
        }

        // Groups made only of APFS clones share storage already; deleting copies would free nothing.
        return groups
            .filter { $0.reclaimableBytes > 0 }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Walks the roots and buckets regular files by exact byte size.
    private static func collectFiles(roots: [String], minimumBytes: Int64, progress: ScanProgress?) -> [Int64: [Candidate]] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ]

        var bySize: [Int64: [Candidate]] = [:]
        var seenPaths = Set<String>()
        var seenFileIDs = Set<NSObject>()

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    progress?.addUnreadable()
                    return true
                }
            ) else { continue }

            var batch = 0
            for case let url as URL in enumerator {
                if progress?.isCancelled == true { return [:] }
                batch += 1
                if batch == 500 {
                    progress?.addItems(batch)
                    batch = 0
                }

                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if skipDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, let size = values.fileSize, Int64(size) >= minimumBytes else { continue }

                let path = url.standardizedFileURL.path
                // iCloud placeholders would be downloaded just to hash them.
                var info = stat()
                if lstat(path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { continue }
                guard seenPaths.insert(path).inserted else { continue }
                // Hard links (and the same file reached via overlapping roots) share an identifier.
                if let fileID = values.fileResourceIdentifier as? NSObject {
                    guard seenFileIDs.insert(fileID).inserted else { continue }
                }

                bySize[Int64(size), default: []].append(
                    Candidate(path: path, size: Int64(size), modified: values.contentModificationDate)
                )
            }
            progress?.addItems(batch)
        }
        return bySize
    }

    /// Same buckets as `collectFiles(roots:)` (hidden items, packages and `skipDirectoryNames` excluded,
    /// hard links counted once), read from the shared index instead of walking.
    private static func collectFiles(from index: FileIndex, roots: [String], minimumBytes: Int64, progress: ScanProgress?) -> [Int64: [Candidate]] {
        let inRoots = index.inclusionMask(roots: roots)
        let excluded = index.exclusionMask { id, record in
            record.flags.contains(.hidden) || record.flags.contains(.package) || record.mode != .indexed
                || skipDirectoryNames.contains(index.dirName(id))
        }
        let buckets = index.sizeBuckets(minBytes: minimumBytes) { inRoots[Int($0)] && !excluded[Int($0)] }
        var bySize: [Int64: [Candidate]] = [:]
        var count = 0
        for (size, files) in buckets {
            // Dataless files are iCloud placeholders; hashing one would download it.
            let visible = files.filter {
                !index.name($0.name).hasPrefix(".") && $0.bsdFlags & UInt32(UF_HIDDEN) == 0
                    && $0.bsdFlags & UInt32(SF_DATALESS) == 0
            }
            count += visible.count
            if visible.count > 1 {
                bySize[size] = visible.map { Candidate(path: index.path(of: $0), size: size, modified: $0.modifiedDate) }
            }
        }
        progress?.addItems(count)
        return bySize
    }

    /// Narrows a same-size bucket to real duplicates: partial hash first, then full content hash.
    private static func confirmDuplicates(in candidates: [Candidate]) -> [DuplicateGroup] {
        guard let size = candidates.first?.size else { return [] }
        let partialLimit = 64 * 1024

        var byPartial: [String: [Candidate]] = [:]
        for candidate in candidates {
            if let digest = partialHash(path: candidate.path, size: size, chunk: partialLimit) {
                byPartial[digest, default: []].append(candidate)
            }
        }

        var results: [DuplicateGroup] = []
        for (partialDigest, group) in byPartial where group.count > 1 {
            // Small files were hashed completely by the partial pass.
            let needsFullHash = size > Int64(partialLimit * 2)
            var byFull: [String: [Candidate]] = [:]
            if needsFullHash {
                for candidate in group {
                    if let digest = fullHash(path: candidate.path) {
                        byFull[digest, default: []].append(candidate)
                    }
                }
            } else {
                byFull[partialDigest] = group
            }

            for (digest, matches) in byFull where matches.count > 1 {
                results.append(DuplicateGroup(
                    id: "\(size)-\(digest)",
                    sizeBytes: size,
                    files: matches
                        .sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                        .map { DuplicateFile(
                            id: $0.path,
                            path: $0.path,
                            name: URL(fileURLWithPath: $0.path).lastPathComponent,
                            modifiedDate: $0.modified,
                            privateBytes: FileSizeHelper.privateSize(atPath: $0.path) ?? $0.size
                        ) }
                ))
            }
        }
        return results
    }

    private static func partialHash(path: String, size: Int64, chunk: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if size <= Int64(chunk * 2) {
                if let data = try handle.readToEnd() { hasher.update(data: data) }
            } else {
                if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
                try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let data = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
                guard let data, !data.isEmpty else { break }
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

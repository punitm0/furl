import Foundation

enum LargeFilesScanner {
    /// `emit` gets files as they're found (each top-level folder's files once it's walked; the
    /// whole list at once when answered from the shared index).
    static func scan(minimumBytes: Int64 = 100_000_000, progress: ScanProgress? = nil,
                     emit: (([LargeFileItem]) -> Void)? = nil) -> [LargeFileItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let skipTopLevel: Set<String> = ["Library", ".Trash", "Applications"]
        let skipSubdirs: Set<String> = [".git", "node_modules", ".venv", "venv", "DerivedData"]

        if let index = ScanIndexContext.index, index.rootPath == home.path, minimumBytes >= RetainRule.default.minBytes {
            let found = fromIndex(index, minimumBytes: minimumBytes, skipTopLevel: skipTopLevel, skipSubdirs: skipSubdirs)
            if !found.isEmpty { emit?(found) }
            return found
        }

        var results: [LargeFileItem] = []

        guard let topChildren = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        progress?.setSteps(done: 0, total: topChildren.count)
        for child in topChildren {
            defer { progress?.advanceStep() }
            if progress?.isCancelled == true { break }
            if skipTopLevel.contains(child.lastPathComponent) { continue }
            progress?.setCurrent(child.path)
            let before = results.count
            defer { if results.count > before { emit?(Array(results[before...])) } }
            guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  vals.isSymbolicLink != true else { continue }

            if vals.isRegularFile == true {
                let size = FileSizeHelper.singleFileSize(at: child)
                if size >= minimumBytes {
                    results.append(makeItem(url: child, size: size, modified: FileSizeHelper.modifiedDate(at: child)))
                }
                continue
            }

            guard vals.isDirectory == true,
                  let enumerator = fm.enumerator(
                    at: child,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }

            for case let fileURL as URL in enumerator {
                if skipSubdirs.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let fvals = try? fileURL.resourceValues(forKeys: keys),
                      fvals.isSymbolicLink != true,
                      fvals.isRegularFile == true else { continue }

                let size = Int64(fvals.totalFileAllocatedSize ?? fvals.fileSize ?? 0)
                if size >= minimumBytes {
                    results.append(makeItem(url: fileURL, size: size, modified: fvals.contentModificationDate))
                }
            }
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Same rules as the walk below (hidden items, packages, the skipped folders), answered from the shared index.
    private static func fromIndex(_ index: FileIndex, minimumBytes: Int64, skipTopLevel: Set<String>, skipSubdirs: Set<String>) -> [LargeFileItem] {
        let excluded = index.exclusionMask { id, record in
            guard id != FileIndex.rootID else { return false }
            let name = index.dirName(id)
            return record.flags.contains(.hidden) || record.flags.contains(.package) || record.mode != .indexed
                || skipSubdirs.contains(name)
                || (record.parent == FileIndex.rootID && skipTopLevel.contains(name))
        }
        return index.largeFiles(minBytes: minimumBytes) { !excluded[Int($0)] }
            .filter { file in
                let name = index.name(file.name)
                return !name.hasPrefix(".") && file.bsdFlags & UInt32(UF_HIDDEN) == 0
            }
            .map { makeItem(url: URL(fileURLWithPath: index.path(of: $0)), size: $0.displaySize, modified: $0.modifiedDate) }
    }

    private static func makeItem(url: URL, size: Int64, modified: Date?) -> LargeFileItem {
        let ext = url.pathExtension.lowercased()
        let kind: LargeFileKind
        if ["dmg", "iso", "pkg", "vmdk", "qcow2", "img"].contains(ext) {
            kind = .diskImage
        } else if ["zip", "tar", "gz", "tgz", "7z", "rar", "xz"].contains(ext) {
            kind = .archive
        } else if ["mp4", "mov", "mkv", "avi", "webm", "wav", "mp3", "m4a"].contains(ext) {
            kind = .media
        } else if ["gguf", "safetensors", "bin", "pt", "pth", "onnx", "parquet", "sqlite", "db", "csv"].contains(ext) {
            kind = .modelOrData
        } else {
            kind = .other
        }

        return LargeFileItem(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            sizeBytes: size,
            modifiedDate: modified,
            kind: kind
        )
    }
}

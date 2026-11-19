import Foundation

enum SpaceAnalyzer {
    struct ScanTarget: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let path: String
        let systemImage: String
    }

    /// Items smaller than this are merged into a single "smaller items" entry per folder.
    private static let keepThreshold: Int64 = 1_000_000
    /// Max individually-listed children per folder.
    private static let maxChildren = 150
    /// Depth below the root that is scanned in parallel.
    private static let parallelDepth = 2

    static func availableTargets() -> [ScanTarget] {
        let fm = FileManager.default
        var targets: [ScanTarget] = [
            ScanTarget(id: "home", name: "Home Folder", path: fm.homeDirectoryForCurrentUser.path, systemImage: "house"),
            ScanTarget(id: "root", name: DiskInfoService.currentDiskUsage().volumeName, path: "/", systemImage: "internaldrive")
        ]
        let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for url in volumes where url.path != "/" && url.path.hasPrefix("/Volumes/") {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            targets.append(ScanTarget(id: url.path, name: name, path: url.path, systemImage: "externaldrive"))
        }
        return targets
    }

    /// Paths never descended into: other volumes and firmlinked duplicates of the data volume.
    private static func skippedPaths(forRoot root: String) -> Set<String> {
        guard root == "/" else { return [] }
        return ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/net", "/home"]
    }

    /// `emit` gets each top-level item as soon as it's measured, as a leaf copy (no children) that is
    /// safe to show while the walk goes on. Answered from the shared index, nothing is emitted: it's instant.
    static func scan(rootPath: String, progress: ScanProgress? = nil,
                     emit: (@Sendable (SpaceNode) -> Void)? = nil) -> SpaceNode {
        let rootURL = URL(fileURLWithPath: rootPath)
        let skipped = skippedPaths(forRoot: rootURL.standardizedFileURL.path)
        let name = rootPath == "/"
            ? DiskInfoService.currentDiskUsage().volumeName
            : (rootPath == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : rootURL.lastPathComponent)
        if let index = ScanIndexContext.index, let id = index.dirID(forPath: rootURL.standardizedFileURL.path),
           index.dirs[Int(id)].mode == .indexed {
            return buildFromIndex(index, id: id, name: name)
        }
        let built = buildDirectory(url: rootURL, name: name, depth: 0, keepChildren: true, isPackage: false, skipped: skipped,
                                   progress: progress, onTopLevel: emit)
        return built
    }

    /// Space Map from the shared index: same sizes (Finder-style allocated bytes) and the same
    /// 1 MB / 150-children folding. Packages and size-only folders (node_modules, .git, …) are leaf folders.
    private static func buildFromIndex(_ index: FileIndex, id: Int32, name: String) -> SpaceNode {
        func node(_ id: Int32, name: String) -> SpaceNode {
            let record = index.dirs[Int(id)]
            let path = index.path(ofDir: id)
            let isPackage = record.flags.contains(.package)
            guard record.mode == .indexed && !isPackage else {
                return SpaceNode(id: path, name: name, path: path, isDirectory: true, isPackage: isPackage,
                                 sizeBytes: record.totalAllocated, itemCount: Int(record.totalFiles))
            }
            var children: [SpaceNode] = []
            var otherSize: Int64 = 0
            var otherCount = 0
            var otherEntries = 0
            for child in index.children(ofDir: id) {
                let c = index.dirs[Int(child)]
                if c.mode == .skipped { continue }
                if c.totalAllocated >= keepThreshold {
                    children.append(node(child, name: index.dirName(child)))
                } else {
                    otherSize += c.totalAllocated; otherCount += Int(c.totalFiles); otherEntries += 1
                }
            }
            var keptFileCount = 0
            var keptFileBytes: Int64 = 0
            for file in index.files(inDir: id) {
                keptFileCount += 1
                keptFileBytes += file.displaySize
                if file.displaySize >= keepThreshold {
                    let filePath = index.path(of: file)
                    children.append(SpaceNode(id: filePath, name: index.name(file.name), path: filePath,
                                              isDirectory: false, sizeBytes: file.displaySize, itemCount: 1))
                } else {
                    otherSize += file.displaySize; otherCount += 1; otherEntries += 1
                }
            }
            // Files below the index's keep threshold are only known as a count and total.
            let unkept = Int(record.ownFiles) - keptFileCount
            if unkept > 0 {
                otherSize += record.ownAllocated - keptFileBytes; otherCount += unkept; otherEntries += unkept
            }
            children.sort { $0.sizeBytes > $1.sizeBytes }
            if children.count > maxChildren {
                for extra in children[maxChildren...] { otherSize += extra.sizeBytes; otherCount += extra.itemCount; otherEntries += 1 }
                children.removeLast(children.count - maxChildren)
            }
            if otherEntries > 0 && otherSize > 0 {
                children.append(SpaceNode(
                    id: path + "#other", name: "\(otherEntries) smaller item\(otherEntries == 1 ? "" : "s")",
                    path: path, isDirectory: false, isAggregate: true, sizeBytes: otherSize, itemCount: otherCount
                ))
            }
            return SpaceNode(id: path, name: name, path: path, isDirectory: true, isPackage: false,
                             sizeBytes: record.totalAllocated, itemCount: Int(record.totalFiles), children: children)
        }
        return node(id, name: name)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
    ]

    private static func buildDirectory(
        url: URL,
        name: String,
        depth: Int,
        keepChildren: Bool,
        isPackage: Bool,
        skipped: Set<String>,
        progress: ScanProgress?,
        onTopLevel: (@Sendable (SpaceNode) -> Void)? = nil
    ) -> SpaceNode {
        let path = url.path
        let fm = FileManager.default

        guard progress?.isCancelled != true,
              let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [])
        else {
            if progress?.isCancelled != true { progress?.addUnreadable() }
            return SpaceNode(id: path, name: name, path: path, isDirectory: true, isPackage: isPackage, sizeBytes: 0, itemCount: 0)
        }
        progress?.addItems(contents.count)
        if depth == 0 { progress?.setSteps(done: 0, total: contents.count) }
        let reportTopLevel: @Sendable (SpaceNode?) -> Void = { node in
            guard depth == 0 else { return }
            progress?.advanceStep()
            guard let node, let onTopLevel else { return }
            onTopLevel(SpaceNode(id: node.id, name: node.name, path: node.path, isDirectory: node.isDirectory,
                                 isPackage: node.isPackage, sizeBytes: node.sizeBytes, itemCount: node.itemCount))
        }

        // Resolve each entry to a child node (files inline, folders recursively).
        @Sendable func makeChild(_ child: URL) -> SpaceNode? {
            guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)),
                  values.isSymbolicLink != true else { return nil }
            let childPath = child.path
            if values.isDirectory == true {
                if skipped.contains(childPath) { return nil }
                let childIsPackage = values.isPackage == true
                return buildDirectory(
                    url: child,
                    name: child.lastPathComponent,
                    depth: depth + 1,
                    keepChildren: keepChildren && !childIsPackage,
                    isPackage: childIsPackage,
                    skipped: skipped,
                    progress: progress
                )
            }
            guard values.isRegularFile == true else { return nil }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            return SpaceNode(id: childPath, name: child.lastPathComponent, path: childPath, isDirectory: false, sizeBytes: size, itemCount: 1)
        }

        var children: [SpaceNode] = []
        if depth < parallelDepth && contents.count > 1 {
            let lock = NSLock()
            nonisolated(unsafe) var collected: [SpaceNode] = []
            DispatchQueue.concurrentPerform(iterations: contents.count) { index in
                let made = makeChild(contents[index])
                reportTopLevel(made)
                if let node = made {
                    lock.lock()
                    collected.append(node)
                    lock.unlock()
                }
            }
            children = collected
        } else {
            children = contents.compactMap { child in
                let made = makeChild(child)
                reportTopLevel(made)
                return made
            }
        }

        let totalSize = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let totalCount = children.reduce(0) { $0 + $1.itemCount }

        guard keepChildren else {
            return SpaceNode(id: path, name: name, path: path, isDirectory: true, isPackage: isPackage, sizeBytes: totalSize, itemCount: totalCount)
        }

        children.sort { $0.sizeBytes > $1.sizeBytes }
        var kept: [SpaceNode] = []
        var otherSize: Int64 = 0
        var otherCount = 0
        var otherEntries = 0
        for child in children {
            if child.sizeBytes >= keepThreshold && kept.count < maxChildren {
                kept.append(child)
            } else {
                otherSize += child.sizeBytes
                otherCount += child.itemCount
                otherEntries += 1
            }
        }
        if otherEntries > 0 && otherSize > 0 {
            kept.append(SpaceNode(
                id: path + "#other",
                name: "\(otherEntries) smaller item\(otherEntries == 1 ? "" : "s")",
                path: path,
                isDirectory: false,
                isAggregate: true,
                sizeBytes: otherSize,
                itemCount: otherCount
            ))
        }

        return SpaceNode(
            id: path, name: name, path: path,
            isDirectory: true, isPackage: isPackage,
            sizeBytes: totalSize, itemCount: totalCount,
            children: kept
        )
    }
}

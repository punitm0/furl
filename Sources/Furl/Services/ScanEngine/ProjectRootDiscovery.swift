import Foundation

/// Finds the user's projects in the home index, so worktree, dev-artifact and .DS_Store scans need no
/// hand-picked folders. Pure index queries: no extra disk walk, and it follows the index's FSEvents updates.
enum ProjectRootDiscovery {
    /// Files that mark a project folder. Kept in the index regardless of size (see `RetainRule`).
    /// `.git` is a *file* in linked worktrees and submodules; repos have a `.git` folder.
    static let markerFileNames: Set<String> = [
        ".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile",
        "pom.xml", "build.gradle", "build.gradle.kts"
    ]
    /// Folder markers: a repository's `.git`, and Xcode projects (packages, so they're single records).
    private static let markerDirNames: Set<String> = [".git"]
    private static let markerDirExtensions: Set<String> = ["xcodeproj", "xcworkspace"]
    /// Top-level home folders that never hold the user's projects.
    private static let skippedTopLevel: Set<String> = ["Library", ".Trash", "Applications"]

    /// Project folders under `index`'s root, outermost first, minus anything inside `excluded`.
    /// A project nested inside another project (packages of a monorepo, worktrees inside a repo) is
    /// dropped: the outer root already covers it in every scan.
    static func discover(in index: FileIndex, excluded: [String] = []) -> [String] {
        roots(in: index, excluded: excluded, within: nil, gitOnly: false)
    }

    /// Outermost Git checkouts (a `.git` folder or file) inside `within` — what `WorktreeScanner` used to
    /// find by walking each root to depth 4. Like that walk, it doesn't look for repos inside a repo.
    static func gitRepositories(in index: FileIndex, within roots: [String], excluded: [String] = []) -> [String] {
        self.roots(in: index, excluded: excluded, within: roots, gitOnly: true)
    }

    private static func roots(in index: FileIndex, excluded: [String], within: [String]?, gitOnly: Bool) -> [String] {
        let inScope = within.map { index.inclusionMask(roots: $0) }
        let excludedIDs = Set(excluded.compactMap { index.dirID(forPath: $0) })
        // Folders we never look into: ~/Library, the Trash, hidden tool folders in home (~/.npm, ~/.cargo,
        // ~/.vscode…), size-only folders (node_modules, packages, .git), user exclusions.
        let blocked = index.exclusionMask { id, record in
            if excludedIDs.contains(id) { return true }
            guard id != FileIndex.rootID else { return false }
            if record.mode != .indexed { return true }
            if record.parent == FileIndex.rootID {
                let name = index.dirName(id)
                return skippedTopLevel.contains(name) || name.hasPrefix(".")
            }
            return false
        }

        var isProject = [Bool](repeating: false, count: index.dirs.count)
        for (id, record) in index.dirs.enumerated() where id != Int(FileIndex.rootID) {
            let parent = Int(record.parent)
            guard parent > Int(FileIndex.rootID), !blocked[parent] else { continue }
            let name = index.name(record.name)
            if markerDirNames.contains(name) || (!gitOnly && markerDirExtensions.contains((name as NSString).pathExtension)) {
                isProject[parent] = true
            }
        }
        for file in index.files {
            let dir = Int(file.dir)
            guard dir != Int(FileIndex.rootID), !blocked[dir], !isProject[dir] else { continue }
            let name = index.name(file.name)
            if gitOnly ? name == ".git" : markerFileNames.contains(name) { isProject[dir] = true }
        }

        // Keep outermost projects only (parent ids are smaller, so ancestors are decided first).
        var insideProject = [Bool](repeating: false, count: index.dirs.count)
        var roots: [String] = []
        for id in 0..<index.dirs.count {
            let parent = Int(index.dirs[id].parent)
            let ancestorIsProject = parent >= 0 && (insideProject[parent] || isProject[parent])
            insideProject[id] = ancestorIsProject
            if isProject[id] && !ancestorIsProject && !blocked[id] && (inScope?[id] ?? true) {
                roots.append(index.path(ofDir: Int32(id)))
            }
        }
        return roots.sorted()
    }
}

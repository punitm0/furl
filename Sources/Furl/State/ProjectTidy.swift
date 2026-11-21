import Foundation

/// "Tidy project" (WorktreesShortcuts board): the rebuildable folders inside one folder the user picked.
/// Only folders that come back with an install or a build, never source files or `.env`. The walk never
/// follows symlinks and every result stays inside the chosen folder.
///
/// Inside a git repo a folder must be ignored by git (so nothing tracked is ever touched). Generic
/// names like `dist` or `build` are only offered there, next to the manifest that builds them; outside
/// a repo only names that can't mean anything else are offered.
enum ProjectTidy {

    struct Folder: Equatable, Sendable {
        var path: String
        var name: String
        /// Board copy after the name: "build output", "cache", or the project folder for node_modules.
        var detail: String
        var bytes: Int64
    }

    enum Kind: Sendable { case dependencies, buildOutput, cache }

    struct Rule: Sendable {
        var kind: Kind
        /// One of these must sit next to the folder (nil: no manifest needed).
        var manifests: [String]?
        /// True for names that could be ordinary folders: only offered when git ignores them.
        var needsGit: Bool
    }

    static let rules: [String: Rule] = [
        "node_modules": Rule(kind: .dependencies, manifests: ["package.json"], needsGit: false),
        ".next": Rule(kind: .buildOutput, manifests: nil, needsGit: false),
        ".nuxt": Rule(kind: .buildOutput, manifests: nil, needsGit: false),
        ".svelte-kit": Rule(kind: .buildOutput, manifests: nil, needsGit: false),
        ".turbo": Rule(kind: .cache, manifests: nil, needsGit: false),
        ".parcel-cache": Rule(kind: .cache, manifests: nil, needsGit: false),
        "__pycache__": Rule(kind: .cache, manifests: nil, needsGit: false),
        ".pytest_cache": Rule(kind: .cache, manifests: nil, needsGit: false),
        "dist": Rule(kind: .buildOutput, manifests: ["package.json"], needsGit: true),
        "build": Rule(kind: .buildOutput, manifests: ["package.json"], needsGit: true),
        "target": Rule(kind: .buildOutput, manifests: ["Cargo.toml"], needsGit: true),
    ]

    /// Folders never walked into.
    private static let skipped: Set<String> = [".git", "Library", ".Trash"]
    private static let maxDepth = 12

    enum RootProblem: Equatable { case notAFolder, tooBroad, protected }

    /// Refuses a missing folder, a symlink, the home folder or anything above it, and protected paths.
    static func check(root: String, home: String = NSHomeDirectory(),
                      isProtected: (String) -> Bool = DeletionService.isProtected) -> RootProblem? {
        let url = URL(fileURLWithPath: root)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return .notAFolder }
        let path = url.standardizedFileURL.path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
        if path == "/" || path == homePath || homePath.hasPrefix(path + "/") { return .tooBroad }
        if isProtected(path) { return .protected }
        return nil
    }

    /// `isIgnored(path)` answers for one folder: true when git ignores it, false when git tracks or
    /// doesn't ignore it, nil when it isn't in a repo (or git couldn't tell).
    static func find(in root: String, isIgnored: (String) -> Bool? = gitIgnores,
                     isProtected: (String) -> Bool = DeletionService.isProtected,
                     size: (URL) -> Int64 = { FileSizeHelper.directorySize(at: $0) }) -> [Folder] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let rootPath = rootURL.path
        let fm = FileManager.default
        // The enumerator never descends into symlinked folders; links themselves are skipped below.
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [.skipsPackageDescendants]) else { return [] }
        var found: [Folder] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if skipped.contains(name) || enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let rule = rules[name] else { continue }
            enumerator.skipDescendants()
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/"), !isProtected(path) else { continue }
            let parent = url.deletingLastPathComponent()
            if let manifests = rule.manifests,
               !manifests.contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                continue
            }
            switch isIgnored(path) {
            case .some(false): continue
            case .none where rule.needsGit: continue
            default: break
            }
            let bytes = size(url)
            guard bytes > 0 else { continue }
            found.append(Folder(path: path, name: name, detail: detail(rule.kind, parent: parent.path), bytes: bytes))
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    private static func detail(_ kind: Kind, parent: String) -> String {
        switch kind {
        case .dependencies: return (parent as NSString).abbreviatingWithTildeInPath
        case .buildOutput: return "build output"
        case .cache: return "cache"
        }
    }

    /// `git check-ignore` from the folder's parent. Tracked files are never reported as ignored.
    static func gitIgnores(_ path: String) -> Bool? {
        let url = URL(fileURLWithPath: path)
        let out = ShellRunner.git(["check-ignore", "-q", "--", url.lastPathComponent],
                                  in: url.deletingLastPathComponent().path, timeout: 10)
        guard !out.timedOut else { return false }
        switch out.exitCode {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    // MARK: - Copy (WorktreesShortcuts board, "Tidy project · confirm" and Results)

    static func confirmTitle(bytes: Int64, project: String) -> String {
        "Move \(FileSizeHelper.formatBytes(bytes)) from \(project) to the Trash?"
    }

    static let confirmBody = "These come back when you run npm install or build again. You can undo this in Furl."
    static let confirmFooter = "Only Safe folders. Source files and .env are never touched."

    static func confirmLine(_ folder: Folder) -> String {
        "\(folder.name) · \(folder.detail) · Safe · \(FileSizeHelper.formatBytes(folder.bytes))"
    }

    static func acceptLabel(bytes: Int64) -> String { "Move \(FileSizeHelper.formatBytes(bytes)) to Trash" }

    @MainActor
    static func resultText(bytes: Int64, project: String, skipped: Int) -> String {
        AppState.withSkipped("Moved \(FileSizeHelper.formatBytes(bytes)) from \(project) to the Trash.", skipped)
    }

    static func nothingText(project: String) -> String {
        "Nothing to tidy in \(project). It has no rebuildable folders."
    }
}

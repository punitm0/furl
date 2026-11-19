import Foundation

enum WorktreeScanner {
    static func defaultSearchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Documents/projects",
            "\(home)/Projects",
            "\(home)/Developer",
            "\(home)/Code",
            "\(home)/Documents",
            "\(home)/src"
        ]
        let fm = FileManager.default
        var roots: [String] = []
        for path in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                if path == "\(home)/Documents", roots.contains("\(home)/Documents/projects") {
                    continue
                }
                roots.append(path)
            }
        }
        return roots
    }

    /// `emit` gets each repository's worktrees as soon as that repository is inspected.
    static func scan(roots: [String], progress: ScanProgress? = nil,
                     emit: (@Sendable ([WorktreeItem]) -> Void)? = nil) -> [WorktreeItem] {
        // Captured here: the task-local index isn't visible on concurrentPerform's threads.
        let index = ScanIndexContext.index
        // Repos under roots the home index covers come straight from it; other roots are walked.
        let indexed = index.map { idx in roots.filter { idx.covers($0) && idx.dirID(forPath: $0) != nil } } ?? []
        let repoPaths = (index.map { ProjectRootDiscovery.gitRepositories(in: $0, within: indexed) } ?? [])
            + discoverGitRepos(in: roots.filter { !indexed.contains($0) }, maxDepth: 4)

        // 1. Ask each discovered checkout for its worktree list (in parallel), then keep one per main repo.
        let lock = NSLock()
        nonisolated(unsafe) var listings: [(order: Int, entries: [PorcelainEntry])] = []
        DispatchQueue.concurrentPerform(iterations: repoPaths.count) { i in
            let out = ShellRunner.git(["worktree", "list", "--porcelain"], in: repoPaths[i])
            guard out.exitCode == 0 else { return }
            let parsed = parsePorcelain(out.stdout)
            lock.lock(); listings.append((i, parsed)); lock.unlock()
        }
        var seenMainRepos = Set<String>()
        var repos: [[PorcelainEntry]] = []
        for listing in listings.sorted(by: { $0.order < $1.order }) {
            guard let main = listing.entries.first?.path, !main.isEmpty, seenMainRepos.insert(main).inserted else { continue }
            repos.append(listing.entries)
        }

        // 2. Inspect repos in parallel (each one also checks its worktrees in parallel).
        let repoList = repos
        nonisolated(unsafe) var inspected: [WorktreeItem] = []
        progress?.setPhase("Checking worktrees")
        progress?.setSteps(done: 0, total: repoList.count)
        DispatchQueue.concurrentPerform(iterations: repoList.count) { i in
            if progress?.isCancelled == true { return }
            let items = inspectWorktrees(parsed: repoList[i], index: index)
            progress?.advanceStep()
            lock.lock(); inspected.append(contentsOf: items); lock.unlock()
            if !items.isEmpty { emit?(items) }
        }

        var results: [WorktreeItem] = []
        var seenWorktreePaths = Set<String>()
        for item in inspected where seenWorktreePaths.insert(item.worktreePath).inserted {
            results.append(item)
        }

        return results.sorted { lhs, rhs in
            if lhs.canAutoSelect != rhs.canAutoSelect {
                return lhs.canAutoSelect && !rhs.canAutoSelect
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    private static func discoverGitRepos(in roots: [String], maxDepth: Int) -> [String] {
        let fm = FileManager.default
        var repos: [String] = []
        var visited = Set<String>()

        func walk(_ dirURL: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            let standardized = dirURL.standardizedFileURL.path
            guard !visited.contains(standardized) else { return }
            visited.insert(standardized)

            let gitMarker = dirURL.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitMarker.path) {
                repos.append(standardized)
                return
            }

            let skipNames: Set<String> = [
                "node_modules", ".venv", "venv", "dist", "build", ".next",
                ".turbo", "target", "DerivedData", ".Trash", "Library"
            ]

            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for child in children {
                let name = child.lastPathComponent
                if skipNames.contains(name) { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else { continue }
                walk(child, depth: depth + 1)
            }
        }

        for root in roots {
            walk(URL(fileURLWithPath: root), depth: 0)
        }

        return repos
    }

    private static func inspectWorktrees(parsed: [PorcelainEntry], index: FileIndex?) -> [WorktreeItem] {
        guard let mainRepoPath = parsed.first?.path, !mainRepoPath.isEmpty else { return [] }

        // Skip single-worktree repos unless they have prunable entries
        if parsed.count <= 1 && parsed.allSatisfy({ !$0.isPrunable }) {
            return []
        }

        let baseBranch = detectDefaultBranch(in: mainRepoPath)
        let mergedBranches = detectMergedBranches(in: mainRepoPath, baseBranch: baseBranch)
        let baseHeadOut = ShellRunner.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(baseBranch)"], in: mainRepoPath)
        let baseHead = baseHeadOut.exitCode == 0 ? baseHeadOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let repoName = URL(fileURLWithPath: mainRepoPath).lastPathComponent

        let lock = NSLock()
        nonisolated(unsafe) var slots = [WorktreeItem?](repeating: nil, count: parsed.count)
        DispatchQueue.concurrentPerform(iterations: parsed.count) { position in
            let entry = parsed[position]
            let isMain = (position == 0) || (entry.path == mainRepoPath)
            let branch = entry.branch ?? "HEAD"
            let exists = FileManager.default.fileExists(atPath: entry.path)

            let isDirty: Bool
            if exists && !entry.isPrunable {
                // If git can't prove it's clean (unsafe repo config, failure, timeout): treat it as dirty.
                let status = ShellRunner.gitStatusPorcelain(in: entry.path)
                isDirty = status.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
            } else {
                isDirty = false
            }

            let lastDate = fetchLastCommitDate(in: exists ? entry.path : mainRepoPath, commit: entry.head)

            let mergeStatus: WorktreeMergeStatus
            if isMain {
                mergeStatus = .main
            } else if entry.branch == nil {
                mergeStatus = .detached
            } else if branch == baseBranch {
                mergeStatus = .main
            } else if mergedBranches.contains(branch) {
                mergeStatus = .merged
            } else if isSquashMerged(branch: branch, baseBranch: baseBranch, repoPath: mainRepoPath) {
                mergeStatus = .squashMerged
            } else {
                mergeStatus = .unmerged
            }

            let size: Int64 = exists
                ? (index?.reclaimableSize(ofPath: entry.path) ?? FileSizeHelper.directorySize(at: URL(fileURLWithPath: entry.path)))
                : 0

            let item = WorktreeItem(
                id: entry.path,
                repoPath: mainRepoPath,
                repoName: repoName,
                worktreePath: entry.path,
                branchName: branch,
                baseBranch: baseBranch,
                commitHash: String(entry.head.prefix(7)),
                lastCommitDate: lastDate,
                mergeStatus: mergeStatus,
                isDirty: isDirty,
                isLocked: entry.isLocked,
                isPrunable: entry.isPrunable || !exists,
                sizeBytes: size,
                pointsAtBaseTip: !isMain && !baseHead.isEmpty && entry.head == baseHead
            )
            lock.lock(); slots[position] = item; lock.unlock()
        }
        return slots.compactMap { $0 }
    }

    private struct PorcelainEntry {
        var path: String = ""
        var head: String = ""
        var branch: String?
        var isLocked: Bool = false
        var isPrunable: Bool = false
    }

    private static func parsePorcelain(_ output: String) -> [PorcelainEntry] {
        var entries: [PorcelainEntry] = []
        var current = PorcelainEntry()

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.path.isEmpty {
                    entries.append(current)
                    current = PorcelainEntry()
                }
                continue
            }

            if line.hasPrefix("worktree ") {
                current.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                current.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                current.branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "locked" || line.hasPrefix("locked ") {
                current.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current.isPrunable = true
            }
        }

        if !current.path.isEmpty {
            entries.append(current)
        }
        return entries
    }

    private static func detectDefaultBranch(in repoPath: String) -> String {
        let originHead = ShellRunner.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoPath)
        if originHead.exitCode == 0 {
            let trimmed = originHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("origin/") {
                return String(trimmed.dropFirst("origin/".count))
            }
        }

        for candidate in ["main", "master", "develop"] {
            let check = ShellRunner.git(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: repoPath)
            if check.exitCode == 0 {
                return candidate
            }
        }
        return "main"
    }

    private static func detectMergedBranches(in repoPath: String, baseBranch: String) -> Set<String> {
        let out = ShellRunner.git(["branch", "--merged", baseBranch, "--format=%(refname:short)"], in: repoPath)
        guard out.exitCode == 0 else { return [] }
        let lines = out.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(lines)
    }

    /// Local-only: no network. (A GitHub PR lookup via `gh` used to run here; the app makes no network calls apart from anonymous community totals.)
    private static func isSquashMerged(branch: String, baseBranch: String, repoPath: String) -> Bool {
        // 1. Check git cherry: if all commits have '-' (equivalent patch in baseBranch), it's rebase/cherry-merged
        let cherry = ShellRunner.git(["cherry", baseBranch, branch], in: repoPath)
        if cherry.exitCode == 0 {
            let lines = cherry.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty && lines.allSatisfy({ $0.hasPrefix("-") }) {
                return true
            }
        }

        // 2. True local squash-merge detection via synthetic single-commit tree comparison:
        // Create a temporary commit with `branch`'s tree parented on `merge-base(baseBranch, branch)`
        // and check if `git cherry baseBranch <tempCommit>` marks it as '-' (already applied in baseBranch).
        let mergeBaseOut = ShellRunner.git(["merge-base", baseBranch, branch], in: repoPath)
        let treeOut = ShellRunner.git(["rev-parse", "\(branch)^{tree}"], in: repoPath)
        if mergeBaseOut.exitCode == 0, treeOut.exitCode == 0 {
            let mergeBase = mergeBaseOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let tree = treeOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mergeBase.isEmpty, !tree.isEmpty {
                let commitTreeOut = ShellRunner.git(["commit-tree", tree, "-p", mergeBase, "-m", "sweepmac-squash-check"], in: repoPath)
                if commitTreeOut.exitCode == 0 {
                    let tempCommit = commitTreeOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let squashCherry = ShellRunner.git(["cherry", baseBranch, tempCommit], in: repoPath)
                    if squashCherry.exitCode == 0,
                       squashCherry.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func fetchLastCommitDate(in path: String, commit: String) -> Date? {
        guard !commit.isEmpty else { return nil }
        let out = ShellRunner.git(["show", "-s", "--no-show-signature", "--format=%ct", commit], in: path)
        guard out.exitCode == 0,
              let timestamp = TimeInterval(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    struct RemovalOutcome: Sendable {
        let reclaimedBytes: Int64
        let warning: String?
    }

    static func removeWorktree(item: WorktreeItem, force: Bool, deleteLocalBranch: Bool) -> Result<RemovalOutcome, Error> {
        let fm = FileManager.default
        if item.isPrunable || !fm.fileExists(atPath: item.worktreePath) {
            _ = ShellRunner.git(["worktree", "prune"], in: item.repoPath)
        } else {
            // `--force` deletes for good, so the same guard as every other deletion applies.
            guard !DeletionService.isProtected(item.worktreePath) else {
                return .failure(NSError(domain: "Furl.Worktree", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Refused: \(item.worktreePath) is a protected folder"
                ]))
            }
            var args = ["worktree", "remove"]
            if force {
                args.append("--force")
            }
            args.append(item.worktreePath)

            let out = ShellRunner.git(args, in: item.repoPath, timeout: 300)
            if out.exitCode != 0 {
                let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(NSError(domain: "Furl.Worktree", code: Int(out.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: msg.isEmpty ? "Failed to remove worktree" : msg
                ]))
            }
        }

        var warning: String?
        if deleteLocalBranch && item.mergeStatus != .detached && item.branchName != "HEAD" {
            // Only squash-merged branches get -D (git -d can't see squash merges). Everything else uses -d,
            // which git refuses for unmerged work — "Allow dirty worktrees" must never force-delete a branch.
            let branchFlag = item.mergeStatus == .squashMerged ? "-D" : "-d"
            let out = ShellRunner.git(["branch", branchFlag, item.branchName], in: item.repoPath)
            if out.exitCode != 0 {
                let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                warning = "Worktree removed but branch '\(item.branchName)' was kept: \(msg.isEmpty ? "git branch failed" : msg)"
            }
        }

        _ = ShellRunner.git(["worktree", "prune"], in: item.repoPath)
        return .success(RemovalOutcome(reclaimedBytes: item.sizeBytes, warning: warning))
    }

    static func pruneStaleWorktrees(in repoPaths: [String]) {
        for repo in Set(repoPaths) {
            _ = ShellRunner.git(["worktree", "prune"], in: repo)
        }
    }
}

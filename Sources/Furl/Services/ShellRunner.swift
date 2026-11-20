import Foundation

struct ShellOutput: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var timedOut: Bool = false
    /// Output arrived but wasn't valid UTF-8, so `stdout` is empty. Never read that as "nothing".
    var stdoutUndecodable: Bool = false
}

enum ShellRunner {
    /// Directories GUI apps don't see in PATH when launched from Finder/Dock.
    private static let extraSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin"
    ]

    private static var augmentedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged = existing
        for path in extraSearchPaths where !merged.contains(path) {
            merged.append(path)
        }
        env["PATH"] = merged.joined(separator: ":")
        // Never let git/gh block waiting for credentials or an editor.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }

    static func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 60
    ) -> ShellOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = augmentedEnvironment
        process.standardInput = FileHandle.nullDevice
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ShellOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        group.wait()

        let decoded = String(data: stdoutData, encoding: .utf8)
        return ShellOutput(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdout: decoded ?? "",
            stderr: timedOut ? "Timed out after \(Int(timeout))s" : (String(data: stderrData, encoding: .utf8) ?? ""),
            timedOut: timedOut,
            stdoutUndecodable: decoded == nil && !stdoutData.isEmpty
        )
    }

    /// Starts a program and returns without waiting; it keeps running after Furl quits (used only to
    /// reopen Furl after an update). Arguments go in as an array, never through a shell string.
    @discardableResult
    static func launchDetached(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Resolves a binary by checking well-known install locations first, then `which`.
    static func which(_ binary: String) -> String? {
        let fm = FileManager.default
        for dir in extraSearchPaths {
            let candidate = "\(dir)/\(binary)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let result = run("/usr/bin/which", arguments: [binary], timeout: 5)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !path.isEmpty ? path : nil
    }

    /// Path to git; prefers /usr/bin/git (Xcode CLT shim), falls back to Homebrew.
    static let gitPath: String = {
        let fm = FileManager.default
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    /// Repos Furl finds on disk can come from anywhere (an unzipped download, a cloned project), and a
    /// repo's own config can name programs git will run: an fsmonitor hook, hooks, a signature checker.
    /// These overrides take precedence over any repo config, and git passes them on to submodule processes.
    /// Filter and diff drivers have no global off switch, so `repoConfigRunsNoPrograms` covers those.
    private static let gitHardening = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.untrackedCache=false",
        "-c", "log.showSignature=false",
        "-c", "commit.gpgSign=false",
        "-c", "gpg.program=/usr/bin/false",
        "-c", "gpg.ssh.program=/usr/bin/false",
        "-c", "gpg.x509.program=/usr/bin/false",
    ]

    static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 60) -> ShellOutput {
        run(gitPath, arguments: gitHardening + arguments, workingDirectory: directory, timeout: timeout)
    }

    /// True when the repo's own config names no program `git status` could run. It reads the local and
    /// per-worktree scopes (`config.worktree`) with includes followed; reading config runs nothing. The
    /// user's system and global config are trusted. A repo with a local `filter.lfs` section (from
    /// `git lfs install --local`) counts as unsafe and so is never offered for cleanup.
    static func repoConfigRunsNoPrograms(in directory: String) -> Bool {
        let out = run(gitPath,
                      arguments: ["config", "--list", "--show-scope", "--includes", "--name-only"],
                      workingDirectory: directory, timeout: 10)
        // A broken config or a timeout is not safe.
        guard out.exitCode == 0 else { return false }
        let risky = try! NSRegularExpression(
            pattern: #"^(filter\..*|diff\.external|diff\..*\.(textconv|command))$"#,
            options: [.caseInsensitive])
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == "local" || parts[0] == "worktree" else { continue }
            let key = String(parts[1])
            if risky.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil { return false }
        }
        return true
    }

    /// True when the index holds a submodule (a gitlink) or the tree has a `.gitmodules` file. A
    /// submodule's own config is never checked, so status skips submodules and callers treat such a repo
    /// as dirty rather than miss work inside one.
    private static func hasSubmodules(in directory: String) -> Bool {
        if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".gitmodules")) {
            return true
        }
        let out = git(["ls-files", "--stage"], in: directory, timeout: 30)
        guard out.exitCode == 0 else { return true }
        return out.stdout.split(separator: "\n").contains { $0.hasPrefix("160000 ") }
    }

    /// True when some tracked file is marked assume-unchanged (a lowercase tag in `ls-files -v`) or
    /// skip-worktree (`S`). Status doesn't look at those files, so edits to them would go unseen.
    private static func hasHiddenEdits(in directory: String) -> Bool {
        let out = git(["ls-files", "-v"], in: directory, timeout: 30)
        guard out.exitCode == 0 else { return true }
        return out.stdout.split(separator: "\n").contains { line in
            guard let tag = line.first else { return false }
            return tag == "S" || tag.isLowercase
        }
    }

    /// `git status --porcelain` output, or nil when git can't prove anything: the repo's config names a
    /// program git might run, it has submodules or files status skips, or status failed or timed out.
    /// Callers treat nil as "dirty". Untracked files are always listed, whatever `status.showUntrackedFiles`
    /// says, because `git worktree remove` deletes them.
    ///
    /// `everyFile` lists each untracked file on its own (not just its new folder) as NUL-separated
    /// `-z` output, for anything that shows or counts what would be lost.
    static func gitStatusPorcelain(in directory: String, timeout: TimeInterval = 60, everyFile: Bool = false) -> String? {
        guard repoConfigRunsNoPrograms(in: directory), !hasSubmodules(in: directory),
              !hasHiddenEdits(in: directory) else { return nil }
        let listing = everyFile ? ["--untracked-files=all", "-z"] : ["--untracked-files=normal"]
        let status = git(["status", "--porcelain"] + listing + ["--ignore-submodules=all"],
                         in: directory, timeout: timeout)
        return status.exitCode == 0 && !status.stdoutUndecodable ? status.stdout : nil
    }
}

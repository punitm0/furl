import Foundation

/// Removes developer tools. Everything is checked again right before it goes: versions are re-read
/// against every project, default and running program; Homebrew kegs and packages are re-listed. A
/// tool that keeps its own records (rustup, Homebrew, npm, pipx…) removes its own things, run through
/// `ShellRunner` with an argument array.
enum DevToolsRemover {
    struct Outcome: Sendable {
        var removedNames: [String] = []
        var removedPaths: [String] = []
        var freedBytes: Int64 = 0
        var skipped = 0
        var errors: [String] = []
    }

    // MARK: - Versions

    /// The picked versions that are still unused now, as freshly read. Anything that changed (a project
    /// now asks for it, it became the default, something from it is running, it moved) is dropped.
    static func recheckVersions(_ picks: [DevVersion], projectRoots: [String], kept: Set<String>,
                                paths: DevToolsPaths = .current) -> (ok: [DevVersion], skipped: Int) {
        let requests = projectRoots.flatMap { VersionFiles.requests(inProject: $0) }
        let fresh = DevToolsScanner.classify(
            DevToolsScanner.installedVersions(paths: paths), requests: requests,
            defaults: DevToolsScanner.defaults(paths: paths), pythonUsers: DevToolsScanner.pythonUsers(paths: paths),
            running: DevToolsScanner.runningExecutables(), kept: kept, paths: paths)
        let byPath = Dictionary(fresh.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var ok: [DevVersion] = []
        for pick in picks {
            guard let now = byPath[pick.path], now.isRemovable, now.manager == pick.manager,
                  isSafeFolder(pick.path) else { continue }
            var v = now
            v.sizeBytes = pick.sizeBytes
            ok.append(v)
        }
        return (ok, picks.count - ok.count)
    }

    /// A real folder (no link anywhere in its path), not protected.
    static func isSafeFolder(_ path: String) -> Bool {
        DevToolsScanner.isRealDirectory(path) && DevToolsScanner.realpathOrSelf(path) == path
            && !DeletionService.isProtected(path)
    }

    /// `rustup toolchain uninstall <name>` for re-checked toolchains. Permanent.
    static func uninstallToolchains(_ toolchains: [DevVersion], paths: DevToolsPaths = .current) -> Outcome {
        var outcome = Outcome()
        let rustup = paths.cargo + "/bin/rustup"
        guard FileManager.default.isExecutableFile(atPath: rustup) else {
            outcome.errors.append("rustup isn’t where Furl expected it, so nothing was removed.")
            return outcome
        }
        for t in toolchains where t.manager == .rustup {
            guard VersionFiles.isPlainName(t.folderName), !t.folderName.contains("/") else { outcome.skipped += 1; continue }
            let out = DevToolsShell.run(rustup, ["toolchain", "uninstall", t.folderName], timeout: 300)
            if !DevToolsScanner.fileExistsNoFollow(t.path) {
                outcome.removedNames.append(t.displayName)
                outcome.removedPaths.append(t.path)
                outcome.freedBytes += t.sizeBytes
            } else {
                outcome.errors.append("\(t.displayName): \(tail(out))")
            }
        }
        return outcome
    }

    // MARK: - Homebrew

    /// `brew cleanup <formulae>` for formulae whose older kegs are still there, the linked keg is still
    /// the newest and the formula still isn't pinned. Reports only kegs that are really gone afterwards.
    static func brewCleanup(_ picks: [BrewOldVersions], prefix: String) -> Outcome {
        var outcome = Outcome()
        let cellar = prefix + "/Cellar"
        let now = Dictionary(DevToolsScanner.formulae(prefix: prefix).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String] = []
        var watched: [(formula: String, path: String, bytes: Int64)] = []
        for pick in picks {
            guard DevToolsScanner.isFormulaName(pick.formula), let f = now[pick.formula],
                  let fresh = DevToolsScanner.oldVersions(of: f, cellar: cellar),
                  fresh.linkedVersion == pick.linkedVersion else { outcome.skipped += 1; continue }
            names.append(pick.formula)
            for path in fresh.oldPaths {
                watched.append((pick.formula, path, FileSizeHelper.directorySize(at: URL(fileURLWithPath: path))))
            }
        }
        guard !names.isEmpty else { return outcome }
        let out = DevToolsShell.run(DevToolsScanner.brewBinary(prefix: prefix), ["cleanup"] + names, timeout: 600)
        var cleaned = Set<String>()
        for w in watched where !DevToolsScanner.fileExistsNoFollow(w.path) {
            outcome.removedPaths.append(w.path)
            outcome.freedBytes += w.bytes
            cleaned.insert(w.formula)
        }
        outcome.removedNames = names.filter(cleaned.contains)
        if out.exitCode != 0 || cleaned.count < names.count {
            let left = names.filter { !cleaned.contains($0) }
            if !left.isEmpty {
                outcome.errors.append("Homebrew kept older versions of \(left.joined(separator: ", ")). \(tail(out))")
            }
        }
        return outcome
    }

    /// `brew uninstall <name>` (never forced, so Homebrew itself refuses if something needs it) for
    /// formulae that are still leaves on a fresh read.
    static func brewUninstall(_ picks: [BrewLeaf], prefix: String, projectRoots: [String]) -> Outcome {
        var outcome = Outcome()
        let all = DevToolsScanner.formulae(prefix: prefix)
        let brewfiles = Set(projectRoots.flatMap(DevToolsScanner.brewfileFormulae))
        let homes = DevToolsScanner.pythonUsers(paths: .current).map(\.home)
        let leaves = Set(DevToolsScanner.leafFormulae(all, cellar: prefix + "/Cellar", projectFormulae: brewfiles,
                                                      pythonHomes: homes).map(\.name))
        for pick in picks {
            guard DevToolsScanner.isFormulaName(pick.name), leaves.contains(pick.name) else { outcome.skipped += 1; continue }
            let out = DevToolsShell.run(DevToolsScanner.brewBinary(prefix: prefix), ["uninstall", pick.name], timeout: 300)
            if !DevToolsScanner.fileExistsNoFollow(pick.path) {
                outcome.removedNames.append(pick.name)
                outcome.removedPaths.append(pick.path)
                outcome.freedBytes += pick.sizeBytes
            } else {
                outcome.errors.append("\(pick.name): \(tail(out))")
            }
        }
        return outcome
    }

    // MARK: - Global packages

    /// Each package manager's own uninstall, for packages still installed on a fresh read.
    static func uninstallPackages(_ picks: [GlobalPackage], paths: DevToolsPaths = .current) -> Outcome {
        var outcome = Outcome()
        let fresh = Dictionary(DevToolsScanner.globalPackages(paths: paths).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for pick in picks {
            guard let now = fresh[pick.id], now.tool == pick.tool,
                  DevToolsScanner.isPackageName(pick.name, manager: pick.manager) else { outcome.skipped += 1; continue }
            let args: [String]
            switch pick.manager {
            case .npm: args = ["uninstall", "-g", "--offline", "--no-audit", "--no-fund", pick.name]
            // Offline: removing never needs the registry, and Furl adds no network calls.
            case .pnpm: args = ["remove", "-g", "--offline", pick.name]
            // Checked with the registry unreachable: bun removes from its global manifest without it.
            case .bun: args = ["remove", "-g", pick.name]
            case .pipx: args = ["uninstall", pick.name]
            case .cargo: args = ["uninstall", pick.name]
            }
            let out = DevToolsShell.run(now.tool, args, timeout: 300)
            let gone: Bool
            if let path = now.path {
                gone = !DevToolsScanner.fileExistsNoFollow(path)
            } else {
                gone = out.exitCode == 0
            }
            if gone {
                outcome.removedNames.append(pick.name)
                if let path = now.path { outcome.removedPaths.append(path) }
                outcome.freedBytes += pick.sizeBytes
            } else {
                outcome.errors.append("\(pick.name): \(tail(out))")
            }
        }
        return outcome
    }

    /// The last line or two a tool printed, for the error banner.
    static func tail(_ out: ShellOutput) -> String {
        let text = (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n").suffix(2).joined(separator: " ")
        if lines.isEmpty { return out.timedOut ? "It took too long and was stopped." : "It stopped with exit code \(out.exitCode)." }
        return String(lines.prefix(300))
    }
}

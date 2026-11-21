import Foundation

/// Why? popovers for Apps & Leftovers › Developer tools (DevTools board). Furl only claims what it
/// can prove: no project asks for a version. It never says you haven't used something.
extension WhySafe {
    // MARK: - Language versions

    static func devVersionTier(_ v: DevVersion) -> RiskTier? {
        guard v.isRemovable else { return nil }
        return v.goesToTrash ? .checkFirst : .permanent
    }

    /// The line under a version's name.
    static func devVersionSubtitle(_ v: DevVersion) -> String {
        switch v.status {
        case .unused:
            let notDefault = "not \(defaultNoun(v))"
            if v.language == .rust { return "No rust-toolchain file asks for it · \(notDefault)" }
            return "No project asks for it · \(notDefault) · \(v.path.abbreviatingHome)"
        case .inUse(let project, let file):
            return "\(project.abbreviatingHome) asks for it in \(file)"
        case .usedBy(let what):
            return what
        case .isDefault(let reason):
            return reason
        case .running:
            return "Something from it is running now"
        case .kept:
            return "You chose to always keep \(v.keepName)"
        case .unsure(let project, let file):
            if project.isEmpty { return "Furl hasn’t found your projects yet, so it keeps this" }
            return "Furl can’t read \(file) in \(project.abbreviatingHome), so it keeps this"
        }
    }

    /// The badge on a locked row: In use, Default or Kept.
    static func devVersionBadge(_ v: DevVersion) -> String? {
        switch v.status {
        case .unused: return nil
        case .inUse, .usedBy, .running: return "In use"
        case .isDefault: return "Default"
        case .kept, .unsure: return "Kept"
        }
    }

    static func devVersion(_ v: DevVersion, projectCount: Int, deletionMode: DeletionMode) -> WhyExplanation {
        let tool = v.manager.label
        let what: String = {
            switch v.language {
            case .node: return "a Node.js version installed with \(tool)."
            case .python: return "a Python version installed with \(tool)."
            case .rust: return "a Rust toolchain installed with rustup."
            }
        }()
        var lines: [WhyExplanation.Line] = [.init(mark: .info, label: "What it is:", text: what)]
        guard v.isRemovable else {
            lines.append(.init(mark: .good, label: "Why it stays:", text: devVersionSubtitle(v) + "."))
            if v.sizeBytes > 0 {
                lines.append(.init(mark: .info, label: "Size:", text: FileSizeHelper.formatBytes(v.sizeBytes) + "."))
            }
            return WhyExplanation(title: "Why \(v.displayName) stays", tier: nil, lines: lines)
        }
        let projects = projectCount == 1 ? "your 1 project" : "your \(projectCount) projects"
        let wanted = v.language == .rust ? DevToolsNaming.rustChannel(v.folderName) : v.version.prefix(v.language.granularity)
        let files: String = {
            switch v.language {
            case .node: return ".nvmrc, .node-version, .tool-versions or package.json"
            case .python: return ".python-version, pyproject.toml or .tool-versions"
            case .rust: return "rust-toolchain or .tool-versions"
            }
        }()
        lines.append(.init(mark: .info, label: "Why it’s listed:",
                           text: "none of \(projects) asks for \(wanted) in \(files). It isn’t \(defaultNoun(v)), and nothing from it is running."))
        lines.append(.init(mark: .good, label: "How it comes back:",
                           text: "\(v.manager.reinstallHint(language: v.language, version: v.version, name: v.folderName)) downloads it again."))
        if v.goesToTrash {
            let extra = v.language == .node ? " Global packages installed under it go with it."
                : " Packages installed into it go with it."
            var line = goesTo(permanentTool: nil, deletionMode: deletionMode)
            if deletionMode == .moveToTrash { line = .init(mark: .good, label: "Goes to:", text: "the Trash." + extra) }
            lines.append(line)
        } else {
            lines.append(goesTo(permanentTool: "rustup", deletionMode: deletionMode))
        }
        return WhyExplanation(title: "Why \(v.displayName) is listed", tier: devVersionTier(v), lines: lines)
    }

    /// "nvm’s default", "pyenv’s global version", "the default".
    private static func defaultNoun(_ v: DevVersion) -> String {
        v.manager == .pyenv ? "the global version" : "the default"
    }

    // MARK: - Homebrew

    /// "Older 3.12.6 and 3.12.4 still installed · 3.12.8 is the one in use".
    static func brewOldSubtitle(_ o: BrewOldVersions) -> String {
        "Older \(DevToolsCopy.list(o.oldVersions.count <= 2 ? o.oldVersions : [o.oldVersions[0], "\(o.oldVersions.count - 1) more"])) still installed · \(o.linkedVersion) is the one in use"
    }

    static func brewOld(_ o: BrewOldVersions) -> WhyExplanation {
        WhyExplanation(title: "Why older \(o.formula) versions are listed", tier: .permanent, lines: [
            .init(mark: .info, label: "What it is:",
                  text: "\(o.oldVersions.count == 1 ? "an older version" : "older versions") Homebrew kept after upgrading \(o.formula): \(o.oldVersions.joined(separator: ", "))."),
            .init(mark: .good, label: "Why it’s listed:",
                  text: "\(o.linkedVersion) is installed and is the one in use. \(o.formula) isn’t pinned."),
            .init(mark: .bad, label: "How it comes back:",
                  text: "it doesn’t. brew install gets the current version, not these."),
            goesTo(permanentTool: "Homebrew", deletionMode: .permanent)
        ])
    }

    /// "Installed 2 years ago · formula" / "… · a newer postgresql@17 is installed too".
    static func brewLeafSubtitle(_ l: BrewLeaf) -> String {
        let installed = l.installedDate.map { "Installed \(DevToolsCopy.age($0))" } ?? "Install date unknown"
        if let newer = l.newerSibling { return "\(installed) · a newer \(newer) is installed too" }
        return "\(installed) · formula"
    }

    static func brewLeaf(_ l: BrewLeaf) -> WhyExplanation {
        var lines: [WhyExplanation.Line] = [
            .init(mark: .info, label: "What it is:", text: "a Homebrew package you installed yourself (\(l.version))."),
            .init(mark: .good, label: "Why it’s listed:", text: "nothing else installed needs it."),
            .init(mark: .bad, label: "Only you know:",
                  text: "Furl can’t tell when you last used it. macOS keeps no reliable last-used date for command-line tools.")
        ]
        if let date = l.installedDate {
            lines.append(.init(mark: .time, label: "Installed:", text: date.relativeDescription + "."))
        }
        lines.append(.init(mark: .good, label: "How it comes back:", text: "brew install \(l.name)."))
        lines.append(goesTo(permanentTool: "Homebrew", deletionMode: .permanent))
        return WhyExplanation(title: "Why check \(l.name) first", tier: .checkFirst, lines: lines)
    }

    // MARK: - Global packages

    static func packageSubtitle(_ p: GlobalPackage) -> String {
        let installed = p.installedDate.map { "Installed \(DevToolsCopy.age($0))" } ?? "Install date unknown"
        return p.commands.isEmpty ? installed : "\(installed) · \(p.commands.joined(separator: ", "))"
    }

    static func package(_ p: GlobalPackage) -> WhyExplanation {
        let tool = p.manager == .pipx ? "pipx" : p.manager.rawValue
        var lines: [WhyExplanation.Line] = [
            .init(mark: .info, label: "What it is:",
                  text: "a package installed for your whole account with \(tool)"
                      + (p.commands.isEmpty ? "." : ". It adds \(p.commands.joined(separator: ", ")).")),
            .init(mark: .bad, label: "Only you know:",
                  text: "Furl can’t tell when you last ran it. macOS keeps no reliable last-used date for command-line tools.")
        ]
        if let date = p.installedDate {
            lines.append(.init(mark: .time, label: "Installed:", text: date.relativeDescription + "."))
        }
        lines.append(.init(mark: .good, label: "How it comes back:", text: p.manager.installCommand(p.name) + "."))
        lines.append(goesTo(permanentTool: tool, deletionMode: .permanent))
        return WhyExplanation(title: "Why check \(p.name) first", tier: .checkFirst, lines: lines)
    }
}

import Foundation

/// What the "Why?" popover shows for one row (WhySafe board): what it is, how it comes back, when it
/// was last used, where it goes. Every line must be true for that rule; when nothing brings an item
/// back, the copy says so.
struct WhyExplanation: Hashable, Sendable {
    enum Mark: Sendable, Hashable {
        /// Plain fact (info icon, secondary ink).
        case info
        /// Reassuring fact (check icon, Safe green).
        case good
        /// A reason to look first (cross icon, secondary ink).
        case bad
        /// A date (clock icon, secondary ink).
        case time
    }

    struct Line: Hashable, Sendable {
        let mark: Mark
        let label: String
        let text: String
    }

    let title: String
    /// Nil for rows that can't be removed (the main worktree, the copy Furl keeps).
    let tier: RiskTier?
    let lines: [Line]
}

enum WhySafe {
    // MARK: - Caches & Junk

    static func junk(_ item: JunkItem, deletionMode: DeletionMode) -> WhyExplanation {
        let tier = item.risk.tier
        let story = junkStory(item)
        var lines: [WhyExplanation.Line] = [
            .init(mark: .info, label: "What it is:", text: story.what),
            .init(mark: story.comesBack ? .good : .bad, label: "How it comes back:", text: story.back)
        ]
        if let used = item.lastUsedDate {
            lines.append(.init(mark: .time, label: "Last used:", text: used.relativeDescription + "."))
        } else if let changed = item.modifiedDate {
            lines.append(.init(mark: .time, label: "Last changed:", text: changed.relativeDescription + "."))
        }
        lines.append(goesTo(permanentTool: item.command.map(toolName), deletionMode: deletionMode))
        return WhyExplanation(title: title(item.name, tier: tier), tier: tier, lines: lines)
    }

    /// What a junk item is and how it comes back. `comesBack` is false when nothing recreates it.
    static func junkStory(_ item: JunkItem) -> (what: String, back: String, comesBack: Bool) {
        let folder = URL(fileURLWithPath: item.path).lastPathComponent
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent
        switch item.category {
        case .devArtifacts:
            switch item.name {
            case "Xcode build files · DerivedData":
                return ("build files and indexes Xcode makes for your projects.",
                        "Xcode rebuilds it the next time you build. That first build is slower.", true)
            case "Xcode iOS DeviceSupport":
                return ("debug files Xcode copied from iPhones and iPads you connected.",
                        "Xcode copies them again when you debug on that device. It can take a few minutes.", true)
            case "Xcode Archives":
                return ("app builds you archived in Xcode, often the ones you shipped.",
                        "It doesn't. You need an archive to read crash reports from that version.", false)
            case "CoreSimulator Caches":
                return ("data the Simulator saves so it starts faster.",
                        "The Simulator rebuilds it when it starts.", true)
            default:
                return devFolderStory(folder, parent: parent)
            }
        case .packageCaches:
            return packageCacheStory(item.name)
        case .systemCaches:
            return ("a cache folder an app keeps (\(item.name)).",
                    "The app rebuilds it as you use it. It may be a little slower the first time.", true)
        case .logsAndCrash:
            if folder == "DiagnosticReports" {
                return ("reports macOS saved when apps crashed.",
                        "Nothing needs them back. New reports are written if an app crashes again.", true)
            }
            return ("log files an app wrote.",
                    "Nothing needs them back. Apps write new logs as they run.", true)
        case .installers:
            let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
            if item.risk == .safe {
                return ("an installer you downloaded and probably already used.",
                        "Download it again from where you got it, if you ever need it.", true)
            }
            if ["dmg", "iso"].contains(ext) {
                return ("a disk image that isn't a plain installer. It could be a backup or an encrypted folder.",
                        "It doesn't, unless you have another copy.", false)
            }
            return ("an old archive in your Downloads folder.",
                    "It doesn't, unless you still have what's inside it or can download it again.", false)
        case .dsStore:
            return ("a small file where Finder remembers how a folder looks.",
                    "Finder makes a new one when you open the folder. Icon positions and window size reset.", true)
        case .aiModels:
            if item.name.hasPrefix("Ollama · ") {
                let model = item.name.dropFirst("Ollama · ".count)
                // Models made locally (ollama create) or copied in can't be pulled again.
                return ("a local AI model in Ollama.",
                        "Only if it came from the Ollama library: run ollama pull \(model). A model you made or copied in doesn't come back.", false)
            }
            if item.name.hasPrefix("LM Studio · ") {
                return ("a local AI model in LM Studio.",
                        "Only if it came from a public download: get it again in LM Studio. A model you added yourself doesn't come back.", false)
            }
            return ("a model or dataset that Hugging Face tools saved.",
                    "Only if it's public on the Hub: it downloads again the next time code asks for it. Private or fine-tuned files don't come back.", false)
        case .docker:
            switch item.id {
            case "docker://dangling-images":
                return ("image layers with no name, left over from rebuilds.",
                        "Nothing uses them. Docker makes new layers as you build.", true)
            case "docker://stopped-containers":
                return ("containers that have stopped. Named volumes are kept.",
                        "Start a new container from its image. Changes made inside the old one don't come back.", false)
            default:
                return ("layers Docker saves to speed up builds.",
                        "Docker builds them again. The next build is slower once.", true)
            }
        case .simulators:
            if item.id == "simctl://unavailable-devices" {
                return ("simulators whose iOS version is no longer installed, so they can't start.",
                        "Create a new simulator in Xcode if you need one. Apps and data inside the old ones don't come back.", false)
            }
            return ("an older simulator runtime that a newer one has replaced.",
                    "Reinstall it from Xcode › Settings › Components if a project needs it.", true)
        case .browserCaches:
            return ("pages and images \(item.name) saved to load sites faster. History, logins and cookies are kept.",
                    "\(item.name) saves them again as you browse. Sites may load a little slower at first.", true)
        case .mailAttachments:
            return ("copies of attachments you opened in Mail.",
                    "Mail downloads them again only while the message is still on the server. Deleted or POP mail: gone for good.", false)
        }
    }

    private static func devFolderStory(_ folder: String, parent: String) -> (what: String, back: String, comesBack: Bool) {
        switch folder {
        case "node_modules":
            return ("packages the project \(parent) installed.",
                    "Run npm install (or yarn, pnpm, bun) in \(parent) to get them back.", true)
        case ".venv", "venv":
            return ("a Python environment for \(parent).",
                    "Make it again with python -m venv and reinstall the project's packages. Anything you added by hand needs adding again.", true)
        case "target":
            return ("build output for \(parent) (Rust, Maven or sbt).",
                    "The next cargo, mvn or sbt build makes it again.", true)
        case ".next", ".nuxt", ".turbo", ".parcel-cache":
            return ("a build cache for \(parent).",
                    "The next build or dev run makes it again.", true)
        case "__pycache__":
            return ("compiled Python files for \(parent).",
                    "Python writes them again the next time the code runs.", true)
        case ".pytest_cache":
            return ("pytest's notes from the last test run in \(parent).",
                    "pytest writes it again on the next run.", true)
        default:
            return ("a build or dependency folder in \(parent).",
                    "The project's next build or install makes it again.", true)
        }
    }

    private static func packageCacheStory(_ name: String) -> (what: String, back: String, comesBack: Bool) {
        switch name {
        case "Homebrew Cache":
            return ("installers Homebrew downloaded.", "Homebrew downloads them again if you reinstall something.", true)
        case "npm Cache":
            return ("packages npm downloaded so installs are faster.",
                    "npm downloads a package again the next time a project needs it.", true)
        case "pnpm Cache", "Yarn Cache", "Bun Cache":
            let tool = name.replacingOccurrences(of: " Cache", with: "")
            return ("packages \(tool) downloaded so installs are faster.",
                    "\(tool) downloads a package again the next time a project needs it.", true)
        case "pip Cache", "pip Cache (~/.cache)", "uv Cache":
            let tool = name.hasPrefix("uv") ? "uv" : "pip"
            return ("Python packages \(tool) downloaded so installs are faster.",
                    "\(tool) downloads a package again the next time you install it.", true)
        case "SwiftPM Cache":
            return ("copies of Swift packages your projects use.",
                    "Swift downloads them again on the next build.", true)
        case "CocoaPods Cache":
            return ("pods CocoaPods downloaded.", "pod install downloads them again.", true)
        case "Gradle Cache":
            return ("libraries and build results Gradle saved.",
                    "Gradle downloads and rebuilds them on the next build. That build is slower.", true)
        case "Cargo Registry Cache":
            return ("Rust crates Cargo downloaded.", "cargo downloads them again on the next build.", true)
        case "Go Build Cache":
            return ("compiled Go packages.", "go build compiles them again. The next build is slower.", true)
        case "Playwright Browsers":
            return ("browsers Playwright downloaded for tests.",
                    "Run npx playwright install to download them again.", true)
        default:
            return ("files a package manager downloaded.",
                    "The package manager downloads them again the next time it needs them.", true)
        }
    }

    private static func toolName(_ command: JunkCommand) -> String {
        URL(fileURLWithPath: command.executable).lastPathComponent == "docker" ? "Docker" : "Xcode"
    }

    // MARK: - Git Worktrees

    static func worktree(_ item: WorktreeItem) -> WhyExplanation {
        let name = "\(item.repoName) · \(item.branchName)"
        if item.mergeStatus == .main {
            return WhyExplanation(
                title: "Why Furl keeps \(item.repoName)",
                tier: nil,
                lines: [
                    .init(mark: .info, label: "What it is:", text: "the main checkout of \(item.repoName)."),
                    .init(mark: .good, label: "Never removed:", text: "Furl only offers the extra worktrees made from it.")
                ])
        }
        let isOK = item.canAutoSelect
        var lines: [WhyExplanation.Line] = []
        if item.mergeStatus == .detached {
            lines.append(.init(mark: .info, label: "What it is:", text: "a git worktree at commit \(item.commitHash), not on a branch."))
        } else {
            lines.append(.init(mark: .info, label: "What it is:", text: "a git worktree for the branch \(item.branchName)."))
        }
        switch item.mergeStatus {
        case .merged:
            if item.pointsAtBaseTip {
                lines.append(.init(mark: .bad, label: "No new commits:",
                                   text: "it points at the same commit as \(item.baseBranch). It may be a branch someone just started."))
            } else {
                lines.append(.init(mark: .good, label: "Merged:",
                                   text: "every commit is on \(item.baseBranch), and the branch stays in the repo."))
            }
        case .squashMerged:
            lines.append(.init(mark: .good, label: "Merged:",
                               text: "its changes are on \(item.baseBranch) (squash or rebase merge), and the branch stays in the repo."))
        case .unmerged:
            lines.append(.init(mark: .bad, label: "Not merged:", text: "the branch has commits that aren't on \(item.baseBranch)."))
        case .detached:
            lines.append(.init(mark: .bad, label: "No branch:", text: "commits made here may not be on any branch."))
        case .main:
            break
        }
        if item.isPrunable {
            lines.append(.init(mark: .info, label: "Folder missing:",
                               text: "git still lists it, but the folder is gone. Removing it only tidies git's records."))
        } else if item.isDirty {
            lines.append(.init(mark: .bad, label: "Uncommitted changes:",
                               text: "some files changed and aren't committed, or Furl couldn't check. Removing it loses them."))
        } else {
            lines.append(.init(mark: .good, label: "Clean:", text: "no uncommitted changes."))
        }
        if item.isLocked {
            lines.append(.init(mark: .bad, label: "Locked:", text: "someone locked it in git so it isn't removed by mistake."))
        }
        // The board's merged popover skips the date; it helps when you're deciding, so check-first rows keep it.
        if !isOK, let date = item.lastCommitDate {
            lines.append(.init(mark: .time, label: "Last used:", text: "last commit \(date.relativeDescription)."))
        }
        if !item.isPrunable {
            lines.append(.init(mark: .bad, label: "Doesn't go to the Trash:",
                               text: "git deletes the folder for good, including files git ignores, like .env."))
        }
        // Never "is safe": removal is permanent.
        let title = isOK ? "Why \(name) is OK to remove" : "Why check \(name) first"
        let tier: RiskTier? = isOK ? (item.isPrunable ? nil : .permanent) : .checkFirst
        return WhyExplanation(title: title, tier: tier, lines: lines)
    }

    /// Chips on a worktree row. Nothing here is Safe: removal can't use the Trash, so merged rows show
    /// Permanent alone and the rest Check first + Permanent. A missing folder deletes nothing on disk
    /// (only git's record), so it never shows Permanent.
    static func worktreeChips(_ item: WorktreeItem) -> [RiskTier] {
        guard item.mergeStatus != .main else { return [] }
        let level: [RiskTier] = item.canAutoSelect ? [] : [.checkFirst]
        return item.isPrunable ? level : level + [.permanent]
    }

    // MARK: - Duplicates

    /// The oldest copy: the one Furl keeps only if every copy is ticked (see `AppState.cleanSelectedDuplicates`).
    /// Auto-Select may keep a different one ("Keep Newest"), so the copy never promises this one stays.
    static func keptCopy(in group: DuplicateGroup) -> DuplicateFile? {
        DuplicateKeepRule.oldest.keeper(in: group.files)
    }

    /// Spare copies are Check first: the bytes match, but only you know which folder it belongs in.
    static func duplicateTier(_ file: DuplicateFile, in group: DuplicateGroup) -> RiskTier? {
        keptCopy(in: group)?.id == file.id ? nil : .checkFirst
    }

    static func duplicate(_ file: DuplicateFile, in group: DuplicateGroup, deletionMode: DeletionMode) -> WhyExplanation {
        let isOldest = keptCopy(in: group)?.id == file.id
        let others = group.files.count - 1
        var lines: [WhyExplanation.Line] = [
            .init(mark: .good, label: "Same bytes:",
                  text: "checked byte for byte against \(others) other cop\(others == 1 ? "y" : "ies").")
        ]
        if isOldest {
            lines.append(.init(mark: .info, label: "Oldest copy:",
                               text: "probably the original. If you tick every copy, Furl keeps this one."))
            if let date = file.modifiedDate {
                lines.append(.init(mark: .time, label: "Last changed:", text: date.relativeDescription + "."))
            }
            lines.append(goesTo(permanentTool: nil, deletionMode: deletionMode))
            return WhyExplanation(title: "About the oldest copy", tier: nil, lines: lines)
        }
        lines.append(.init(mark: .good, label: "You keep one:",
                           text: "Furl never removes the last copy. If you tick them all, it keeps the oldest."))
        lines.append(.init(mark: .bad, label: "Only you know:",
                           text: "Furl can't tell which folder you want this file in."))
        if file.isClone {
            lines.append(.init(mark: .info, label: "Shares space:",
                               text: "this copy already shares space with another, so removing it frees nothing."))
        }
        if let date = file.modifiedDate {
            lines.append(.init(mark: .time, label: "Last changed:", text: date.relativeDescription + "."))
        }
        lines.append(goesTo(permanentTool: nil, deletionMode: deletionMode))
        return WhyExplanation(title: "Why check this copy first", tier: .checkFirst, lines: lines)
    }

    // MARK: - Apps & Leftovers

    /// Safe only for data an app rebuilds and that was matched exactly. Settings, app support files and
    /// containers can hold your own data, so they're Check first.
    static func leftoverTier(_ item: AppDataItem) -> RiskTier {
        item.isSafeToRemove ? .safe : .checkFirst
    }

    /// One short line under the leftover's name.
    static func leftoverSubtitle(_ item: AppDataItem) -> String {
        guard item.isStrongMatch else { return "Name only partly matches · may belong to another app" }
        switch item.location {
        case .preferences: return "Settings · keep if you may reinstall"
        case .applicationSupport, .containers, .groupContainers: return "App is gone · may hold its documents"
        case .caches, .webKit, .httpStorages: return "App is gone · cached data"
        case .savedState: return "App is gone · window positions"
        case .logs: return "App is gone · log files"
        }
    }

    static func leftover(_ item: AppDataItem, group: OrphanedAppDataGroup, deletionMode: DeletionMode) -> WhyExplanation {
        let tier = leftoverTier(item)
        let app = group.displayName
        var lines: [WhyExplanation.Line] = []
        switch item.location {
        case .caches, .webKit, .httpStorages:
            lines.append(.init(mark: .info, label: "What it is:", text: "data \(app) cached to run faster."))
        case .savedState:
            lines.append(.init(mark: .info, label: "What it is:", text: "where \(app) remembered its open windows."))
        case .logs:
            lines.append(.init(mark: .info, label: "What it is:", text: "log files \(app) wrote."))
        case .preferences:
            lines.append(.init(mark: .info, label: "What it is:", text: "\(app)'s settings."))
        case .applicationSupport, .containers, .groupContainers:
            lines.append(.init(mark: .info, label: "What it is:",
                               text: "files \(app) kept for itself. Some apps keep your documents or libraries here."))
        }
        if item.isStrongMatch {
            lines.append(.init(mark: .good, label: "App is gone:", text: "it matches \(app) by its ID, and \(app) isn't installed."))
        } else {
            lines.append(.init(mark: .bad, label: "Loose match:",
                               text: "the name only partly matches \(app). It may belong to a related app that's still installed."))
        }
        // By what the folder holds, not by the tier: a loosely matched cache still rebuilds itself.
        if item.rebuildsItself {
            lines.append(.init(mark: .good, label: "How it comes back:", text: "\(app) makes it again if you reinstall it."))
        } else {
            lines.append(.init(mark: .bad, label: "How it comes back:",
                               text: "it doesn't. If you reinstall \(app), it starts fresh without this."))
        }
        if let date = item.modifiedDate {
            lines.append(.init(mark: .time, label: "Last changed:", text: date.relativeDescription + "."))
        }
        lines.append(goesTo(permanentTool: nil, deletionMode: deletionMode))
        return WhyExplanation(title: title(item.name, tier: tier), tier: tier, lines: lines)
    }

    // MARK: - Shared

    static func title(_ name: String, tier: RiskTier) -> String {
        tier == .safe ? "Why \(name) is safe" : "Why check \(name) first"
    }

    /// Where the item goes. Only says "the Trash" when it really does.
    static func goesTo(permanentTool: String?, deletionMode: DeletionMode) -> WhyExplanation.Line {
        if let tool = permanentTool {
            return .init(mark: .bad, label: "Goes to:", text: "nowhere. \(tool) deletes it for good, so it can't be undone.")
        }
        if deletionMode == .permanent {
            return .init(mark: .bad, label: "Goes to:", text: "nowhere. Delete Permanently is on, so it can't be undone.")
        }
        return .init(mark: .good, label: "Goes to:", text: "the Trash. You can undo from History.")
    }
}

import Foundation

/// Where a language version came from. The label is the badge on its row.
enum DevVersionManager: String, Sendable, Hashable, Codable {
    case nvm, fnm, volta, mise, asdf, pyenv, uv, rustup

    var label: String { rawValue }

    /// rustup keeps its own records, so it removes toolchains itself (Permanent). The rest are folders.
    var goesToTrash: Bool { self != .rustup }

    /// "nvm install 16 downloads it again."
    func reinstallHint(language: DevLanguage, version: DevVersionNumber, name: String) -> String {
        let major = version.prefix(language.granularity)
        switch self {
        case .nvm: return "nvm install \(major)"
        case .fnm: return "fnm install \(major)"
        case .volta: return "volta install node@\(major)"
        case .mise: return "mise install \(language == .node ? "node" : "python")@\(version.string)"
        case .asdf: return "asdf install \(language == .node ? "nodejs" : "python") \(version.string)"
        case .pyenv: return "pyenv install \(version.string)"
        case .uv: return "uv python install \(major)"
        case .rustup: return "rustup toolchain install \(name)"
        }
    }
}

/// One installed Node, Python or Rust version.
struct DevVersion: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        /// No project asks for it and it isn't a default: listed, and ticked by "Select unused versions".
        case unused
        /// A project's version file asks for it.
        case inUse(project: String, file: String)
        /// A virtualenv or tool made from it points at it.
        case usedBy(String)
        /// The version a manager uses when nothing else says (new terminals, `rustup default`).
        case isDefault(String)
        /// A program from it is running now.
        case running
        /// The user chose "Always keep".
        case kept
        /// A version file Furl couldn't read with certainty, so every version of the language stays.
        case unsure(project: String, file: String)
    }

    let language: DevLanguage
    let manager: DevVersionManager
    let version: DevVersionNumber
    /// The folder name as installed ("v16.20.2", "1.70.0-aarch64-apple-darwin").
    let folderName: String
    let path: String
    var sizeBytes: Int64
    var status: Status

    var id: String { path }
    var isRemovable: Bool { status == .unused }
    var goesToTrash: Bool { manager.goesToTrash }

    /// "Node 16.20.2", "Rust 1.70.0", "Rust nightly-2024-01-05".
    var displayName: String {
        if language == .rust { return "Rust \(DevToolsNaming.rustChannel(folderName))" }
        return "\(language.rawValue) \(version.string)"
    }

    /// The key "Always keep" stores: language plus the part a project request pins ("node:16").
    var keepKey: String {
        if language == .rust { return "rust:" + DevToolsNaming.rustChannel(folderName) }
        return language.rawValue.lowercased() + ":" + version.prefix(language.granularity)
    }

    /// "Node 16", "Python 3.9": what "Always keep" names.
    var keepName: String {
        if language == .rust { return displayName }
        return "\(language.rawValue) \(version.prefix(language.granularity))"
    }
}

/// A Homebrew formula with older versions still in the Cellar next to the one in use.
struct BrewOldVersions: Identifiable, Hashable, Sendable {
    let formula: String
    let linkedVersion: String
    let oldVersions: [String]
    let oldPaths: [String]
    var sizeBytes: Int64
    var id: String { "brew-old:" + formula }
}

/// A Homebrew formula installed on request that no other installed formula needs.
struct BrewLeaf: Identifiable, Hashable, Sendable {
    let name: String
    let version: String
    let path: String
    let installedDate: Date?
    var sizeBytes: Int64
    /// "postgresql@17" when a newer version of the same formula is installed too.
    let newerSibling: String?
    var id: String { "brew-leaf:" + name }
}

/// A package installed globally with a language's package manager.
struct GlobalPackage: Identifiable, Hashable, Sendable {
    enum Manager: String, Sendable, Hashable, CaseIterable {
        case npm, pnpm, bun, pipx, cargo

        /// The badge on its row.
        var label: String {
            switch self {
            case .npm: return "npm -g"
            case .pnpm: return "pnpm -g"
            case .bun: return "bun -g"
            case .pipx: return "pipx"
            case .cargo: return "cargo"
            }
        }

        func uninstallCommand(_ name: String) -> String {
            switch self {
            case .npm: return "npm uninstall -g \(name)"
            case .pnpm: return "pnpm remove -g \(name)"
            case .bun: return "bun remove -g \(name)"
            case .pipx: return "pipx uninstall \(name)"
            case .cargo: return "cargo uninstall \(name)"
            }
        }

        func installCommand(_ name: String) -> String {
            switch self {
            case .npm: return "npm install -g \(name)"
            case .pnpm: return "pnpm add -g \(name)"
            case .bun: return "bun add -g \(name)"
            case .pipx: return "pipx install \(name)"
            case .cargo: return "cargo install \(name)"
            }
        }
    }

    let manager: Manager
    let name: String
    /// The commands it adds ("ng"; "http, https").
    let commands: [String]
    let installedDate: Date?
    var sizeBytes: Int64
    /// The folder it lives in, when it has one of its own (not cargo).
    let path: String?
    /// The tool binary that listed it, used again to uninstall it.
    let tool: String
    var id: String { "pkg:\(manager.rawValue):\(name)" }
}

/// Everything the Developer tools filter lists.
struct DevToolsSnapshot: Hashable, Sendable {
    var versions: [DevVersion] = []
    var brewOld: [BrewOldVersions] = []
    var brewLeaves: [BrewLeaf] = []
    var packages: [GlobalPackage] = []
    /// How many projects Furl read version files from ("none of your 48 projects…").
    var projectCount = 0
    /// Homebrew's install prefix, when Homebrew is installed.
    var brewPrefix: String?

    var rowCount: Int { versions.count + brewOld.count + brewLeaves.count + packages.count }

    /// Unused versions: these add to the Overview's Quick look.
    var unusedVersions: [DevVersion] { versions.filter(\.isRemovable) }
}

enum DevToolsNaming {
    /// Host triples rustup appends to toolchain folder names.
    private static let hostSuffixes = ["-aarch64-apple-darwin", "-x86_64-apple-darwin"]

    /// "1.70.0-aarch64-apple-darwin" → "1.70.0".
    static func rustChannel(_ folder: String) -> String {
        for suffix in hostSuffixes where folder.hasSuffix(suffix) {
            return String(folder.dropLast(suffix.count))
        }
        return folder
    }
}

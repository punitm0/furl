import Foundation

/// Where each tool keeps its installs. Built from the home folder and the app's environment, so tests
/// can point it at a temporary folder.
struct DevToolsPaths: Sendable {
    let home: String
    let env: [String: String]

    static var current: DevToolsPaths {
        DevToolsPaths(home: FileManager.default.homeDirectoryForCurrentUser.path,
                      env: ProcessInfo.processInfo.environment)
    }

    private func h(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
    /// An env override only when it's an absolute path; anything else falls back to the default.
    private func dir(_ key: String, _ fallback: String) -> String {
        if let v = env[key], v.hasPrefix("/") { return v }
        return h(fallback)
    }

    var nvm: String { dir("NVM_DIR", ".nvm") }
    var fnmCandidates: [String] {
        var out: [String] = []
        if let v = env["FNM_DIR"], v.hasPrefix("/") { out.append(v) }
        return out + [h(".local/share/fnm"), h("Library/Application Support/fnm"), h(".fnm")]
    }
    var volta: String { dir("VOLTA_HOME", ".volta") }
    var mise: String { dir("MISE_DATA_DIR", ".local/share/mise") }
    var miseConfig: String { h(".config/mise/config.toml") }
    var asdf: String { dir("ASDF_DATA_DIR", ".asdf") }
    var pyenv: String { dir("PYENV_ROOT", ".pyenv") }
    var uvPython: String { dir("UV_PYTHON_INSTALL_DIR", ".local/share/uv/python") }
    var uvTools: String { dir("UV_TOOL_DIR", ".local/share/uv/tools") }
    var uvGlobalPin: String { h(".config/uv/.python-version") }
    var rustup: String { dir("RUSTUP_HOME", ".rustup") }
    var cargo: String { dir("CARGO_HOME", ".cargo") }
    var toolVersions: String { h(".tool-versions") }
    var pipxCandidates: [String] {
        var out: [String] = []
        if let v = env["PIPX_HOME"], v.hasPrefix("/") { out.append(v) }
        return out + [h(".local/pipx"), h("Library/Application Support/pipx")]
    }
    var bunGlobal: String { h(".bun/install/global") }
    var bunBinary: String { h(".bun/bin/bun") }
}

/// The environment every tool runs with: Homebrew never updates, cleans up or sends analytics, and
/// npm-style tools don't check for updates. Nothing new goes over the network.
enum DevToolsShell {
    static let environment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_COLOR": "1",
        "NONINTERACTIVE": "1",
        "NO_UPDATE_NOTIFIER": "1",
        "npm_config_update_notifier": "false",
        "npm_config_fund": "false",
        "npm_config_audit": "false",
        "npm_config_offline": "true",
        "DO_NOT_TRACK": "1",
        "CI": "1",
    ]

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> ShellOutput {
        // From the home folder, so no project's config files are picked up.
        ShellRunner.run(tool, arguments: arguments,
                        workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                        timeout: timeout, environment: environment)
    }
}

/// A default a version manager falls back to, as a spec over its installs.
struct DevDefault: Hashable, Sendable {
    let language: DevLanguage
    let managers: Set<DevVersionManager>
    let spec: VersionSpec
    let reason: String
}

/// A Python install that a virtualenv or tool points at (`home =` in its pyvenv.cfg).
struct DevPythonUser: Hashable, Sendable {
    let home: String
    let label: String
}

enum DevToolsScanner {
    // MARK: - Whole scan

    static func scan(projectRoots: [String], kept: Set<String>, paths: DevToolsPaths = .current,
                     progress: ScanProgress? = nil) -> DevToolsSnapshot {
        var snapshot = DevToolsSnapshot()
        snapshot.projectCount = projectRoots.count
        progress?.setPhase("Reading project version files")
        let requests = projectRoots.flatMap { VersionFiles.requests(inProject: $0) }
        progress?.setPhase("Looking for Node, Python and Rust versions")
        let pythonUsers = pythonUsers(paths: paths)
        var versions = classify(installedVersions(paths: paths), requests: requests,
                                defaults: defaults(paths: paths), pythonUsers: pythonUsers,
                                running: runningExecutables(), kept: kept, paths: paths)
        for i in versions.indices {
            if progress?.isCancelled == true { break }
            progress?.setPhase("Measuring \(versions[i].displayName)")
            versions[i].sizeBytes = FileSizeHelper.directorySize(at: URL(fileURLWithPath: versions[i].path))
        }
        snapshot.versions = versions.sorted(by: versionOrder)

        if let prefix = brewPrefix() {
            progress?.setPhase("Checking Homebrew")
            snapshot.brewPrefix = prefix
            let brewfiles = Set(projectRoots.flatMap(brewfileFormulae))
            let homes = pythonUsers.map(\.home) + requests.compactMap {
                if case .path(let p) = $0.spec { return p } else { return nil }
            }
            let brew = scanHomebrew(prefix: prefix, projectFormulae: brewfiles, pythonHomes: homes)
            snapshot.brewOld = brew.old
            snapshot.brewLeaves = brew.leaves
        }
        progress?.setPhase("Checking global packages")
        snapshot.packages = globalPackages(paths: paths)
        return snapshot
    }

    /// Unused first, then by language, then newest first.
    static func versionOrder(_ a: DevVersion, _ b: DevVersion) -> Bool {
        if a.isRemovable != b.isRemovable { return a.isRemovable }
        if a.language != b.language {
            return DevLanguage.allCases.firstIndex(of: a.language)! < DevLanguage.allCases.firstIndex(of: b.language)!
        }
        if a.version != b.version { return a.version < b.version }
        return a.path < b.path
    }

    // MARK: - Installed versions

    static func installedVersions(paths: DevToolsPaths) -> [DevVersion] {
        var out: [DevVersion] = []
        func add(_ root: String, _ lang: DevLanguage, _ manager: DevVersionManager,
                 version: (String) -> DevVersionNumber? = { DevVersionNumber(parsing: $0) }) {
            for name in childDirectories(root) {
                guard let v = version(name) else { continue }
                out.append(DevVersion(language: lang, manager: manager, version: v, folderName: name,
                                      path: (root as NSString).appendingPathComponent(name), sizeBytes: 0, status: .unused))
            }
        }
        add((paths.nvm as NSString).appendingPathComponent("versions/node"), .node, .nvm, version: strictVersion)
        if let fnm = paths.fnmCandidates.first(where: isRealDirectory) {
            add((fnm as NSString).appendingPathComponent("node-versions"), .node, .fnm, version: strictVersion)
        }
        add((paths.volta as NSString).appendingPathComponent("tools/image/node"), .node, .volta, version: strictVersion)
        add((paths.mise as NSString).appendingPathComponent("installs/node"), .node, .mise, version: strictVersion)
        add((paths.mise as NSString).appendingPathComponent("installs/python"), .python, .mise, version: strictVersion)
        add((paths.asdf as NSString).appendingPathComponent("installs/nodejs"), .node, .asdf, version: strictVersion)
        add((paths.asdf as NSString).appendingPathComponent("installs/python"), .python, .asdf, version: strictVersion)
        add((paths.pyenv as NSString).appendingPathComponent("versions"), .python, .pyenv, version: strictVersion)
        add(paths.uvPython, .python, .uv) { name in
            // "cpython-3.12.1-macos-aarch64-none"
            let parts = name.split(separator: "-")
            guard parts.count >= 2, parts[0] == "cpython" else { return nil }
            return strictVersion(String(parts[1]))
        }
        add((paths.rustup as NSString).appendingPathComponent("toolchains"), .rust, .rustup) { name in
            let channel = DevToolsNaming.rustChannel(name)
            // Tracking channels follow updates and are never listed; only pinned versions and dated builds.
            if let v = strictVersion(channel) { return v }
            for prefix in ["nightly-", "beta-", "stable-"] where channel.hasPrefix(prefix) {
                let date = channel.dropFirst(prefix.count)
                if date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return DevVersionNumber([0]) }
            }
            return nil
        }
        return out
    }

    /// Only "16.20.2" / "v16.20.2" / "3.12" (numbers and dots), nothing after.
    static func strictVersion(_ name: String) -> DevVersionNumber? {
        guard name.range(of: #"^v?\d{1,4}(\.\d{1,6}){1,2}$"#, options: .regularExpression) != nil else { return nil }
        return DevVersionNumber(parsing: name)
    }

    // MARK: - Deciding what's in use

    /// Marks every version that something asks for, uses or runs. Whatever is left is `.unused`.
    static func classify(_ installed: [DevVersion], requests: [VersionRequest], defaults: [DevDefault],
                         pythonUsers: [DevPythonUser], running: [String], kept: Set<String>,
                         paths: DevToolsPaths) -> [DevVersion] {
        let resolvedRequests = requests.map { resolve($0, paths: paths) }
        return installed.map { item in
            var v = item
            v.status = status(of: item, all: installed, requests: resolvedRequests, defaults: defaults,
                              pythonUsers: pythonUsers, running: running, kept: kept)
            return v
        }
    }

    private static func status(of v: DevVersion, all: [DevVersion], requests: [VersionRequest], defaults: [DevDefault],
                               pythonUsers: [DevPythonUser], running: [String], kept: Set<String>) -> DevVersion.Status {
        let realPath = realpathOrSelf(v.path)
        if running.contains(where: { $0.hasPrefix(v.path + "/") || $0.hasPrefix(realPath + "/") }) { return .running }
        for d in defaults where d.language == v.language && d.managers.contains(v.manager) {
            if matches(d.spec, v, all: all.filter { d.managers.contains($0.manager) }) || d.spec == .unreadable {
                return .isDefault(d.reason)
            }
        }
        let mine = requests.filter { $0.language == v.language }
        if let r = mine.first(where: { matches($0.spec, v, all: all) }) {
            if case .path = r.spec { return .usedBy("A virtualenv in \(r.project.abbreviatingHome) uses it") }
            return .inUse(project: r.project, file: r.file)
        }
        if v.language == .python,
           let user = pythonUsers.first(where: { isInside($0.home, v.path) || isInside(realpathOrSelf($0.home), realPath) }) {
            return .usedBy(user.label)
        }
        // A version file Furl couldn't read keeps every version of that language.
        if let r = mine.first(where: { isUnreadable($0.spec, v.language, all: all) }) {
            return .unsure(project: r.project, file: r.file)
        }
        if kept.contains(v.keepKey) { return .kept }
        // A Python folder with virtualenvs inside (pyenv-virtualenv) is in use by them.
        if v.language == .python, !childDirectories((v.path as NSString).appendingPathComponent("envs")).isEmpty {
            return .usedBy("It has virtualenvs inside")
        }
        return .unused
    }

    /// True when `spec` asks for `v`. `all` is the pool "newest" picks from.
    static func matches(_ spec: VersionSpec, _ v: DevVersion, all: [DevVersion]) -> Bool {
        let same = all.filter { $0.language == v.language }
        switch spec {
        case .ranges:
            return v.language != .rust && spec.asks(v.version, granularity: v.language.granularity)
        case .newest:
            guard v.language != .rust, let top = same.map(\.version).max() else { return false }
            return v.version.prefix(v.language.granularity) == top.prefix(v.language.granularity)
        case .newestLTS:
            guard v.language == .node,
                  let top = same.map({ $0.version.parts[0] }).filter({ $0 % 2 == 0 }).max() else { return false }
            return v.version.parts[0] == top
        case .name(let n):
            switch v.language {
            case .rust:
                let channel = DevToolsNaming.rustChannel(v.folderName)
                return n == v.folderName || n == channel || channel.hasPrefix(n + ".")
            case .node, .python:
                return n == v.folderName || n == "v" + v.folderName || "v" + n == v.folderName
            }
        case .path(let p):
            return isInside(p, v.path) || isInside(realpathOrSelf(p), realpathOrSelf(v.path))
        case .unreadable:
            return false
        }
    }

    /// Unreadable requests, and Node names no folder matches (an nvm alias Furl couldn't resolve).
    private static func isUnreadable(_ spec: VersionSpec, _ lang: DevLanguage, all: [DevVersion]) -> Bool {
        switch spec {
        case .unreadable: return true
        case .name where lang == .node: return !all.contains { matches(spec, $0, all: all) }
        default: return false
        }
    }

    /// Turns names Furl can look up into what they point at: nvm aliases, pyenv virtualenvs.
    static func resolve(_ request: VersionRequest, paths: DevToolsPaths) -> VersionRequest {
        guard case .name(let name) = request.spec else { return request }
        let spec: VersionSpec
        switch request.language {
        case .node: spec = nvmAlias(name, paths: paths) ?? request.spec
        case .python: spec = pyenvVirtualenv(name, paths: paths) ?? request.spec
        case .rust: spec = request.spec
        }
        return VersionRequest(language: request.language, spec: spec, project: request.project, file: request.file)
    }

    /// Follows nvm alias files (`~/.nvm/alias/<name>`), up to five hops.
    static func nvmAlias(_ name: String, paths: DevToolsPaths) -> VersionSpec? {
        var current = name
        for _ in 0..<5 {
            guard VersionFiles.isPlainName(current), !current.contains(".."),
                  let text = VersionFiles.readSmallFile((paths.nvm as NSString).appendingPathComponent("alias/" + current)),
                  let line = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces),
                  !line.isEmpty else { return nil }
            let spec = VersionFiles.nodeSpec(line)
            guard case .name(let next) = spec else { return spec }
            current = next
        }
        return nil
    }

    /// pyenv-virtualenv names are links in `versions/` into `versions/<python>/envs/<name>`.
    static func pyenvVirtualenv(_ name: String, paths: DevToolsPaths) -> VersionSpec? {
        guard VersionFiles.isPlainName(name), !name.contains("/"), !name.contains("..") else { return nil }
        let link = (paths.pyenv as NSString).appendingPathComponent("versions/" + name)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        let absolute = target.hasPrefix("/") ? target
            : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        return .path((absolute as NSString).standardizingPath)
    }

    // MARK: - Defaults

    static func defaults(paths: DevToolsPaths) -> [DevDefault] {
        var out: [DevDefault] = []
        let terminals = "The version new terminals use"
        // nvm: alias/default names a version or another alias.
        let nvmDefault = (paths.nvm as NSString).appendingPathComponent("alias/default")
        if fileExistsNoFollow(nvmDefault) {
            out.append(DevDefault(language: .node, managers: [.nvm],
                                  spec: nvmAlias("default", paths: paths) ?? .unreadable, reason: terminals))
        }
        // fnm: aliases/default is a link to the version's folder.
        for fnm in paths.fnmCandidates {
            let link = (fnm as NSString).appendingPathComponent("aliases/default")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
                let abs = target.hasPrefix("/") ? target : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                out.append(DevDefault(language: .node, managers: [.fnm], spec: .path((abs as NSString).standardizingPath), reason: terminals))
            } else if fileExistsNoFollow(link) {
                out.append(DevDefault(language: .node, managers: [.fnm], spec: .unreadable, reason: terminals))
            }
        }
        // Volta: tools/user/platform.json.
        let platform = (paths.volta as NSString).appendingPathComponent("tools/user/platform.json")
        if let text = VersionFiles.readSmallFile(platform) {
            let runtime = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                .flatMap { $0["node"] as? [String: Any] }.flatMap { $0["runtime"] as? String }
            out.append(DevDefault(language: .node, managers: [.volta],
                                  spec: runtime.map(VersionFiles.nodeSpec) ?? .unreadable, reason: terminals))
        }
        // asdf and mise both read ~/.tool-versions; mise also its own global config.
        if let text = VersionFiles.readSmallFile(paths.toolVersions) {
            for (lang, spec) in VersionFiles.toolVersions(text) {
                out.append(DevDefault(language: lang, managers: [.asdf, .mise], spec: spec, reason: "Set in ~/.tool-versions"))
            }
        }
        if let text = VersionFiles.readSmallFile(paths.miseConfig) {
            for (lang, spec) in VersionFiles.miseTools(text) {
                out.append(DevDefault(language: lang, managers: [.mise], spec: spec, reason: "Set in mise’s global config"))
            }
        }
        // pyenv: the global version file (one or more lines).
        if let text = VersionFiles.readSmallFile((paths.pyenv as NSString).appendingPathComponent("version")) {
            for (_, spec) in VersionFiles.parse(name: ".python-version", contents: text) {
                out.append(DevDefault(language: .python, managers: [.pyenv], spec: resolvePython(spec, paths), reason: "pyenv’s global version"))
            }
        }
        if let text = VersionFiles.readSmallFile(paths.uvGlobalPin) {
            for (_, spec) in VersionFiles.parse(name: ".python-version", contents: text) {
                out.append(DevDefault(language: .python, managers: [.uv], spec: spec, reason: "uv’s default Python"))
            }
        }
        // rustup: settings.toml names the default and per-folder overrides.
        let settings = (paths.rustup as NSString).appendingPathComponent("settings.toml")
        if fileExistsNoFollow(settings) {
            if let text = VersionFiles.readSmallFile(settings) {
                out += rustupDefaults(text)
            } else {
                out.append(DevDefault(language: .rust, managers: [.rustup], spec: .unreadable, reason: "rustup’s default toolchain"))
            }
        }
        return out
    }

    private static func resolvePython(_ spec: VersionSpec, _ paths: DevToolsPaths) -> VersionSpec {
        guard case .name(let n) = spec else { return spec }
        return pyenvVirtualenv(n, paths: paths) ?? spec
    }

    static func rustupDefaults(_ text: String) -> [DevDefault] {
        var out: [DevDefault] = []
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { continue }
            value = String(value.dropFirst().dropLast())
            let spec: VersionSpec = VersionFiles.isPlainName(value) ? .name(value) : .unreadable
            if section.isEmpty && key == "default_toolchain" {
                out.append(DevDefault(language: .rust, managers: [.rustup], spec: spec, reason: "rustup’s default toolchain"))
            } else if section == "[overrides]" {
                out.append(DevDefault(language: .rust, managers: [.rustup], spec: spec, reason: "Set for a folder with rustup override"))
            }
        }
        return out
    }

    // MARK: - Pythons that tools use

    /// pipx and uv tools each live in a virtualenv made from some Python.
    static func pythonUsers(paths: DevToolsPaths) -> [DevPythonUser] {
        var out: [DevPythonUser] = []
        for root in paths.pipxCandidates {
            let venvs = (root as NSString).appendingPathComponent("venvs")
            for name in childDirectories(venvs) {
                let cfg = (venvs as NSString).appendingPathComponent(name + "/pyvenv.cfg")
                if let text = VersionFiles.readSmallFile(cfg), let home = VersionFiles.venvHome(text) {
                    out.append(DevPythonUser(home: home, label: "pipx’s \(name) uses it"))
                }
            }
        }
        for name in childDirectories(paths.uvTools) {
            let cfg = (paths.uvTools as NSString).appendingPathComponent(name + "/pyvenv.cfg")
            if let text = VersionFiles.readSmallFile(cfg), let home = VersionFiles.venvHome(text) {
                out.append(DevPythonUser(home: home, label: "uv’s \(name) tool uses it"))
            }
        }
        return out
    }

    // MARK: - Running programs

    /// Executable paths of running processes, so a version with something running is never listed.
    static func runningExecutables() -> [String] {
        let out = ShellRunner.run("/bin/ps", arguments: ["-axww", "-o", "comm="], timeout: 10)
        guard out.exitCode == 0 else { return [] }
        return out.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") }
    }

    // MARK: - Homebrew

    static func brewPrefix() -> String? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            if FileManager.default.isExecutableFile(atPath: prefix + "/bin/brew"), isRealDirectory(prefix + "/Cellar") {
                return prefix
            }
        }
        return nil
    }

    static func brewBinary(prefix: String) -> String { prefix + "/bin/brew" }

    /// A formula name as Homebrew writes them; anything else is never passed to brew.
    static func isFormulaName(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9+._@-]{0,99}$"#, options: .regularExpression) != nil
    }

    /// One formula's kegs as Homebrew sees them on disk.
    struct Formula: Sendable {
        let name: String
        let versions: [String]
        let linked: String?
        let pinned: Bool
        let receipt: Receipt?
    }

    /// The parts of INSTALL_RECEIPT.json Furl reads.
    struct Receipt: Sendable {
        let installedOnRequest: Bool
        let runtimeDependencies: [String]
        let time: Double?

        init(installedOnRequest: Bool, runtimeDependencies: [String], time: Double?) {
            self.installedOnRequest = installedOnRequest
            self.runtimeDependencies = runtimeDependencies
            self.time = time
        }

        init?(json text: String) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            installedOnRequest = json["installed_on_request"] as? Bool == true
            runtimeDependencies = ((json["runtime_dependencies"] as? [[String: Any]]) ?? []).compactMap {
                ($0["full_name"] as? String).map { String($0.split(separator: "/").last ?? "") }
            }
            time = (json["time"] as? NSNumber)?.doubleValue
        }
    }

    static func formulae(prefix: String) -> [Formula] {
        let cellar = prefix + "/Cellar"
        let fm = FileManager.default
        return childDirectories(cellar).filter(isFormulaName).map { name in
            let kegs = childDirectories(cellar + "/" + name)
            var linked: String?
            if let target = try? fm.destinationOfSymbolicLink(atPath: prefix + "/opt/" + name) {
                let parts = target.split(separator: "/").map(String.init)
                if parts.count >= 2, parts[parts.count - 2] == name, kegs.contains(parts[parts.count - 1]) {
                    linked = parts[parts.count - 1]
                }
            }
            let pinned = fileExistsNoFollow(prefix + "/var/homebrew/pinned/" + name)
            let receiptKeg = linked ?? kegs.max(by: { brewVersionLess($0, $1) ?? false })
            let receipt = receiptKeg
                .flatMap { VersionFiles.readSmallFile(cellar + "/\(name)/\($0)/INSTALL_RECEIPT.json") }
                .flatMap { Receipt(json: $0) }
            return Formula(name: name, versions: kegs, linked: linked, pinned: pinned, receipt: receipt)
        }
    }

    /// Compares Homebrew keg versions ("3.12.8", "1.2.3_1"); nil when either isn't a plain version.
    static func brewVersionLess(_ a: String, _ b: String) -> Bool? {
        func key(_ s: String) -> ([Int], Int)? {
            let pieces = s.split(separator: "_", maxSplits: 1)
            guard let base = pieces.first,
                  String(base).range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil else { return nil }
            let revision = pieces.count > 1 ? Int(pieces[1]) : 0
            guard let rev = revision else { return nil }
            return (base.split(separator: ".").compactMap { Int($0) }, rev)
        }
        guard let ka = key(a), let kb = key(b) else { return nil }
        let n = max(ka.0.count, kb.0.count)
        let pa = ka.0 + Array(repeating: 0, count: n - ka.0.count)
        let pb = kb.0 + Array(repeating: 0, count: n - kb.0.count)
        if pa != pb { return pa.lexicographicallyPrecedes(pb) }
        return ka.1 < kb.1
    }

    /// Older kegs of a formula: only when the linked keg is the newest one and the formula isn't pinned.
    static func oldVersions(of f: Formula, cellar: String) -> BrewOldVersions? {
        guard !f.pinned, f.versions.count > 1, let linked = f.linked else { return nil }
        var old: [String] = []
        for v in f.versions where v != linked {
            guard let less = brewVersionLess(v, linked) else { return nil }
            guard less else { return nil }  // A newer keg than the linked one: leave the formula alone.
            old.append(v)
        }
        old.sort { brewVersionLess($1, $0) ?? false }
        return BrewOldVersions(formula: f.name, linkedVersion: linked, oldVersions: old,
                               oldPaths: old.map { "\(cellar)/\(f.name)/\($0)" }, sizeBytes: 0)
    }

    static func scanHomebrew(prefix: String, projectFormulae: Set<String>, pythonHomes: [String]) -> (old: [BrewOldVersions], leaves: [BrewLeaf]) {
        let cellar = prefix + "/Cellar"
        let all = formulae(prefix: prefix)
        var old: [BrewOldVersions] = []
        for f in all {
            guard var o = oldVersions(of: f, cellar: cellar) else { continue }
            o.sizeBytes = o.oldPaths.reduce(Int64(0)) { $0 + FileSizeHelper.directorySize(at: URL(fileURLWithPath: $1)) }
            old.append(o)
        }
        let leaves = leafFormulae(all, cellar: cellar, projectFormulae: projectFormulae, pythonHomes: pythonHomes)
            .map { leaf -> BrewLeaf in
                var l = leaf
                l.sizeBytes = FileSizeHelper.directorySize(at: URL(fileURLWithPath: leaf.path))
                return l
            }
        return (old.sorted { $0.sizeBytes > $1.sizeBytes }, leaves.sorted { $0.sizeBytes > $1.sizeBytes })
    }

    /// Formulae installed on request that no other installed formula needs at run time, minus pinned
    /// ones, ones a project's Brewfile names, and Pythons a virtualenv or tool was made from.
    static func leafFormulae(_ all: [Formula], cellar: String, projectFormulae: Set<String>, pythonHomes: [String]) -> [BrewLeaf] {
        var needed = Set<String>()
        var unreadable = false
        for f in all {
            guard let receipt = f.receipt else { unreadable = true; continue }
            needed.formUnion(receipt.runtimeDependencies)
        }
        // A formula whose receipt can't be read might need anything; then nothing is listed.
        guard !unreadable else { return [] }
        let realHomes = pythonHomes.map(realpathOrSelf)
        let names = Set(all.map(\.name))
        return all.compactMap { f in
            guard let receipt = f.receipt, receipt.installedOnRequest,
                  !f.pinned, !needed.contains(f.name), !projectFormulae.contains(f.name) else { return nil }
            let keg = f.linked ?? f.versions.max(by: { brewVersionLess($0, $1) ?? false })
            guard let keg else { return nil }
            let kegRoot = "\(cellar)/\(f.name)"
            if realHomes.contains(where: { $0.hasPrefix(kegRoot + "/") }) { return nil }
            let time = receipt.time
            return BrewLeaf(name: f.name, version: keg, path: "\(kegRoot)/\(keg)",
                            installedDate: time.map { Date(timeIntervalSince1970: $0) },
                            sizeBytes: 0, newerSibling: newerSibling(f.name, among: names))
        }
    }

    /// "postgresql@17" for "postgresql@14" when it's installed too.
    static func newerSibling(_ name: String, among names: Set<String>) -> String? {
        let parts = name.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let mine = DevVersionNumber(parsing: String(parts[1])) else { return nil }
        let base = parts[0]
        return names.compactMap { other -> (String, DevVersionNumber)? in
            let p = other.split(separator: "@", maxSplits: 1)
            guard p.count == 2, p[0] == base, let v = DevVersionNumber(parsing: String(p[1])), mine < v else { return nil }
            return (other, v)
        }.max { $0.1 < $1.1 }?.0
    }

    /// Formulae a project's Brewfile asks for (`brew "name"`).
    static func brewfileFormulae(_ root: String) -> [String] {
        guard let text = VersionFiles.readSmallFile((root as NSString).appendingPathComponent("Brewfile")) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("brew ") else { return nil }
            let rest = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let q = rest.first, q == "\"" || q == "'" else { return nil }
            let inner = rest.dropFirst().prefix { $0 != q }
            return String(inner.split(separator: "/").last ?? "")
        }
    }

    // MARK: - Global packages

    static func isPackageName(_ s: String, manager: GlobalPackage.Manager) -> Bool {
        switch manager {
        case .npm, .pnpm, .bun:
            return s.range(of: #"^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]{0,213}$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
        case .pipx, .cargo:
            return s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$"#, options: .regularExpression) != nil
        }
    }

    static func globalPackages(paths: DevToolsPaths) -> [GlobalPackage] {
        var out: [GlobalPackage] = []
        if let npm = ShellRunner.which("npm") { out += nodeGlobals(.npm, tool: npm, root: globalRoot(npm)) }
        if let pnpm = ShellRunner.which("pnpm") ?? existingTool(paths.home + "/Library/pnpm/pnpm") {
            out += nodeGlobals(.pnpm, tool: pnpm, root: globalRoot(pnpm))
        }
        if let bun = existingTool(paths.bunBinary) ?? ShellRunner.which("bun") { out += bunGlobals(tool: bun, paths: paths) }
        if let pipx = existingTool(paths.home + "/.local/bin/pipx") ?? ShellRunner.which("pipx") {
            out += pipxGlobals(tool: pipx, paths: paths)
        }
        if let cargo = existingTool(paths.cargo + "/bin/cargo") { out += cargoGlobals(tool: cargo, paths: paths) }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// `npm root -g` / `pnpm root -g`: where global packages live.
    private static func globalRoot(_ tool: String) -> String? {
        let out = DevToolsShell.run(tool, ["root", "-g"], timeout: 20)
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.exitCode == 0, path.hasPrefix("/"), !path.contains("\n"), isRealDirectory(path) else { return nil }
        return path
    }

    /// npm and pnpm globals: one folder (npm) or link into `.pnpm` (pnpm) per package. Linked packages
    /// (`npm link`) point into your own projects and are never listed.
    static func nodeGlobals(_ manager: GlobalPackage.Manager, tool: String, root: String?) -> [GlobalPackage] {
        guard let root else { return [] }
        var names: [String] = []
        for name in childEntries(root) where !name.hasPrefix(".") {
            if name.hasPrefix("@") {
                names += childEntries(root + "/" + name).filter { !$0.hasPrefix(".") }.map { "\(name)/\($0)" }
            } else {
                names.append(name)
            }
        }
        let bundled: Set<String> = ["npm", "corepack", "pnpm"]
        return names.compactMap { name in
            guard !bundled.contains(name), isPackageName(name, manager: manager) else { return nil }
            let entry = root + "/" + name
            let folder: String
            if manager == .npm {
                guard isRealDirectory(entry) else { return nil }
                folder = entry
            } else {
                // pnpm: a link into this same global folder's .pnpm store.
                let resolved = realpathOrSelf(entry)
                let base = realpathOrSelf((root as NSString).deletingLastPathComponent)
                guard resolved.hasPrefix(base + "/"), isRealDirectory(resolved) else { return nil }
                folder = resolved
            }
            // Only folders whose own package.json names them: anything else (pnpm's hashed store
            // folders, half-installed leftovers) isn't a package Furl can name to the tool.
            guard packageJSONName(folder) == name else { return nil }
            return GlobalPackage(manager: manager, name: name, commands: packageBins(folder, name: name),
                                 installedDate: creationDate(entry),
                                 sizeBytes: FileSizeHelper.directorySize(at: URL(fileURLWithPath: folder)),
                                 path: folder, tool: tool)
        }
    }

    private static func bunGlobals(tool: String, paths: DevToolsPaths) -> [GlobalPackage] {
        guard let text = VersionFiles.readSmallFile(paths.bunGlobal + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any] else { return [] }
        return deps.keys.sorted().compactMap { name in
            guard isPackageName(name, manager: .bun) else { return nil }
            let folder = paths.bunGlobal + "/node_modules/" + name
            guard isRealDirectory(folder), packageJSONName(folder) == name else { return nil }
            return GlobalPackage(manager: .bun, name: name, commands: packageBins(folder, name: name),
                                 installedDate: creationDate(folder),
                                 sizeBytes: FileSizeHelper.directorySize(at: URL(fileURLWithPath: folder)),
                                 path: folder, tool: tool)
        }
    }

    private static func pipxGlobals(tool: String, paths: DevToolsPaths) -> [GlobalPackage] {
        guard let root = paths.pipxCandidates.first(where: { isRealDirectory($0 + "/venvs") }) else { return [] }
        let venvs = root + "/venvs"
        return childDirectories(venvs).compactMap { name in
            guard isPackageName(name, manager: .pipx) else { return nil }
            let folder = venvs + "/" + name
            var apps: [String] = []
            if let text = VersionFiles.readSmallFile(folder + "/pipx_metadata.json"),
               let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let main = json["main_package"] as? [String: Any] {
                apps = ((main["apps"] as? [String]) ?? []).filter { VersionFiles.isPlainName($0) }
            }
            return GlobalPackage(manager: .pipx, name: name, commands: apps, installedDate: creationDate(folder),
                                 sizeBytes: FileSizeHelper.directorySize(at: URL(fileURLWithPath: folder)),
                                 path: folder, tool: tool)
        }
    }

    private static func cargoGlobals(tool: String, paths: DevToolsPaths) -> [GlobalPackage] {
        guard let text = VersionFiles.readSmallFile(paths.cargo + "/.crates2.json"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let installs = json["installs"] as? [String: Any] else { return [] }
        return installs.keys.sorted().compactMap { key in
            guard let name = key.split(separator: " ").first.map(String.init), isPackageName(name, manager: .cargo),
                  let info = installs[key] as? [String: Any] else { return nil }
            let bins = ((info["bins"] as? [String]) ?? []).filter { VersionFiles.isPlainName($0) && !$0.contains("/") }
            var size: Int64 = 0
            var date: Date?
            for bin in bins {
                let path = paths.cargo + "/bin/" + bin
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                size += Int64(st.st_blocks) * 512
                date = date ?? creationDate(path)
            }
            return GlobalPackage(manager: .cargo, name: name, commands: bins, installedDate: date,
                                 sizeBytes: size, path: nil, tool: tool)
        }
    }

    private static func packageJSONName(_ folder: String) -> String? {
        guard let text = VersionFiles.readSmallFile(folder + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    /// The commands a package.json's `bin` adds.
    private static func packageBins(_ folder: String, name: String) -> [String] {
        guard let text = VersionFiles.readSmallFile(folder + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        if json["bin"] is String { return [String(name.split(separator: "/").last ?? "")] }
        let bins = (json["bin"] as? [String: Any])?.keys.sorted() ?? []
        return bins.filter { VersionFiles.isPlainName($0) }
    }

    // MARK: - File helpers

    /// Real (non-link) folders directly inside `path`, hidden ones skipped.
    static func childDirectories(_ path: String) -> [String] {
        childEntries(path).filter { !$0.hasPrefix(".") && isRealDirectory(path + "/" + $0) }
    }

    private static func childEntries(_ path: String) -> [String] {
        guard isRealDirectory(path) || isLinkToDirectory(path) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Tool homes are sometimes links (a moved ~/.pyenv); listing through one is fine, removing never is.
    private static func isLinkToDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func fileExistsNoFollow(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func existingTool(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func realpathOrSelf(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` is `folder` or inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    private static func creationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }
}

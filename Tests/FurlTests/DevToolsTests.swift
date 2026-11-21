import XCTest
@testable import Furl

final class DevToolsVersionParsingTests: XCTestCase {
    private func v(_ s: String) -> DevVersionNumber { DevVersionNumber(parsing: s)! }

    private func asks(_ spec: String, _ version: String, _ lang: DevLanguage) -> Bool {
        guard let ranges = VersionRangeParser.parse(spec) else { XCTFail("couldn't parse \(spec)"); return false }
        return VersionSpec.ranges(ranges).asks(v(version), granularity: lang.granularity)
    }

    func testNpmRanges() {
        XCTAssertTrue(asks("^18 || ^20", "18.19.0", .node))
        XCTAssertTrue(asks("^18 || ^20", "20.1.0", .node))
        XCTAssertFalse(asks("^18 || ^20", "16.20.2", .node))
        XCTAssertTrue(asks(">=14", "16.20.2", .node))
        XCTAssertFalse(asks(">=18", "16.20.2", .node))
        XCTAssertTrue(asks("16.x", "16.20.2", .node))
        XCTAssertTrue(asks("~16.14", "16.0.0", .node), "Node matches by major")
        XCTAssertTrue(asks(">=16 <19", "18.19.0", .node))
        XCTAssertFalse(asks(">=16 <19", "19.0.0", .node))
        XCTAssertFalse(asks(">16", "16.20.2", .node), ">16 means 17 and up")
        XCTAssertTrue(asks(">16.2.1", "16.20.2", .node))
        XCTAssertTrue(asks("<=18", "18.19.0", .node))
        XCTAssertTrue(asks("1.2 - 2.3", "2.0.0", .node))
        XCTAssertTrue(asks("v16.20.2", "16.1.0", .node))
        XCTAssertTrue(asks("*", "4.0.0", .node))
        XCTAssertTrue(asks("18.0.0-rc.1", "18.19.0", .node))
    }

    func testPythonSpecifiers() {
        XCTAssertTrue(asks(">=3.9,<3.13", "3.12.1", .python))
        XCTAssertFalse(asks(">=3.9,<3.13", "3.13.0", .python))
        XCTAssertFalse(asks(">=3.10", "3.9.18", .python))
        XCTAssertTrue(asks(">=3.9", "3.9.18", .python))
        XCTAssertTrue(asks("~=3.10", "3.12.1", .python))
        XCTAssertFalse(asks("~=3.10", "3.9.18", .python))
        XCTAssertTrue(asks("==3.11.*", "3.11.4", .python))
        XCTAssertFalse(asks("==3.11.*", "3.10.4", .python))
        XCTAssertTrue(asks(">=3.8, !=3.9.1", "3.9.18", .python))
        XCTAssertTrue(asks("^3.9", "3.11.0", .python), "Poetry caret")
        XCTAssertFalse(asks("3.11", "3.12.0", .python), "Python matches by minor")
    }

    func testGarbageIsUnparseable() {
        XCTAssertNil(VersionRangeParser.parse("foo bar"))
        XCTAssertNil(VersionRangeParser.parse(">=abc"))
        XCTAssertNil(VersionRangeParser.parse("1.2.3.4"))
        XCTAssertNil(VersionRangeParser.parse(String(repeating: "1", count: 300)))
    }

    func testNodeVersionFiles() {
        XCTAssertEqual(VersionFiles.parse(name: ".nvmrc", contents: "lts/*\n").first?.1, .newestLTS)
        XCTAssertEqual(VersionFiles.parse(name: ".nvmrc", contents: "node").first?.1, .newest)
        guard case .ranges = VersionFiles.parse(name: ".nvmrc", contents: "# comment\nv16.20.2\n").first?.1 else {
            return XCTFail("a pinned version reads as a range")
        }
        let hydrogen = VersionFiles.parse(name: ".node-version", contents: "lts/hydrogen").first!.1
        XCTAssertTrue(hydrogen.asks(v("18.19.0"), granularity: 1))
        XCTAssertFalse(hydrogen.asks(v("20.1.0"), granularity: 1))
        XCTAssertEqual(VersionFiles.parse(name: ".nvmrc", contents: "lts/unknownname").first?.1, .unreadable)
        XCTAssertEqual(VersionFiles.parse(name: ".nvmrc", contents: "$(rm -rf ~)").first?.1, .unreadable)
        XCTAssertEqual(VersionFiles.parse(name: ".nvmrc", contents: "myalias").first?.1, .name("myalias"))
    }

    func testPackageJSON() {
        let json = #"{"engines": {"node": ">=18"}, "volta": {"node": "20.10.0"}}"#
        let specs = VersionFiles.parse(name: "package.json", contents: json)
        XCTAssertEqual(specs.count, 2)
        XCTAssertTrue(specs.allSatisfy { $0.0 == .node })
        XCTAssertTrue(specs[0].1.asks(v("22.0.0"), granularity: 1))
        XCTAssertFalse(specs[1].1.asks(v("18.0.0"), granularity: 1))
        // A number where a string belongs can't be read with certainty.
        XCTAssertEqual(VersionFiles.parse(name: "package.json", contents: #"{"engines": {"node": 18}}"#).first?.1, .unreadable)
        XCTAssertEqual(VersionFiles.parse(name: "package.json", contents: #"{"engines": {"node": "latest-ish"}}"#).first?.1, .unreadable)
        XCTAssertTrue(VersionFiles.parse(name: "package.json", contents: "not json").isEmpty)
    }

    func testPythonFiles() {
        let pv = VersionFiles.parse(name: ".python-version", contents: "3.11.4\nsystem\nmyenv\n")
        XCTAssertEqual(pv.count, 2)
        XCTAssertEqual(pv.last?.1, .name("myenv"))
        let toml = """
        [build-system]
        requires = ["setuptools"]
        [project]
        name = "x"
        requires-python = ">=3.10" # comment
        """
        let req = VersionFiles.parse(name: "pyproject.toml", contents: toml)
        XCTAssertEqual(req.count, 1)
        XCTAssertFalse(req[0].1.asks(v("3.9.18"), granularity: 2))
        XCTAssertTrue(req[0].1.asks(v("3.12.0"), granularity: 2))
        let poetry = "[tool.poetry.dependencies]\npython = \"^3.9\"\n"
        XCTAssertTrue(VersionFiles.parse(name: "pyproject.toml", contents: poetry)[0].1.asks(v("3.9.1"), granularity: 2))
        // requires-python outside [project] is someone else's key.
        XCTAssertTrue(VersionFiles.parse(name: "pyproject.toml", contents: "[tool.x]\nrequires-python = \">=3\"").isEmpty)
        XCTAssertEqual(VersionFiles.venvHome("home = /Users/me/.pyenv/versions/3.9.18/bin\nversion = 3.9.18"),
                       "/Users/me/.pyenv/versions/3.9.18/bin")
        XCTAssertNil(VersionFiles.venvHome("home = relative/bin"))
    }

    func testToolVersionsAndMise() {
        let tv = VersionFiles.toolVersions("nodejs 18.17.0 16.0.0\npython 3.11.4 system\nrust 1.70.0\nruby 3.2.0\n")
        XCTAssertEqual(tv.filter { $0.0 == .node }.count, 2)
        XCTAssertEqual(tv.filter { $0.0 == .python }.count, 1)
        XCTAssertEqual(tv.filter { $0.0 == .rust }.first?.1, .name("1.70.0"))
        let mise = VersionFiles.miseTools("""
        [env]
        node = "ignored"
        [tools]
        node = "20"
        python = ["3.11", "3.10"]
        "rust" = { version = "1.75.0" }
        """)
        XCTAssertEqual(mise.filter { $0.0 == .node }.count, 1)
        XCTAssertEqual(mise.filter { $0.0 == .python }.count, 2)
        XCTAssertEqual(mise.filter { $0.0 == .rust }.first?.1, .name("1.75.0"))
        XCTAssertEqual(VersionFiles.miseTools("[tools]\nnode = 20").first?.1, .unreadable)
    }

    func testRustToolchainFiles() {
        XCTAssertEqual(VersionFiles.rustToolchain("1.70.0\n"), .name("1.70.0"))
        XCTAssertEqual(VersionFiles.rustToolchain("[toolchain]\nchannel = \"nightly-2024-01-05\"\n"), .name("nightly-2024-01-05"))
        XCTAssertNil(VersionFiles.rustToolchain("[toolchain]\npath = \"/opt/rust\"\n"))
        XCTAssertNil(VersionFiles.rustToolchain("[toolchain]\ncomponents = [\"clippy\"]\n"))
        XCTAssertEqual(VersionFiles.rustToolchain("[toolchain]\nchannel = 1\n"), .unreadable)
    }

    func testReadSmallFileRefusesLinksAndBigFiles() throws {
        let dir = try devToolsTempDir()
        let real = dir + "/real"
        try "18".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir + "/.nvmrc", withDestinationPath: real)
        XCTAssertEqual(VersionFiles.readSmallFile(real), "18")
        XCTAssertNil(VersionFiles.readSmallFile(dir + "/.nvmrc"))
        try String(repeating: "x", count: 300 * 1024).write(toFile: dir + "/big", atomically: true, encoding: .utf8)
        XCTAssertNil(VersionFiles.readSmallFile(dir + "/big"))
    }
}

final class DevToolsClassificationTests: XCTestCase {
    private var home = ""
    private var paths: DevToolsPaths { DevToolsPaths(home: home, env: [:]) }

    override func setUpWithError() throws {
        home = try devToolsTempDir()
    }

    private func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: home + "/" + rel, withIntermediateDirectories: true)
    }

    private func write(_ rel: String, _ text: String) throws {
        try mkdir((rel as NSString).deletingLastPathComponent)
        try text.write(toFile: home + "/" + rel, atomically: true, encoding: .utf8)
    }

    private func classify(projects: [String] = [], running: [String] = [], kept: Set<String> = []) -> [String: DevVersion] {
        let requests = projects.flatMap { VersionFiles.requests(inProject: home + "/" + $0) }
        let result = DevToolsScanner.classify(
            DevToolsScanner.installedVersions(paths: paths), requests: requests,
            defaults: DevToolsScanner.defaults(paths: paths), pythonUsers: DevToolsScanner.pythonUsers(paths: paths),
            running: running, kept: kept, paths: paths)
        return Dictionary(uniqueKeysWithValues: result.map { ($0.displayName, $0) })
    }

    private func nvmSetup() throws {
        for v in ["v16.20.2", "v18.19.0", "v22.11.0"] { try mkdir(".nvm/versions/node/\(v)/bin") }
        try write(".nvm/alias/default", "22\n")
        try write("code/legacy-api/.nvmrc", "18\n")
    }

    func testNodeInUseDefaultAndUnused() throws {
        try nvmSetup()
        let r = classify(projects: ["code/legacy-api"])
        XCTAssertEqual(r["Node 16.20.2"]?.status, .unused)
        XCTAssertEqual(r["Node 18.19.0"]?.status, .inUse(project: home + "/code/legacy-api", file: ".nvmrc"))
        XCTAssertEqual(r["Node 22.11.0"]?.status, .isDefault("The version new terminals use"))
        XCTAssertEqual(r["Node 16.20.2"]?.manager, .nvm)
    }

    func testNvmDefaultThroughAliasChain() throws {
        try nvmSetup()
        try write(".nvm/alias/default", "work\n")
        try write(".nvm/alias/work", "lts/gallium\n")
        let r = classify(projects: ["code/legacy-api"])
        XCTAssertEqual(r["Node 16.20.2"]?.status, .isDefault("The version new terminals use"))
        XCTAssertEqual(r["Node 22.11.0"]?.status, .unused)
    }

    func testUnresolvableNvmDefaultKeepsEveryNvmVersion() throws {
        try nvmSetup()
        try write(".nvm/alias/default", "missing-alias\n")
        let r = classify(projects: ["code/legacy-api"])
        XCTAssertFalse(r.values.contains { $0.isRemovable })
    }

    func testUnreadableVersionFileKeepsEveryVersionOfThatLanguage() throws {
        try nvmSetup()
        try write("code/odd/.nvmrc", "!!!\n")
        try mkdir(".pyenv/versions/3.9.18")
        let r = classify(projects: ["code/legacy-api", "code/odd"])
        XCTAssertEqual(r["Node 16.20.2"]?.status, .unsure(project: home + "/code/odd", file: ".nvmrc"))
        XCTAssertEqual(r["Python 3.9.18"]?.status, .unused, "Only Node is affected")
    }

    func testMonorepoPackageFilesCount() throws {
        try nvmSetup()
        try write("code/mono/web/package.json", #"{"engines": {"node": "^16"}}"#)
        let r = classify(projects: ["code/mono"])
        XCTAssertEqual(r["Node 16.20.2"]?.status, .inUse(project: home + "/code/mono", file: "web/package.json"))
    }

    func testRunningAndKept() throws {
        try nvmSetup()
        let r = classify(projects: ["code/legacy-api"], running: [home + "/.nvm/versions/node/v16.20.2/bin/node"])
        XCTAssertEqual(r["Node 16.20.2"]?.status, .running)
        let k = classify(projects: ["code/legacy-api"], kept: ["node:16"])
        XCTAssertEqual(k["Node 16.20.2"]?.status, .kept)
        XCTAssertEqual(k["Node 16.20.2"]?.keepKey, "node:16")
    }

    func testPyenvGlobalVenvsAndProjectRanges() throws {
        for v in ["3.9.18", "3.10.4", "3.12.1"] { try mkdir(".pyenv/versions/\(v)/bin") }
        try mkdir(".pyenv/versions/3.8.10/envs/oldenv")
        try write(".pyenv/version", "3.12.1\n")
        try write("code/api/pyproject.toml", "[project]\nrequires-python = \">=3.11\"\n")
        try write("code/tool/.venv/pyvenv.cfg", "home = \(home)/.pyenv/versions/3.10.4/bin\n")
        let r = classify(projects: ["code/api", "code/tool"])
        XCTAssertEqual(r["Python 3.12.1"]?.status, .isDefault("pyenv’s global version"))
        XCTAssertEqual(r["Python 3.9.18"]?.status, .unused)
        if case .usedBy = r["Python 3.10.4"]?.status {} else { XCTFail("a project venv uses 3.10.4") }
        XCTAssertEqual(r["Python 3.8.10"]?.status, .usedBy("It has virtualenvs inside"))
    }

    func testPyenvVirtualenvNameInProject() throws {
        try mkdir(".pyenv/versions/3.9.18/envs/proj")
        try mkdir(".pyenv/versions/3.11.2")
        try FileManager.default.createSymbolicLink(atPath: home + "/.pyenv/versions/proj",
                                                   withDestinationPath: home + "/.pyenv/versions/3.9.18/envs/proj")
        try write("code/p/.python-version", "proj\n")
        let r = classify(projects: ["code/p"])
        XCTAssertFalse(r["Python 3.9.18"]!.isRemovable)
        XCTAssertNil(r["Python proj"], "Links in versions/ are never listed")
        XCTAssertEqual(r["Python 3.11.2"]?.status, .unused)
    }

    func testPipxToolKeepsItsPython() throws {
        try mkdir(".local/share/uv/python/cpython-3.11.7-macos-aarch64-none/bin")
        try write(".local/pipx/venvs/httpie/pyvenv.cfg",
                  "home = \(home)/.local/share/uv/python/cpython-3.11.7-macos-aarch64-none/bin\n")
        let r = classify()
        XCTAssertEqual(r["Python 3.11.7"]?.status, .usedBy("pipx’s httpie uses it"))
        XCTAssertEqual(r["Python 3.11.7"]?.manager, .uv)
    }

    func testRustupChannelsDefaultAndToolchainFile() throws {
        for t in ["1.70.0-aarch64-apple-darwin", "1.75.0-aarch64-apple-darwin", "stable-aarch64-apple-darwin",
                  "nightly-2024-01-05-aarch64-apple-darwin"] {
            try mkdir(".rustup/toolchains/\(t)")
        }
        try write(".rustup/settings.toml", "default_toolchain = \"1.75.0-aarch64-apple-darwin\"\n[overrides]\n\"/x\" = \"nightly-2024-01-05-aarch64-apple-darwin\"\n")
        try write("code/r/rust-toolchain.toml", "[toolchain]\nchannel = \"1.70\"\n")
        let r = classify(projects: ["code/r"])
        XCTAssertNil(r["Rust stable"], "Tracking channels are never listed")
        XCTAssertEqual(r["Rust 1.70.0"]?.status, .inUse(project: home + "/code/r", file: "rust-toolchain.toml"))
        XCTAssertEqual(r["Rust 1.75.0"]?.status, .isDefault("rustup’s default toolchain"))
        XCTAssertEqual(r["Rust nightly-2024-01-05"]?.status, .isDefault("Set for a folder with rustup override"))
        XCTAssertFalse(r["Rust 1.70.0"]!.goesToTrash)
    }

    func testOddFolderNamesAreNeverListed() throws {
        try mkdir(".nvm/versions/node/v16.20.2")
        try mkdir(".nvm/versions/node/system")
        try mkdir(".nvm/versions/node/v16.20.2-custom")
        try FileManager.default.createSymbolicLink(atPath: home + "/.nvm/versions/node/v99.0.0",
                                                   withDestinationPath: home + "/.nvm/versions/node/v16.20.2")
        let names = DevToolsScanner.installedVersions(paths: paths).map(\.folderName)
        XCTAssertEqual(names, ["v16.20.2"])
    }

    func testRecheckDropsVersionsAProjectNowAsksFor() throws {
        home = DevToolsScanner.realpathOrSelf(home)
        try nvmSetup()
        let roots = [home + "/code/legacy-api"]
        let first = DevToolsScanner.classify(DevToolsScanner.installedVersions(paths: paths),
                                             requests: roots.flatMap(VersionFiles.requests(inProject:)),
                                             defaults: DevToolsScanner.defaults(paths: paths), pythonUsers: [],
                                             running: [], kept: [], paths: paths)
        let unused = first.filter(\.isRemovable)
        XCTAssertEqual(unused.map(\.displayName), ["Node 16.20.2"])
        XCTAssertEqual(DevToolsRemover.recheckVersions(unused, projectRoots: roots, kept: [], paths: paths).ok.count, 1)
        try write("code/legacy-api/.nvmrc", "16\n")
        let again = DevToolsRemover.recheckVersions(unused, projectRoots: roots, kept: [], paths: paths)
        XCTAssertTrue(again.ok.isEmpty)
        XCTAssertEqual(again.skipped, 1)
    }

    func testRecheckRefusesFoldersReachedThroughALink() throws {
        home = DevToolsScanner.realpathOrSelf(home)
        try mkdir("real-nvm/versions/node/v16.20.2")
        try FileManager.default.createSymbolicLink(atPath: home + "/.nvm", withDestinationPath: home + "/real-nvm")
        let listed = DevToolsScanner.installedVersions(paths: paths)
        XCTAssertEqual(listed.count, 1, "Listing through a moved tool folder is fine")
        XCTAssertTrue(DevToolsRemover.recheckVersions(listed, projectRoots: [], kept: [], paths: paths).ok.isEmpty,
                      "Removing through a link never is")
    }
}

final class DevToolsHomebrewTests: XCTestCase {
    private typealias F = DevToolsScanner.Formula
    private typealias R = DevToolsScanner.Receipt

    func testBrewVersionOrder() {
        XCTAssertEqual(DevToolsScanner.brewVersionLess("3.12.4", "3.12.8"), true)
        XCTAssertEqual(DevToolsScanner.brewVersionLess("1.2.3_1", "1.2.3"), false)
        XCTAssertEqual(DevToolsScanner.brewVersionLess("1.2.3", "1.2.3_1"), true)
        XCTAssertEqual(DevToolsScanner.brewVersionLess("1.2", "1.10"), true)
        XCTAssertNil(DevToolsScanner.brewVersionLess("2024a", "2024b"))
    }

    func testOlderVersionsOnlyWhenLinkedIsNewestAndNotPinned() {
        let cellar = "/opt/homebrew/Cellar"
        let ok = F(name: "python@3.12", versions: ["3.12.4", "3.12.6", "3.12.8"], linked: "3.12.8", pinned: false, receipt: nil)
        let old = DevToolsScanner.oldVersions(of: ok, cellar: cellar)
        XCTAssertEqual(old?.oldVersions, ["3.12.6", "3.12.4"])
        XCTAssertEqual(old?.oldPaths.first, "/opt/homebrew/Cellar/python@3.12/3.12.6")
        XCTAssertNil(DevToolsScanner.oldVersions(of: F(name: "a", versions: ["1", "2"], linked: "2", pinned: true, receipt: nil), cellar: cellar))
        XCTAssertNil(DevToolsScanner.oldVersions(of: F(name: "a", versions: ["1", "2"], linked: "1", pinned: false, receipt: nil), cellar: cellar),
                     "A newer keg than the linked one leaves the formula alone")
        XCTAssertNil(DevToolsScanner.oldVersions(of: F(name: "a", versions: ["1", "2"], linked: nil, pinned: false, receipt: nil), cellar: cellar))
        XCTAssertNil(DevToolsScanner.oldVersions(of: F(name: "a", versions: ["2"], linked: "2", pinned: false, receipt: nil), cellar: cellar))
    }

    func testLeavesExcludeDependenciesPinnedBrewfileAndToolPythons() {
        let cellar = "/opt/homebrew/Cellar"
        let all = [
            F(name: "ffmpeg", versions: ["7.1"], linked: "7.1", pinned: false,
              receipt: R(installedOnRequest: true, runtimeDependencies: ["x264"], time: 1_600_000_000)),
            F(name: "x264", versions: ["1"], linked: "1", pinned: false,
              receipt: R(installedOnRequest: true, runtimeDependencies: [], time: nil)),
            F(name: "wget", versions: ["1.24"], linked: "1.24", pinned: true,
              receipt: R(installedOnRequest: true, runtimeDependencies: [], time: nil)),
            F(name: "jq", versions: ["1.7"], linked: "1.7", pinned: false,
              receipt: R(installedOnRequest: true, runtimeDependencies: [], time: nil)),
            F(name: "python@3.12", versions: ["3.12.8"], linked: "3.12.8", pinned: false,
              receipt: R(installedOnRequest: true, runtimeDependencies: [], time: nil)),
            F(name: "libpng", versions: ["1.6"], linked: "1.6", pinned: false,
              receipt: R(installedOnRequest: false, runtimeDependencies: [], time: nil)),
        ]
        let leaves = DevToolsScanner.leafFormulae(all, cellar: cellar, projectFormulae: ["jq"],
                                                  pythonHomes: ["/opt/homebrew/Cellar/python@3.12/3.12.8/bin"])
        XCTAssertEqual(leaves.map(\.name), ["ffmpeg"])
        XCTAssertEqual(leaves.first?.installedDate, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(leaves.first?.path, "/opt/homebrew/Cellar/ffmpeg/7.1")
    }

    func testAnUnreadableReceiptListsNoLeaves() {
        let all = [
            F(name: "ffmpeg", versions: ["7.1"], linked: "7.1", pinned: false,
              receipt: R(installedOnRequest: true, runtimeDependencies: [], time: nil)),
            F(name: "mystery", versions: ["1"], linked: "1", pinned: false, receipt: nil),
        ]
        XCTAssertTrue(DevToolsScanner.leafFormulae(all, cellar: "/c", projectFormulae: [], pythonHomes: []).isEmpty)
    }

    func testReceiptParsingAndNames() {
        let r = R(json: #"{"installed_on_request": true, "time": 1700000000, "runtime_dependencies": [{"full_name": "homebrew/core/openssl@3"}]}"#)
        XCTAssertEqual(r?.installedOnRequest, true)
        XCTAssertEqual(r?.runtimeDependencies, ["openssl@3"])
        XCTAssertEqual(DevToolsScanner.newerSibling("postgresql@14", among: ["postgresql@14", "postgresql@17", "postgresql@16"]), "postgresql@17")
        XCTAssertNil(DevToolsScanner.newerSibling("node", among: ["node", "node@18"]))
        XCTAssertTrue(DevToolsScanner.isFormulaName("python@3.12"))
        XCTAssertFalse(DevToolsScanner.isFormulaName("--force"))
        XCTAssertTrue(DevToolsScanner.isPackageName("@angular/cli", manager: .npm))
        XCTAssertFalse(DevToolsScanner.isPackageName("-g", manager: .npm))
        XCTAssertFalse(DevToolsScanner.isPackageName("../x", manager: .pipx))
    }

    func testBrewfileFormulae() throws {
        let dir = try devToolsTempDir()
        try "tap \"x/y\"\nbrew \"jq\"\nbrew 'user/tap/thing', args: []\ncask \"firefox\"\n".write(
            toFile: dir + "/Brewfile", atomically: true, encoding: .utf8)
        XCTAssertEqual(DevToolsScanner.brewfileFormulae(dir), ["jq", "thing"])
    }
}

final class DevToolsOverviewTests: XCTestCase {
    func testOldVersionsAddToQuickLookOnly() {
        let unused = DevVersion(language: .node, manager: .nvm, version: DevVersionNumber([16, 20, 2]), folderName: "v16.20.2",
                                path: "/Users/me/.nvm/versions/node/v16.20.2", sizeBytes: 182_000_000, status: .unused)
        var locked = unused
        locked.status = .isDefault("x")
        let steps = SpaceSteps.make(plan: AppState.SafeCleanupPlan(), worktrees: [], duplicates: [], leftovers: [],
                                    largeFiles: [], oldVersions: [unused, locked])
        XCTAssertEqual(steps.oldVersionBytes, 182_000_000)
        XCTAssertEqual(steps.oldVersionCount, 1)
        XCTAssertEqual(steps.quickLookBytes, 182_000_000)
        XCTAssertEqual(steps.trayBytes, 0)
    }

    func testCopy() {
        XCTAssertEqual(DevToolsCopy.list(["Node 16.20.2", "Python 3.9.18"]), "Node 16.20.2 and Python 3.9.18")
        let now = Date()
        XCTAssertEqual(DevToolsCopy.age(now.addingTimeInterval(-800 * 86_400), now: now), "2 years ago")
        XCTAssertEqual(DevToolsCopy.age(now.addingTimeInterval(-430 * 86_400), now: now), "14 months ago")
    }
}

func devToolsTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("furl-devtools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

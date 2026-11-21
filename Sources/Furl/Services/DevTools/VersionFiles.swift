import Foundation

/// One version a project's file asks for.
struct VersionRequest: Hashable, Sendable {
    let language: DevLanguage
    let spec: VersionSpec
    /// The project folder, and the file name inside it (e.g. ".nvmrc").
    let project: String
    let file: String
}

/// Reads the version files Furl looks for in each project it already found. Every file is untrusted:
/// only regular files (never a symlink) up to 256 KB, and anything ambiguous reads as `.unreadable`.
enum VersionFiles {
    static let nodeFiles = [".nvmrc", ".node-version"]
    static let names: [String] = [".nvmrc", ".node-version", ".tool-versions", "package.json", ".python-version",
                                  "pyproject.toml", "rust-toolchain", "rust-toolchain.toml", "mise.toml", ".mise.toml"]
    /// Virtualenvs in a project point at the Python they were made from.
    static let venvConfigs = [".venv/pyvenv.cfg", "venv/pyvenv.cfg"]
    private static let maxBytes = 256 * 1024

    /// Requests from one project folder (and its direct subfolders, for monorepo packages).
    static func requests(inProject root: String) -> [VersionRequest] {
        var out: [VersionRequest] = []
        for dir in [root] + subfolders(of: root) {
            for name in names {
                guard let text = readSmallFile((dir as NSString).appendingPathComponent(name)) else { continue }
                let where_ = dir == root ? name : "\((dir as NSString).lastPathComponent)/\(name)"
                out += parse(name: name, contents: text).map {
                    VersionRequest(language: $0.0, spec: $0.1, project: root, file: where_)
                }
            }
            for cfg in venvConfigs {
                guard let text = readSmallFile((dir as NSString).appendingPathComponent(cfg)),
                      let home = venvHome(text) else { continue }
                out.append(VersionRequest(language: .python, spec: .path(home), project: root, file: cfg))
            }
        }
        return out
    }

    /// Visible direct subfolders, skipping dependency and build folders. Capped so a huge folder of
    /// folders can't slow the scan.
    private static func subfolders(of root: String) -> [String] {
        let skip: Set<String> = ["node_modules", "build", "dist", "target", "vendor", "Pods", "DerivedData"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") && !skip.contains(name) {
            let path = (root as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            out.append(path)
            if out.count >= 200 { break }
        }
        return out
    }

    /// Contents of a regular file no bigger than 256 KB, as UTF-8; nil for links, folders, big files.
    static func readSmallFile(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What one file asks for, by file name.
    static func parse(name: String, contents: String) -> [(DevLanguage, VersionSpec)] {
        switch name {
        case ".nvmrc", ".node-version":
            guard let line = firstValue(contents) else { return [] }
            return [(.node, nodeSpec(line))]
        case ".python-version":
            return valueLines(contents).compactMap { line in
                line == "system" ? nil : (.python, pythonSpec(line))
            }
        case ".tool-versions":
            return toolVersions(contents)
        case "package.json":
            return packageJSON(contents)
        case "pyproject.toml":
            return pyproject(contents)
        case "rust-toolchain", "rust-toolchain.toml":
            return rustToolchain(contents).map { [(.rust, $0)] } ?? []
        case "mise.toml", ".mise.toml":
            return miseTools(contents)
        default:
            return []
        }
    }

    // MARK: - Node

    /// Node's LTS code names, for "lts/hydrogen" and friends.
    static let ltsNames: [String: Int] = [
        "argon": 4, "boron": 6, "carbon": 8, "dubnium": 10, "erbium": 12, "fermium": 14,
        "gallium": 16, "hydrogen": 18, "iron": 20, "jod": 22, "krypton": 24
    ]

    static func nodeSpec(_ raw: String) -> VersionSpec {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "node", "latest", "stable", "current": return .newest
        case "lts/*", "lts", "--lts": return .newestLTS
        default: break
        }
        if value.hasPrefix("lts/") {
            guard let major = ltsNames[String(value.dropFirst(4))] else { return .unreadable }
            return .ranges([VersionRange(lower: DevVersionNumber([major]), upper: DevVersionNumber([major + 1]))])
        }
        if let ranges = VersionRangeParser.parse(value) { return .ranges(ranges) }
        // Anything else could be an nvm alias; the scanner resolves names it knows.
        return isPlainName(value) ? .name(value) : .unreadable
    }

    private static func packageJSON(_ text: String) -> [(DevLanguage, VersionSpec)] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [(DevLanguage, VersionSpec)] = []
        for key in ["engines", "volta"] {
            guard let block = object[key] else { continue }
            guard let dict = block as? [String: Any] else { continue }
            if let node = dict["node"] {
                guard let value = node as? String else { out.append((.node, .unreadable)); continue }
                out.append((.node, key == "volta" ? nodeSpec(value) : rangeOrUnreadable(value)))
            }
        }
        return out
    }

    // MARK: - Python

    static func pythonSpec(_ raw: String) -> VersionSpec {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if DevVersionNumber(parsing: value) != nil, let ranges = VersionRangeParser.parse(value) { return .ranges(ranges) }
        // "pypy3.9-7.3.9", "miniconda3-latest" or a pyenv virtualenv name.
        return isPlainName(value) ? .name(value) : .unreadable
    }

    private static func pyproject(_ text: String) -> [(DevLanguage, VersionSpec)] {
        var out: [(DevLanguage, VersionSpec)] = []
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard let (key, value) = keyValue(line) else { continue }
            let isRequires = key == "requires-python" && section == "[project]"
            let isPoetry = key == "python" && section == "[tool.poetry.dependencies]"
            guard isRequires || isPoetry else { continue }
            guard let string = quoted(value) else { out.append((.python, .unreadable)); continue }
            out.append((.python, rangeOrUnreadable(string)))
        }
        return out
    }

    /// `home = /Users/me/.pyenv/versions/3.9.18/bin` from a pyvenv.cfg.
    static func venvHome(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "home" else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("/") ? value : nil
        }
        return nil
    }

    // MARK: - Rust

    static func rustToolchain(_ text: String) -> VersionSpec? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Old plain format: one line naming the toolchain.
        if !trimmed.contains("[") && !trimmed.contains("=") {
            guard let line = firstValue(trimmed) else { return nil }
            return isPlainName(line) ? .name(line) : .unreadable
        }
        var section = ""
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[toolchain]", let (key, value) = keyValue(line) else { continue }
            if key == "path" { return nil }  // A custom toolchain folder, not one rustup lists.
            if key == "channel" {
                guard let name = quoted(value), isPlainName(name) else { return .unreadable }
                return .name(name)
            }
        }
        // A toolchain file with no channel uses the default toolchain.
        return nil
    }

    // MARK: - asdf / mise

    /// Tool names asdf and mise use for each language.
    private static func language(forTool tool: String) -> DevLanguage? {
        switch tool.lowercased() {
        case "node", "nodejs": return .node
        case "python": return .python
        case "rust": return .rust
        default: return nil
        }
    }

    static func toolVersions(_ text: String) -> [(DevLanguage, VersionSpec)] {
        var out: [(DevLanguage, VersionSpec)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let parts = stripComment(rawLine).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, let lang = language(forTool: parts[0]) else { continue }
            for value in parts.dropFirst() where value != "system" {
                out.append((lang, spec(value, for: lang)))
            }
        }
        return out
    }

    /// `[tools]` in mise.toml: `node = "20"`, `python = ["3.11", "3.10"]`, `node = { version = "20" }`.
    static func miseTools(_ text: String) -> [(DevLanguage, VersionSpec)] {
        var out: [(DevLanguage, VersionSpec)] = []
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[tools]", let (key, value) = keyValue(line),
                  let lang = language(forTool: key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) else { continue }
            let values = miseValues(value)
            if values.isEmpty { out.append((lang, .unreadable)) }
            for v in values where v != "system" { out.append((lang, spec(v, for: lang))) }
        }
        return out
    }

    private static func miseValues(_ value: String) -> [String] {
        if let single = quoted(value) { return [single] }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let strings = inner.compactMap(quoted)
            return strings.count == inner.count ? strings : []
        }
        if value.hasPrefix("{"), let range = value.range(of: #"version\s*=\s*("[^"]*"|'[^']*')"#, options: .regularExpression) {
            let match = String(value[range])
            if let eq = match.firstIndex(of: "="), let v = quoted(match[match.index(after: eq)...].trimmingCharacters(in: .whitespaces)) {
                return [v]
            }
        }
        return []
    }

    private static func spec(_ value: String, for lang: DevLanguage) -> VersionSpec {
        switch lang {
        case .node: return nodeSpec(value)
        case .python: return pythonSpec(value)
        case .rust: return isPlainName(value) ? .name(value) : .unreadable
        }
    }

    // MARK: - Small helpers

    private static func rangeOrUnreadable(_ value: String) -> VersionSpec {
        VersionRangeParser.parse(value).map { .ranges($0) } ?? .unreadable
    }

    /// Letters, digits and `._-/+` only, 1 to 64 characters, not starting with `-`.
    static func isPlainName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64, s.first != "-" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-/+".unicodeScalars.contains($0) }
    }

    private static func valueLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { stripComment($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func firstValue(_ text: String) -> String? { valueLines(text).first }

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash])
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func quoted(_ value: String) -> String? {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return nil }
        let inner = String(value.dropFirst().dropLast())
        return inner.contains(first) ? nil : inner
    }
}

import Foundation

/// The languages whose installed versions Furl compares against what projects ask for.
enum DevLanguage: String, Sendable, Hashable, CaseIterable, Codable {
    case node = "Node"
    case python = "Python"
    case rust = "Rust"

    /// How much of a version a project request pins down for this language: Node by major (the board's
    /// "no project asks for that major version"), Python by major.minor. Rust toolchains match by name.
    var granularity: Int {
        switch self {
        case .node: return 1
        case .python: return 2
        case .rust: return 3
        }
    }
}

/// A plain three-part version (missing parts are 0) for comparing installs and requests.
struct DevVersionNumber: Hashable, Comparable, Sendable {
    let parts: [Int]

    init(_ parts: [Int]) {
        var p = Array(parts.prefix(3))
        while p.count < 3 { p.append(0) }
        self.parts = p
    }

    /// "v16.20.2", "3.12.1", "1.70" → numbers; nil for anything else. Trailing text after the numbers
    /// (e.g. "3.13.0rc1", "1.70.0-aarch64-apple-darwin") is ignored.
    init?(parsing text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        var parts: [Int] = []
        var digits = ""
        for ch in s {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
                guard digits.count <= 6 else { return nil }
            } else if ch == "." && !digits.isEmpty && parts.count < 2 {
                parts.append(Int(digits)!)
                digits = ""
            } else {
                break
            }
        }
        guard !digits.isEmpty else { return nil }
        parts.append(Int(digits)!)
        self.init(parts)
    }

    static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }

    var string: String { parts.map(String.init).joined(separator: ".") }

    /// "16" for Node, "3.9" for Python: the part a request is compared on.
    func prefix(_ count: Int) -> String { parts.prefix(count).map(String.init).joined(separator: ".") }
}

/// What one version file asks for. Contents come from projects on disk and are untrusted: anything
/// Furl can't read with certainty becomes `.unreadable`, which keeps every version of that language.
enum VersionSpec: Hashable, Sendable {
    /// Alternatives (OR) of comparator sets (AND), each a half-open range.
    case ranges([VersionRange])
    /// "node", "latest", "stable", "current": the newest installed version.
    case newest
    /// "lts/*": the newest installed even-numbered Node major.
    case newestLTS
    /// A name: a pyenv virtualenv, a Rust toolchain or channel, "pypy3.9-7.3.9", an nvm alias.
    case name(String)
    /// A Python install path (a virtualenv's `home =`), matched against version folders.
    case path(String)
    /// Furl can't tell what this asks for.
    case unreadable

    /// Whether `version` falls in what this asks for at `granularity` (1 = same major, 2 = same minor).
    func asks(_ version: DevVersionNumber, granularity: Int) -> Bool {
        guard case .ranges(let alternatives) = self else { return false }
        let bucket = VersionRange.bucket(version, granularity: granularity)
        return alternatives.contains { $0.overlaps(bucket) }
    }
}

/// A half-open range [lower, upper) over three-part versions; nil upper means no limit.
struct VersionRange: Hashable, Sendable {
    var lower: DevVersionNumber
    var upper: DevVersionNumber?

    static let all = VersionRange(lower: DevVersionNumber([0]), upper: nil)

    func overlaps(_ other: VersionRange) -> Bool {
        let lo = max(lower, other.lower)
        switch (upper, other.upper) {
        case (nil, nil): return true
        case (let u?, nil), (nil, let u?): return lo < u
        case (let a?, let b?): return lo < min(a, b)
        }
    }

    func intersect(_ other: VersionRange) -> VersionRange {
        let hi: DevVersionNumber?
        switch (upper, other.upper) {
        case (nil, nil): hi = nil
        case (let u?, nil), (nil, let u?): hi = u
        case (let a?, let b?): hi = min(a, b)
        }
        return VersionRange(lower: max(lower, other.lower), upper: hi)
    }

    var isEmpty: Bool { upper.map { lower >= $0 } ?? false }

    /// All versions that share `version`'s first `granularity` parts.
    static func bucket(_ version: DevVersionNumber, granularity: Int) -> VersionRange {
        let g = max(1, min(3, granularity))
        let lower = Array(version.parts.prefix(g))
        var upper = lower
        upper[g - 1] += 1
        return VersionRange(lower: DevVersionNumber(lower), upper: DevVersionNumber(upper))
    }
}

/// Reads npm-style (`^18 || >=20.1 <21`, `18.x`, `1.2 - 2.3`) and PEP 440 (`>=3.9,<3.13`, `~=3.10`,
/// `==3.11.*`) version specifiers into ranges. Returns nil for anything it doesn't fully understand.
enum VersionRangeParser {
    static func parse(_ raw: String) -> [VersionRange]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 256 else { return nil }
        if text.isEmpty || text == "*" || text.lowercased() == "x" { return [.all] }
        var result: [VersionRange] = []
        for alternative in text.components(separatedBy: "||") {
            guard let range = parseSet(alternative) else { return nil }
            if !range.isEmpty { result.append(range) }
        }
        return result
    }

    /// One AND-ed comparator set.
    private static func parseSet(_ raw: String) -> VersionRange? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "*" || text.lowercased() == "x" { return .all }
        // Hyphen range: "1.2.3 - 2.3".
        let hyphen = text.components(separatedBy: " - ")
        if hyphen.count == 2 {
            guard let lo = Partial(hyphen[0]), let hi = Partial(hyphen[1]) else { return nil }
            return VersionRange(lower: lo.floor, upper: hi.ceiling)
        }
        // PEP 440 separates with commas; npm with spaces. Glue an operator to its version ("> = 3" never
        // appears, but ">= 3.9" does).
        text = text.replacingOccurrences(of: ",", with: " ")
        var tokens: [String] = []
        for piece in text.split(separator: " ").map(String.init) {
            if let last = tokens.last, isBareOperator(last) {
                tokens[tokens.count - 1] = last + piece
            } else {
                tokens.append(piece)
            }
        }
        var range = VersionRange.all
        for token in tokens {
            guard let r = comparator(token) else { return nil }
            range = range.intersect(r)
        }
        return range
    }

    private static let operators = ["===", "~=", "==", "!=", ">=", "<=", ">", "<", "^", "~", "="]

    private static func isBareOperator(_ token: String) -> Bool { operators.contains(token) }

    private static func comparator(_ token: String) -> VersionRange? {
        let op = operators.first(where: { token.hasPrefix($0) }) ?? ""
        let rest = String(token.dropFirst(op.count))
        if op == "!=" {
            // Excluding one version never rules out a whole major or minor; treat as no limit.
            return Partial(rest) == nil ? nil : .all
        }
        guard let v = Partial(rest) else { return nil }
        switch op {
        case "", "=", "==", "===":
            return VersionRange(lower: v.floor, upper: v.ceiling)
        case ">=":
            return VersionRange(lower: v.floor, upper: nil)
        case ">":
            // ">16" means 17 and up; ">16.2.1" means anything after 16.2.1.
            return VersionRange(lower: v.isFull ? v.next : v.ceiling, upper: nil)
        case "<":
            return VersionRange(lower: DevVersionNumber([0]), upper: v.floor)
        case "<=":
            return VersionRange(lower: DevVersionNumber([0]), upper: v.isFull ? v.next : v.ceiling)
        case "^":
            return VersionRange(lower: v.floor, upper: v.caretCeiling)
        case "~":
            return VersionRange(lower: v.floor, upper: v.tildeCeiling)
        case "~=":
            // PEP 440: ~=3.10 → >=3.10,<4; ~=3.10.2 → >=3.10.2,<3.11. Needs at least two parts.
            guard v.given.count >= 2 else { return nil }
            var up = Array(v.given.dropLast())
            up[up.count - 1] += 1
            return VersionRange(lower: v.floor, upper: DevVersionNumber(up))
        default:
            return nil
        }
    }

    /// A version that may stop early or end in a wildcard: "18", "18.x", "3.11.*", "v16.20.2".
    struct Partial: Equatable {
        let given: [Int]

        init?(_ raw: String) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            // npm prerelease/build tags ("18.0.0-rc.1") and PEP 440 suffixes ("3.13.0rc1") pin to the
            // numbers before them.
            if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
            guard !s.isEmpty else { return nil }
            var parts: [Int] = []
            for (i, piece) in s.split(separator: ".", omittingEmptySubsequences: false).enumerated() {
                guard i < 3 else { return nil }
                if piece == "x" || piece == "X" || piece == "*" { break }
                let digits = piece.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty, digits.count <= 6 else { return nil }
                // Only a last part may carry a suffix ("0rc1").
                if digits.count != piece.count {
                    let suffix = piece.dropFirst(digits.count).lowercased()
                    guard ["a", "b", "rc", "c", "dev", "post", "pre", "alpha", "beta"].contains(where: { suffix.hasPrefix($0) })
                    else { return nil }
                }
                parts.append(Int(digits)!)
                if digits.count != piece.count { break }
            }
            guard !parts.isEmpty else { return nil }
            given = parts
        }

        var isFull: Bool { given.count == 3 }
        var floor: DevVersionNumber { DevVersionNumber(given) }
        /// The first version past everything this partial covers ("18" → 19.0.0, "16.2.1" → 16.2.2).
        var ceiling: DevVersionNumber {
            var up = given
            up[up.count - 1] += 1
            return DevVersionNumber(up)
        }
        var next: DevVersionNumber { ceiling }

        /// npm caret: the leftmost non-zero part may not change.
        var caretCeiling: DevVersionNumber {
            let p = DevVersionNumber(given).parts
            if p[0] > 0 || given.count == 1 { return DevVersionNumber([p[0] + 1]) }
            if p[1] > 0 || given.count == 2 { return DevVersionNumber([0, p[1] + 1]) }
            return DevVersionNumber([0, 0, p[2] + 1])
        }

        /// npm tilde: patch changes if a minor is given, otherwise minor changes.
        var tildeCeiling: DevVersionNumber {
            if given.count == 1 { return DevVersionNumber([given[0] + 1]) }
            return DevVersionNumber([given[0], given[1] + 1])
        }
    }
}

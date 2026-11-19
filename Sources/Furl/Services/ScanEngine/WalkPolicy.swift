import Foundation

/// Decides, per directory, whether the walker indexes it, only sizes it, or skips it.
/// Defaults are the union of what the existing scanners skip, chosen so ONE walk can serve Junk, Large Files,
/// Duplicates, Smart Review and Space Map: anything those features never list file-by-file is sized once.
struct WalkPolicy: Sendable {
    /// Folder names whose contents are never individual decisions: sized once, contents not kept.
    var sizeOnlyNames: Set<String> = [
        "node_modules", ".git", "DerivedData", ".venv", "venv", "__pycache__", ".pytest_cache",
        ".next", ".turbo", ".nuxt", ".parcel-cache", "Pods", ".gradle", ".build", ".svn", ".hg"
    ]
    /// Packages (apps, Photos libraries, bundles…) are one item, as in Finder.
    var packagesAreSizeOnly = true
    /// Absolute paths never entered (e.g. firmlinked duplicates when walking "/").
    var skippedPaths: Set<String> = []
    /// Don't cross into other volumes mounted below the root.
    var stayOnVolume = true

    static let `default` = WalkPolicy()

    /// The same skips `SpaceAnalyzer` applies when the root is "/".
    static func forRoot(_ root: String) -> WalkPolicy {
        var policy = WalkPolicy()
        if root == "/" {
            policy.skippedPaths = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/net", "/home"]
        }
        return policy
    }

    @inline(__always)
    func classify(name: String, path: String, parentMode: DirMode, isPackage: Bool, isMountPoint: Bool) -> DirMode {
        if isMountPoint && stayOnVolume { return .skipped }
        if !skippedPaths.isEmpty && skippedPaths.contains(path) { return .skipped }
        if parentMode == .sizeOnly { return .sizeOnly }
        if isPackage && packagesAreSizeOnly { return .sizeOnly }
        if sizeOnlyNames.contains(name) { return .sizeOnly }
        return .indexed
    }

    var fingerprint: UInt64 {
        var h = FNV1a()
        for name in sizeOnlyNames.sorted() { h.add(name) }
        h.add(packagesAreSizeOnly ? "p1" : "p0")
        for path in skippedPaths.sorted() { h.add(path) }
        h.add(stayOnVolume ? "v1" : "v0")
        return h.value
    }
}

/// Which files (inside indexed folders) are kept as individual records. Everything is still counted in the
/// folder totals; this only bounds memory. Pick the smallest threshold any consumer needs.
struct RetainRule: Sendable {
    /// Smart Review looks at files ≥ 32 KB in Downloads/Desktop; everything else wants ≥ 512 KB or more.
    var minBytes: Int64 = 32 * 1024
    /// Always kept regardless of size: .DS_Store (Junk) and project markers (project-root discovery).
    var alwaysKeepNames: Set<String> {
        didSet { keepNameBytes = alwaysKeepNames.map { Array($0.utf8) } }
    }
    /// Byte forms of `alwaysKeepNames`, compared without decoding a String per small file.
    private var keepNameBytes: [[UInt8]]

    static let defaultKeepNames: Set<String> = Set([".DS_Store"]).union(ProjectRootDiscovery.markerFileNames)
    static let `default` = RetainRule()

    init(minBytes: Int64 = 32 * 1024, alwaysKeepNames: Set<String> = RetainRule.defaultKeepNames) {
        self.minBytes = minBytes
        self.alwaysKeepNames = alwaysKeepNames
        self.keepNameBytes = alwaysKeepNames.map { Array($0.utf8) }
    }

    @inline(__always)
    func keeps(_ entry: BulkEntry, name: UnsafeRawBufferPointer) -> Bool {
        if entry.displaySize >= minBytes || entry.logicalSize >= minBytes { return true }
        for candidate in keepNameBytes where candidate.count == name.count {
            if candidate.withUnsafeBytes({ memcmp($0.baseAddress, name.baseAddress, name.count) == 0 }) { return true }
        }
        return false
    }

    var fingerprint: UInt64 {
        var h = FNV1a()
        h.add("\(minBytes)")
        for name in alwaysKeepNames.sorted() { h.add(name) }
        return h.value
    }
}

struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
        value ^= 0xff
        value &*= 0x0000_0100_0000_01B3
    }
}

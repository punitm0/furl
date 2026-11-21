import Darwin
import DiskArbitration
import Foundation

/// Where the running Furl.app lives, and whether it should offer to move itself to Applications
/// (InstallHandoff board). The decisions are pure functions so tests can drive them with made-up paths.
enum InstallLocation {
    enum Place: Equatable, Sendable {
        /// /Applications or ~/Applications (or a folder inside them). No offer.
        case applications
        /// A read-only, ejectable volume: the disk image. `volume` is its mount point.
        case diskImage(volume: URL)
        /// macOS's hidden read-only copy of a downloaded app. `original` is the download, when known.
        case translocated(original: URL?)
        /// Any other folder, like Downloads or the Desktop.
        case otherFolder(URL)
        /// Not a bundled app (`swift run`), so there is nothing to move.
        case notAnApp

        var offersMove: Bool {
            switch self {
            case .applications, .notAnApp: return false
            case .diskImage, .translocated, .otherFolder: return true
            }
        }
    }

    struct VolumeFacts: Equatable, Sendable {
        var mountPoint: URL
        var isReadOnly: Bool
        var isEjectable: Bool
        /// Backed by a disk image. A read-only USB stick, SD card or network share is never ejected.
        var isDiskImage: Bool
    }

    /// The folder name every copy is installed under.
    static let bundleName = "Furl.app"

    // MARK: - Decide

    /// - Parameters:
    ///   - bundlePath: the running bundle's path.
    ///   - originalPath: for a translocated bundle, where the app really is (nil when unknown or not translocated).
    ///   - volume: facts about the volume holding a path (nil when they can't be read).
    ///   - cameFromHandoff: the old copy opened this one after moving it (launch argument).
    static func classify(bundlePath: String, originalPath: String?, homeDirectory: String,
                         cameFromHandoff: Bool = false, volume: (String) -> VolumeFacts?) -> Place {
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return .notAnApp }
        let translocated = isTranslocatedPath(bundlePath)
        // A translocated copy is judged by where the real app is: one already in Applications is
        // done (a copy there can itself be translocated, and offering again would loop).
        let effective = translocated ? originalPath : bundlePath
        guard let effective else {
            // The copy Furl just opened, translocated by macOS with no way to read the original path:
            // treat it as done rather than offering the move again.
            return cameFromHandoff ? .applications : .translocated(original: nil)
        }
        if isInApplications(effective, homeDirectory: homeDirectory) { return .applications }
        if let facts = volume(effective), facts.isReadOnly, facts.isEjectable, facts.isDiskImage,
           facts.mountPoint.path != "/" {
            // Volume URLs come back with a trailing slash; keep one spelling.
            return .diskImage(volume: URL(fileURLWithPath: facts.mountPoint.path))
        }
        if translocated { return .translocated(original: URL(fileURLWithPath: effective)) }
        return .otherFolder(URL(fileURLWithPath: URL(fileURLWithPath: effective).deletingLastPathComponent().path))
    }

    /// macOS runs quarantined downloads from a random read-only path under .../AppTranslocation/.
    static func isTranslocatedPath(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// "/Applications". A debug update-test copy can point it at a scratch folder with
    /// `FurlMoveTestApplications`, so the move can be tested without touching the real Furl.
    static var systemApplications: String {
        #if DEBUG
        if UpdateTestMode.isActive, let path = UserDefaults.standard.string(forKey: "FurlMoveTestApplications"),
           path.hasPrefix("/") { return path }
        #endif
        return "/Applications"
    }

    /// ~/Applications counts as Applications (board decision), and so do folders inside either.
    static func isInApplications(_ bundlePath: String, homeDirectory: String) -> Bool {
        let parent = components(URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path)
        let roots = [components(systemApplications), components(homeDirectory) + ["Applications"]]
        return roots.contains { root in parent.count >= root.count && Array(parent.prefix(root.count)) == root }
    }

    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.path
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - A copy already in Applications

    enum Existing: Equatable, Sendable {
        case none
        /// Our app, older than this one: "Replace It" is offered.
        case older(version: String)
        /// Our app, same version or newer: only "Open the One in Applications".
        case sameOrNewer(version: String)
        /// Something else is at that name (another app, a file, a link). Never touched.
        case notFurl
    }

    static func compareExisting(identifier: String?, version: String?, isDirectory: Bool,
                                ourIdentifier: String, ourVersion: String) -> Existing {
        guard isDirectory, identifier == ourIdentifier, let version, !version.isEmpty else { return .notFurl }
        return UpdateChecker.isNewer(ourVersion, than: version) ? .older(version: version) : .sameOrNewer(version: version)
    }

    // MARK: - Read the running system

    /// The place of the running app.
    static func current(bundleURL: URL = Bundle.main.bundleURL) -> Place {
        let path = bundleURL.path
        let original = isTranslocatedPath(path) ? Translocation.originalURL(of: bundleURL)?.path : nil
        let handoff = ProcessInfo.processInfo.arguments.contains(InstallHandoff.Argument.movedFrom)
        return classify(bundlePath: path, originalPath: original, homeDirectory: NSHomeDirectory(),
                        cameFromHandoff: handoff, volume: volumeFacts(for:))
    }

    static func volumeFacts(for path: String) -> VolumeFacts? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey, .volumeIsEjectableKey]),
              let mount = values.volume else { return nil }
        return VolumeFacts(mountPoint: mount, isReadOnly: values.volumeIsReadOnly ?? false,
                           isEjectable: values.volumeIsEjectable ?? false, isDiskImage: isDiskImage(mount))
    }

    /// DiskArbitration reports "Disk Image" as the device model of a mounted .dmg.
    static func isDiskImage(_ mount: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (description[kDADiskDescriptionDeviceModelKey] as? String)?
            .trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    /// Where the copy goes: /Applications/Furl.app, unless the user keeps Furl in ~/Applications.
    static func destinations(homeDirectory: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: systemApplications, isDirectory: true).appendingPathComponent(bundleName),
         URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true).appendingPathComponent(bundleName)]
    }

    /// Bundle id and version at `url`, without following a link at the top.
    static func bundleFacts(at url: URL) -> (exists: Bool, isDirectory: Bool, identifier: String?, version: String?) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return (false, false, nil, nil) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return (true, false, nil, nil) }
        let dict = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (true, true, dict?["CFBundleIdentifier"] as? String, dict?["CFBundleShortVersionString"] as? String)
    }
}

/// The Security framework's App Translocation calls. They are exported but not in the SDK headers,
/// so they're looked up at run time; if they are missing, Furl simply doesn't know the original path.
enum Translocation {
    private typealias OriginalPathFunction = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    static func originalURL(of url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
                ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPathFunction.self)
        guard let original = function(url as CFURL, nil)?.takeRetainedValue() as URL? else { return nil }
        return original.standardizedFileURL
    }
}

/// Copies the running bundle into Applications. Every failure leaves Applications as it was.
enum AppMover {
    struct Failure: Error, Equatable {
        enum Kind: Equatable { case noPermission, other }
        let kind: Kind
        let message: String
    }

    /// Copies `source` to `destination` (which must not exist, or must be the `replacing` copy, which is
    /// swapped out and moved to the Trash). `trash` is replaceable for tests. `progress` gets 0…1.
    /// Runs off the main thread.
    static func copy(_ source: URL, to destination: URL, replacing: InstallLocation.Existing,
                     ourIdentifier: String, ourVersion: String,
                     trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                     progress: @escaping @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path), folder.path != "/Applications" {
            // ~/Applications only ever gets used when a Furl is already there, but be safe.
            try? fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw Failure(kind: .noPermission,
                          message: "Your account can’t add apps to Applications. Drag Furl there in Finder instead, then open it from Applications. Nothing was changed.")
        }

        // Work folder on the destination's volume, so the last step is a single rename.
        let work: URL
        do {
            work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        } catch {
            throw Failure(kind: .other, message: "Furl couldn’t prepare the copy. Nothing was changed.")
        }
        // Kept when the old Furl is stuck inside it (see the swap-back below), so it's never deleted.
        var keepWork = false
        defer { if !keepWork { try? fm.removeItem(at: work) } }
        let staged = work.appendingPathComponent(InstallLocation.bundleName, isDirectory: true)

        // ditto keeps the bundle exactly as it is: symlinks, the code signature and the extended
        // attributes, including the quarantine flags that carry the user's approval.
        let total = max(1, bundleBytes(source))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = ShellOutput(exitCode: -1, stdout: "", stderr: "")
        DispatchQueue.global(qos: .userInitiated).async {
            result = ShellRunner.run("/usr/bin/ditto", arguments: [source.path, staged.path], timeout: 300)
            done.signal()
        }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            progress(min(0.99, Double(bundleBytes(staged)) / Double(total)))
        }
        guard result.exitCode == 0 else {
            throw Failure(kind: .other, message: "Furl couldn’t copy itself to Applications. Nothing was changed.")
        }
        progress(1)

        // What gets installed is the copy, so check the copy: same app, signature still valid.
        let copied = InstallLocation.bundleFacts(at: staged)
        guard copied.identifier == ourIdentifier, copied.version == ourVersion, signatureIsValid(staged, identifier: ourIdentifier) else {
            throw Failure(kind: .other, message: "The copy didn’t match the original, so it wasn’t installed. Nothing was changed.")
        }

        // Right before acting: what's at the destination is still what the user was told about.
        let now = InstallLocation.bundleFacts(at: destination)
        let current: InstallLocation.Existing = now.exists
            ? InstallLocation.compareExisting(identifier: now.identifier, version: now.version, isDirectory: now.isDirectory,
                                              ourIdentifier: ourIdentifier, ourVersion: ourVersion)
            : .none
        guard current == replacing else {
            throw Failure(kind: .other, message: "Applications changed while Furl was copying. Nothing was changed.")
        }
        switch replacing {
        case .none:
            // Exclusive rename: never replaces anything that appeared in the meantime.
            guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure(kind: .other, message: "Furl couldn’t be put in Applications. Nothing was changed.")
            }
        case .older:
            // Atomic swap, so Applications is never left without a Furl. Then check that what came out
            // is the older Furl the user was told about; if not, swap back.
            guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure(kind: .other, message: "Furl couldn’t be put in Applications. Nothing was changed.")
            }
            let old = InstallLocation.bundleFacts(at: staged)
            let outcome = InstallLocation.compareExisting(identifier: old.identifier, version: old.version,
                                                          isDirectory: old.isDirectory,
                                                          ourIdentifier: ourIdentifier, ourVersion: ourVersion)
            guard outcome == replacing, (try? trash(staged)) != nil else {
                // Put the old one back; the new copy is removed with the work folder.
                if renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
                    keepWork = true
                    throw Failure(kind: .other, message: "Furl was put in Applications, but the older Furl couldn’t be moved to the Trash. It was kept here: \(staged.path)")
                }
                throw Failure(kind: .other, message: "The older Furl couldn’t be moved to the Trash. Nothing was changed.")
            }
        case .sameOrNewer, .notFurl:
            throw Failure(kind: .other, message: "Furl is already in Applications. Nothing was changed.")
        }
    }

    static func signatureIsValid(_ url: URL, identifier: String) -> Bool {
        ShellRunner.run("/usr/bin/codesign", arguments: [
            // "-R=<text>": the leading "=" makes codesign read an inline requirement, not a file.
            "--verify", "--strict", "-R=identifier \"\(identifier)\"", url.path,
        ], timeout: 120).exitCode == 0
    }

    /// Allocated bytes inside a bundle, without following links.
    static func bundleBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

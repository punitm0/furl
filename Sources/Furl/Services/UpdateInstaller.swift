import CryptoKit
import Darwin
import Foundation

/// Fixed facts about releases that Install and Relaunch relies on.
enum UpdateConfig {
    /// Base64 of the raw 32-byte Ed25519 public key whose private half signs each release's Furl.dmg
    /// (`scripts/sign_update.swift`). The checksum asset comes from the same GitHub release as the DMG,
    /// so it only catches broken downloads; this signature is what proves a release came from us.
    /// Empty: in-place install is off and the update card falls back to opening the release page.
    static let signingPublicKey = "IzXy9HA7PbGEyWsH0+ob6bwtc5i6Zdn/tAunuFUkk1E="

    /// The bundle id every installed and downloaded Furl must have.
    static var bundleIdentifier: String {
        #if DEBUG
        if UpdateTestMode.isActive, let id = Bundle.main.bundleIdentifier { return id }
        #endif
        return "app.getfurl.furl"
    }
    static let dmgAssetName = "Furl.dmg"
    static let checksumAssetName = "Furl.dmg.sha256"
    static let signatureAssetName = "Furl.dmg.sig"
    /// The DMG is about 10 MB; anything far bigger is not ours.
    static let maxDMGBytes: Int64 = 300_000_000
    /// Background checks run at most this often.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
}

/// Pure checks used before anything on disk is replaced. Kept separate so tests can drive them.
enum UpdateVerifier {
    /// The release JSON: GitHub's releases/latest (a local feed in an update-test debug build).
    static var releaseFeedURL: URL {
        #if DEBUG
        if let feed = UpdateTestMode.feedURL { return feed }
        #endif
        return SupportConfig.latestReleaseAPIURL
    }

    /// Only https://github.com/<repo>/releases/download/<tag>/<file>, nothing else (no query, port or userinfo).
    static func isAllowedAssetURL(_ url: URL, repository: String = SupportConfig.githubRepository) -> Bool {
        #if DEBUG
        if let feed = UpdateTestMode.feedURL {
            return url.scheme == "http" && url.host == feed.host && url.port == feed.port
        }
        #endif
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        let prefix = "/\(repository)/releases/download/"
        guard components.path.hasPrefix(prefix) else { return false }
        let parts = components.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Asset downloads redirect from github.com to GitHub's storage hosts; allow https to those only.
    static func isAllowedRedirect(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `shasum -a 256` output ("<hex>  Furl.dmg") or a bare hex digest → lowercase hex, or nil.
    static func expectedChecksum(from text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first
        else { return nil }
        let hex = first.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    static func checksumMatches(data: Data, checksumFile: String) -> Bool {
        guard let expected = expectedChecksum(from: checksumFile) else { return false }
        return sha256Hex(of: data) == expected
    }

    /// Ed25519 signature (base64, 64 bytes) over the DMG's bytes.
    static func isValidSignature(_ signatureBase64: String, for data: Data, publicKeyBase64: String) -> Bool {
        let trimmedKey = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSignature = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let keyData = Data(base64Encoded: trimmedKey), keyData.count == 32,
              let signature = Data(base64Encoded: trimmedSignature), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// Once-a-day throttle for the background check.
enum UpdateSchedule {
    static func isDue(enabled: Bool, lastCheck: Date?, now: Date,
                      interval: TimeInterval = UpdateConfig.automaticCheckInterval) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        // Clock moved backwards: the stored date can't be trusted, so check once and store the new one.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// Download, verify, swap and relaunch. Every failure before the swap leaves the running copy untouched.
enum UpdateInstaller {
    enum Phase: Equatable, Sendable {
        case downloading, verifying, installing
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    // MARK: - Can this copy update itself?

    /// Why this copy can't replace itself, in plain words, or nil when it can.
    static func installProblem(bundleURL: URL, bundleIdentifier: String?,
                               publicKey: String = UpdateConfig.signingPublicKey) -> String? {
        if publicKey.isEmpty { return "This build can't install updates by itself." }
        guard bundleURL.pathExtension == "app", bundleIdentifier == UpdateConfig.bundleIdentifier else {
            return "Only the Furl app can update itself."
        }
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") { return "Move Furl to your Applications folder first." }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return "Move Furl to your Applications folder first."
        }
        let parent = bundleURL.deletingLastPathComponent()
        if let readOnly = try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly, readOnly {
            return "Move Furl to your Applications folder first."
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return "You don't have permission to replace Furl in this folder."
        }
        return nil
    }

    // MARK: - Install

    /// Returns the installed app's URL. The caller relaunches.
    static func install(_ update: UpdateChecker.AvailableUpdate, currentVersion: String, bundleURL: URL,
                        progress: @escaping @Sendable (Phase) -> Void) async throws -> URL {
        if let problem = installProblem(bundleURL: bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier) {
            throw Failure(message: problem)
        }
        guard let dmgURL = update.dmgURL, let checksumURL = update.checksumURL, let signatureURL = update.signatureURL,
              [dmgURL, checksumURL, signatureURL].allSatisfy({ UpdateVerifier.isAllowedAssetURL($0) }) else {
            throw Failure(message: "This release can't be installed automatically.")
        }
        guard UpdateChecker.isNewer(update.version, than: currentVersion) else {
            throw Failure(message: "You already have this version.")
        }

        // Work folder on the same volume as the app, so the final swap is a single rename.
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        defer { try? fm.removeItem(at: work) }

        progress(.downloading)
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let checksumText = try await downloadText(checksumURL, session: session)
        let signatureText = try await downloadText(signatureURL, session: session)
        let dmgFile = work.appendingPathComponent("Furl.dmg")
        try await downloadFile(dmgURL, to: dmgFile, session: session)

        progress(.verifying)
        let dmgData: Data
        do { dmgData = try Data(contentsOf: dmgFile, options: .alwaysMapped) } catch {
            throw Failure(message: "The download couldn't be read.")
        }
        guard UpdateVerifier.checksumMatches(data: dmgData, checksumFile: checksumText) else {
            throw Failure(message: "The download didn't match its checksum.")
        }
        guard UpdateVerifier.isValidSignature(signatureText, for: dmgData, publicKeyBase64: UpdateConfig.signingPublicKey) else {
            throw Failure(message: "The download isn't signed by Furl.")
        }

        progress(.installing)
        let oldCopy = try installVerifiedDMG(dmgFile, work: work, expectedVersion: update.version,
                                             currentVersion: currentVersion, bundleURL: bundleURL)
        // `oldCopy` now holds the previous version: Trash it, like everything else Furl removes.
        var trashed: NSURL?
        if (try? fm.trashItem(at: oldCopy, resultingItemURL: &trashed)) == nil {
            try? fm.removeItem(at: oldCopy)
        }
        #if DEBUG
        if UpdateTestMode.isActive { UpdateTestMode.log("previous version moved to \(trashed?.path ?? "(removed, Trash failed)")") }
        #endif
        return bundleURL
    }

    /// Mounts a DMG whose checksum and signature already passed, checks the Furl.app inside, copies it
    /// into `work` (same volume as `bundleURL`) and swaps it with the running copy in one rename.
    /// Returns where the previous version now is (inside `work`). Throws, changing nothing, on any problem.
    static func installVerifiedDMG(_ dmgFile: URL, work: URL, expectedVersion: String, currentVersion: String,
                                   bundleURL: URL) throws -> URL {
        let fm = FileManager.default
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let attach = ShellRunner.run("/usr/bin/hdiutil", arguments: [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, dmgFile.path,
        ], timeout: 120)
        guard attach.exitCode == 0 else { throw Failure(message: "The disk image couldn't be opened.") }
        defer { _ = ShellRunner.run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"], timeout: 60) }

        let source = mountPoint.appendingPathComponent("Furl.app", isDirectory: true)
        try checkApp(at: source, expectedVersion: expectedVersion, currentVersion: currentVersion)

        let staged = work.appendingPathComponent("Furl.app", isDirectory: true)
        let copy = ShellRunner.run("/usr/bin/ditto", arguments: [source.path, staged.path], timeout: 300)
        guard copy.exitCode == 0 else { throw Failure(message: "The new version couldn't be copied.") }
        // What gets installed is the copy, so check the copy too.
        try checkApp(at: staged, expectedVersion: expectedVersion, currentVersion: currentVersion)

        // Right before swapping: the app on disk is still the one that's running.
        let onDisk = bundleInfo(at: bundleURL)
        var info = stat()
        guard onDisk.identifier == UpdateConfig.bundleIdentifier, onDisk.version == currentVersion,
              lstat(bundleURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure(message: "Furl changed on disk while updating. Nothing was replaced.")
        }

        // Atomic swap: either both names change or neither does.
        guard renamex_np(staged.path, bundleURL.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure(message: "Furl couldn't replace itself. Nothing was changed.")
        }
        return staged
    }

    /// Waits for this process to quit, then opens the new copy. The script is a constant; the pid and
    /// path go in as positional arguments, never into the script text.
    static func relaunch(appURL: URL) -> Bool {
        let script = #"i=0; while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; exec /usr/bin/open "$2""#
        return ShellRunner.launchDetached("/bin/sh", arguments: [
            "-c", script, "furl-relaunch", String(ProcessInfo.processInfo.processIdentifier), appURL.path,
        ])
    }

    // MARK: - Checks

    private static func checkApp(at url: URL, expectedVersion: String, currentVersion: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure(message: "The disk image doesn't contain Furl.")
        }
        let bundle = bundleInfo(at: url)
        guard bundle.identifier == UpdateConfig.bundleIdentifier else {
            throw Failure(message: "The disk image doesn't contain Furl.")
        }
        guard let version = bundle.version, version == UpdateChecker.strippedTag(expectedVersion),
              UpdateChecker.isNewer(version, than: currentVersion) else {
            throw Failure(message: "The downloaded version doesn't match the release.")
        }
        let verify = ShellRunner.run("/usr/bin/codesign", arguments: [
            // "-R=<text>": the leading "=" makes codesign read an inline requirement, not a file.
            "--verify", "--strict", "-R=identifier \"\(UpdateConfig.bundleIdentifier)\"", url.path,
        ], timeout: 120)
        guard verify.exitCode == 0 else { throw Failure(message: "The new version's code signature is broken.") }
    }

    private static func bundleInfo(at url: URL) -> (identifier: String?, version: String?) {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return (nil, nil) }
        return (dict["CFBundleIdentifier"] as? String, dict["CFBundleShortVersionString"] as? String)
    }

    // MARK: - Network

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            UpdateVerifier.isAllowedRedirect(request.url) ? request : nil
        }
    }

    /// Same privacy as the check: ephemeral, no cookies, no cache, no identifiers.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    private static func downloadText(_ url: URL, session: URLSession) async throws -> String {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) } catch {
            throw Failure(message: "Couldn't download the update. Check your connection.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4096,
              let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "GitHub didn't send the update files.")
        }
        return text
    }

    private static func downloadFile(_ url: URL, to destination: URL, session: URLSession) async throws {
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(from: url) } catch {
            throw Failure(message: "Couldn't download the update. Check your connection.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "GitHub didn't send the update files.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? Int64
        guard let size, size > 0, size <= UpdateConfig.maxDMGBytes else {
            throw Failure(message: "The download is the wrong size.")
        }
        do { try FileManager.default.moveItem(at: temporary, to: destination) } catch {
            throw Failure(message: "The download couldn't be saved.")
        }
    }
}

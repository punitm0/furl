import AppKit
import Foundation
import SwiftUI

/// Check for Updates (UpdateCheck board). Reads GitHub Releases when the user clicks, and (unless
/// turned off in Settings › General) quietly once a day in the background. A newer version shows in
/// About and in the app menu; nothing is downloaded until the user clicks Install and Relaunch.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// A newer release, with its asset links when the release carries them.
    struct AvailableUpdate: Equatable, Sendable {
        /// The release tag without a leading "v".
        let version: String
        /// The release's html_url.
        let releaseURL: URL
        let dmgURL: URL?
        let checksumURL: URL?
        let signatureURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        /// No network, DNS failure or timeout.
        case offline
        /// GitHub answered with something other than a release (403, 429, 5xx, or anything unreadable).
        case refused
        /// Install and Relaunch is running.
        case installing(UpdateInstaller.Phase)
        /// Install and Relaunch stopped; the running copy was left as it was.
        case installFailed(message: String, update: AvailableUpdate)
    }

    enum Keys {
        /// Settings › General › Help toggle. Missing means on.
        static let automaticChecks = "updates.automaticChecks"
        static let lastCheck = "updates.lastCheck"
        /// The last version the update notification was shown for (one notice per version).
        static let notifiedVersion = "updates.notifiedVersion"
    }

    @Published private(set) var status: Status = .idle
    /// The newest release found by any check (manual or background). Kept when About closes, so the
    /// menu and About can show it until a check says otherwise.
    @Published private(set) var availableUpdate: AvailableUpdate?

    private var task: Task<Void, Never>?
    private var backgroundLoop: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var automaticChecksEnabled: Bool {
        defaults.object(forKey: Keys.automaticChecks) as? Bool ?? true
    }

    /// Why this copy can't install `update` by itself (then the card offers Download instead), or nil.
    func installProblem(for update: AvailableUpdate) -> String? {
        if let problem = UpdateInstaller.installProblem(bundleURL: Bundle.main.bundleURL,
                                                        bundleIdentifier: Bundle.main.bundleIdentifier) {
            return problem
        }
        let assets = [update.dmgURL, update.checksumURL, update.signatureURL]
        guard assets.allSatisfy({ $0.map { UpdateVerifier.isAllowedAssetURL($0) } ?? false }) else {
            return "This release can only be installed by hand."
        }
        return nil
    }

    /// CFBundleShortVersionString, e.g. "1.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check() {
        if case .installing = status { return }
        task?.cancel()
        status = .checking
        defaults.set(Date(), forKey: Keys.lastCheck)
        task = Task { [weak self] in
            let result = await Self.fetch()
            guard !Task.isCancelled, let self else { return }
            self.status = result
            self.remember(result)
        }
    }

    /// Starts the background check: looks hourly whether a day has passed since the last check (manual
    /// or automatic), so a Mac that sleeps or a Furl that runs for weeks still checks about once a day.
    func startAutomaticChecks() {
        guard backgroundLoop == nil else { return }
        backgroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkInBackgroundIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func checkInBackgroundIfDue(now: Date = Date()) async {
        let last = defaults.object(forKey: Keys.lastCheck) as? Date
        guard UpdateSchedule.isDue(enabled: automaticChecksEnabled, lastCheck: last, now: now) else { return }
        switch status {
        case .checking, .installing: return
        default: break
        }
        defaults.set(now, forKey: Keys.lastCheck)
        let result = await Self.fetch()
        remember(result)
        // About is open and showing nothing yet: show what we found.
        if status == .idle, case .available = result { status = result }
        // UpdateCheck board: one notification per new version, only from the daily check.
        if case .available(let update) = result, defaults.string(forKey: Keys.notifiedVersion) != update.version {
            defaults.set(update.version, forKey: Keys.notifiedVersion)
            await NotificationService.shared.postUpdateAvailable(version: update.version)
        }
        #if DEBUG
        // Update-test copies only: install what the check found, so the end-to-end test runs unattended.
        if UpdateTestMode.isActive, defaults.bool(forKey: "FurlUpdateTestAutoInstall") {
            UpdateTestMode.log("check result \(result)")
            if case .available(let update) = result {
                if let problem = installProblem(for: update) {
                    UpdateTestMode.log("can't install: \(problem)")
                } else {
                    install(update)
                }
            }
        }
        #endif
    }

    /// Offline or refused says nothing new, so a known update stays known.
    private func remember(_ result: Status) {
        switch result {
        case .available(let update): availableUpdate = update
        case .upToDate: availableUpdate = nil
        default: break
        }
    }

    /// Install and Relaunch: download, verify, swap, reopen. Any failure leaves this copy as it was.
    func install(_ update: AvailableUpdate) {
        if case .installing = status { return }
        task?.cancel()
        status = .installing(.downloading)
        let current = Self.currentVersion
        let bundleURL = Bundle.main.bundleURL
        task = Task { [weak self] in
            do {
                let installed = try await Task.detached(priority: .userInitiated) {
                    try await UpdateInstaller.install(update, currentVersion: current, bundleURL: bundleURL) { phase in
                        Task { @MainActor in
                            let checker = UpdateChecker.shared
                            guard case .installing = checker.status else { return }
                            checker.status = .installing(phase)
                        }
                    }
                }.value
                #if DEBUG
                if UpdateTestMode.isActive { UpdateTestMode.log("installed at \(installed.path), relaunching") }
                #endif
                guard UpdateInstaller.relaunch(appURL: installed) else {
                    self?.status = .installFailed(message: "Furl is updated. Quit and open it again to finish.", update: update)
                    return
                }
                NSApp.terminate(nil)
            } catch let failure as UpdateInstaller.Failure {
                #if DEBUG
                if UpdateTestMode.isActive { UpdateTestMode.log("install failed: \(failure.message)") }
                #endif
                self?.status = .installFailed(message: failure.message, update: update)
            } catch {
                self?.status = .installFailed(message: "The update couldn't be installed. Nothing was changed.", update: update)
            }
        }
    }

    /// Furl › Check for Updates… (and Settings › General › Help): opens About and starts the check
    /// at once, so the user sees Checking → result.
    func openAboutAndCheck(openWindow: OpenWindowAction) {
        AppWindows.activateForWindow()
        openWindow(id: "about")
        check()
    }

    static func openAboutAndCheck(openWindow: OpenWindowAction) {
        shared.openAboutAndCheck(openWindow: openWindow)
    }

    /// About closed: the next time it opens, the slot is idle again (a found update is still shown).
    /// An install keeps running.
    func reset() {
        if case .installing = status { return }
        task?.cancel()
        task = nil
        status = .idle
    }

    // MARK: - Request

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// GET …/releases/latest with Accept and User-Agent only. No cookies, no identifiers, no query string.
    nonisolated private static func fetch() async -> Status {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Checking times out after 10 s → Offline.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let version = await MainActor.run { currentVersion }
        var request = URLRequest(url: UpdateVerifier.releaseFeedURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Furl/\(version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .offline
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .refused
        }
        let latest = strippedTag(release.tagName)
        if isNewer(latest, than: version) {
            func asset(_ name: String) -> URL? {
                release.assets?.first { $0.name == name }?.browserDownloadURL
            }
            return .available(AvailableUpdate(
                version: latest, releaseURL: release.htmlURL,
                dmgURL: asset(UpdateConfig.dmgAssetName),
                checksumURL: asset(UpdateConfig.checksumAssetName),
                signatureURL: asset(UpdateConfig.signatureAssetName)))
        }
        return .upToDate
    }

    // MARK: - Compare

    /// Strip a leading "v" from tag_name.
    nonisolated static func strippedTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "v" || trimmed.first == "V" { return String(trimmed.dropFirst()) }
        return trimmed
    }

    /// Compares dot-separated versions as numbers (1.10 is newer than 1.9; 1.1 equals 1.1.0).
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numericComponents(candidate)
        let b = numericComponents(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "1.10.2" → [1, 10, 2]. Each part counts by its leading digits ("3-beta" → 3).
    nonisolated private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}

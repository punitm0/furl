import Foundation
import SwiftUI

/// Check for Updates (UpdateCheck board). Reads GitHub Releases only when the user clicks:
/// no launch-time check, no background timer, no badge. The result is shown in About and
/// forgotten when About closes.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        /// `version` is the release tag without a leading "v"; `releaseURL` is the release's html_url.
        case available(version: String, releaseURL: URL)
        /// No network, DNS failure or timeout.
        case offline
        /// GitHub answered with something other than a release (403, 429, 5xx, or anything unreadable).
        case refused
    }

    @Published private(set) var status: Status = .idle

    private var task: Task<Void, Never>?

    /// CFBundleShortVersionString, e.g. "1.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func check() {
        task?.cancel()
        status = .checking
        task = Task { [weak self] in
            let result = await Self.fetch()
            guard !Task.isCancelled else { return }
            self?.status = result
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

    /// About closed: the next time it opens, the slot is idle again (no remembered result).
    func reset() {
        task?.cancel()
        task = nil
        status = .idle
    }

    // MARK: - Request

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
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
        var request = URLRequest(url: SupportConfig.latestReleaseAPIURL)
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
            return .available(version: latest, releaseURL: release.htmlURL)
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

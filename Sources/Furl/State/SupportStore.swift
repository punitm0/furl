import Foundation

/// One request to show the support sheet after a big cleanup.
struct SupportPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// What the cleanup that triggered the prompt freed.
    let freedBytes: Int64
}

/// Decides when Furl may ask for support. Rules:
/// - only right after a single cleanup of at least `SupportConfig.promptMinimumBytes`,
/// - at most once every `SupportConfig.promptInterval`,
/// - never on launch (prompts aren't persisted, only the bookkeeping is),
/// - never again once the user says they've paid.
/// Everything is stored in UserDefaults on this Mac. No tracking. The one network call is
/// `refreshCheckoutLink()`: a plain GET for the current checkout link, carrying no user data.
@MainActor
final class SupportStore: ObservableObject {
    static let shared = SupportStore()

    private enum Keys {
        static let lastPrompt = "supportLastPromptDate"
        static let hasPaid = "supportHasPaid"
        static let checkoutLink = "supportCheckoutLink"
        /// Last time the Worker was asked (success or failure).
        static let checkoutLinkCheckedAt = "supportCheckoutLinkCheckedAt"
    }

    private let defaults: UserDefaults

    /// Set by `recordCleanup(bytes:)` when the sheet should appear. Present it with `.sheet(item:)`
    /// and the sheet clears it on close.
    @Published var pendingPrompt: SupportPrompt?

    /// Self-reported: the user tapped "I've paid". Never asked again after that.
    @Published private(set) var hasPaid: Bool {
        didSet { defaults.set(hasPaid, forKey: Keys.hasPaid) }
    }

    private(set) var lastPromptDate: Date? {
        didSet { defaults.set(lastPromptDate, forKey: Keys.lastPrompt) }
    }

    /// The Dodo checkout link: the last one the stats Worker served (cached), else the built-in
    /// `SupportConfig.checkoutBaseURL`. Nil until one of them is a valid Dodo link; the sheet then never
    /// opens by itself and its pay button is disabled.
    @Published private(set) var checkoutLink: URL?

    var isCheckoutConfigured: Bool { checkoutLink != nil }

    private var isRefreshing = false
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        hasPaid = defaults.bool(forKey: Keys.hasPaid)
        lastPromptDate = defaults.object(forKey: Keys.lastPrompt) as? Date
        checkoutLink = SupportConfig.validCheckoutLink(defaults.string(forKey: Keys.checkoutLink))
            ?? SupportConfig.validCheckoutLink(SupportConfig.checkoutBaseURL)
    }

    func checkoutURL(amount: Int) -> URL? {
        checkoutLink.flatMap { SupportConfig.checkoutURL(link: $0, amount: amount) }
    }

    /// Asks the stats Worker for the current checkout link, but only when the stored answer is stale:
    /// `checkoutLinkRefreshInterval` (24 h) once a link is stored, `checkoutLinkRetryInterval` (6 h) while
    /// none is. Called at launch and when the sheet opens; there is no timer. A plain GET with no cookies,
    /// ids or user data. A served link is stored and used from then on; an explicit `null` clears it (back
    /// to the built-in link); a failed fetch keeps what we had and waits for the next interval.
    func refreshCheckoutLink(now: Date = Date()) {
        guard !isRefreshing, let endpoint = SupportConfig.supportEndpointURL else { return }
        let hasStoredLink = SupportConfig.validCheckoutLink(defaults.string(forKey: Keys.checkoutLink)) != nil
        let interval = hasStoredLink ? SupportConfig.checkoutLinkRefreshInterval : SupportConfig.checkoutLinkRetryInterval
        if let checkedAt = defaults.object(forKey: Keys.checkoutLinkCheckedAt) as? Date,
           checkedAt <= now, now.timeIntervalSince(checkedAt) < interval { return }
        isRefreshing = true
        defaults.set(now, forKey: Keys.checkoutLinkCheckedAt)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Task {
            defer { isRefreshing = false }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONDecoder().decode(SupportResponse.self, from: data)
            else { return }
            if let served = SupportConfig.validCheckoutLink(body.checkoutUrl) {
                defaults.set(served.absoluteString, forKey: Keys.checkoutLink)
                checkoutLink = served
            } else if body.checkoutUrl == nil {
                defaults.removeObject(forKey: Keys.checkoutLink)
                checkoutLink = SupportConfig.validCheckoutLink(SupportConfig.checkoutBaseURL)
            }
            // A non-null but invalid link is ignored: keep the last good one.
        }
    }

    private struct SupportResponse: Decodable {
        let checkoutUrl: String?
    }

    /// Call once after a cleanup has actually freed `bytes`. Returns true when it queued the support sheet.
    @discardableResult
    func recordCleanup(bytes: Int64, now: Date = Date()) -> Bool {
        guard shouldPrompt(afterFreeing: bytes, now: now) else { return false }
        lastPromptDate = now
        pendingPrompt = SupportPrompt(freedBytes: bytes)
        return true
    }

    func shouldPrompt(afterFreeing bytes: Int64, now: Date = Date()) -> Bool {
        guard isCheckoutConfigured, !hasPaid, pendingPrompt == nil,
              bytes >= SupportConfig.promptMinimumBytes
        else { return false }
        if let last = lastPromptDate, now.timeIntervalSince(last) < SupportConfig.promptInterval {
            return false
        }
        return true
    }

    /// `clearPrompt: false` keeps a cleanup-triggered sheet on screen (PayWhatYouLike board: "I've paid"
    /// shows the thank-you, and the sheet only closes on Done, which calls `dismissPrompt()`).
    func markPaid(clearPrompt: Bool = true) {
        hasPaid = true
        if clearPrompt { pendingPrompt = nil }
    }

    func dismissPrompt() {
        pendingPrompt = nil
    }
}

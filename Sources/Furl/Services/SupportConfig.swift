import Foundation

/// Links and amounts for "pay what you like". Furl stays free; nothing here is ever required.
/// The only network use: a plain GET of `supportEndpointURL` (no user data, no ids) to learn the
/// current checkout link. Checkout itself opens in the user's browser, only when they click.
enum SupportConfig {
    /// Built-in fallback for the Dodo Payments static payment link of the one-time, Pay What You Want
    /// "Furl" product: https://checkout.dodopayments.com/buy/pdt_… (test: https://test.checkout.dodopayments.com/buy/pdt_…).
    /// Normally the link comes from the stats Worker (`DODO_CHECKOUT_URL` var, GET /v1/support), so shipped
    /// builds pick it up without an update; this constant is used only until that has answered once.
    /// No API key: links need none, and secrets never ship in the app.
    static let checkoutBaseURL = "https://checkout.dodopayments.com/buy/pdt_0NsELiRCJ3tL7BN41EZgN"

    /// GET /v1/support on the stats Worker: `{"checkoutUrl": "https://checkout.dodopayments.com/buy/pdt_…" | null}`.
    /// Same host as the stats endpoint.
    static var supportEndpointURL: URL? {
        guard let report = CommunityStatsConfig.endpointURL,
              var components = URLComponents(url: report, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/v1/support"
        components.query = nil
        return components.url
    }

    /// How often the stored link is checked again (at launch or when the support sheet opens; no timer).
    static let checkoutLinkRefreshInterval: TimeInterval = 24 * 60 * 60
    /// Shorter while no link is stored (or the Worker said null), so a newly set link turns on soon.
    static let checkoutLinkRetryInterval: TimeInterval = 6 * 60 * 60

    /// Only an https Dodo checkout link (`/buy/pdt_…`) is ever opened. Mirrors `validCheckoutUrl` in the Worker.
    static func validCheckoutLink(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host, ["checkout.dodopayments.com", "test.checkout.dodopayments.com"].contains(host),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.range(of: #"^/buy/pdt_[A-Za-z0-9]+/?$"#, options: .regularExpression) != nil
        else { return nil }
        return components.url
    }
    /// "owner/repo" on GitHub. Source link, Check for Updates and Report a Problem all derive from it.
    static let githubRepository = "punitm0/furl"
    static let githubURL = URL(string: "https://github.com/\(githubRepository)")!
    /// The project website (UpdateCheck board: What's New opens getfurl.app/changelog#1.1).
    static let websiteURL = URL(string: "https://getfurl.app")!
    /// New issue page; Report a Problem adds `template`, `title` and `body` (see `DiagnosticsReport`).
    static let issuesURL = URL(string: "https://github.com/\(githubRepository)/issues/new")!
    /// GitHub Releases, latest published (never a draft or pre-release). Read only by Check for Updates.
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(githubRepository)/releases/latest")!

    // Help menu (ReportProblem board): Install Help, Release Notes, Privacy.
    static let installHelpURL = websiteURL.appendingPathComponent("install")
    static let changelogURL = websiteURL.appendingPathComponent("changelog")
    static let privacyURL = websiteURL.appendingPathComponent("privacy")

    /// What's New for one version: /changelog#1.1.
    static func changelogURL(version: String) -> URL {
        var components = URLComponents(url: changelogURL, resolvingAgainstBaseURL: false)
        components?.fragment = version
        return components?.url ?? changelogURL
    }

    /// Suggested amounts in whole US dollars.
    static let amounts = [5, 12, 25]
    static let defaultAmount = 12
    static let currencySymbol = "$"
    static let maximumAmount = 1_000

    /// The support sheet only appears after a single cleanup at least this big...
    static let promptMinimumBytes: Int64 = 5_000_000_000
    /// ...and at most once in this long.
    static let promptInterval: TimeInterval = 30 * 24 * 60 * 60

    /// After paying, Dodo sends people to the website's thank-you state (it appends payment_id and status).
    static let paymentReturnURL = URL(string: "https://getfurl.app/?paid=1")!

    /// `link` (a valid Dodo link, see `SupportStore.checkoutLink`) with the amount fixed. `paymentAmount`
    /// is in major units (12 = $12, not cents) and only works on a Pay What You Want product whose
    /// Minimum Price is at or below it. One time only.
    static func checkoutURL(link: URL, amount: Int) -> URL? {
        guard var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "paymentAmount", value: String(amount)))
        query.append(URLQueryItem(name: "redirect_url", value: paymentReturnURL.absoluteString))
        components.queryItems = query
        return components.url
    }

    /// About $1 for every 10 GB freed, nudged to the closest suggested amount, never below the default.
    static func suggestedAmount(forFreedBytes bytes: Int64) -> Int {
        let dollars = Double(bytes) / 10_000_000_000
        let closest = amounts.min { abs(Double($0) - dollars) < abs(Double($1) - dollars) } ?? defaultAmount
        return max(closest, defaultAmount)
    }
}

import CryptoKit
import Foundation

/// Where community stats go. Fill in before release (see stats-worker/README.md).
enum CommunityStatsConfig {
    /// POST endpoint of the stats Worker. A `.invalid` host means "not set up": nothing is ever sent
    /// and Furl never asks.
    static let endpoint = "https://stats.getfurl.app/v1/report"

    /// Must match the Worker's REPORT_HMAC_KEY secret. This is NOT a secret in any real sense: it ships
    /// in the app, so anyone can extract it. It's a speed bump against drive-by junk, nothing more.
    static let hmacKey = "858e7619b19bb84213c4e9afcbc9ec790f1b146a562119e625d8d27ca8a3d0ba"

    static var endpointURL: URL? {
        guard let url = URL(string: endpoint), url.scheme == "https",
              let host = url.host, !host.hasSuffix(".invalid") else { return nil }
        return url
    }

    static var isConfigured: Bool { endpointURL != nil }

    // Mirrors the Worker's limits (stats-worker/src/limits.ts) so a request is never rejected as a whole.
    static let maxEventsPerRequest = 40
    static let maxRequestsPerAttempt = 4
    static let maxDiskBytesPerEvent: Int64 = 4 << 40      // 4 TiB
    static let maxMemoryBytesPerEvent: Int64 = 256 << 30  // 256 GiB
    static let maxFilesPerEvent = 100_000
    static let maxItemsPerEvent = 100_000
    static let osMajorRange = 14...99
}

/// "Community stats": adds this Mac's anonymous totals to the public Furl total (always on).
///
/// Sends unsent StatsLedger events (kind, category, bytes, file or item count, a random event id)
/// under a random install id, at most once a day, and marks events sent only after a 2xx. Each
/// report also carries the macOS major version, the Mac's CPU architecture and whether Full Disk
/// Access is granted. Nothing else: no paths, names, hostnames or hardware ids. Legacy totals from
/// before the ledger are never sent.
@MainActor
final class CommunityStatsReporter: ObservableObject {
    static let shared = CommunityStatsReporter()

    /// Small bookkeeping file next to the ledger.
    private struct State: Codable {
        var installID: UUID?
        var lastSuccess: Date?
        var nextAttempt: Date?
        var failures = 0
    }

    private let ledger: StatsLedger
    private let stateURL: URL
    private var state: State
    private var loop: Task<Void, Never>?
    private var isSending = false

    /// Anonymous totals are always on; there is no setting. getfurl.app/privacy lists exactly what
    /// is sent, and this file is the only code that sends it.
    var isEnabled: Bool { true }

    @Published private(set) var lastSuccess: Date?

    init(ledger: StatsLedger = .shared,
         stateURL: URL = AutoSweepStore.supportDirectory.appendingPathComponent("community-stats.json")) {
        self.ledger = ledger
        self.stateURL = stateURL
        state = Self.loadState(stateURL) ?? State()
        lastSuccess = state.lastSuccess
    }

    var isConfigured: Bool { CommunityStatsConfig.isConfigured }
    var unsentCount: Int { ledger.unsentReportableEvents.filter(Self.isReportable).count }

    /// Called after a successful cleanup. Totals are always shared, so there is nothing to ask;
    /// kept so callers don't change.
    func cleanupSucceeded() {}

    // MARK: - Sending

    /// Starts the background check (hourly; a send happens at most daily, sooner only to retry).
    func start() {
        guard loop == nil, isEnabled, isConfigured else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self, self.isEnabled else { break }
                await self.sendIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
            self?.loop = nil
        }
    }

    func sendIfDue(now: Date = Date()) async {
        guard isEnabled, !isSending, let endpoint = CommunityStatsConfig.endpointURL else { return }
        if let next = state.nextAttempt, now < next { return }
        let pending = ledger.unsentReportableEvents.filter(Self.isReportable)
        guard !pending.isEmpty else {
            state.nextAttempt = now.addingTimeInterval(24 * 3600)
            saveState()
            return
        }

        isSending = true
        defer { isSending = false }
        let installID = state.installID ?? UUID()
        if state.installID == nil {
            state.installID = installID
            saveState()
        }

        let chunks = stride(from: 0, to: pending.count, by: CommunityStatsConfig.maxEventsPerRequest)
            .prefix(CommunityStatsConfig.maxRequestsPerAttempt)
            .map { Array(pending[$0..<min($0 + CommunityStatsConfig.maxEventsPerRequest, pending.count)]) }
        var allSent = true
        let environment = ReportEnvironment.current()
        for chunk in chunks {
            guard let body = Self.body(installID: installID, environment: environment, events: chunk) else {
                allSent = false
                break
            }
            if await Self.post(body, to: endpoint) {
                ledger.markSent(Set(chunk.map(\.id)))
            } else {
                allSent = false
                break
            }
        }

        if allSent {
            state.failures = 0
            state.lastSuccess = now
            lastSuccess = now
            // More left than one attempt sends: come back in an hour, otherwise tomorrow.
            let more = ledger.unsentReportableEvents.contains(where: Self.isReportable)
            state.nextAttempt = now.addingTimeInterval(more ? 3600 : 24 * 3600)
        } else {
            // Exponential backoff: 15 min, 30, 60 … capped at a day.
            state.failures += 1
            let delay = min(24 * 3600, 15 * 60 * pow(2, Double(min(state.failures - 1, 10))))
            state.nextAttempt = now.addingTimeInterval(delay)
        }
        saveState()
    }

    /// Events the server would refuse are kept local (they still count on this Mac).
    static func isReportable(_ event: StatsEvent) -> Bool {
        switch event.kind {
        case .legacy: return false
        case .reversal: return event.reverses != nil
        case .disk:
            return event.bytes > 0 && event.bytes <= CommunityStatsConfig.maxDiskBytesPerEvent
                && diskCategories.contains(event.category)
        case .memory:
            return event.bytes > 0 && event.bytes <= CommunityStatsConfig.maxMemoryBytesPerEvent
                && (event.category == .processes || event.category == .autoSweep)
        case .compress:
            return event.bytes >= 0 && event.bytes <= CommunityStatsConfig.maxDiskBytesPerEvent
                && event.files > 0 && event.files <= CommunityStatsConfig.maxFilesPerEvent
                && (event.category == .compress || event.category == .shrink)
        }
    }

    private static let diskCategories: Set<StatsEvent.Category> = [
        .junk, .worktrees, .apps, .largeFiles, .duplicates, .smartReview, .trash, .autoSweep, .other,
    ]

    // MARK: - Wire format (stats-worker/src/schema.ts)

    /// Sent once per report, not per event.
    struct ReportEnvironment {
        /// macOS major version, clamped into the range the Worker accepts.
        let osMajor: Int
        /// The Mac's CPU, not the build's: an x86_64 build under Rosetta still reports "arm64".
        let arch: String
        let fullDiskAccess: Bool

        @MainActor static func current() -> ReportEnvironment {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let range = CommunityStatsConfig.osMajorRange
            FullDiskAccess.shared.refresh()
            return ReportEnvironment(osMajor: min(max(major, range.lowerBound), range.upperBound),
                                     arch: hardwareIsArm64 ? "arm64" : "x86_64",
                                     fullDiskAccess: FullDiskAccess.shared.isGranted)
        }

        private static var hardwareIsArm64: Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        }
    }

    private struct Payload: Encodable {
        let v = 1
        let installId: String
        let appVersion: String
        let os: Int
        let arch: String
        let fda: Bool
        let events: [WireEvent]
    }

    private struct WireEvent: Encodable {
        let id: String
        let kind: String
        var category: String?
        var bytes: Int64?
        var files: Int?
        var items: Int?
        var reverses: String?
    }

    static func body(installID: UUID, environment: ReportEnvironment, events: [StatsEvent]) -> Data? {
        let wire = events.map { e -> WireEvent in
            let id = e.id.uuidString.lowercased()
            switch e.kind {
            case .reversal:
                return WireEvent(id: id, kind: "reversal", reverses: e.reverses?.uuidString.lowercased())
            case .compress:
                return WireEvent(id: id, kind: "compress", category: e.category.rawValue, bytes: e.bytes, files: e.files)
            case .disk:
                // Omitted when unknown (older events) or zero; capped at the Worker's per-event ceiling.
                let items = (e.items ?? 0) > 0 ? min(e.items ?? 0, CommunityStatsConfig.maxItemsPerEvent) : nil
                return WireEvent(id: id, kind: "disk", category: e.category.rawValue, bytes: e.bytes, items: items)
            default:
                return WireEvent(id: id, kind: e.kind.rawValue, category: e.category.rawValue, bytes: e.bytes)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(installId: installID.uuidString.lowercased(), appVersion: appVersion,
                                           os: environment.osMajor, arch: environment.arch,
                                           fda: environment.fullDiskAccess, events: wire))
    }

    private static var appVersion: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let valid = raw.range(of: #"^\d{1,4}(\.\d{1,4}){0,3}$"#, options: .regularExpression) != nil
        return valid ? raw : "0"
    }

    /// One signed POST. True only for a 2xx.
    private static func post(_ body: Data, to url: URL) async -> Bool {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var signed = Data((timestamp + ".").utf8)
        signed.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(CommunityStatsConfig.hmacKey.utf8)))
        let signature = mac.map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-SweepMac-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-SweepMac-Signature")

        // No cookies, cache or credentials: an ephemeral session per send.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Persistence

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: stateURL, options: .atomic)
    }

    private static func loadState(_ url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }
}

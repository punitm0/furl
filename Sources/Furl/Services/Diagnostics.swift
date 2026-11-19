import AppKit
import Combine
import Foundation

/// Times the last full scan per area and the last Smart Review run, for Report a Problem.
/// It only watches AppState's published scan flags; it never reads what the scans found
/// (apart from Smart Review's count).
@MainActor
final class ScanTimingRecorder {
    static let shared = ScanTimingRecorder()

    /// The areas the ReportProblem board lists, in its order.
    enum Area: String, CaseIterable, Codable, Sendable {
        case projects = "Projects"
        case libraryCaches = "Library caches"
        case appsAndLeftovers = "Apps & leftovers"
        case homeFolder = "Home folder"
    }

    struct FullScan: Codable, Equatable {
        let started: Date
        let duration: TimeInterval
        let areas: [Area: TimeInterval]
    }

    struct SmartReviewRun: Codable, Equatable {
        let started: Date
        let duration: TimeInterval
        let found: Int
    }

    private(set) var lastFullScan: FullScan?
    private(set) var lastSmartReview: SmartReviewRun?

    private struct Run {
        var started: Date
        var ended: Date?
    }

    private var runs: [Area: Run] = [:]
    private var smartStarted: Date?
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let fullScan = "diagnostics.lastFullScan"
        static let smartReview = "diagnostics.lastSmartReview"
    }

    init() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.fullScan) {
            lastFullScan = try? decoder.decode(FullScan.self, from: data)
        }
        if let data = defaults.data(forKey: Keys.smartReview) {
            lastSmartReview = try? decoder.decode(SmartReviewRun.self, from: data)
        }
    }

    func connect(to state: AppState) {
        watch(state.$isScanningWorktrees, area: .projects)
        watch(state.$isScanningJunk, area: .libraryCaches)
        watch(state.$isScanningApps, area: .appsAndLeftovers)
        watch(state.$isScanningLargeFiles, area: .homeFolder)

        // lastScanDate is stamped once every area of a full scan is idle.
        state.$lastScanDate
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] finished in self?.noteFullScanFinished(at: finished) }
            .store(in: &cancellables)

        Publishers.CombineLatest(state.$isScanningSmart, state.$isReviewingSmart)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self, weak state] busy in
                guard let self else { return }
                if busy {
                    self.smartStarted = Date()
                } else if let started = self.smartStarted {
                    self.smartStarted = nil
                    let run = SmartReviewRun(started: started, duration: Date().timeIntervalSince(started),
                                             found: state?.smartItems.count ?? 0)
                    self.lastSmartReview = run
                    self.persist(run, key: Keys.smartReview)
                }
            }
            .store(in: &cancellables)
    }

    private func watch(_ publisher: Published<Bool>.Publisher, area: Area) {
        publisher
            .removeDuplicates()
            .sink { [weak self] scanning in
                guard let self else { return }
                if scanning {
                    self.runs[area] = Run(started: Date(), ended: nil)
                } else if self.runs[area] != nil, self.runs[area]?.ended == nil {
                    self.runs[area]?.ended = Date()
                }
            }
            .store(in: &cancellables)
    }

    private func noteFullScanFinished(at finished: Date) {
        // Only runs that ended in the last hour belong to this scan.
        let recent = runs.compactMapValues { run -> (Date, TimeInterval)? in
            guard let ended = run.ended, finished.timeIntervalSince(ended) < 3600 else { return nil }
            return (run.started, ended.timeIntervalSince(run.started))
        }
        guard let started = recent.values.map(\.0).min() else { return }
        let scan = FullScan(started: started, duration: finished.timeIntervalSince(started),
                            areas: recent.mapValues(\.1))
        lastFullScan = scan
        persist(scan, key: Keys.fullScan)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The text Report a Problem shows, copies and puts in the GitHub issue (ReportProblem board).
/// Contains: app and macOS versions, Mac model, chip, memory, startup disk size, three settings,
/// scan timings and recent errors. Never: file or folder names, paths, user name, Mac name,
/// serial number, IP address, app list or scan results.
@MainActor
enum DiagnosticsReport {
    // MARK: Diagnostics text

    static func diagnosticsText(state: AppState) -> String {
        var lines: [String] = []
        lines.append("Furl \(appVersion)")
        lines.append("macOS \(macOSVersion.full)")
        lines.append("Mac: \(sysctlString("hw.model") ?? "Unknown") · \(sysctlString("machdep.cpu.brand_string") ?? "Unknown chip") · \(memoryGB) GB memory")
        let disk = DiskInfoService.currentDiskUsage()
        lines.append("Disk: \(roundedGB(disk.totalBytes)) GB, \(roundedGB(disk.availableBytes)) GB free")
        let removal = state.deletionMode == .moveToTrash ? "Trash" : "Permanent"
        let fda = FullDiskAccess.checkAccess() ? "on" : "off"
        lines.append("Theme: \(FurlPalette.current.displayName) · Removal: \(removal) · Full Disk Access: \(fda)")
        lines.append("")

        let timings = ScanTimingRecorder.shared
        if let scan = timings.lastFullScan {
            lines.append("Last full scan, \(longDate.string(from: scan.started)), took \(longDuration(scan.duration))")
            for area in ScanTimingRecorder.Area.allCases {
                guard let seconds = scan.areas[area] else { continue }
                let name = "  " + area.rawValue.padding(toLength: 21, withPad: " ", startingAt: 0)
                let value = String(format: "%.1f", seconds)
                lines.append(name + String(repeating: " ", count: max(0, 5 - value.count)) + value + " s")
            }
        } else {
            lines.append("Last full scan: none yet")
        }
        if let smart = timings.lastSmartReview {
            lines.append("Smart Review, \(longDate.string(from: smart.started)): \(smart.found) found, \(String(format: "%.1f", smart.duration)) s")
        }
        lines.append("")

        lines.append("Recent errors (last 7 days)")
        let errors = ErrorLog.shared.recent()
        if errors.isEmpty {
            lines.append("  None")
        } else {
            for entry in errors {
                let times = entry.count > 1 ? " ×\(entry.count)" : ""
                lines.append("  \(shortDate.string(from: entry.date))  \(entry.area): \(entry.message)\(times)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Issue

    /// "Problem report: Furl {version} on macOS {version}".
    static var issueTitle: String {
        "Problem report: Furl \(appVersion) on macOS \(macOSVersion.short)"
    }

    /// The Markdown issue body; Copy Report puts the same text on the clipboard.
    static func issueBody(whatHappened: String, diagnostics: String) -> String {
        """
        ### What happened
        \(whatHappened.trimmingCharacters(in: .whitespacesAndNewlines))

        ### Diagnostics
        ```
        \(diagnostics)
        ```
        """
    }

    /// Body without the diagnostics, for when the full one makes the link too long.
    static func shortIssueBody(whatHappened: String) -> String {
        """
        ### What happened
        \(whatHappened.trimmingCharacters(in: .whitespacesAndNewlines))

        ### Diagnostics

        """
    }

    /// GitHub links stop working past about 8 KB; keep the encoded URL under this.
    static let maximumURLLength = 7_000

    /// github.com/punitm0/furl/issues/new?template=bug.md&title=…&body=…, all percent-encoded.
    static func issueURL(body: String) -> URL? {
        let query = [("template", "bug.md"), ("title", issueTitle), ("body", body)]
            .map { "\($0.0)=\(percentEncoded($0.1))" }
            .joined(separator: "&")
        return URL(string: SupportConfig.issuesURL.absoluteString + "?" + query)
    }

    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: Values

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development build"
        if let build = info?["CFBundleVersion"] as? String, build != short { return "\(short) (\(build))" }
        return short
    }

    /// From "Version 15.2 (Build 24C101)": full "15.2 (24C101)", short "15.2".
    static var macOSVersion: (full: String, short: String) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var short = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { short += ".\(version.patchVersion)" }
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        if let range = raw.range(of: "Build ") {
            let build = raw[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            return ("\(short) (\(build))", short)
        }
        return (short, short)
    }

    private static var memoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    private static func roundedGB(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000_000).rounded())
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// "1 min 12 s", or "48.3 s" under a minute.
    private static func longDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 60 else { return String(format: "%.1f s", seconds) }
        let minutes = whole / 60
        let rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// "18 Nov 2026 14:02".
    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    /// "18 Nov 14:03".
    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()
}

import Combine
import Foundation
import SystemConfiguration

/// Recent errors for Report a Problem (ReportProblem board). Kept in memory and in a small rolling
/// log (Application Support/Furl/errors.log, at most 200 lines) so they survive a relaunch.
/// Every message runs through `ErrorScrubber` before it is stored: no file names or paths.
@MainActor
final class ErrorLog {
    static let shared = ErrorLog()

    struct Entry: Equatable, Sendable {
        let date: Date
        /// Where it happened, e.g. "Caches & Junk".
        let area: String
        let message: String
        /// Identical messages from one failure are stored once, "×3".
        let count: Int
    }

    static let maximumLines = 200

    private(set) var entries: [Entry] = []
    private var cancellables = Set<AnyCancellable>()
    private let fileURL: URL

    init(fileURL: URL = AppIdentity.supportDirectory.appendingPathComponent("errors.log")) {
        self.fileURL = fileURL
        entries = Self.load(from: fileURL)
    }

    /// Records the error banner whenever one appears. The area is the section the user is in.
    func connect(to state: AppState) {
        state.$errorBanner
            .compactMap { $0 }
            .sink { [weak self, weak state] banner in
                guard let self else { return }
                let area = state?.selectedSection.rawValue ?? "Furl"
                self.record(area: area, messages: banner.components(separatedBy: "\n"))
            }
            .store(in: &cancellables)
    }

    /// Names (such as an app's) that a banner is about to show. They're taken out of anything recorded
    /// afterwards, so "Report a Problem" never lists which apps are installed. Call before setting the banner.
    func redact(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short names ("Go", "Up") would also blank out ordinary words in every later message.
        guard trimmed.count >= 3 else { return }
        redactions.removeAll { $0 == trimmed }
        redactions.append(trimmed)
        if redactions.count > 50 { redactions.removeFirst(redactions.count - 50) }
    }

    private var redactions: [String] = []

    /// Scrubs each message, folds identical ones into a count, and appends them to the log.
    func record(area: String, messages: [String], date: Date = Date()) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for raw in messages {
            let message = ErrorScrubber.scrub(raw, area: area, redacting: redactions)
            guard !message.isEmpty else { continue }
            if counts[message] == nil { order.append(message) }
            counts[message, default: 0] += 1
        }
        guard !order.isEmpty else { return }
        let cleanArea = ErrorScrubber.singleLine(area)
        entries.append(contentsOf: order.map { Entry(date: date, area: cleanArea, message: $0, count: counts[$0] ?? 1) })
        if entries.count > Self.maximumLines {
            entries.removeFirst(entries.count - Self.maximumLines)
        }
        save()
    }

    /// Last `days` days, at most `limit`, newest first.
    func recent(days: Int = 7, limit: Int = 20, now: Date = Date()) -> [Entry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return Array(entries.filter { $0.date >= cutoff }.reversed().prefix(limit))
    }

    // MARK: - File

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One entry per line: date, area, count, message, separated by tabs (tabs are scrubbed out).
    private func save() {
        let text = entries.map { entry in
            [Self.dateFormatter.string(from: entry.date), entry.area, String(entry.count), entry.message]
                .joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func load(from url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let entries: [Entry] = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let date = dateFormatter.date(from: String(parts[0])) else { return nil }
            return Entry(date: date, area: String(parts[1]), message: String(parts[3]), count: max(1, Int(parts[2]) ?? 1))
        }
        return Array(entries.suffix(maximumLines))
    }
}

/// Turns error text into something safe to show in a public issue: any path becomes its area name,
/// and item names, the user name and the Mac's name are taken out.
enum ErrorScrubber {
    static func scrub(_ raw: String, area: String, redacting names: [String] = []) -> String {
        var text = singleLine(raw)
        guard !text.isEmpty else { return "" }

        // Longest first, so "Foo Pro" goes before "Foo" can leave " Pro" behind.
        for name in names.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            text = text.replacingOccurrences(of: name, with: "An app", options: .caseInsensitive)
        }

        // Furl's error lines read "<item name or path>: <message>". Drop the item part.
        if let separator = text.range(of: ": ") {
            let rest = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { text = rest }
        }

        // Any absolute or home-relative path left in the message becomes the area name. Folder and file
        // names can contain spaces ("My Projects/secret.txt"), so a path runs to the next punctuation mark
        // or the end. That can swallow words after it, which is the safe way to be wrong.
        text = replacing(#"(?<![\w.])~?/(?:[^:"“”‘’,;()\[\]]*[^\s:"“”‘’,;()\[\]])?"#, in: text, with: area)
        // Quoted names from system errors ("“report.pdf” couldn’t be moved…").
        text = replacing(#"[“"‘][^”"’]{1,200}[”"’]"#, in: text, with: "an item")
        // git's own quotes ("the branch 'client-x' is not fully merged"). The edges must not touch a
        // letter, so apostrophes in "couldn't" or "it's" are left alone.
        text = replacing(#"(?<!\w)'[^'\n]{1,200}'(?!\w)"#, in: text, with: "an item")

        // Never the user name or the Mac's name.
        for word in identifyingWords {
            text = text.replacingOccurrences(of: word, with: "…", options: .caseInsensitive)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Newlines and tabs become spaces so one message is one log line.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// The user name, full name and the Mac's name (Sharing settings; no network lookup).
    private static let identifyingWords: [String] = {
        var words = [NSUserName(), NSFullUserName()]
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { words.append(name) }
        // Short words would mangle ordinary text ("al" in "already"); names that short are rare.
        return words.filter { $0.count >= 3 }
    }()
}

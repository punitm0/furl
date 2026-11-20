import Foundation

// AutoSweepTrust board: Off / Ask first / Automatic, a preview of the next run, the approval
// count that offers Automatic once, and the Overview suggestion after repeated manual cleans.

/// Replaces the old on/off switch. New users start on Off.
enum AutoSweepMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case askFirst
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .askFirst: return "Ask first"
        case .automatic: return "Automatic"
        }
    }
}

/// One-time moves from the old settings to the trust-ladder ones. Pure, so tests can call them.
enum AutoSweepMigration {
    /// The mode for a saved value, or for someone who only has the old switch. Anyone who had
    /// Auto-Sweep on keeps it running by itself (Automatic), so their behaviour doesn't change.
    static func mode(stored: String?, legacyEnabled: Bool?) -> AutoSweepMode {
        if let stored, let mode = AutoSweepMode(rawValue: stored) {
            // Furl writes the old switch as on only for Automatic. Off there means an older build
            // turned Auto-Sweep off after a downgrade, so it must not start running again.
            if mode == .automatic, legacyEnabled == false { return .off }
            return mode
        }
        return legacyEnabled == true ? .automatic : .off
    }

    /// "Empty Furl's Trash items" used to default to on. It's now a Permanent rule that starts
    /// unticked. A saved choice is kept. Without one, it stays on only for people whose Auto-Sweep
    /// was running (they relied on the old default); for everyone else it never ran, so unticking
    /// it changes nothing.
    static func expireTrash(stored: Bool?, legacyEnabled: Bool?) -> Bool {
        if let stored { return stored }
        return legacyEnabled == true
    }
}

/// Ask first: after 3 runs approved without changes, Furl offers Automatic once. Saying no keeps
/// asking and never offers again.
struct AutoSweepTrustLadder: Equatable, Sendable {
    static let approvalsBeforeOffer = 3

    /// Runs approved in a row with nothing unticked.
    var approvedInARow = 0
    /// The Automatic offer was made (whatever the answer).
    var offeredAutomatic = false

    /// Records one approved run and returns true when the offer is due. Call `markOffered()` once
    /// the offer was actually shown, so a notification that couldn't be posted is tried again.
    /// `changed`: the user unticked something in Review before approving.
    mutating func recordApproval(changed: Bool) -> Bool {
        if changed {
            approvedInARow = 0
            return false
        }
        approvedInARow += 1
        return !offeredAutomatic && approvedInARow >= Self.approvalsBeforeOffer
    }

    mutating func markOffered() {
        offeredAutomatic = true
    }
}

// MARK: - Preview of a run

/// What one run would do, worked out without touching anything. Ask first approves exactly this:
/// the approved run moves only these items, and only if each still matches its stamp.
struct AutoSweepPreview: Sendable, Equatable {
    struct Item: Sendable, Hashable, Identifiable {
        enum Kind: String, Sendable { case cache, dependency, download, process, trash }
        var id: String { path }
        let kind: Kind
        /// File path, or a process group id for `.process`.
        let path: String
        /// Moves to the Trash together with `path` (an item's extra paths).
        var extraPaths: [String] = []
        let name: String
        let bytes: Int64
        /// Downloads "already unzipped": the folder that must still be there when the archive moves.
        var extractedFolder: String? = nil
        /// The Trash ledger entry, for `.trash`.
        var ledgerEntry: TrashLedgerEntry? = nil
        /// Row subtitle: the folder, "~/code/web · not used for 41 days", or a dev server's project.
        var detail: String? = nil
        /// Build and dependency folders: the project around them and the folder's own date. They go
        /// only while the project is still unused, so these are judged again when the run happens.
        var project: String? = nil
        var modified: Date? = nil
    }

    let date: Date
    /// The run is due for the scheduled (caches) rule, the daily rules, or both.
    var scheduled: Bool
    var daily: Bool
    var items: [Item]
    /// How every file path looked when the preview was made. The approved run moves a path only if
    /// it still matches (`CleanupRecheck`); a path without a stamp is never moved.
    var stamps: [String: CleanupStamp] = [:]
    /// Items left out because the user unticked them in See list. Such a run counts as changed.
    var userSkipped = false

    var isEmpty: Bool { items.isEmpty }
    var totalBytes: Int64 { items.filter { $0.kind != .process }.reduce(0) { $0 + $1.bytes } }

    func items(_ kind: Item.Kind) -> [Item] { items.filter { $0.kind == kind } }
    func bytes(_ kind: Item.Kind) -> Int64 { items(kind).reduce(0) { $0 + $1.bytes } }
    var hasPermanent: Bool { !items(.trash).isEmpty }

    /// "Caches 3.1 GB · 14 stale node_modules 1.9 GB" (Settings caption, separator " · ").
    func breakdown(separator: String = " · ") -> String {
        parts.joined(separator: separator)
    }

    /// "Caches 3.1 GB and 14 stale node_modules 1.9 GB" (notification).
    var sentence: String {
        let parts = self.parts
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    private var parts: [String] {
        var parts: [String] = []
        if !items(.cache).isEmpty { parts.append("Caches \(FileSizeHelper.formatBytes(bytes(.cache)))") }
        let deps = items(.dependency)
        if !deps.isEmpty { parts.append("\(deps.count) stale node_modules \(FileSizeHelper.formatBytes(bytes(.dependency)))") }
        let downloads = items(.download)
        if !downloads.isEmpty { parts.append("Downloads \(FileSizeHelper.formatBytes(bytes(.download)))") }
        let processes = items(.process)
        if !processes.isEmpty {
            parts.append(processes.count == 1 ? "1 dev server" : "\(processes.count) dev servers")
        }
        let trash = items(.trash)
        if !trash.isEmpty { parts.append("Furl’s Trash items \(FileSizeHelper.formatBytes(bytes(.trash)))") }
        return parts
    }

    /// Second sentence of the Ask first notification.
    var safetySentence: String {
        let movesFiles = items.contains { [.cache, .dependency, .download].contains($0.kind) }
        if hasPermanent { return "Furl’s old Trash items are removed for good." }
        guard movesFiles else { return "" }
        let allSafe = items.allSatisfy { $0.kind != .download }
        return allSafe ? "All safe, all to the Trash." : "All to the Trash."
    }

    /// Everything else in a reviewed preview when some items were unticked.
    func keeping(_ ids: Set<String>) -> AutoSweepPreview {
        var copy = self
        copy.items = items.filter { ids.contains($0.id) }
        return copy
    }
}

/// History: why a run happened ("Why: weekly rule “Clean caches and stale node_modules”. You approved it.").
enum AutoSweepWhy {
    static func ruleTitle(_ rule: AutoSweepRule) -> String {
        switch rule {
        case .caches: return "Clean caches and stale node_modules"
        case .expireTrash: return "Empty Furl’s Trash items"
        case .downloads: return "Tidy Downloads"
        case .compress: return "Compress folders you haven’t opened"
        case .processes: return "Stop dev servers left by closed agent sessions"
        case .safeClean: return "Clean safe items"
        }
    }

    static func text(parts: [AutoSweepRunPart], frequency: AutoSweepFrequency, approved: Bool,
                     processHours: Int) -> String? {
        let rules = parts.filter { $0.itemCount > 0 }.map(\.rule)
        guard !rules.isEmpty else { return nil }
        var why: String
        if rules == [.processes] {
            let age = processHours >= 24 ? "a day" : (processHours == 1 ? "an hour" : "\(processHours) hours")
            why = "Why: their agent session closed over \(age) ago."
        } else if rules.count == 1, let rule = rules.first {
            let cadence = rule == .caches ? frequency.rawValue.lowercased() : "daily"
            why = "Why: \(cadence) rule “\(ruleTitle(rule))”."
        } else {
            let names = rules.map { "“\(ruleTitle($0))”" }
            why = "Why: rules " + names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] + "."
        }
        if approved { why += " You approved it." }
        return why
    }
}

// MARK: - Approving an ask

/// The rule settings when an approved run starts. An ask can be answered days later, after the
/// user changed a rule or started using a project again; the run follows today's settings.
struct AutoSweepRules: Equatable, Sendable {
    var cachesEnabled: Bool
    var cachesUnusedDays: Int
    var stopProcessesEnabled: Bool
    var expireTrashEnabled: Bool
    var expireTrashDays: Int
    var tidyDownloadsEnabled: Bool
}

enum AutoSweepApproval {
    /// An unanswered ask stops being acted on after this, or once the next slot arrives. Clean then
    /// opens Review with a fresh list.
    static let askLifetime: TimeInterval = 24 * 3600

    static func isExpired(_ ask: AutoSweepPreview, now: Date, nextSlot: Date?) -> Bool {
        if now.timeIntervalSince(ask.date) > askLifetime { return true }
        if let nextSlot, nextSlot > ask.date, now >= nextSlot { return true }
        return false
    }

    /// Whether a previewed item may still go under today's rules. Stamps are checked separately,
    /// right before each move; this catches what a stamp can't see: a project edited since the ask
    /// (its node_modules' own date doesn't change), a Trash item no longer old enough after the
    /// days setting went up, and rules switched off.
    static func stillAllowed(_ item: AutoSweepPreview.Item, rules: AutoSweepRules, now: Date,
                             projectActivity: (String) -> Date) -> Bool {
        switch item.kind {
        case .cache, .dependency:
            guard rules.cachesEnabled else { return false }
            // Plain caches are safe by kind; build and dependency folders depend on the project.
            guard item.kind == .dependency || item.project != nil else { return true }
            guard let project = item.project, let modified = item.modified else { return false }
            let cutoff = now.addingTimeInterval(-Double(rules.cachesUnusedDays) * 86_400)
            return modified <= cutoff && projectActivity(project) <= cutoff
        case .process:
            // The stop itself re-checks how long each one has been orphaned.
            return rules.stopProcessesEnabled
        case .trash:
            guard rules.expireTrashEnabled, let entry = item.ledgerEntry else { return false }
            return entry.date <= now.addingTimeInterval(-Double(rules.expireTrashDays) * 86_400)
        case .download:
            return rules.tidyDownloadsEnabled
        }
    }

    /// The approved items that still pass, and how many were dropped.
    static func filter(_ preview: AutoSweepPreview, rules: AutoSweepRules, now: Date,
                       projectActivity: (String) -> Date) -> (preview: AutoSweepPreview, dropped: Int) {
        var cache: [String: Date] = [:]
        let kept = preview.items.filter { item in
            stillAllowed(item, rules: rules, now: now) { project in
                if let known = cache[project] { return known }
                let date = projectActivity(project)
                cache[project] = date
                return date
            }
        }
        return (preview.keeping(Set(kept.map(\.id))), preview.items.count - kept.count)
    }
}

// MARK: - Overview suggestion

/// "You’ve cleaned caches by hand twice this month": offered (Ask first, never Automatic) while
/// Auto-Sweep is off, after two manual Caches & Junk cleans in 30 days.
enum AutoSweepSuggestion {
    static let cleansNeeded = 2
    static let window: TimeInterval = 30 * 86_400

    struct Offer: Equatable {
        let cleanCount: Int
        /// Average size of one manual clean.
        let typicalBytes: Int64
    }

    /// `dismissedAt`: "Not now" hides it until two more manual cleans happen after that moment.
    static func offer(entries: [ActivityEntry], mode: AutoSweepMode, dismissedAt: Date?,
                      now: Date = Date()) -> Offer? {
        guard mode == .off else { return nil }
        let since = max(now.addingTimeInterval(-window), dismissedAt ?? .distantPast)
        let cleans = entries.filter {
            $0.kind == .cleanup && $0.title == SidebarSection.junk.rawValue
                && !$0.automatic && !$0.undone && $0.date > since && $0.date <= now
        }
        guard cleans.count >= cleansNeeded else { return nil }
        let total = cleans.reduce(Int64(0)) { $0 + $1.diskBytes }
        return Offer(cleanCount: cleans.count, typicalBytes: total / Int64(cleans.count))
    }
}

extension AutoSweepRun {
    /// What a run did, in words ("Caches and stale node_modules and 2 dev servers stopped"): the
    /// done notification and the History row title.
    var whatText: String {
        var phrases: [String] = []
        for part in self.parts where part.itemCount > 0 {
            switch part.rule {
            case .caches: phrases.append("Caches and stale node_modules")
            case .downloads: phrases.append(part.itemCount == 1 ? "1 old download" : "\(part.itemCount) old downloads")
            case .processes: phrases.append(part.itemCount == 1 ? "Stopped 1 dev server" : "Stopped \(part.itemCount) dev servers")
            case .expireTrash:
                phrases.append(part.itemCount == 1 ? "1 old Furl item emptied from the Trash" : "\(part.itemCount) old Furl items emptied from the Trash")
            case .compress, .safeClean: phrases.append(part.rule.title)
            }
        }
        guard let first = phrases.first else { return summary }
        guard phrases.count > 1 else { return first }
        let rest = phrases.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }
        return ([first] + rest.dropLast()).joined(separator: ", ") + " and " + rest[rest.count - 1]
    }
}

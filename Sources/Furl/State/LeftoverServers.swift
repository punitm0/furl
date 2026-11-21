import Foundation

/// "Stop leftover servers" (WorktreesShortcuts board): which of the leftovers Processes & Sessions
/// already lists the Shortcuts action may stop, and the confirm and result copy.
enum LeftoverServers {

    /// Kinds that are plain dev servers and watchers. Databases, tunnels, terminal multiplexers,
    /// containers and emulators are never stopped from Shortcuts.
    static let stoppableCategories: Set<LeftoverCategory> = [.devServer, .server, .watcher, .process]

    /// Leftovers Furl marked (agent gone) that aren't exempt from automatic stops and where no process
    /// in the tree is still attached to a terminal.
    static func eligible(_ leftovers: [LeftoverProcess],
                         isAttachedToTerminal: (Int32) -> Bool = ProcessTable.isAttachedToTerminal) -> [LeftoverProcess] {
        leftovers.filter { item in
            item.autoStopExemption == nil
                && stoppableCategories.contains(item.category)
                && !item.members.contains(where: { isAttachedToTerminal($0.pid) })
        }
    }

    // MARK: - Copy (board: "Stop leftover servers · confirm" and Results)

    static func noun(_ count: Int) -> String {
        count == 1 ? "1 leftover server" : "\(count) leftover servers"
    }

    static func confirmTitle(count: Int) -> String { "Stop \(noun(count))?" }

    static let confirmBody = "Their terminals and editors stay open. Unsaved work inside these servers is lost."
    static let confirmFooter = "Start them again from your terminal when you need them."

    static func acceptLabel(count: Int) -> String { count == 1 ? "Stop 1 Server" : "Stop \(count) Servers" }

    /// "vite · web-app · port 5173 · started 2 days ago · no terminal · 410 MB"
    static func confirmLine(_ item: LeftoverProcess, now: Date = Date()) -> String {
        var parts = [item.displayName]
        if let cwd = item.cwd { parts[0] += " · " + URL(fileURLWithPath: cwd).lastPathComponent }
        if !item.ports.isEmpty {
            parts.append((item.ports.count == 1 ? "port " : "ports ")
                         + item.ports.map(String.init).joined(separator: ", "))
        }
        parts.append("started " + age(item.startedAt, now: now))
        parts.append("no terminal")
        parts.append(FileSizeHelper.formatBytes(Int64(clamping: item.memoryBytes)))
        return parts.joined(separator: " · ")
    }

    static func age(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func resultText(count: Int, bytes: UInt64, stuck: Int) -> String {
        var text = "Stopped \(noun(count))."
        if bytes > 0 { text += " Freed \(FileSizeHelper.formatBytes(Int64(clamping: bytes))) of memory." }
        if stuck > 0 {
            text += stuck == 1 ? " 1 didn’t stop; open Furl to force quit it." : " \(stuck) didn’t stop; open Furl to force quit them."
        }
        return text
    }

    static let nothingText = "No leftover servers right now."
}

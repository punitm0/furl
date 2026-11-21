import Darwin
import Foundation

/// Working/Idle state of one agent session, derived from CPU use between refreshes.
struct SessionActivity: Sendable, Hashable {
    enum Status: Sendable { case working, idle }
    let status: Status
    /// For `.working`: when the session started. For `.idle`: when activity was last seen
    /// (or when Furl first saw the session, if it has been quiet since).
    let since: Date
}

/// Transient message shown at the top of the Processes page.
struct ProcessesBanner: Identifiable, Sendable, Equatable {
    let id = UUID()
    let message: String
    var resumeHint: String? = nil
    var isError = false
}

/// Finds AI coding agent sessions and the processes they left running, and stops them on request.
/// Everything runs locally against the process table; nothing leaves the Mac.
///
/// Integration:
/// - Use `ProcessesStore.shared` (or create your own instance) and pass it to `ProcessesView(store:)`.
/// - Call `startBackgroundMonitoring()` once at app launch so auto-end / auto-stop work while the page is closed.
/// - The menu bar can read `leftoverCount`, `leftoverMemoryBytes`, `idleSessionCount` and call `stopAllLeftovers()`.
@MainActor
final class ProcessesStore: ObservableObject {
    static let shared = ProcessesStore()

    // MARK: Published state

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var leftovers: [LeftoverProcess] = []
    @Published private(set) var activity: [String: SessionActivity] = [:]
    @Published var selectedLeftoverIDs: Set<String> = []
    /// `nil` = all agents.
    @Published var agentFilter: AgentKind?
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var stoppingIDs: Set<String> = []
    /// Leftovers that ignored SIGTERM; the UI offers Force Quit for these.
    @Published private(set) var stubbornLeftoverIDs: Set<String> = []
    @Published private(set) var endingSessionIDs: Set<String> = []
    /// Sessions that ignored SIGINT and SIGTERM; the UI offers Force Quit for these.
    @Published private(set) var stubbornSessionIDs: Set<String> = []
    @Published var banner: ProcessesBanner?
    /// Total memory reclaimed by stopping processes since launch.
    @Published private(set) var reclaimedBytesThisSession: UInt64 = 0

    // MARK: Settings (UserDefaults)

    static let idleLimitOptions = [30, 120, 480]
    static let leftoverLimitOptions = [15, 60, 240]

    @Published var autoEndIdleSessions: Bool {
        didSet { defaults.set(autoEndIdleSessions, forKey: Keys.autoEnd); policyChanged() }
    }
    @Published var idleLimitMinutes: Int {
        didSet { defaults.set(idleLimitMinutes, forKey: Keys.idleLimit) }
    }
    @Published var autoStopLeftovers: Bool {
        didSet { defaults.set(autoStopLeftovers, forKey: Keys.autoStop); policyChanged() }
    }
    @Published var leftoverLimitMinutes: Int {
        didSet { defaults.set(leftoverLimitMinutes, forKey: Keys.leftoverLimit) }
    }

    // MARK: Menu bar API

    var leftoverCount: Int { leftovers.count }
    var leftoverMemoryBytes: Int64 { Int64(clamping: leftovers.reduce(UInt64(0)) { $0 + $1.memoryBytes }) }
    var idleSessionCount: Int { sessions.filter { activity[$0.id]?.status != .working }.count }
    var workingSessionCount: Int { sessions.count - idleSessionCount }

    // MARK: Filtering helpers for the view

    var filteredLeftovers: [LeftoverProcess] {
        guard let agentFilter else { return leftovers }
        return leftovers.filter { $0.agent == agentFilter }
    }

    var filteredSessions: [AgentSession] {
        guard let agentFilter else { return sessions }
        return sessions.filter { $0.agent == agentFilter }
    }

    /// Agents that have something running, plus the primary five, for the filter chips.
    var chipAgents: [AgentKind] {
        var kinds = AgentKind.primary
        if leftovers.contains(where: { $0.agent == .other }) || sessions.contains(where: { $0.agent == .other }) {
            kinds.append(.other)
        }
        return kinds
    }

    func count(for agent: AgentKind?) -> Int {
        guard let agent else { return leftovers.count + sessions.count }
        return leftovers.filter { $0.agent == agent }.count + sessions.filter { $0.agent == agent }.count
    }

    // MARK: Private state

    private enum Keys {
        static let autoEnd = "processes.autoEndIdleSessions"
        static let idleLimit = "processes.idleLimitMinutes"
        static let autoStop = "processes.autoStopLeftovers"
        static let leftoverLimit = "processes.leftoverLimitMinutes"
    }

    /// Average CPU (fraction of one core) above which a session tree counts as busy.
    private let busyCPUFraction = 0.025
    /// A session stays "Working" this long after the last observed activity.
    private let workingGrace: TimeInterval = 90

    private let defaults: UserDefaults
    private let lineageURL: URL?
    private var lineage = AgentLineage()
    private var cpuSamples: [String: (cpu: UInt64, at: Date)] = [:]
    private var lastActive: [String: Date] = [:]
    private var firstSeen: [String: Date] = [:]
    private var lastDescendants: [String: Set<String>] = [:]
    private var leftoverFirstSeen: [String: Date] = [:]
    private var knownLeftoverIDs: Set<String> = []
    private var autoEndedIDs: Set<String> = []

    private var visibleClients = 0
    private var backgroundEnabled = false
    private var backgroundInterval: TimeInterval = 60
    private var loopTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, lineageURL: URL? = ProcessesStore.defaultLineageURL()) {
        self.defaults = defaults
        self.lineageURL = lineageURL
        autoEndIdleSessions = defaults.bool(forKey: Keys.autoEnd)
        let idle = defaults.integer(forKey: Keys.idleLimit)
        idleLimitMinutes = idle > 0 ? idle : 120
        autoStopLeftovers = defaults.bool(forKey: Keys.autoStop)
        let leftover = defaults.integer(forKey: Keys.leftoverLimit)
        leftoverLimitMinutes = leftover > 0 ? leftover : 60

        if let lineageURL, let data = try? Data(contentsOf: lineageURL),
           let decoded = try? JSONDecoder().decode(AgentLineage.self, from: data) {
            lineage = decoded
        }
        if autoEndIdleSessions || autoStopLeftovers {
            startBackgroundMonitoring()
        }
    }

    nonisolated static func defaultLineageURL() -> URL? {
        return AppIdentity.supportDirectory.appendingPathComponent("agent-lineage.json")
    }

    // MARK: Refresh loop

    /// Call from `onAppear`; refreshes every few seconds while at least one view is visible.
    func beginLiveUpdates() {
        visibleClients += 1
        restartLoop()
    }

    /// Call from `onDisappear`.
    func endLiveUpdates() {
        visibleClients = max(0, visibleClients - 1)
        restartLoop()
    }

    /// Keeps scanning in the background (default once a minute) so the auto policies and the
    /// menu bar counts stay current while the page is closed. Cheap: one in-process scan.
    func startBackgroundMonitoring(interval: TimeInterval = 60) {
        backgroundEnabled = true
        backgroundInterval = max(10, interval)
        restartLoop()
    }

    func stopBackgroundMonitoring() {
        backgroundEnabled = false
        restartLoop()
    }

    private func policyChanged() {
        if autoEndIdleSessions || autoStopLeftovers { startBackgroundMonitoring() }
    }

    private var currentInterval: TimeInterval? {
        if visibleClients > 0 { return 3 }
        if backgroundEnabled { return backgroundInterval }
        return nil
    }

    private func restartLoop() {
        loopTask?.cancel()
        guard let interval = currentInterval else {
            loopTask = nil
            return
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // A second quick sample right after the first gives a Working/Idle reading immediately.
                if self.cpuSamples.isEmpty == false, self.lastRefreshWasFirst {
                    self.lastRefreshWasFirst = false
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private var lastRefreshWasFirst = true

    /// Rescans processes. Safe to call at any time; overlapping calls are coalesced.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            let currentLineage = lineage
            let result = await Task.detached(priority: .utility) {
                AgentProcessScanner.scan(lineage: currentLineage)
            }.value
            apply(result, now: Date())
        } while refreshAgain
        isRefreshing = false
        await runAutoPolicies(now: Date())
    }

    private var refreshAgain = false

    private func apply(_ result: AgentScanResult, now: Date) {
        lineage = result.lineage
        if result.lineageChanged { saveLineage() }

        // Session activity.
        var newActivity: [String: SessionActivity] = [:]
        let liveSessionIDs = Set(result.sessions.map(\.id))
        for session in result.sessions {
            let id = session.id
            if firstSeen[id] == nil { firstSeen[id] = now }
            var active = false
            if let previous = cpuSamples[id] {
                let wall = now.timeIntervalSince(previous.at)
                if wall > 0.2 {
                    let cpuSeconds = Double(session.treeCPUNanos &- min(previous.cpu, session.treeCPUNanos)) / 1_000_000_000
                    active = cpuSeconds / wall >= busyCPUFraction
                }
                // A new child process (a tool call or command) is activity too.
                if let before = lastDescendants[id], !session.descendantKeys.subtracting(before).isEmpty {
                    active = true
                }
            }
            cpuSamples[id] = (session.treeCPUNanos, now)
            lastDescendants[id] = session.descendantKeys
            if active { lastActive[id] = now }

            if let last = lastActive[id], now.timeIntervalSince(last) < workingGrace {
                newActivity[id] = SessionActivity(status: .working, since: session.startedAt)
            } else {
                newActivity[id] = SessionActivity(status: .idle, since: lastActive[id] ?? firstSeen[id] ?? now)
            }
        }
        for key in Array(cpuSamples.keys) where !liveSessionIDs.contains(key) {
            cpuSamples[key] = nil
            lastActive[key] = nil
            firstSeen[key] = nil
            lastDescendants[key] = nil
        }
        endingSessionIDs.formIntersection(liveSessionIDs)
        stubbornSessionIDs.formIntersection(liveSessionIDs)
        autoEndedIDs.formIntersection(liveSessionIDs)

        // Leftovers: new ones start selected.
        let liveLeftoverIDs = Set(result.leftovers.map(\.id))
        for item in result.leftovers where !knownLeftoverIDs.contains(item.id) {
            selectedLeftoverIDs.insert(item.id)
            leftoverFirstSeen[item.id] = now
        }
        knownLeftoverIDs = liveLeftoverIDs
        selectedLeftoverIDs.formIntersection(liveLeftoverIDs)
        stubbornLeftoverIDs.formIntersection(liveLeftoverIDs)
        leftoverFirstSeen = leftoverFirstSeen.filter { liveLeftoverIDs.contains($0.key) }

        sessions = result.sessions
        leftovers = result.leftovers
        activity = newActivity
        lastRefresh = now
        hasLoaded = true
    }

    private func saveLineage() {
        guard let lineageURL else { return }
        let snapshot = lineage
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: lineageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: lineageURL, options: .atomic)
        }
    }

    // MARK: Auto policies

    /// When a leftover became orphaned: the agent's exit time if known, else when Furl first saw it.
    func orphanedSince(_ item: LeftoverProcess) -> Date {
        item.agentExitedAt ?? leftoverFirstSeen[item.id] ?? Date()
    }

    private func runAutoPolicies(now: Date) async {
        if autoStopLeftovers {
            let limit = TimeInterval(leftoverLimitMinutes * 60)
            // Databases, tmux/screen and tunnels are never auto-stopped (see AutoStopPolicy).
            let due = leftovers.filter {
                $0.autoStopExemption == nil
                    && now.timeIntervalSince(orphanedSince($0)) >= limit
                    && !stoppingIDs.contains($0.id)
                    && !stubbornLeftoverIDs.contains($0.id)
            }
            if !due.isEmpty {
                await stop(due, signal: SIGTERM, automatic: true)
            }
        }
        if autoEndIdleSessions {
            let limit = TimeInterval(idleLimitMinutes * 60)
            let due = sessions.filter { session in
                guard let state = activity[session.id], state.status == .idle else { return false }
                return now.timeIntervalSince(state.since) >= limit
                    && !endingSessionIDs.contains(session.id)
                    && !autoEndedIDs.contains(session.id)
            }
            for session in due {
                autoEndedIDs.insert(session.id)
                await endSession(session, automatic: true)
            }
        }
    }

    // MARK: Stopping leftovers

    func stopLeftovers(ids: Set<String>) async {
        let targets = leftovers.filter { ids.contains($0.id) }
        await stop(targets, signal: SIGTERM, automatic: false)
    }

    func stopSelectedLeftovers() async {
        let visible = Set(filteredLeftovers.map(\.id))
        await stopLeftovers(ids: selectedLeftoverIDs.intersection(visible))
    }

    /// Gracefully stops every leftover (SIGTERM). Returns the bytes reclaimed.
    @discardableResult
    func stopAllLeftovers() async -> UInt64 {
        await stop(leftovers, signal: SIGTERM, automatic: false)
    }

    /// Leftovers Auto-Sweep would stop now (orphaned for at least `hours`, never exempt ones).
    /// Refreshes first so the list is current. Stops nothing; Ask first shows these.
    func leftoversDue(orphanedForAtLeast hours: Int, now: Date = Date()) async -> [LeftoverProcess] {
        // refresh() returns at once if another refresh is running; wait for that one instead.
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await refresh()
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        // Auto-Sweep is automatic too: never databases, tmux/screen or tunnels.
        return leftovers.filter { $0.autoStopExemption == nil && orphanedSince($0) <= cutoff }
    }

    /// Gracefully stops leftovers orphaned for at least `hours` (used by Auto-Sweep).
    /// Refreshes first so the list is current. Returns how many were stopped and the memory freed.
    /// `onlyIDs`: Ask first, the leftovers the user approved; any others wait.
    func stopLeftovers(orphanedForAtLeast hours: Int, onlyIDs: Set<String>? = nil,
                       now: Date = Date()) async -> (count: Int, bytes: UInt64) {
        var targets = await leftoversDue(orphanedForAtLeast: hours, now: now)
        if let onlyIDs { targets = targets.filter { onlyIDs.contains($0.id) } }
        guard !targets.isEmpty else { return (0, 0) }
        let bytes = await stop(targets, signal: SIGTERM, automatic: true)
        let stopped = targets.filter { !stubbornLeftoverIDs.contains($0.id) }.count
        return (stopped, bytes)
    }

    /// The leftovers after a refresh that finished after this call (waits for one already running).
    func freshLeftovers() async -> [LeftoverProcess] {
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await refresh()
        return leftovers
    }

    /// Shortcuts' "Stop leftover servers": only the leftovers the user confirmed that are still listed
    /// after a fresh refresh and still pass `LeftoverServers.eligible` (checked again right now).
    func stopConfirmedLeftovers(ids: Set<String>) async -> (stopped: Int, stuck: Int, bytes: UInt64) {
        let targets = LeftoverServers.eligible(await freshLeftovers().filter { ids.contains($0.id) })
        guard !targets.isEmpty else { return (0, 0, 0) }
        let bytes = await stop(targets, signal: SIGTERM, automatic: false)
        let stuck = targets.filter { stubbornLeftoverIDs.contains($0.id) }.count
        return (targets.count - stuck, stuck, bytes)
    }

    /// SIGKILL for leftovers that ignored SIGTERM.
    func forceQuitLeftovers(ids: Set<String>) async {
        let targets = leftovers.filter { ids.contains($0.id) }
        await stop(targets, signal: SIGKILL, automatic: false)
    }

    @discardableResult
    private func stop(_ targets: [LeftoverProcess], signal: Int32, automatic: Bool) async -> UInt64 {
        // Last line of defence for automatic stops; a manual stop may stop anything the user picked.
        let targets = automatic ? targets.filter { $0.autoStopExemption == nil } : targets
        guard !targets.isEmpty else { return 0 }
        let ids = Set(targets.map(\.id))
        stoppingIDs.formUnion(ids)
        defer { stoppingIDs.subtract(ids) }

        var refs: [ProcessRef] = []
        var memory: [ProcessRef: UInt64] = [:]
        for item in targets {
            refs.append(contentsOf: item.members)
            for (index, ref) in item.members.enumerated() where index < item.memberMemory.count {
                memory[ref] = item.memberMemory[index]
            }
        }

        let outcome = await ProcessTerminator.terminate(refs, signal: signal, timeout: signal == SIGKILL ? 2 : 3, memory: memory)
        let survivors = Set(outcome.stillRunning).union(outcome.refused.filter(ProcessTerminator.isAlive))
        var stopped = 0
        for item in targets {
            if item.members.contains(where: { survivors.contains($0) }) {
                stubbornLeftoverIDs.insert(item.id)
            } else {
                stopped += 1
                stubbornLeftoverIDs.remove(item.id)
                selectedLeftoverIDs.remove(item.id)
            }
        }
        reclaimedBytesThisSession += outcome.reclaimedBytes
        StatsLedger.shared.recordMemoryFreed(Int64(clamping: outcome.reclaimedBytes), category: automatic ? .autoSweep : .processes)
        let stoppedNames = targets.filter { !stubbornLeftoverIDs.contains($0.id) }.map(\.displayName)
        ActivityLog.shared.recordProcessStop(count: stopped, bytes: outcome.reclaimedBytes, automatic: automatic,
                                             names: stoppedNames)

        let stuck = targets.count - stopped
        var parts: [String] = []
        if stopped > 0 {
            var text = (automatic ? "Auto-stopped " : "Stopped ") + (stopped == 1 ? "1 leftover process" : "\(stopped) leftover processes")
            if outcome.reclaimedBytes > 0 {
                text += " · \(FileSizeHelper.formatBytes(Int64(clamping: outcome.reclaimedBytes))) memory freed"
            }
            parts.append(text)
        }
        if stuck > 0 {
            parts.append(stuck == 1 ? "1 process didn't exit; you can force quit it" : "\(stuck) processes didn't exit; you can force quit them")
        }
        showBanner(ProcessesBanner(message: parts.joined(separator: ". ") + ".", isError: stuck > 0 && stopped == 0))
        await refresh()
        return outcome.reclaimedBytes
    }

    // MARK: Ending sessions

    func endSession(id: String) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        await endSession(session, automatic: false)
    }

    /// SIGKILL for a session that ignored SIGINT/SIGTERM.
    func forceQuitSession(id: String) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        endingSessionIDs.insert(id)
        defer { endingSessionIDs.remove(id) }
        let outcome = await ProcessTerminator.terminate([session.ref], signal: SIGKILL, timeout: 2)
        if outcome.exited.contains(session.ref) {
            stubbornSessionIDs.remove(id)
            let message = "Force quit \(session.agentName) in \(session.projectName)."
            ActivityLog.shared.recordSessionEnd(label: "\(session.agentName) in \(session.projectName)",
                                                detail: String(message.dropLast()), automatic: false)
            showBanner(ProcessesBanner(message: message, resumeHint: session.resumeHint))
        } else {
            showBanner(ProcessesBanner(message: "Couldn't end \(session.agentName) in \(session.projectName).", isError: true))
        }
        await refresh()
    }

    /// Graceful end: SIGINT, then SIGTERM. Agents save their transcript, so the session can be resumed.
    private func endSession(_ session: AgentSession, automatic: Bool) async {
        let id = session.id
        guard !endingSessionIDs.contains(id) else { return }
        endingSessionIDs.insert(id)
        defer { endingSessionIDs.remove(id) }

        var outcome = await ProcessTerminator.terminate([session.ref], signal: SIGINT, timeout: 1.5)
        if !outcome.stillRunning.isEmpty {
            outcome = await ProcessTerminator.terminate([session.ref], signal: SIGTERM, timeout: 5)
        }

        let label = "\(session.agentName) in \(session.projectName)"
        if outcome.exited.contains(session.ref) {
            stubbornSessionIDs.remove(id)
            let prefix = automatic ? "Ended idle session: " : "Ended "
            ActivityLog.shared.recordSessionEnd(label: label, detail: prefix + label, automatic: automatic)
            showBanner(ProcessesBanner(message: prefix + label + ".", resumeHint: session.resumeHint))
        } else if !outcome.refused.isEmpty {
            showBanner(ProcessesBanner(message: "Furl won't end \(label): it is Furl's own parent or belongs to another user.", isError: true))
        } else {
            stubbornSessionIDs.insert(id)
            showBanner(ProcessesBanner(message: "\(label) is still running. You can force quit it.", isError: true))
        }
        await refresh()
    }

    // MARK: Banner

    private func showBanner(_ banner: ProcessesBanner) {
        self.banner = banner
        bannerTask?.cancel()
        let id = banner.id
        let seconds: UInt64 = banner.resumeHint == nil ? 6 : 15
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.banner?.id == id else { return }
            self.banner = nil
        }
    }
}

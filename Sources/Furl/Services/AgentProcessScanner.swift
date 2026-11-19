import Darwin
import Foundation

// MARK: - Public models

/// Stable identity of a process: PID plus start time, so a reused PID never matches.
struct ProcessRef: Sendable, Hashable, Codable {
    let pid: Int32
    let startMicros: UInt64

    var id: String { "\(pid)@\(startMicros)" }
}

/// A running agent session (Claude Code, Codex, …).
struct AgentSession: Identifiable, Sendable, Hashable {
    let ref: ProcessRef
    let agent: AgentKind
    let agentName: String
    let cwd: String?
    let startedAt: Date
    /// Short description of how it was launched, e.g. "Claude app", "CLI · --resume".
    let detail: String
    let resumeHint: String?
    /// CPU time of the agent plus every descendant, in nanoseconds (used for Working/Idle).
    let treeCPUNanos: UInt64
    /// PIDs of descendants; a new child appearing counts as activity (a tool call started).
    let descendantKeys: Set<String>
    let memoryBytes: UInt64
    /// Background processes this session detached from itself (still traceable, not leftovers while it lives).
    let detachedCount: Int

    var id: String { ref.id }
    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown folder" }
        return (cwd as NSString).lastPathComponent
    }
}

/// What a leftover process looks like it is.
enum LeftoverCategory: String, Sendable {
    case devServer = "dev server"
    case server = "server"
    case watcher = "watcher"
    case emulator = "emulator"
    case container = "container"
    case database = "database"
    case tunnel = "tunnel"
    case multiplexer = "terminal multiplexer"
    case process = "process"
}

/// A process tree left running after the agent that started it exited.
struct LeftoverProcess: Identifiable, Sendable, Hashable {
    /// Root of the leftover tree.
    let ref: ProcessRef
    /// Every process in the tree (root first) with its memory, used when stopping.
    let members: [ProcessRef]
    /// Memory of each member, parallel to `members`.
    let memberMemory: [UInt64]
    let displayName: String
    let executableName: String
    let category: LeftoverCategory
    let agent: AgentKind
    let agentName: String
    let cwd: String?
    let ports: [Int]
    let memoryBytes: UInt64
    let workerCount: Int
    let startedAt: Date
    /// When the originating agent was last seen alive, if Furl observed it.
    let agentExitedAt: Date?
    /// One-line explanation, e.g. "Started by Claude Code in ~/code/app, agent exited 2 days ago".
    let summary: String
    /// Individual pieces of evidence for the attribution.
    let evidence: [String]
    /// Set when some process in the tree is a database, terminal multiplexer or tunnel. Auto-stop and
    /// Auto-Sweep never stop these; stopping by hand still works.
    var autoStopExemption: AutoStopExemption? = nil

    var id: String { ref.id }
}

/// Persisted memory of which processes ran under which agent. Lets Furl attribute
/// leftovers from agents that do not export env markers, and say when the agent exited.
struct AgentLineage: Codable, Sendable {
    struct ProcessRecord: Codable, Sendable {
        var agentName: String
        var agentPid: Int32
        var agentStartMicros: UInt64
        var observedAt: Date
    }

    struct AgentRecord: Codable, Sendable {
        var agentName: String
        var pid: Int32
        var startMicros: UInt64
        var cwd: String?
        var lastSeen: Date
        var exitedAt: Date?
    }

    /// Keyed by `ProcessRef.id` of the descendant.
    var processes: [String: ProcessRecord] = [:]
    /// Keyed by `ProcessRef.id` of the agent.
    var agents: [String: AgentRecord] = [:]
}

struct AgentScanResult: Sendable {
    let sessions: [AgentSession]
    let leftovers: [LeftoverProcess]
    let lineage: AgentLineage
    let lineageChanged: Bool
}

// MARK: - Scanner

enum AgentProcessScanner {
    /// Takes a fresh snapshot of the process table and classifies it. Runs off the main actor.
    static func scan(lineage: AgentLineage, now: Date = Date()) -> AgentScanResult {
        let table = ProcessTable.snapshot()
        var result = analyze(table: table, lineage: lineage, selfPID: getpid(), now: now)
        let pids = result.leftovers.flatMap { $0.members.map(\.pid) }
        if !pids.isEmpty {
            let ports = listeningPorts(pids: pids)
            if !ports.isEmpty {
                let leftovers = result.leftovers.map { item -> LeftoverProcess in
                    let found = Set(item.members.flatMap { ports[$0.pid] ?? [] }).sorted()
                    guard !found.isEmpty else { return item }
                    return item.with(ports: found)
                }
                result = AgentScanResult(sessions: result.sessions, leftovers: leftovers, lineage: result.lineage, lineageChanged: result.lineageChanged)
            }
        }
        return result
    }

    // MARK: Analysis (pure; takes the table so it can be tested)

    static func analyze(table: [Int32: ProcInfo], lineage oldLineage: AgentLineage, selfPID: Int32, now: Date) -> AgentScanResult {
        var children: [Int32: [Int32]] = [:]
        for proc in table.values where proc.ppid > 0 && proc.pid != proc.ppid {
            children[proc.ppid, default: []].append(proc.pid)
        }

        func descendants(of pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var stack = children[pid] ?? []
            var seen: Set<Int32> = [pid]
            while let next = stack.popLast() {
                guard seen.insert(next).inserted else { continue }
                out.append(next)
                stack.append(contentsOf: children[next] ?? [])
            }
            return out
        }

        func ancestors(of pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var current = table[pid]?.ppid ?? 0
            var guardCount = 0
            while current > 1, guardCount < 64, let proc = table[current] {
                out.append(current)
                current = proc.ppid
                guardCount += 1
            }
            return out
        }

        // 1. Identify agent processes.
        var agentMatches: [Int32: (AgentDefinition, AgentRole)] = [:]
        for proc in table.values where !proc.isZombie {
            if let match = detectAgent(proc) { agentMatches[proc.pid] = match }
        }

        // Our own process, its ancestors and its descendants are never touched.
        let selfAncestors = Set(ancestors(of: selfPID))
        let selfDescendants = Set(descendants(of: selfPID))
        let protected = selfAncestors.union(selfDescendants).union([selfPID, 1])

        // 2. Update lineage with what is alive right now.
        var lineage = oldLineage
        var lineageChanged = false
        let aliveKeys = Set(table.values.map(\.key))

        for (pid, (def, role)) in agentMatches where role == .session {
            guard let proc = table[pid] else { continue }
            if var record = lineage.agents[proc.key] {
                record.lastSeen = now
                record.cwd = proc.cwd ?? record.cwd
                lineage.agents[proc.key] = record
            } else {
                lineage.agents[proc.key] = .init(agentName: def.name, pid: pid, startMicros: proc.startMicros, cwd: proc.cwd, lastSeen: now, exitedAt: nil)
                lineageChanged = true
            }
            for child in descendants(of: pid) {
                guard let childProc = table[child], agentMatches[child] == nil else { continue }
                if lineage.processes[childProc.key] == nil {
                    lineage.processes[childProc.key] = .init(agentName: def.name, agentPid: pid, agentStartMicros: proc.startMicros, observedAt: now)
                    lineageChanged = true
                }
            }
        }
        for (key, record) in lineage.agents where record.exitedAt == nil && !aliveKeys.contains(key) {
            var updated = record
            updated.exitedAt = record.lastSeen
            lineage.agents[key] = updated
            lineageChanged = true
        }
        let processCountBefore = lineage.processes.count
        lineage.processes = lineage.processes.filter { aliveKeys.contains($0.key) }
        let referencedAgents = Set(lineage.processes.values.map { "\($0.agentPid)@\($0.agentStartMicros)" })
        let agentCountBefore = lineage.agents.count
        lineage.agents = lineage.agents.filter { key, record in
            guard let exited = record.exitedAt else { return true }
            return referencedAgents.contains(key) || now.timeIntervalSince(exited) < 14 * 86_400
        }
        if lineage.processes.count != processCountBefore || lineage.agents.count != agentCountBefore { lineageChanged = true }

        func isLiveAgentProcess(pid: Int32, startedBefore start: UInt64) -> Bool {
            guard let proc = table[pid], agentMatches[pid] != nil, !proc.isZombie else { return false }
            return proc.startMicros <= start
        }

        // 3. Attribute every user process to an agent, if possible.
        struct Attribution {
            var def: AgentDefinition
            var agentPid: Int32?
            var agentStartMicros: UInt64?
            var evidence: [String]
        }

        func attribution(for proc: ProcInfo) -> Attribution? {
            if let match = envAttribution(proc) {
                var evidence = ["Its environment carries \(match.marker), which \(match.def.name) sets for the commands it runs."]
                var agentStart: UInt64?
                if let pid = match.agentPid {
                    if let record = lineage.agents.values.first(where: { $0.pid == pid && $0.startMicros <= proc.startMicros && $0.agentName == match.def.name }) {
                        agentStart = record.startMicros
                    }
                    evidence[0] += " Agent PID was \(pid)."
                }
                return Attribution(def: match.def, agentPid: match.agentPid, agentStartMicros: agentStart, evidence: evidence)
            }
            if let record = lineage.processes[proc.key], let def = AgentDefinition.definition(named: record.agentName) {
                let evidence = ["Furl saw it running under \(def.name) (PID \(record.agentPid)) \(relative(record.observedAt, now: now))."]
                return Attribution(def: def, agentPid: record.agentPid, agentStartMicros: record.agentStartMicros, evidence: evidence)
            }
            // Process group led by an agent that has since exited.
            if proc.pgid != proc.pid,
               let record = lineage.agents.values.first(where: { $0.pid == proc.pgid && $0.startMicros <= proc.startMicros }),
               record.exitedAt != nil,
               let def = AgentDefinition.definition(named: record.agentName) {
                let evidence = ["Its process group was led by \(def.name) (PID \(record.pid)), which has exited."]
                return Attribution(def: def, agentPid: record.pid, agentStartMicros: record.startMicros, evidence: evidence)
            }
            return nil
        }

        // 4. Find leftover candidates.
        var candidates: [Int32: Attribution] = [:]
        var detachedPerAgent: [Int32: Int] = [:]
        for proc in table.values {
            guard !proc.isZombie,
                  !protected.contains(proc.pid),
                  agentMatches[proc.pid] == nil,
                  !isSystemOrExcluded(proc),
                  let attr = attribution(for: proc) else { continue }

            let procAncestors = ancestors(of: proc.pid)
            // Still under a live agent (session or host)? Then it is in use.
            if procAncestors.contains(where: { agentMatches[$0] != nil }) { continue }
            // Our own tree is off limits.
            if procAncestors.contains(where: { protected.contains($0) && $0 != 1 }) { continue }

            // The agent it names is still alive (it detached on purpose, e.g. a daemon).
            if let agentPid = attr.agentPid, isLiveAgentProcess(pid: agentPid, startedBefore: proc.startMicros) {
                detachedPerAgent[agentPid, default: 0] += 1
                continue
            }
            // No PID to check: be conservative and treat it as in use while any live session
            // of the same agent works in the same folder.
            if attr.agentPid == nil, let cwd = proc.cwd {
                let sameFolderSession = agentMatches.contains { pid, match in
                    guard match.0.name == attr.def.name, let agentCwd = table[pid]?.cwd else { return false }
                    return cwd == agentCwd || cwd.hasPrefix(agentCwd + "/")
                }
                if sameFolderSession { continue }
            }
            // Hosts something that is itself a live agent (e.g. a tmux server running a new session).
            if descendants(of: proc.pid).contains(where: { agentMatches[$0] != nil }) { continue }

            candidates[proc.pid] = attr
        }

        // 5. Collapse to tree roots and describe.
        // macOS hides the environment of Apple platform binaries such as /bin/sh and /bin/zsh, so
        // the agent's wrapper shell carries no marker even when the server under it does. Climb
        // through such unmarked wrappers; the topmost one becomes the root if launchd owns it.
        var roots: [Int32: Attribution] = [:]
        for (pid, attr) in candidates {
            if ancestors(of: pid).contains(where: { candidates[$0] != nil }) { continue }
            var rootPID = pid
            while let current = table[rootPID], current.ppid != 1, let parent = table[current.ppid] {
                guard candidates[parent.pid] == nil,
                      agentMatches[parent.pid] == nil,
                      !protected.contains(parent.pid),
                      !isSystemOrExcluded(parent),
                      parent.markers.isEmpty,
                      wrappers.contains(normalizedName(parent)) else { break }
                rootPID = parent.pid
            }
            // A root must be detached: owned by launchd, or its parent belongs to someone else.
            // A root whose parent is still a live process of ours is attached to that process.
            guard let root = table[rootPID], root.ppid == 1 || table[root.ppid] == nil else { continue }
            if roots[rootPID] == nil { roots[rootPID] = attr }
        }

        var leftovers: [LeftoverProcess] = []
        for (pid, attr) in roots {
            guard let root = table[pid] else { continue }

            let memberPIDs = [pid] + descendants(of: pid).filter { !protected.contains($0) && agentMatches[$0] == nil }
            let members = memberPIDs.compactMap { table[$0] }
            let display = displayProcess(root: root, table: table, children: children)
            let memory = members.reduce(UInt64(0)) { $0 + $1.memoryBytes }

            var agentExitedAt: Date?
            if let agentPid = attr.agentPid {
                let record = lineage.agents.values
                    .filter { $0.pid == agentPid && $0.agentName == attr.def.name && $0.startMicros <= root.startMicros }
                    .max { $0.startMicros < $1.startMicros }
                if let start = attr.agentStartMicros, let exact = lineage.agents["\(agentPid)@\(start)"] {
                    agentExitedAt = exact.exitedAt
                } else {
                    agentExitedAt = record?.exitedAt
                }
            }

            var evidence = attr.evidence
            if let exited = agentExitedAt {
                evidence.append("\(attr.def.name) exited \(relative(exited, now: now)).")
            } else if let agentPid = attr.agentPid {
                evidence.append("\(attr.def.name) (PID \(agentPid)) is no longer running.")
            } else {
                evidence.append("No running \(attr.def.name) session is attached to it or works in its folder.")
            }
            if root.ppid == 1 {
                evidence.append("Its parent exited, so macOS handed it to launchd; nothing is attached to it.")
            }
            if let cwd = root.cwd {
                evidence.append("Working folder: \(abbreviate(cwd)).")
            }

            let category = classify(display)
            let interpreter = display.executableName.lowercased().hasPrefix("python") ? "python" : display.executableName
            var summary = "Started by \(attr.def.name)"
            if let cwd = root.cwd { summary += " in \(abbreviate(cwd))" }
            if let exited = agentExitedAt {
                summary += ", agent exited \(relative(exited, now: now))"
            } else {
                summary += ", agent no longer running"
            }

            leftovers.append(LeftoverProcess(
                ref: ProcessRef(pid: root.pid, startMicros: root.startMicros),
                members: members.map { ProcessRef(pid: $0.pid, startMicros: $0.startMicros) },
                memberMemory: members.map(\.memoryBytes),
                displayName: friendlyName(display),
                executableName: interpreter,
                category: category,
                agent: attr.def.kind,
                agentName: attr.def.name,
                cwd: root.cwd,
                ports: [],
                memoryBytes: memory,
                workerCount: max(0, members.count - 1),
                startedAt: root.startDate,
                agentExitedAt: agentExitedAt,
                summary: summary,
                evidence: evidence,
                autoStopExemption: AutoStopPolicy.exemption(for: members + [display])
            ))
        }
        leftovers.sort { $0.memoryBytes > $1.memoryBytes }

        // 6. Sessions.
        var sessions: [AgentSession] = []
        for (pid, (def, role)) in agentMatches where role == .session {
            guard let proc = table[pid] else { continue }
            // Skip agents nested inside another session of the same agent (sub-processes).
            if ancestors(of: pid).contains(where: { agentMatches[$0]?.0.name == def.name && agentMatches[$0]?.1 == .session }) { continue }
            let tree = descendants(of: pid).compactMap { table[$0] }
            let cpu = tree.reduce(proc.cpuNanos) { $0 &+ $1.cpuNanos }
            let memory = tree.reduce(proc.memoryBytes) { $0 + $1.memoryBytes }
            let isDesktop = proc.markers["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop"
                || ancestors(of: pid).contains { table[$0]?.path.contains("/Claude.app/") == true }
            sessions.append(AgentSession(
                ref: ProcessRef(pid: pid, startMicros: proc.startMicros),
                agent: def.kind,
                agentName: def.name,
                cwd: proc.cwd,
                startedAt: proc.startDate,
                detail: sessionDetail(proc, def: def, isDesktop: isDesktop),
                resumeHint: isDesktop ? "Reopen it from the Claude app" : def.resumeHint,
                treeCPUNanos: cpu,
                descendantKeys: Set(tree.map(\.key)),
                memoryBytes: memory,
                detachedCount: detachedPerAgent[pid] ?? 0
            ))
        }
        sessions.sort { $0.startedAt > $1.startedAt }

        return AgentScanResult(sessions: sessions, leftovers: leftovers, lineage: lineage, lineageChanged: lineageChanged)
    }

    // MARK: Agent detection

    static func detectAgent(_ proc: ProcInfo) -> (AgentDefinition, AgentRole)? {
        var exe = proc.executableName
        // Native installs run from e.g. ~/.local/share/claude/versions/2.1.325, so the executable's
        // basename is a version number; argv[0] still says "claude".
        if let first = proc.args.first, !first.isEmpty {
            let argv0 = (first as NSString).lastPathComponent
            if !AgentDefinition.all.contains(where: { $0.executableNames.contains(exe) }),
               AgentDefinition.all.contains(where: { $0.executableNames.contains(argv0) }) {
                exe = argv0
            }
        }
        let argTokens = Set(proc.args.dropFirst())
        for def in AgentDefinition.all {
            if !def.hostPathMarkers.isEmpty, def.hostPathMarkers.contains(where: { proc.path.contains($0) }) {
                return (def, .host)
            }
            var matched = def.executableNames.contains(exe)
            if !matched, AgentDefinition.interpreters.contains(exe.lowercased()) || exe.lowercased().hasPrefix("python") {
                let joined = proc.args.dropFirst().prefix(3).joined(separator: " ")
                matched = def.scriptMarkers.contains { joined.contains($0) }
            }
            if !matched, exe == "gh", def.kind == .copilot, proc.args.dropFirst().first == "copilot" {
                matched = true
            }
            guard matched else { continue }
            if def.hostArguments.contains(where: { argTokens.contains($0) }) {
                return (def, .host)
            }
            return (def, .session)
        }
        return nil
    }

    private static func envAttribution(_ proc: ProcInfo) -> (def: AgentDefinition, marker: String, agentPid: Int32?)? {
        let markers = proc.markers
        guard !markers.isEmpty else { return nil }
        for def in AgentDefinition.all {
            if let key = def.envMarkers.first(where: { markers[$0] != nil }) {
                let pid = def.pidEnvKey.flatMap { markers[$0] }.flatMap { Int32($0) }
                let display = key == def.pidEnvKey ? key : "\(key)=\(markers[key] ?? "")"
                return (def, display, pid)
            }
        }
        if let value = markers["AI_AGENT"]?.lowercased(), !value.isEmpty {
            for def in AgentDefinition.all where def.aiAgentPrefixes.contains(where: { value.hasPrefix($0) }) {
                let pid = def.pidEnvKey.flatMap { markers[$0] }.flatMap { Int32($0) }
                return (def, "AI_AGENT", pid)
            }
        }
        return nil
    }

    private static func sessionDetail(_ proc: ProcInfo, def: AgentDefinition, isDesktop: Bool) -> String {
        var parts: [String] = []
        if isDesktop {
            parts.append("Claude app")
        } else if proc.markers["CLAUDE_CODE_ENTRYPOINT"].map({ $0.contains("vscode") }) == true {
            parts.append("VS Code")
        } else {
            parts.append("CLI")
        }
        let interesting = proc.args.dropFirst().filter { ["--resume", "-r", "--continue", "-c", "-p", "--print", "exec", "resume"].contains($0) }
        if let first = interesting.first { parts.append(first) }
        return parts.joined(separator: " · ")
    }

    // MARK: Exclusions

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Applications/", "/System/Applications/"]
    private static let excludedNames: Set<String> = ["launchd", "loginwindow", "Finder", "Dock", "WindowServer", "ssh-agent", "gpg-agent", "caffeinate"]

    private static func isSystemOrExcluded(_ proc: ProcInfo) -> Bool {
        if proc.pid <= 1 { return true }
        if proc.path.isEmpty && proc.args.isEmpty { return true }
        if systemPrefixes.contains(where: { proc.path.hasPrefix($0) }) { return true }
        if excludedNames.contains(proc.executableName) { return true }
        // Interactive login shells (argv[0] like "-zsh") belong to the user's terminal.
        if proc.args.first?.hasPrefix("-") == true { return true }
        return false
    }

    // MARK: Description

    private static let wrappers: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "env", "nohup", "timeout", "npm", "npx", "pnpm", "yarn", "uv", "poetry", "pipenv", "make", "bundle", "xargs"]

    /// Shell and package-manager wrappers are described by the process they run.
    private static func displayProcess(root: ProcInfo, table: [Int32: ProcInfo], children: [Int32: [Int32]]) -> ProcInfo {
        var current = root
        var depth = 0
        while depth < 6, wrappers.contains(normalizedName(current)) {
            let kids = (children[current.pid] ?? []).compactMap { table[$0] }
            guard let next = kids.max(by: { $0.memoryBytes < $1.memoryBytes }) else { break }
            current = next
            depth += 1
        }
        return current
    }

    private static func normalizedName(_ proc: ProcInfo) -> String {
        let exe = proc.executableName.lowercased()
        if exe.hasPrefix("python") { return "python" }
        // npm/npx/yarn run under node; look at the script.
        if exe == "node", let script = proc.args.dropFirst().first {
            let base = (script as NSString).lastPathComponent
            if ["npm", "npx", "npm-cli.js", "npx-cli.js", "pnpm", "pnpm.cjs", "yarn", "yarn.js"].contains(base) {
                return "npm"
            }
        }
        return exe
    }

    static func friendlyName(_ proc: ProcInfo) -> String {
        let rawExe = proc.executableName
        let exe = rawExe.lowercased().hasPrefix("python") ? "python" : rawExe
        let args = Array(proc.args.dropFirst())
        let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "php", "java"]
        var name: String

        if exe.hasPrefix("python") {
            if let m = args.firstIndex(of: "-m"), m + 1 < args.count {
                name = args[m + 1]
                if m + 2 < args.count, !args[m + 2].hasPrefix("-"), Int(args[m + 2]) == nil { name += " " + args[m + 2] }
            } else if let script = args.first(where: { !$0.hasPrefix("-") }) {
                name = scriptName(script, following: args)
            } else {
                name = exe
            }
        } else if interpreters.contains(exe), let scriptIndex = args.firstIndex(where: { !$0.hasPrefix("-") }) {
            name = scriptName(args[scriptIndex], following: Array(args[(scriptIndex + 1)...]))
        } else {
            name = exe
            if let sub = args.first, !sub.hasPrefix("-"), !sub.contains("/"), sub.count <= 16 { name += " " + sub }
        }
        if args.contains("--watch") || args.contains("-w"), !name.contains("watch") { name += " --watch" }
        return name.count > 42 ? String(name.prefix(41)) + "…" : name
    }

    private static func scriptName(_ script: String, following: [String]) -> String {
        let components = script.split(separator: "/").map(String.init)
        var base = (script as NSString).lastPathComponent
        // node_modules/.bin/next, next/dist/bin/next, vite/bin/vite.js, wrangler/bin/wrangler.js
        if let nm = components.lastIndex(of: "node_modules"), nm + 1 < components.count {
            let pkg = components[nm + 1]
            base = pkg == ".bin" && nm + 2 < components.count ? components[nm + 2] : pkg
            if base.hasPrefix("@"), nm + 2 < components.count { base = components[nm + 2] }
        }
        for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where base.hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
        }
        if base == "index" || base == "cli" || base == "main", components.count >= 2 {
            base = components[components.count - 2]
        }
        if let sub = following.first, !sub.hasPrefix("-"), !sub.contains("/"), sub.count <= 16, Int(sub) == nil {
            base += " " + sub
        }
        return base
    }

    static func classify(_ proc: ProcInfo) -> LeftoverCategory {
        let exe = proc.executableName.lowercased()
        let joined = proc.args.joined(separator: " ").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { joined.contains($0) } }

        if exe.hasPrefix("qemu") || exe == "emulator" || exe.contains("simulator") || has(["emulator -avd", "/emulator/"]) { return .emulator }
        if ["docker", "docker-compose", "podman", "colima", "limactl", "com.docker.cli"].contains(exe) { return .container }
        if ["postgres", "redis-server", "mysqld", "mongod", "memcached"].contains(exe) { return .database }
        if exe == "tmux" || exe == "screen" || exe == "zellij" { return .multiplexer }
        if exe == "ngrok" || exe == "cloudflared" || exe == "tailscale" || exe == "tailscaled"
            || (exe == "ssh" && AutoStopPolicy.isForwardingSSH(Array(proc.args.dropFirst()))) || has(["fly proxy", "flyctl proxy", "port-forward"]) { return .tunnel }
        if has(["--watch", " -w ", "nodemon", "watchman", "chokidar", "cargo watch", "watchexec", "vitest", "jest --watch"]) { return .watcher }
        if has(["next dev", "next start", "vite", "webpack", "nuxt", "astro dev", "remix", "react-scripts", "wrangler dev", "parcel", "storybook", "expo start", "http-server", "serve "]) { return .devServer }
        if has(["uvicorn", "gunicorn", "flask", "runserver", "http.server", "rails", "puma", "php -s", "hypercorn", "streamlit", "jupyter"]) { return .server }
        if ["node", "bun", "deno"].contains(exe) { return .devServer }
        return .process
    }

    // MARK: Ports

    /// Listening TCP ports for the given PIDs via `lsof` (local only).
    static func listeningPorts(pids: [Int32]) -> [Int32: [Int]] {
        let list = Set(pids).map(String.init).joined(separator: ",")
        let output = ShellRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", list, "-Fpn"], timeout: 8)
        var result: [Int32: Set<Int>] = [:]
        var currentPID: Int32?
        for line in output.stdout.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            if tag == "p" {
                currentPID = Int32(value)
            } else if tag == "n", let pid = currentPID, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    // MARK: Formatting helpers

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        return formatDuration(seconds) + " ago"
    }

    /// "14 min", "3 h 20 min", "2 days".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let minutes = total / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        if hours >= 1 {
            let rem = minutes % 60
            return rem == 0 ? "\(hours) h" : "\(hours) h \(rem) min"
        }
        if minutes >= 1 { return "\(minutes) min" }
        return "\(total) s"
    }
}

extension LeftoverProcess {
    func with(ports: [Int]) -> LeftoverProcess {
        LeftoverProcess(
            ref: ref, members: members, memberMemory: memberMemory, displayName: displayName, executableName: executableName,
            category: category, agent: agent, agentName: agentName, cwd: cwd, ports: ports,
            memoryBytes: memoryBytes, workerCount: workerCount, startedAt: startedAt,
            agentExitedAt: agentExitedAt, summary: summary, evidence: evidence,
            autoStopExemption: autoStopExemption
        )
    }
}

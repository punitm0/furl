import Foundation

/// The AI coding agents Furl knows how to recognise.
/// To support a new agent, add a case (or reuse `.other`) and an entry in `AgentDefinition.all`.
enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case gemini
    case copilot
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot"
        case .other: return "Other agents"
        }
    }

    /// Agents shown as filter chips even when nothing is running for them.
    static let primary: [AgentKind] = [.claudeCode, .codex, .cursor, .gemini, .copilot]
}

/// How a matched process relates to an agent.
enum AgentRole: Sendable {
    /// An interactive or headless agent session the user may want to end.
    case session
    /// Infrastructure that hosts agent work (e.g. the Codex app-server, Cursor.app).
    /// Counts as "agent still alive" for children, but is never offered for ending.
    case host
}

/// Declarative description of one agent CLI. Everything is matched locally against
/// the process table; nothing is looked up online.
struct AgentDefinition: Sendable {
    let kind: AgentKind
    let name: String
    /// Executable basenames (case-sensitive), e.g. `claude`.
    let executableNames: Set<String>
    /// Substrings in argv that identify the agent when it runs under an interpreter
    /// (`node …/@anthropic-ai/claude-code/cli.js`).
    let scriptMarkers: [String]
    /// When the executable matches but argv contains one of these, the process is a host, not a session.
    let hostArguments: [String]
    /// Path substrings that mark host processes (e.g. `/Cursor.app/`).
    let hostPathMarkers: [String]
    /// Environment variables the agent sets for the commands it runs. Inherited env survives
    /// reparenting to launchd, so this is the strongest evidence for leftovers.
    let envMarkers: [String]
    /// Environment variable holding the agent's own PID, if the agent exports one.
    let pidEnvKey: String?
    /// Prefixes of the cross-agent `AI_AGENT` variable.
    let aiAgentPrefixes: [String]
    /// Shell command that picks an ended session back up.
    let resumeHint: String?

    static let all: [AgentDefinition] = [
        AgentDefinition(
            kind: .claudeCode,
            name: "Claude Code",
            executableNames: ["claude"],
            scriptMarkers: ["@anthropic-ai/claude-code", "/claude-code/cli.js"],
            hostArguments: [],
            hostPathMarkers: [],
            envMarkers: ["CLAUDECODE", "CLAUDE_PID"],
            pidEnvKey: "CLAUDE_PID",
            aiAgentPrefixes: ["claude-code", "claude"],
            resumeHint: "claude --resume"
        ),
        AgentDefinition(
            kind: .codex,
            name: "Codex",
            executableNames: ["codex"],
            scriptMarkers: ["@openai/codex", "/codex-cli/bin/codex"],
            hostArguments: ["app-server", "exec-server", "mcp-server", "mcp"],
            hostPathMarkers: [],
            envMarkers: ["CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID", "CODEX_SESSION_ID"],
            pidEnvKey: nil,
            aiAgentPrefixes: ["codex", "openai-codex"],
            resumeHint: "codex resume"
        ),
        AgentDefinition(
            kind: .cursor,
            name: "Cursor",
            executableNames: ["cursor-agent"],
            scriptMarkers: ["cursor-agent"],
            hostArguments: [],
            hostPathMarkers: ["/Cursor.app/Contents/"],
            // CURSOR_TRACE_ID is deliberately absent: it is also set in the user's own
            // Cursor terminal tabs, and those processes are the user's, not the agent's.
            envMarkers: ["CURSOR_AGENT"],
            pidEnvKey: nil,
            aiAgentPrefixes: ["cursor"],
            resumeHint: "cursor-agent resume"
        ),
        AgentDefinition(
            kind: .gemini,
            name: "Gemini CLI",
            executableNames: ["gemini"],
            scriptMarkers: ["@google/gemini-cli", "gemini-cli/dist"],
            hostArguments: [],
            hostPathMarkers: [],
            envMarkers: ["GEMINI_CLI"],
            pidEnvKey: nil,
            aiAgentPrefixes: ["gemini"],
            resumeHint: "gemini --resume"
        ),
        AgentDefinition(
            kind: .copilot,
            name: "Copilot",
            executableNames: ["copilot", "gh-copilot"],
            scriptMarkers: ["@github/copilot"],
            hostArguments: [],
            hostPathMarkers: [],
            envMarkers: ["COPILOT_CLI", "COPILOT_AGENT"],
            pidEnvKey: nil,
            aiAgentPrefixes: ["copilot", "github-copilot"],
            resumeHint: "copilot --resume"
        ),
        // Generic agents: easy to extend. They share the `.other` chip.
        AgentDefinition(
            kind: .other, name: "Aider", executableNames: ["aider"], scriptMarkers: ["/bin/aider"],
            hostArguments: [], hostPathMarkers: [], envMarkers: [], pidEnvKey: nil,
            aiAgentPrefixes: ["aider"], resumeHint: nil
        ),
        AgentDefinition(
            kind: .other, name: "opencode", executableNames: ["opencode"], scriptMarkers: ["opencode-ai"],
            hostArguments: [], hostPathMarkers: [], envMarkers: ["OPENCODE"], pidEnvKey: nil,
            aiAgentPrefixes: ["opencode"], resumeHint: "opencode --continue"
        ),
        AgentDefinition(
            kind: .other, name: "Amp", executableNames: ["amp"], scriptMarkers: ["@sourcegraph/amp"],
            hostArguments: [], hostPathMarkers: [], envMarkers: [], pidEnvKey: nil,
            aiAgentPrefixes: ["amp"], resumeHint: "amp threads continue"
        ),
        AgentDefinition(
            kind: .other, name: "Goose", executableNames: ["goose"], scriptMarkers: [],
            hostArguments: ["mcp"], hostPathMarkers: [], envMarkers: [], pidEnvKey: nil,
            aiAgentPrefixes: ["goose"], resumeHint: "goose session --resume"
        )
    ]

    /// All env keys worth reading from other processes. Only these are kept; every other
    /// environment value (tokens, secrets) is discarded the moment it is parsed.
    static let watchedEnvKeys: Set<String> = {
        var keys: Set<String> = ["AI_AGENT", "CLAUDE_CODE_ENTRYPOINT"]
        for def in all {
            keys.formUnion(def.envMarkers)
            if let pidEnvKey = def.pidEnvKey { keys.insert(pidEnvKey) }
        }
        return keys
    }()

    static func definition(named name: String) -> AgentDefinition? {
        all.first { $0.name == name }
    }

    /// Interpreters an agent CLI may run under.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
}

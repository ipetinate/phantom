import Foundation

/// The four agents, and the one place that knows all of them.
///
/// A list of closures rather than a protocol, for the reason
/// `MCPToolRegistry` gives about tools: each installer is a value that lives
/// beside the file it writes, and adding a fifth agent should be one entry
/// here rather than a type hierarchy. `AgentsSettingsView` writes the same four
/// rows out longhand for the hooks; this exists because the MCP pane has a
/// second caller — the launch-time repair — and two hand-written lists of four
/// agents is how the fifth one ends up in only one of them.
@MainActor
enum MCPServerRegistration {
    struct Agent: Identifiable {
        let id: CodingAgent

        /// What the reader calls it, from the same place the sidebar's agent
        /// menu takes it.
        var name: String { id.displayName }

        let isRegistered: () -> Bool
        let register: () -> Bool
        let remove: () -> Bool
        let repairIfStale: () -> Bool
        let lastError: () -> String?
    }

    static var agents: [Agent] {
        [
            Agent(
                id: .claude,
                isRegistered: { ClaudeMCPInstaller.isRegistered },
                register: { ClaudeMCPInstaller.register() },
                remove: { ClaudeMCPInstaller.remove() },
                repairIfStale: { ClaudeMCPInstaller.repairIfStale() },
                lastError: { ClaudeMCPInstaller.lastError }),
            Agent(
                id: .codex,
                isRegistered: { CodexMCPInstaller.isRegistered },
                register: { CodexMCPInstaller.register() },
                remove: { CodexMCPInstaller.remove() },
                repairIfStale: { CodexMCPInstaller.repairIfStale() },
                lastError: { CodexMCPInstaller.lastError }),
            Agent(
                id: .opencode,
                isRegistered: { OpenCodeMCPInstaller.isRegistered },
                register: { OpenCodeMCPInstaller.register() },
                remove: { OpenCodeMCPInstaller.remove() },
                repairIfStale: { OpenCodeMCPInstaller.repairIfStale() },
                lastError: { OpenCodeMCPInstaller.lastError }),
            Agent(
                id: .antigravity,
                isRegistered: { AntigravityMCPInstaller.isRegistered },
                register: { AntigravityMCPInstaller.register() },
                remove: { AntigravityMCPInstaller.remove() },
                repairIfStale: { AntigravityMCPInstaller.repairIfStale() },
                lastError: { AntigravityMCPInstaller.lastError }),
        ]
    }

    /// Agents this app knows but does not register itself with, and why.
    ///
    /// Declared rather than implied by omission, because omission is exactly
    /// how an agent gets forgotten: `everyAgentIsOffered` asserts that this set
    /// and ``agents`` together account for every `CodingAgent`, so a new one
    /// fails the suite until somebody decides which side it belongs on. That is
    /// the point — the decision is cheap, the silence is not.
    ///
    /// **Kimi and Pi.** Both were added as agents on the strength of documented
    /// launch and resume flags, and neither has a *verified* MCP configuration
    /// surface. Kimi keeps its settings in TOML at `~/.kimi-code/config.toml`
    /// and its own documentation steers the reader to configure MCP by talking
    /// to the agent rather than by editing a file, so the file's shape for an
    /// MCP entry is not established. Pi's extension system is TypeScript
    /// modules rather than declarative configuration, which is a different
    /// shape from every installer here.
    ///
    /// Writing into either on a guess is the one thing an installer must never
    /// do: these files belong to other programs, and a malformed entry is a
    /// failure the reader sees in that program with nothing pointing back here.
    static let withoutInstaller: Set<CodingAgent> = [.kimi, .pi]

    /// Who is registered right now, read off disk each time.
    ///
    /// Not cached, for the reason `AgentsSettingsView` rechecks on every
    /// activation: these files belong to the agents as much as to Phantom, and
    /// a status the app remembers from launch describes a state the buttons can
    /// no longer act on.
    static func status() -> [CodingAgent: Bool] {
        var found: [CodingAgent: Bool] = [:]
        for agent in agents { found[agent.id] = agent.isRegistered() }
        return found
    }

    /// Brings every existing registration up to this build, and installs none.
    ///
    /// The same rule the hooks installers' `repairIfStale` follows, and here it
    /// carries more weight than there: the command each entry holds is a path
    /// into this bundle, so moving Phantom on disk breaks all four at once and
    /// nothing about the failure the reader sees names Phantom. An agent with
    /// no entry is an agent the reader never asked about, and stays that way.
    static func repairAll() {
        for agent in agents { _ = agent.repairIfStale() }
    }

    static let footer = "Writes Phantom's MCP server into each agent's own configuration, merging rather than replacing it. The entry points at this copy of Phantom, so it is rewritten when the app moves. Claude Code and Antigravity take it as a command and its arguments, Codex as a TOML table, OpenCode as a single command array \u{2014} each shape from that agent's own documentation."
}

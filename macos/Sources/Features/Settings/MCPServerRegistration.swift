import Foundation

@MainActor
protocol MCPEngine: AnyObject {
    var descriptor: AgentDescriptor { get }
    var isRegistered: Bool { get }
    var lastError: String? { get }

    @discardableResult func register() -> Bool
    @discardableResult func remove() -> Bool
    @discardableResult func repairIfStale() -> Bool
}

/// The agents, and the one place that knows all of them.
///
/// A list of closures rather than a protocol on the row, for the reason
/// `MCPToolRegistry` gives about tools: each engine is a value that lives
/// beside the file it writes, and adding an agent should be one descriptor in
/// the registry rather than a type hierarchy. `AgentsSettingsView` writes the
/// same rows out for the hooks; this exists because the MCP pane has a second
/// caller — the launch-time repair — and two hand-written lists of agents is how
/// the next one ends up in only one of them.
@MainActor
enum MCPServerRegistration {
    struct Agent: Identifiable {
        let id: CodingAgent

        /// What the reader calls it, from the same place the sidebar's agent
        /// menu takes it.
        var name: String { id.displayName }

        let isRegistered: @MainActor () -> Bool
        let register: @MainActor () -> Bool
        let remove: @MainActor () -> Bool
        let repairIfStale: @MainActor () -> Bool
        let lastError: @MainActor () -> String?

        init(id: CodingAgent, engine: MCPEngine) {
            self.id = id
            self.isRegistered = { engine.isRegistered }
            self.register = { engine.register() }
            self.remove = { engine.remove() }
            self.repairIfStale = { engine.repairIfStale() }
            self.lastError = { engine.lastError }
        }
    }

    static func engine(for agent: CodingAgent) -> MCPEngine? {
        engine(for: agent.descriptor)
    }

    static func engine(for descriptor: AgentDescriptor) -> MCPEngine? {
        switch descriptor.mcp {
        case .json(let mcp)?:
            return JSONMCPInstaller(descriptor: descriptor, mcp: mcp)
        case .toml(let mcp)?:
            return TOMLMCPInstaller(descriptor: descriptor, mcp: mcp)
        case nil:
            return nil
        }
    }

    static var agents: [Agent] {
        CodingAgent.allCases.compactMap { agent in
            engine(for: agent).map { Agent(id: agent, engine: $0) }
        }
    }

    /// Agents this app knows but does not register itself with: the ones whose
    /// descriptor carries no MCP integration.
    ///
    /// Declared rather than implied by omission, because omission is exactly
    /// how an agent gets forgotten: `everyAgentIsOffered` asserts that this set
    /// and ``agents`` together account for every `CodingAgent`, so a new one
    /// fails the suite until somebody decides which side it belongs on. That is
    /// the point — the decision is cheap, the silence is not.
    ///
    /// Empty, and kept rather than deleted. It held Kimi and Pi for exactly as
    /// long as it took to establish where each of them keeps MCP declarations —
    /// Kimi in its own `mcp.json` rather than in `config.toml`, Pi in a file
    /// read by an extension rather than by Pi itself — and the mechanism is
    /// what made that a decision somebody had to make instead of a gap nobody
    /// noticed. The next agent gets the same treatment.
    static var withoutInstaller: Set<CodingAgent> {
        Set(CodingAgent.allCases.filter { $0.descriptor.mcp == nil })
    }

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
    /// into this bundle, so moving Phantom on disk breaks all of them at once
    /// and nothing about the failure the reader sees names Phantom. An agent
    /// with no entry is an agent the reader never asked about, and stays that
    /// way.
    static func repairAll() {
        for agent in agents { _ = agent.repairIfStale() }
    }

    static let footer = "Writes Phantom's MCP server into each agent's own configuration, merging rather than replacing it. The entry points at this copy of Phantom, so it is rewritten when the app moves. Claude Code, Antigravity and Kimi Code take it as a command and its arguments, Codex as a TOML table, OpenCode as a single command array \u{2014} each shape from that agent's own documentation. Pi has no MCP client of its own: the file is written where the community extension for it reads, so the entry is live only once that extension is installed."
}

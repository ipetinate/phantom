import Foundation

/// The six agents' hooks, and the one place that knows all of them.
///
/// The MCP side has had `MCPServerRegistration` since it grew a second caller,
/// and for the reason stated there: two hand-written lists of six agents is how
/// the seventh lands in only one of them. The hooks side had three such lists —
/// the launch-time repair in `AppDelegate`, the rows in `AgentsSettingsView`,
/// and the state that pane re-reads when the window comes back — and the third
/// one was already wrong. Its refresh covered four of the six, with Kimi and Pi
/// updated from inside Antigravity's install closure, so a hook installed in
/// another window showed as missing here until the pane was reopened.
///
/// Closures rather than a protocol, mirroring `MCPServerRegistration` exactly:
/// each installer is a value that lives beside the file it writes, and adding a
/// seventh agent should be one entry here.
@MainActor
enum AgentHooksRegistration {
    struct Agent: Identifiable {
        let id: CodingAgent

        /// What the reader calls it, from the same place the sidebar's agent
        /// menu takes it.
        var name: String { id.displayName }

        let isInstalled: () -> Bool

        /// Installed, but not the script this build ships. Absent from
        /// `MCPServerRegistration.Agent`, and present here because the hooks
        /// are generated files that go out of date with the app while an MCP
        /// entry only goes out of date when the app moves.
        let isStale: () -> Bool

        let install: () -> Bool
        let uninstall: () -> Bool
        let repairIfStale: () -> Bool
        let lastError: () -> String?
    }

    static var agents: [Agent] {
        [
            Agent(
                id: .claude,
                isInstalled: { ClaudeHooksInstaller.isInstalled },
                isStale: { ClaudeHooksInstaller.isStale },
                install: { ClaudeHooksInstaller.install() },
                uninstall: { ClaudeHooksInstaller.uninstall() },
                repairIfStale: { ClaudeHooksInstaller.repairIfStale() },
                lastError: { ClaudeHooksInstaller.lastError }),
            Agent(
                id: .codex,
                isInstalled: { CodexHooksInstaller.isInstalled },
                isStale: { CodexHooksInstaller.isStale },
                install: { CodexHooksInstaller.install() },
                uninstall: { CodexHooksInstaller.uninstall() },
                repairIfStale: { CodexHooksInstaller.repairIfStale() },
                lastError: { CodexHooksInstaller.lastError }),
            Agent(
                id: .opencode,
                isInstalled: { OpenCodeHooksInstaller.isInstalled },
                isStale: { OpenCodeHooksInstaller.isStale },
                install: { OpenCodeHooksInstaller.install() },
                uninstall: { OpenCodeHooksInstaller.uninstall() },
                repairIfStale: { OpenCodeHooksInstaller.repairIfStale() },
                lastError: { OpenCodeHooksInstaller.lastError }),
            Agent(
                id: .antigravity,
                isInstalled: { AntigravityHooksInstaller.isInstalled },
                isStale: { AntigravityHooksInstaller.isStale },
                install: { AntigravityHooksInstaller.install() },
                uninstall: { AntigravityHooksInstaller.uninstall() },
                repairIfStale: { AntigravityHooksInstaller.repairIfStale() },
                lastError: { AntigravityHooksInstaller.lastError }),
            Agent(
                id: .kimi,
                isInstalled: { KimiHooksInstaller.isInstalled },
                isStale: { KimiHooksInstaller.isStale },
                install: { KimiHooksInstaller.install() },
                uninstall: { KimiHooksInstaller.uninstall() },
                repairIfStale: { KimiHooksInstaller.repairIfStale() },
                lastError: { KimiHooksInstaller.lastError }),
            Agent(
                id: .pi,
                isInstalled: { PiHooksInstaller.isInstalled },
                isStale: { PiHooksInstaller.isStale },
                install: { PiHooksInstaller.install() },
                uninstall: { PiHooksInstaller.uninstall() },
                repairIfStale: { PiHooksInstaller.repairIfStale() },
                lastError: { PiHooksInstaller.lastError }),
        ]
    }

    /// Agents this app knows but installs no hooks for, and why.
    ///
    /// Declared rather than implied by omission, for the reason
    /// `MCPServerRegistration.withoutInstaller` gives: omission is how an agent
    /// gets forgotten, and a test asserts that this set and ``agents`` together
    /// account for every `CodingAgent`. Empty today — every agent this app
    /// launches has somewhere to put a hook.
    static let withoutInstaller: Set<CodingAgent> = []

    /// Who has hooks installed right now, read off disk each time.
    ///
    /// Not cached, for the reason `MCPServerRegistration.status` gives: these
    /// files belong to the agents as much as to Phantom, and a status the app
    /// remembers from launch describes a state the buttons can no longer act
    /// on.
    static func status() -> [CodingAgent: Bool] {
        var found: [CodingAgent: Bool] = [:]
        for agent in agents { found[agent.id] = agent.isInstalled() }
        return found
    }

    /// Brings every installed hook up to this build, and installs none.
    ///
    /// The rule each installer's own `repairIfStale` follows: the script
    /// carries this build's text and a path into this bundle, so an app that
    /// updated or moved leaves every installed hook stale at once — and an
    /// agent with no hook is an agent the reader never asked about, which stays
    /// that way.
    static func repairAll() {
        for agent in agents { _ = agent.repairIfStale() }
    }
}

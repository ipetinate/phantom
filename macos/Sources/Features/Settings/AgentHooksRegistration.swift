import Foundation

@MainActor
protocol HooksEngine: AnyObject {
    var descriptor: AgentDescriptor { get }
    var isInstalled: Bool { get }
    var isStale: Bool { get }
    var lastError: String? { get }

    @discardableResult func install() -> Bool
    @discardableResult func uninstall() -> Bool
    @discardableResult func repairIfStale() -> Bool
}

/// The agents' hooks, and the one place that knows all of them.
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
/// Closures rather than a protocol on the row, mirroring `MCPServerRegistration`
/// exactly. Each closure reaches an engine built from the agent's descriptor,
/// so an agent the registry gains is listed here without another entry.
@MainActor
enum AgentHooksRegistration {
    struct Agent: Identifiable {
        let id: CodingAgent

        /// What the reader calls it, from the same place the sidebar's agent
        /// menu takes it.
        var name: String { id.displayName }

        let isInstalled: @MainActor () -> Bool

        /// Installed, but not the script this build ships. Absent from
        /// `MCPServerRegistration.Agent`, and present here because the hooks
        /// are generated files that go out of date with the app while an MCP
        /// entry only goes out of date when the app moves.
        let isStale: @MainActor () -> Bool

        let install: @MainActor () -> Bool
        let uninstall: @MainActor () -> Bool
        let repairIfStale: @MainActor () -> Bool
        let lastError: @MainActor () -> String?

        init(id: CodingAgent, engine: HooksEngine) {
            self.id = id
            self.isInstalled = { engine.isInstalled }
            self.isStale = { engine.isStale }
            self.install = { engine.install() }
            self.uninstall = { engine.uninstall() }
            self.repairIfStale = { engine.repairIfStale() }
            self.lastError = { engine.lastError }
        }
    }

    static func engine(for agent: CodingAgent) -> HooksEngine? {
        engine(for: agent.descriptor)
    }

    static func engine(for descriptor: AgentDescriptor) -> HooksEngine? {
        switch descriptor.hooks {
        case .json(let hooks)?:
            return JSONHooksInstaller(descriptor: descriptor, hooks: hooks)
        case .toml(let hooks)?:
            return TOMLHooksInstaller(descriptor: descriptor, hooks: hooks)
        case .file(let plugin)?:
            return PluginFileInstaller(descriptor: descriptor, plugin: plugin)
        case nil:
            return nil
        }
    }

    static func pluginFile(for agent: CodingAgent) -> PluginFileInstaller? {
        engine(for: agent) as? PluginFileInstaller
    }

    static var agents: [Agent] {
        CodingAgent.allCases.compactMap { agent in
            engine(for: agent).map { Agent(id: agent, engine: $0) }
        }
    }

    /// Agents this app knows but installs no hooks for: the ones whose
    /// descriptor carries no hooks integration.
    ///
    /// Declared rather than implied by omission, for the reason
    /// `MCPServerRegistration.withoutInstaller` gives: omission is how an agent
    /// gets forgotten, and a test asserts that this set and ``agents`` together
    /// account for every `CodingAgent`. Empty today — every agent this app
    /// launches has somewhere to put a hook.
    static var withoutInstaller: Set<CodingAgent> {
        Set(CodingAgent.allCases.filter { $0.descriptor.hooks == nil })
    }

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

    static func logStatus() {
        for agent in CodingAgent.allCases {
            (engine(for: agent) as? JSONHooksInstaller)?.logStatus()
        }
    }
}

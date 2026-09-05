import Foundation

/// The package managers an agent's own documentation installs it with.
enum AgentPackageManager: String, CaseIterable, Sendable {
    case homebrew
    case npm

    /// The binary to look for before offering a command that starts with it.
    var command: String {
        switch self {
        case .homebrew: return "brew"
        case .npm: return "npm"
        }
    }

    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        }
    }
}

/// One way to install one agent, exactly as its own documentation spells it.
struct AgentInstallCommand: Equatable, Sendable {
    let manager: AgentPackageManager

    /// Handed to the login shell verbatim. No interpolation, no assembly from
    /// parts: what runs is what a reader could paste themselves, which is also
    /// what makes the Copy button honest.
    let command: String
}

/// How to install each agent's CLI, and which agents this app will not offer to
/// install.
///
/// **Every command was read off that agent's own documentation**, and lives on
/// the agent's descriptor in `AgentRegistry`. None is inferred from a package
/// name that looks right — `pi` alone has three similarly named packages on npm
/// by three different publishers, and the one that matches the extension
/// directory Phantom writes is neither the shortest nor the first result.
///
/// The refusals matter as much as the commands. An agent whose only documented
/// install is a script piped into a shell is **not** offered: a welcome panel
/// that opens by itself, on a machine somebody has just started using, is the
/// last place to normalise `curl … | bash`. It shows the documentation instead,
/// which is where that decision belongs.
enum AgentInstallPlan {
    struct Entry: Identifiable {
        let agent: CodingAgent
        var id: CodingAgent { agent }

        /// In the order this app prefers them. The first whose manager is on
        /// the machine is the one offered.
        let commands: [AgentInstallCommand]

        /// The page the commands were read from, shown whether or not there is
        /// a command — an agent this app cannot install is still an agent the
        /// reader can go and install.
        let documentation: URL?
    }

    /// What every one of these has in common once it is installed, said once
    /// rather than six times: the binary is the easy half.
    static let signInNote = """
        Installing only puts the command on your PATH. Each agent asks you to \
        sign in the first time you run it, in its own terminal.
        """

    static var all: [Entry] {
        CodingAgent.allCases.compactMap { agent in
            let installation = agent.descriptor.installation
            guard !installation.commands.isEmpty else { return nil }
            return Entry(
                agent: agent,
                commands: installation.commands,
                documentation: installation.documentation)
        }
    }

    /// Agents this app will not offer to install — the ones whose descriptor
    /// carries no command — declared so a test can assert this set and ``all``
    /// together account for every `CodingAgent`.
    static var withoutInstallCommand: Set<CodingAgent> {
        Set(CodingAgent.allCases.filter { $0.descriptor.installation.commands.isEmpty })
    }

    /// The page for an agent, whether or not this app can install it.
    static var documentation: [CodingAgent: URL] {
        Dictionary(uniqueKeysWithValues: CodingAgent.allCases.compactMap { agent in
            agent.descriptor.installation.documentation.map { (agent, $0) }
        })
    }

    static func entry(for agent: CodingAgent) -> Entry? {
        all.first { $0.agent == agent }
    }

    /// The command to offer, given what is on the machine.
    ///
    /// Nil when this app installs the agent but no manager it knows is there:
    /// the card then names the managers rather than running a command that will
    /// fail on its first word.
    static func command(
        for agent: CodingAgent,
        managers available: Set<AgentPackageManager>
    ) -> AgentInstallCommand? {
        entry(for: agent)?.commands.first { available.contains($0.manager) }
    }
}

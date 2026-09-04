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
/// **Every command here was read off that agent's own documentation.** None is
/// inferred from a package name that looks right — `pi` alone has three
/// similarly named packages on npm by three different publishers, and the one
/// that matches the extension directory Phantom writes is neither the shortest
/// nor the first result.
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
        let documentation: URL
    }

    /// What every one of these has in common once it is installed, said once
    /// rather than six times: the binary is the easy half.
    static let signInNote = """
        Installing only puts the command on your PATH. Each agent asks you to \
        sign in the first time you run it, in its own terminal.
        """

    static let all: [Entry] = [
        Entry(
            agent: .claude,
            commands: [
                AgentInstallCommand(manager: .homebrew, command: "brew install --cask claude-code"),
                AgentInstallCommand(manager: .npm, command: "npm install -g @anthropic-ai/claude-code"),
            ],
            documentation: URL(string: "https://code.claude.com/docs/en/setup")!),
        Entry(
            agent: .codex,
            commands: [
                AgentInstallCommand(manager: .homebrew, command: "brew install --cask codex"),
                AgentInstallCommand(manager: .npm, command: "npm install -g @openai/codex"),
            ],
            documentation: URL(string: "https://developers.openai.com/codex/quickstart")!),
        Entry(
            agent: .opencode,
            commands: [
                /// The tap rather than the core formula, on the project's own
                /// advice: it calls the core one "maintained by the Homebrew
                /// team and updated less frequently".
                AgentInstallCommand(
                    manager: .homebrew, command: "brew install anomalyco/tap/opencode"),
                AgentInstallCommand(manager: .npm, command: "npm install -g opencode-ai"),
            ],
            documentation: URL(string: "https://opencode.ai/docs/")!),
        Entry(
            agent: .kimi,
            commands: [
                AgentInstallCommand(
                    manager: .npm, command: "npm install -g @moonshot-ai/kimi-code"),
            ],
            documentation: URL(
                string: "https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html")!),
        Entry(
            agent: .pi,
            commands: [
                /// `--ignore-scripts` is the vendor's own spelling and is kept
                /// rather than tidied away: dropping it would install the same
                /// package a different way from the way its documentation says
                /// to.
                AgentInstallCommand(
                    manager: .npm,
                    command: "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"),
            ],
            documentation: URL(string: "https://pi.dev/docs/latest/")!),
    ]

    /// Agents this app will not offer to install, and why — declared rather
    /// than implied by omission, the discipline `MCPServerRegistration`
    /// established: a test asserts this set and ``all`` together account for
    /// every `CodingAgent`, so a seventh agent fails the suite until somebody
    /// decides which side it belongs on.
    ///
    /// Antigravity publishes one install for macOS and it is
    /// `curl -fsSL … | bash`. See the type's own note for why that is not
    /// offered from here.
    static let withoutInstallCommand: Set<CodingAgent> = [.antigravity]

    /// The page for an agent, whether or not this app can install it.
    static let documentation: [CodingAgent: URL] = {
        var pages = Dictionary(uniqueKeysWithValues: all.map { ($0.agent, $0.documentation) })
        pages[.antigravity] = URL(string: "https://antigravity.google/docs/cli/install")!
        return pages
    }()

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

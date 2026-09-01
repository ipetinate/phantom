import Foundation
@testable import Ghostty
import Testing

/// The commands this app is willing to run to install an agent.
///
/// Every one was read off that agent's own documentation, and the tests below
/// are about the two ways that goes wrong: a command that was inferred rather
/// than read, and a command whose shape makes it unsafe to offer from a window
/// that opened by itself.
struct AgentInstallPlanTests {
    /// The discipline `MCPServerRegistration.withoutInstaller` established. An
    /// agent missing from both sides is one nobody decided about.
    @Test func everyAgentIsEitherInstallableOrDeclined() {
        let installable = Set(AgentInstallPlan.all.map(\.agent))
        let declined = AgentInstallPlan.withoutInstallCommand

        #expect(installable.union(declined) == Set(CodingAgent.allCases))
        #expect(installable.isDisjoint(with: declined))
    }

    /// Antigravity's only documented macOS install is a script piped into a
    /// shell. A welcome panel that opens by itself, on a machine somebody has
    /// just started using, is the last place to normalise that.
    @Test func anAgentInstalledOnlyByAPipedScriptIsNotOffered() {
        #expect(AgentInstallPlan.withoutInstallCommand.contains(.antigravity))
        #expect(AgentInstallPlan.entry(for: .antigravity) == nil)
    }

    /// Whether or not this app can install it, an agent has a page to send
    /// somebody to.
    @Test func everyAgentHasDocumentation() {
        for agent in CodingAgent.allCases {
            #expect(AgentInstallPlan.documentation[agent] != nil, "\(agent.rawValue)")
        }
    }

    @Test func everyEntryOffersAtLeastOneCommand() {
        for entry in AgentInstallPlan.all {
            #expect(!entry.commands.isEmpty, "\(entry.agent.rawValue)")
        }
    }

    /// A command whose first word is not its manager's binary is a command the
    /// availability probe cannot check before running it.
    @Test func everyCommandStartsWithItsManagersBinary() {
        for entry in AgentInstallPlan.all {
            for install in entry.commands {
                #expect(
                    install.command.hasPrefix(install.manager.command + " "),
                    "\(entry.agent.rawValue): \(install.command)")
            }
        }
    }

    /// The shapes this app will not run: a download piped into an interpreter,
    /// a second command hidden behind a separator, and anything asking for a
    /// password it has no way to answer — `runStreaming` gives the child
    /// `/dev/null` on stdin, so a `sudo` prompt would hang rather than ask.
    @Test func noCommandPipesDownloadsOrAsksForAPassword() {
        for entry in AgentInstallPlan.all {
            for install in entry.commands {
                for forbidden in ["curl", "|", "sudo", ";", "&&", "$("] {
                    #expect(
                        !install.command.contains(forbidden),
                        "\(entry.agent.rawValue) contains \(forbidden): \(install.command)")
                }
            }
        }
    }

    /// Each command names the package it installs, so what is being installed
    /// is legible in the card before it runs.
    @Test func eachCommandNamesItsPackage() {
        let packages: [CodingAgent: String] = [
            .claude: "claude-code",
            .codex: "codex",
            .opencode: "opencode",
            .kimi: "kimi-code",
            .pi: "pi-coding-agent",
        ]

        for entry in AgentInstallPlan.all {
            let package = packages[entry.agent]
            #expect(package != nil, "\(entry.agent.rawValue)")
            for install in entry.commands {
                #expect(
                    install.command.contains(package ?? "\u{0}"),
                    "\(entry.agent.rawValue): \(install.command)")
            }
        }
    }

    // MARK: Choosing one

    /// The first command whose manager is on the machine.
    @Test func theOfferedCommandIsOneTheMachineCanRun() {
        let brewOnly = AgentInstallPlan.command(for: .claude, managers: [.homebrew])
        let npmOnly = AgentInstallPlan.command(for: .claude, managers: [.npm])

        #expect(brewOnly?.manager == .homebrew)
        #expect(npmOnly?.manager == .npm)
        #expect(npmOnly?.command == "npm install -g @anthropic-ai/claude-code")
    }

    /// Nothing to offer is a real answer: the card names the managers instead
    /// of running a command whose first word is missing.
    @Test func noManagerMeansNoCommand() {
        #expect(AgentInstallPlan.command(for: .claude, managers: []) == nil)
        #expect(AgentInstallPlan.command(for: .kimi, managers: [.homebrew]) == nil)
    }

    /// An agent this app does not install has no command however much is
    /// installed on the machine.
    @Test func aDeclinedAgentIsNeverOffered() {
        #expect(AgentInstallPlan.command(for: .antigravity, managers: [.homebrew, .npm]) == nil)
    }

    /// Pi's command carries `--ignore-scripts` because its documentation does.
    /// Tidying that away would install the same package a different way from
    /// the way its own docs say to.
    @Test func piKeepsTheFlagItsDocumentationPrints() {
        let command = AgentInstallPlan.command(for: .pi, managers: [.npm])

        #expect(command?.command == "npm install -g --ignore-scripts @earendil-works/pi-coding-agent")
    }
}

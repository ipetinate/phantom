import Foundation
@testable import Ghostty
import Testing

struct AgentRegistryTests {
    private func extensionAgent(id: String) -> AgentDescriptor {
        AgentDescriptor(
            id: id,
            displayName: "Ext \(id)",
            launchCommand: id,
            resume: ResumeCommand(withSession: "\(id) --resume {session}", withoutSession: "\(id) --continue"),
            installation: AgentInstallation(commands: [], documentation: nil),
            icon: .symbol("sparkles"),
            brandColour: .label,
            keepsOriginalColours: false,
            settingsKeyToken: id.capitalized,
            hooks: nil,
            mcp: nil,
            sessions: .none)
    }

    @Test func theSixBuiltInAgentsComeInAFixedOrder() {
        #expect(AgentRegistry.builtIn.map(\.id) == [
            "claude", "codex", "opencode", "antigravity", "kimi", "pi",
        ])
        #expect(AgentRegistry.shared.all.map(\.id) == AgentRegistry.builtIn.map(\.id))
    }

    @Test func everyBuiltInIdIsUnique() {
        let ids = AgentRegistry.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func aDescriptorIsFoundByItsId() {
        #expect(AgentRegistry.shared.descriptor(for: "claude") == AgentRegistry.claude)
        #expect(AgentRegistry.shared.descriptor(for: "agy") == nil)
        #expect(AgentRegistry.shared.descriptor(for: "Claude") == nil)
    }

    @Test func extensionAgentsAreAppendedAfterTheBuiltInOnes() {
        let registry = AgentRegistry(extensionAgents: [extensionAgent(id: "acme.aider")])

        #expect(registry.all.map(\.id).last == "acme.aider")
        #expect(registry.all.count == AgentRegistry.builtIn.count + 1)
        #expect(registry.descriptor(for: "acme.aider")?.displayName == "Ext acme.aider")
    }

    @Test func anExtensionCannotShadowABuiltInAgent() {
        let registry = AgentRegistry(extensionAgents: [extensionAgent(id: "claude")])

        #expect(registry.all.count == AgentRegistry.builtIn.count)
        #expect(registry.descriptor(for: "claude") == AgentRegistry.claude)
    }

    @Test func replacingTheExtensionAgentsDropsTheOldOnes() {
        let registry = AgentRegistry(extensionAgents: [extensionAgent(id: "acme.aider")])
        registry.setExtensionAgents([extensionAgent(id: "acme.goose")])

        #expect(registry.descriptor(for: "acme.aider") == nil)
        #expect(registry.descriptor(for: "acme.goose") != nil)
    }

    @Test func aDuplicateExtensionIdIsRegisteredOnce() {
        let registry = AgentRegistry(
            extensionAgents: [extensionAgent(id: "acme.aider"), extensionAgent(id: "acme.aider")])

        #expect(registry.all.filter { $0.id == "acme.aider" }.count == 1)
    }

    @Test func theResumeCommandFillsTheSessionOrFallsBack() {
        let resume = AgentRegistry.claude.resume

        #expect(resume.command(sessionID: "abc") == "claude --resume abc")
        #expect(resume.command(sessionID: nil) == "claude --continue")
        #expect(resume.command(sessionID: "") == "claude --continue")
    }

    @Test func theCodexAndKimiHomesFollowTheirVariables() {
        #expect(AgentRegistry.codexHome.candidates == ["$CODEX_HOME", "~/.codex-cli", "~/.codex"])
        #expect(AgentRegistry.kimiHome.candidates == ["$KIMI_CODE_HOME", "~/.kimi-code"])
    }

    @Test func onlyOpenCodeKeepsItsOriginalColours() {
        let exceptions = AgentRegistry.builtIn.filter(\.keepsOriginalColours).map(\.id)
        #expect(exceptions == ["opencode"])
    }

    @Test func thePluginBodiesCarryTheirPlaceholders() {
        for body in [AgentRegistry.openCodePlugin, AgentRegistry.piExtension] {
            #expect(body.contains(HooksIntegration.PluginFile.agentPlaceholder))
            #expect(body.contains(HooksIntegration.PluginFile.stateFileVariablePlaceholder))
        }
    }

    @Test func aPlaceholderDescriptorAnswersEveryQuestion() {
        let placeholder = AgentDescriptor.placeholder(id: "acme.aider")

        #expect(placeholder.displayName == "acme.aider")
        #expect(placeholder.launchCommand == "acme.aider")
        #expect(placeholder.resume.command(sessionID: "x") == "acme.aider --resume x")
        #expect(placeholder.resume.command(sessionID: nil) == "acme.aider")
        #expect(placeholder.hooks == nil)
        #expect(placeholder.mcp == nil)
        #expect(placeholder.sessions == SessionDiscovery.none)
    }
}

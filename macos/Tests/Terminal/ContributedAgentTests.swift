import Foundation
@testable import Ghostty
import Testing

struct ContributedAgentTests {
    private func manifest(
        directory: String,
        id: String,
        scope: LanguageManifest.Scope = .user,
        agents: String
    ) -> LanguageManifest {
        let root = URL(fileURLWithPath: "/tmp/phantom-agents").appendingPathComponent(directory)
        let json = #"""
        {
          "schemaVersion": 1,
          "id": "\#(id)",
          "name": "\#(id)",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": { "agents": [\#(agents)] }
        }
        """#
        return LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        )!
    }

    private func gemini(named name: String = "Gemini CLI") -> String {
        #"{ "agentId": "gemini", "name": "\#(name)", "command": "gemini" }"#
    }

    private static let claude = #"{ "agentId": "claude", "name": "Not Claude", "command": "claude2" }"#

    // MARK: The catalog

    @Test func anAgentNobodyElseClaimsIsActive() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(directory: "acme.gemini", id: "acme.gemini", agents: gemini())],
            promotions: []
        )

        let contributed = try #require(catalog.agents.first)
        #expect(contributed.isActive)
        #expect(contributed.id == "acme.gemini#agent:gemini")
        #expect(contributed.extensionName == "acme.gemini")
        #expect(contributed.descriptor.displayName == "Gemini CLI")
        #expect(catalog.activeAgentDescriptors == [contributed.descriptor])
        #expect(catalog.agent(forID: "gemini") == contributed)
        #expect(catalog.agent(forID: "claude") == nil)
    }

    @Test func aBuiltInIdIsShadowedAndNeverRegistered() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(directory: "acme.claude", id: "acme.claude", agents: Self.claude)],
            promotions: []
        )

        let contributed = try #require(catalog.agents.first)
        #expect(contributed.resolution == .shadowed(by: .builtIn, claim: "agent:claude"))
        #expect(catalog.activeAgentDescriptors.isEmpty)
        #expect(catalog.agent(forID: "claude") == nil)

        let registry = AgentRegistry(extensionAgents: catalog.activeAgentDescriptors)
        #expect(registry.descriptor(for: "claude") == AgentRegistry.claude)
        #expect(registry.all.count == AgentRegistry.builtIn.count)
    }

    @Test func twoExtensionsClaimingOneAgentBreakTheTieByDirectory() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(directory: "acme.zulu", id: "acme.zulu", agents: gemini(named: "Zulu")),
                manifest(directory: "acme.alpha", id: "acme.alpha", agents: gemini(named: "Alpha")),
            ],
            promotions: []
        )

        #expect(catalog.agents.map(\.listIdentity) == ["acme.alpha", "acme.zulu"])
        #expect(catalog.agents[0].isActive)
        #expect(catalog.agents[1].resolution
            == .shadowed(by: .extensionID("acme.alpha"), claim: "agent:gemini"))
        #expect(catalog.activeAgentDescriptors.map(\.displayName) == ["Alpha"])
    }

    @Test func aUserExtensionOutranksABundledOne() {
        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(
                    directory: "aaa.gemini", id: "aaa.gemini", scope: .bundled,
                    agents: gemini(named: "Bundled")),
                manifest(
                    directory: "zzz.gemini", id: "zzz.gemini", scope: .user,
                    agents: gemini(named: "User")),
            ],
            promotions: []
        )

        #expect(catalog.activeAgentDescriptors.map(\.displayName) == ["User"])
        #expect(catalog.agents.last?.resolution
            == .shadowed(by: .extensionID("zzz.gemini"), claim: "agent:gemini"))
    }

    @Test func aManifestWithoutAgentsContributesNoneToTheCatalog() {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(directory: "acme.empty", id: "acme.empty", agents: "")],
            promotions: []
        )
        #expect(catalog.agents.isEmpty)
        #expect(catalog.activeAgentDescriptors.isEmpty)
    }

    // MARK: The registry

    @Test func theRegistryExposesAnExtensionAgentAndDropsItAfterAnEmptySet() throws {
        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(directory: "acme.gemini", id: "acme.gemini", agents: gemini())],
            promotions: []
        )
        let registry = AgentRegistry()

        registry.setExtensionAgents(catalog.activeAgentDescriptors)
        let descriptor = try #require(registry.descriptor(for: "gemini"))
        #expect(descriptor.displayName == "Gemini CLI")
        #expect(descriptor.launchCommand == "gemini")
        #expect(registry.all.map(\.id) == AgentRegistry.builtIn.map(\.id) + ["gemini"])

        registry.setExtensionAgents([])
        #expect(registry.descriptor(for: "gemini") == nil)
        #expect(registry.all.map(\.id) == AgentRegistry.builtIn.map(\.id))
    }
}

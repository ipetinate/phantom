import Foundation
@testable import Ghostty
import Testing

struct ExtensionAgentSettingsTests {
    private func extensionAgent(id: String, hooks: HooksIntegration?) -> AgentDescriptor {
        AgentDescriptor(
            id: id,
            displayName: "Ext \(id)",
            launchCommand: id,
            resume: AgentDescriptor.placeholder(id: id).resume,
            installation: AgentInstallation(commands: [], documentation: nil),
            icon: .symbol("sparkles"),
            brandColour: .label,
            keepsOriginalColours: false,
            settingsKeyToken: id,
            hooks: hooks,
            mcp: nil,
            sessions: .none)
    }

    private let plugin = HooksIntegration.PluginFile(
        directory: "~/.gemini",
        subdirectory: "plugins",
        fileName: "phantom.js",
        body: "export default {}",
        events: ["session.start", "session.end"])

    @Test func anExtensionAgentWithATemplateNamesItsFile() {
        #expect(AgentHooksRegistration.installsAnExtensionTemplate(
            extensionAgent(id: "gemini", hooks: .file(plugin))))
    }

    @Test func aBuiltInPluginFileIsNotAnExtensionTemplate() {
        for descriptor in AgentRegistry.builtIn {
            #expect(!AgentHooksRegistration.installsAnExtensionTemplate(descriptor), "\(descriptor.id)")
        }
    }

    @Test func anExtensionAgentWithHooksOrNothingKeepsThePlainRow() {
        let json = HooksIntegration.JSONHooks(
            directory: "~/.gemini",
            fileName: "settings.json",
            key: "hooks",
            entryShape: .grouped,
            ownership: .shared,
            events: [.init("Stop", "done")],
            script: HooksIntegration.ScriptOptions(subdirectory: "", sessionKeys: ["session_id"]))

        #expect(!AgentHooksRegistration.installsAnExtensionTemplate(
            extensionAgent(id: "gemini", hooks: .json(json))))
        #expect(!AgentHooksRegistration.installsAnExtensionTemplate(
            extensionAgent(id: "gemini", hooks: nil)))
    }

    @Test func theFooterNamesTheFileTheExtensionAndTheEvents() {
        let footer = AgentHooksRegistration.templateFooter(
            agentName: "Gemini CLI",
            extensionName: "Gemini for Phantom",
            fileName: "phantom.js",
            events: ["session.start", "session.end"])

        #expect(footer.hasPrefix("phantom.js is a plugin the Gemini for Phantom extension ships"))
        #expect(footer.contains("Phantom writes the file when you press Install and runs none of it; Gemini CLI does."))
        #expect(footer.hasSuffix("It subscribes to session.start, session.end."))
    }

    @Test func theFooterCopesWithoutAnExtensionNameOrEvents() {
        let footer = AgentHooksRegistration.templateFooter(
            agentName: "Gemini CLI", extensionName: nil, fileName: "phantom.js", events: [])

        #expect(footer.contains("a plugin an extension ships"))
        #expect(!footer.contains("subscribes"))
    }
}

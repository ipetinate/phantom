import Foundation
@testable import Ghostty
import Testing

@MainActor
struct GooseAndKiloInstallerTests {
    private let home = URL(fileURLWithPath: "/h", isDirectory: true)

    private func gooseMCP() throws -> YAMLMCPInstaller {
        try #require(YAMLMCPInstaller(
            descriptor: AgentRegistry.goose,
            environment: [:],
            home: home))
    }

    private func gooseHooks() throws -> GooseHooksInstaller {
        try #require(GooseHooksInstaller(
            descriptor: AgentRegistry.goose,
            environment: [:],
            home: home,
            bundleID: PhantomBuild.releaseBundleID))
    }

    private func kiloMCP() throws -> JSONMCPInstaller {
        try #require(JSONMCPInstaller(
            descriptor: AgentRegistry.kilo,
            environment: [:],
            home: home))
    }

    @Test func gooseUsesItsDocumentedConfigAndPluginLocations() throws {
        let mcp = try gooseMCP()
        let hooks = try gooseHooks()

        #expect(mcp.configURL.path == "/h/.config/goose/config.yaml")
        #expect(hooks.manifestURL.path == "/h/.agents/plugins/phantom/.plugin/plugin.json")
        #expect(hooks.hooksURL.path == "/h/.agents/plugins/phantom/hooks/hooks.json")
        #expect(hooks.scriptURL.path == "/h/.agents/plugins/phantom/phantom-tab-state.sh")
    }

    @Test func gooseMCPMergesOnlyItsOwnExtension() throws {
        let mcp = try gooseMCP()
        let block = mcp.block(executable: "/x/Phantom.app/Contents/MacOS/ghostty", arguments: [
            "+mcp-server", "--socket=/tmp/phantom.sock",
        ])
        let existing = """
        active_provider: anthropic
        extensions:
          developer:
            bundled: true
            enabled: true
            name: developer
            type: builtin
        """

        let merged = mcp.merged(block, into: existing)

        #expect(merged.contains("active_provider: anthropic"))
        #expect(merged.contains("developer:"))
        #expect(merged.contains("\(mcp.extensionName):"))
        #expect(merged.components(separatedBy: "\(mcp.extensionName):").count == 2)
        #expect(mcp.isRegistered(in: merged))
    }

    @Test func gooseMCPRegistrationIsIdempotentAndRemovable() throws {
        let mcp = try gooseMCP()
        let block = mcp.block(executable: "/x/ghostty", arguments: ["+mcp-server"])
        let once = mcp.merged(block, into: "extensions:\n  other:\n    enabled: true\n")
        let twice = mcp.merged(block, into: once)

        #expect(twice.components(separatedBy: "  \(MCPServerCommand.name):").count == 2)
        #expect(!mcp.isRegistered(in: mcp.removed(from: twice)))
        #expect(mcp.removed(from: twice).contains("other:"))
    }

    @Test func gooseHooksUseOpenPluginCommandsAndStateScript() throws {
        let hooks = try gooseHooks()

        #expect(hooks.hooksBody.contains("\"SessionStart\""))
        #expect(hooks.hooksBody.contains("\"PreToolUse\""))
        let normalized = hooks.hooksBody.replacingOccurrences(of: "\\/", with: "/")
        #expect(normalized.contains("${PLUGIN_ROOT}/phantom-tab-state.sh --agent goose"))
        #expect(!normalized.contains("'' --agent"))
        #expect(hooks.hooksBody.contains("--session-key session_id"))
        #expect(hooks.isInstalled == false)
        #expect(hooks.isStale == false)
    }

    @Test func kiloUsesGlobalJSONMCPAndPluginLocations() throws {
        let mcp = try kiloMCP()
        let hooks = try #require(PluginFileInstaller(
            descriptor: AgentRegistry.kilo,
            environment: [:],
            home: home,
            bundleID: PhantomBuild.releaseBundleID))

        #expect(mcp.configURL.path == "/h/.config/kilo/kilo.json")
        #expect(mcp.key == "mcp")
        #expect(mcp.entry?["type"] as? String == "local")
        #expect(mcp.entry?["enabled"] as? Bool == true)
        #expect(hooks.fileURL.path == "/h/.config/kilo/plugin/phantom.ts")
        #expect(hooks.body.contains("id: \"phantom\""))
        #expect(hooks.body.contains("session.idle"))
    }
}

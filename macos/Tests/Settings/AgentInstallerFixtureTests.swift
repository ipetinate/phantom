import CryptoKit
import Foundation
@testable import Ghostty
import Testing

/// What the six agents' installers write, pinned as literal documents.
///
/// The installers are about to be replaced by engines driven by the built-in
/// descriptors, and nobody can run the app to see whether an engine wrote what
/// its installer wrote. So the products of today's pure builders are written
/// out here, byte for byte, and the engines have to reproduce them.
@MainActor
struct AgentInstallerFixtureTests {
    private let executable = "/x/Phantom.app/Contents/MacOS/ghostty"
    private let arguments = ["+mcp-server", "--socket=/tmp/phantom.sock"]

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func bytes(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func expectSame(_ produced: [String: Any], _ expected: [String: Any]) throws {
        #expect((produced as NSDictionary) == (expected as NSDictionary))
        #expect(try bytes(produced) == bytes(expected))
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let claudeArguments =
        " --agent claude --session-key session_id --state-from source=compact:compacting"
    static let codexArguments = " --agent codex --session-key session_id --session-key sessionId"
        + " --session-key conversation_id --session-key conversationId --session-key thread_id"

    // MARK: Claude Code

    static let claudeSettingsBefore = #"""
    {"theme":"dark","hooks":{
      "Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]},
              {"hooks":[{"type":"command","command":"'/old/phantom-tab-state.sh' done"}]}],
      "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'/h/ghostty-tab-state.sh' working"}]}]}}
    """#

    static let claudeSettingsAfter = #"""
    {"theme":"dark","hooks":{
      "SessionStart":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PreCompact":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' compacting --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PostCompact":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' working --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' working --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PreToolUse":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' working --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PostToolUse":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' working --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PermissionRequest":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' awaiting --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]},
              {"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' done --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "StopFailure":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' failed --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "PermissionDenied":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' denied --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "Notification":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' notify --agent claude --session-key session_id --state-from source=compact:compacting"}]}],
      "SessionEnd":[{"hooks":[{"type":"command","command":"'/h/.claude/hooks/phantom-tab-state.sh' ended --agent claude --session-key session_id --state-from source=compact:compacting"}]}]}}
    """#

    static let claudeSettingsRemoved = #"""
    {"theme":"dark","hooks":{
      "SessionStart":[],"PreCompact":[],"PostCompact":[],"UserPromptSubmit":[],"PreToolUse":[],
      "PostToolUse":[],"PermissionRequest":[],"Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]}],
      "StopFailure":[],"PermissionDenied":[],"Notification":[],"SessionEnd":[]}}
    """#

    @Test func claudeHooksDocument() throws {
        let produced = ClaudeHooksInstaller.registered(
            into: try json(Self.claudeSettingsBefore),
            scriptPath: "/h/.claude/hooks/phantom-tab-state.sh",
            legacyScriptName: "ghostty-tab-state.sh")

        try expectSame(produced, try json(Self.claudeSettingsAfter))
    }

    @Test func claudeHooksRemoval() throws {
        let produced = ClaudeHooksInstaller.removed(
            from: try json(Self.claudeSettingsAfter),
            scriptName: "phantom-tab-state.sh",
            legacyScriptName: "ghostty-tab-state.sh")

        try expectSame(produced, try json(Self.claudeSettingsRemoved))
    }

    @Test func claudeCommandLines() {
        let path = "/h/.claude/hooks/phantom-tab-state.sh"

        #expect(ClaudeHooksInstaller.command(for: "", scriptPath: path) == "'/h/.claude/hooks/phantom-tab-state.sh' --agent claude --session-key session_id --state-from source=compact:compacting")
        #expect(ClaudeHooksInstaller.command(for: "done", scriptPath: path) == "'/h/.claude/hooks/phantom-tab-state.sh' done --agent claude --session-key session_id --state-from source=compact:compacting")
    }

    @Test func claudeMCPEntry() throws {
        let produced = ClaudeMCPInstaller.entry(executable: executable, arguments: arguments)
        let expected = try json(#"""
        {"type":"stdio","command":"/x/Phantom.app/Contents/MacOS/ghostty","args":["+mcp-server","--socket=/tmp/phantom.sock"]}
        """#)

        try expectSame(produced, expected)
    }

    // MARK: Codex

    static let codexHooksBefore = #"""
    {"model":"gpt-5","hooks":{
      "Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]},
              {"hooks":[{"type":"command","command":"'/old/phantom-tab-state.sh' done"}]}]}}
    """#

    static let codexHooksAfter = #"""
    {"model":"gpt-5","hooks":{
      "SessionStart":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' working --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "PreToolUse":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' working --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "PostToolUse":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' working --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "PermissionRequest":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' awaiting --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]},
              {"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' done --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}],
      "SessionEnd":[{"hooks":[{"type":"command","command":"'/h/.codex/phantom-tab-state.sh' ended --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id"}]}]}}
    """#

    static let codexHooksRemoved = #"""
    {"model":"gpt-5","hooks":{
      "SessionStart":[],"UserPromptSubmit":[],"PreToolUse":[],"PostToolUse":[],"PermissionRequest":[],
      "Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]}],"SessionEnd":[]}}
    """#

    @Test func codexHooksDocument() throws {
        let produced = CodexHooksInstaller.registered(
            into: try json(Self.codexHooksBefore),
            scriptPath: "/h/.codex/phantom-tab-state.sh")

        try expectSame(produced, try json(Self.codexHooksAfter))
    }

    @Test func codexHooksRemoval() throws {
        let produced = CodexHooksInstaller.removed(
            from: try json(Self.codexHooksAfter), scriptName: "phantom-tab-state.sh")

        try expectSame(produced, try json(Self.codexHooksRemoved))
    }

    @Test func codexCommandLines() {
        let path = "/h/.codex/phantom-tab-state.sh"

        #expect(CodexHooksInstaller.command(for: "", scriptPath: path) == "'/h/.codex/phantom-tab-state.sh' --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id")
        #expect(CodexHooksInstaller.command(for: "working", scriptPath: path) == "'/h/.codex/phantom-tab-state.sh' working --agent codex --session-key session_id --session-key sessionId --session-key conversation_id --session-key conversationId --session-key thread_id")
    }

    static let codexMCPTable = """
    [mcp_servers.phantom]
    command = "/x/Phantom.app/Contents/MacOS/ghostty"
    args = ["+mcp-server", "--socket=/tmp/phantom.sock"]
    """

    @Test func codexMCPBlock() {
        let produced = CodexMCPInstaller.block(
            executable: executable, arguments: arguments, name: "phantom")

        #expect(produced == Self.codexMCPTable)
    }

    // MARK: OpenCode

    @Test func openCodeMCPEntry() throws {
        let produced = OpenCodeMCPInstaller.entry(executable: executable, arguments: arguments)
        let expected = try json(#"""
        {"type":"local","command":["/x/Phantom.app/Contents/MacOS/ghostty","+mcp-server","--socket=/tmp/phantom.sock"],"enabled":true}
        """#)

        try expectSame(produced, expected)
    }

    @Test func openCodePluginBody() {
        #expect(sha256(OpenCodeHooksInstaller.pluginBody)
            == "3309039ceb21cd890bc87e9e53230702258a2cba20d456653eb2e010042dfe98")
        #expect(OpenCodeHooksInstaller.pluginBody == Self.filled(AgentRegistry.openCodePlugin, agent: "opencode"))
    }

    // MARK: Antigravity

    static let antigravityRegistration = #"""
    {"PreInvocation":[{"type":"command","command":"'/h/.gemini/config/phantom-tab-state.sh' working --agent antigravity --session-key conversationId --session-key conversation_id --session-key sessionId --session-key session_id --reply '{}'"}],
     "Stop":[{"type":"command","command":"'/h/.gemini/config/phantom-tab-state.sh' done --agent antigravity --session-key conversationId --session-key conversation_id --session-key sessionId --session-key session_id --reply '{\"decision\":\"stop\"}'"}]}
    """#

    @Test func antigravityHooksRegistration() throws {
        let produced = AntigravityHooksInstaller.registration(
            scriptPath: "/h/.gemini/config/phantom-tab-state.sh")

        try expectSame(produced, try json(Self.antigravityRegistration))
    }

    @Test func antigravityMCPEntry() throws {
        let produced = AntigravityMCPInstaller.entry(executable: executable, arguments: arguments)
        let expected = try json(#"""
        {"command":"/x/Phantom.app/Contents/MacOS/ghostty","args":["+mcp-server","--socket=/tmp/phantom.sock"]}
        """#)

        try expectSame(produced, expected)
    }

    // MARK: Kimi Code

    static let kimiReaderConfig = """
    # my own settings, hand written
    model = "kimi-k2"

    [[hooks]]
    event = "PreToolUse"
    command = "~/bin/my-own-audit.sh"

    [permissions]
    mode = "ask"
    """

    static let kimiBlock = """
    # Phantom: reports this tab's agent state to the sidebar.
    # Managed by Phantom. Edit the app's Settings rather than these blocks.

    [[hooks]]
    event = "SessionStart"
    command = "'/h/.kimi-code/phantom-tab-state.sh' --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "UserPromptSubmit"
    command = "'/h/.kimi-code/phantom-tab-state.sh' working --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "PreToolUse"
    command = "'/h/.kimi-code/phantom-tab-state.sh' working --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "PostToolUse"
    command = "'/h/.kimi-code/phantom-tab-state.sh' working --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "PermissionRequest"
    command = "'/h/.kimi-code/phantom-tab-state.sh' awaiting --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "Stop"
    command = "'/h/.kimi-code/phantom-tab-state.sh' done --agent kimi --session-key session_id"
    timeout = 5

    [[hooks]]
    event = "SessionEnd"
    command = "'/h/.kimi-code/phantom-tab-state.sh' ended --agent kimi --session-key session_id"
    timeout = 5
    """

    @Test func kimiHooksBlock() {
        #expect(KimiHooksInstaller.block(scriptPath: "/h/.kimi-code/phantom-tab-state.sh") == Self.kimiBlock)
    }

    @Test func kimiHooksDocument() {
        let produced = KimiHooksInstaller.installed(
            into: Self.kimiReaderConfig, scriptPath: "/h/.kimi-code/phantom-tab-state.sh")

        #expect(produced == Self.kimiReaderConfig + "\n\n" + Self.kimiBlock + "\n")
        #expect(KimiHooksInstaller.removed(from: produced)
            .trimmingCharacters(in: .whitespacesAndNewlines) == Self.kimiReaderConfig)
    }

    @Test func kimiMCPEntry() throws {
        let produced = KimiMCPInstaller.entry(executable: executable, arguments: arguments)
        let expected = try json(#"""
        {"command":"/x/Phantom.app/Contents/MacOS/ghostty","args":["+mcp-server","--socket=/tmp/phantom.sock"]}
        """#)

        try expectSame(produced, expected)
    }

    // MARK: Pi

    @Test func piExtensionBody() {
        #expect(sha256(PiHooksInstaller.source)
            == "6498f2e0b4e931cb7fe6121bb7d06b58047a377f63aaf086e6c31fdcd3918454")
        #expect(PiHooksInstaller.source == Self.filled(AgentRegistry.piExtension, agent: "pi"))
    }

    @Test func piMCPEntry() throws {
        let produced = PiMCPInstaller.entry(executable: executable, arguments: arguments)
        let expected = try json(#"""
        {"command":"/x/Phantom.app/Contents/MacOS/ghostty","args":["+mcp-server","--socket=/tmp/phantom.sock"]}
        """#)

        try expectSame(produced, expected)
    }

    // MARK: The shell scripts

    @Test func everyShellHookIsTheOneSharedScript() {
        #expect(ClaudeHooksInstaller.scriptBody == TabStateScript.body)
        #expect(CodexHooksInstaller.scriptBody == TabStateScript.body)
        #expect(AntigravityHooksInstaller.scriptBody == TabStateScript.body)
        #expect(KimiHooksInstaller.scriptBody == TabStateScript.body)
        #expect(TabStateScript.body.hasPrefix("#!/bin/bash\n"))
    }

    private static func filled(_ template: String, agent: String) -> String {
        template
            .replacingOccurrences(of: HooksIntegration.PluginFile.agentPlaceholder, with: agent)
            .replacingOccurrences(
                of: HooksIntegration.PluginFile.stateFileVariablePlaceholder,
                with: "GHOSTTY_TAB_STATE_FILE")
    }
}

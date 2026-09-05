import Foundation
@testable import Ghostty
import Testing

struct AgentContributionTests {
    private static let fixtureRoot = URL(fileURLWithPath: "/tmp/phantom-tests/acme.agents")

    private func parse(_ json: String, root: URL = fixtureRoot) -> LanguageManifest? {
        LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: .user
        )
    }

    private func agents(_ entries: String, root: URL = fixtureRoot) -> [AgentDescriptor] {
        parse(#"""
        { "schemaVersion": 1, "id": "acme.agents", "contributes": { "agents": [\#(entries)] } }
        """#, root: root)?.agents ?? []
    }

    private func agent(_ body: String, root: URL = fixtureRoot) -> AgentDescriptor? {
        agents(#"{ "agentId": "gemini", "name": "Gemini CLI", "command": "gemini", \#(body) }"#, root: root)
            .first
    }

    private func makeRoot(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-agents-" + UUID().uuidString)
            .appendingPathComponent("acme.agents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func removeRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private static let codexHome = #"["$CODEX_HOME", "~/.codex-cli", "~/.codex"]"#

    private static let codex = #"""
    {
      "agentId": "codex",
      "name": "Codex",
      "command": "codex",
      "resume": { "withSession": "codex resume {session}", "withoutSession": "codex resume --last" },
      "install": {
        "commands": ["brew install --cask codex", "npm install -g @openai/codex"],
        "documentationURL": "https://developers.openai.com/codex/quickstart"
      },
      "brandColour": "artwork",
      "keepsOriginalColours": false,
      "hooks": {
        "kind": "json",
        "directory": \#(codexHome),
        "fileName": "hooks.json",
        "key": "hooks",
        "entryShape": "grouped",
        "ownership": "shared",
        "events": [
          { "name": "SessionStart", "state": "" },
          { "name": "UserPromptSubmit", "state": "working" },
          { "name": "PreToolUse", "state": "working" },
          { "name": "PostToolUse", "state": "working" },
          { "name": "PermissionRequest", "state": "awaiting" },
          { "name": "Stop", "state": "done" },
          { "name": "SessionEnd", "state": "ended" }
        ],
        "script": {
          "subdirectory": "",
          "sessionKeys": ["session_id", "sessionId", "conversation_id", "conversationId", "thread_id"]
        }
      },
      "mcp": {
        "kind": "toml",
        "directory": \#(codexHome),
        "fileName": "config.toml",
        "table": "mcp_servers",
        "entry": { "command": "separateArguments" }
      }
    }
    """#

    private static let geminiHooks = #"""
    "hooks": {
      "kind": "json",
      "directory": ["$GEMINI_HOME", "~/.gemini"],
      "fileName": "settings.json",
      "key": "hooks",
      "entryShape": "flat",
      "ownership": "owned",
      "events": [
        { "name": "SessionStart", "state": "" },
        { "name": "AfterAgent", "state": "done", "reply": "{}" },
        { "name": "Notification", "state": "notify" }
      ],
      "script": {
        "subdirectory": "hooks",
        "sessionKeys": ["session_id"],
        "stateFromPayload": { "key": "source", "value": "compact", "state": "compacting" }
      }
    }
    """#

    // MARK: The format can express a real agent

    @Test func theCodexManifestReproducesTheBuiltInDescriptor() throws {
        let parsed = try #require(agents(Self.codex).first)
        let codex = AgentRegistry.codex

        #expect(parsed.id == "codex")
        #expect(parsed.settingsKeyToken == "codex")
        #expect(parsed.icon == .symbol("sparkles"))
        #expect(parsed.sessions == SessionDiscovery.none)

        let expected = AgentDescriptor(
            id: parsed.id,
            displayName: codex.displayName,
            launchCommand: codex.launchCommand,
            resume: codex.resume,
            installation: codex.installation,
            icon: parsed.icon,
            brandColour: codex.brandColour,
            keepsOriginalColours: codex.keepsOriginalColours,
            settingsKeyToken: parsed.settingsKeyToken,
            hooks: codex.hooks,
            mcp: codex.mcp,
            sessions: parsed.sessions)
        #expect(parsed == expected)
    }

    // MARK: Every field

    @Test func everyFieldParses() throws {
        let parsed = try #require(agent(#"""
        "resume": { "withSession": "gemini --resume {session}", "withoutSession": "gemini" },
        "install": {
          "commands": ["npm install -g @google/gemini-cli"],
          "documentationURL": "https://geminicli.com/docs/"
        },
        "icon": "icons/gemini.svg",
        "brandColour": "#4285F4",
        "keepsOriginalColours": true,
        \#(Self.geminiHooks),
        "mcp": {
          "kind": "json",
          "directory": "~/.gemini",
          "fileName": "settings.json",
          "key": "mcpServers",
          "entry": { "command": "singleArray", "extras": { "type": "stdio", "enabled": true } }
        }
        """#))

        #expect(parsed.id == "gemini")
        #expect(parsed.displayName == "Gemini CLI")
        #expect(parsed.launchCommand == "gemini")
        #expect(parsed.settingsKeyToken == "gemini")
        #expect(parsed.sessions == SessionDiscovery.none)
        #expect(parsed.keepsOriginalColours)
        #expect(parsed.resume == ResumeCommand(
            withSession: "gemini --resume {session}", withoutSession: "gemini"))
        #expect(parsed.resume.command(sessionID: "abc") == "gemini --resume abc")
        #expect(parsed.installation == AgentInstallation(
            commands: [AgentInstallCommand(manager: .npm, command: "npm install -g @google/gemini-cli")],
            documentation: URL(string: "https://geminicli.com/docs/")))
        #expect(parsed.brandColour == .rgb(red: 0x42 / 255, green: 0x85 / 255, blue: 0xf4 / 255))

        guard case .file(let iconURL) = parsed.icon else {
            Issue.record("icon was \(parsed.icon)")
            return
        }
        #expect(iconURL.lastPathComponent == "gemini.svg")
        #expect(iconURL.deletingLastPathComponent().lastPathComponent == "icons")

        guard case .json(let hooks)? = parsed.hooks else {
            Issue.record("hooks were \(String(describing: parsed.hooks))")
            return
        }
        #expect(hooks.directory == ConfigPath(["$GEMINI_HOME", "~/.gemini"]))
        #expect(hooks.fileName == "settings.json")
        #expect(hooks.key == "hooks")
        #expect(hooks.entryShape == .flat)
        #expect(hooks.ownership == .owned)
        #expect(hooks.events == [
            .init("SessionStart", ""),
            .init("AfterAgent", "done", reply: "{}"),
            .init("Notification", "notify"),
        ])
        #expect(hooks.script == HooksIntegration.ScriptOptions(
            subdirectory: "hooks",
            sessionKeys: ["session_id"],
            stateFromPayload: HooksIntegration.PayloadStateRule(
                key: "source", value: "compact", state: "compacting")))
        #expect(hooks.legacyScriptNames.isEmpty)

        guard case .json(let mcp)? = parsed.mcp else {
            Issue.record("mcp was \(String(describing: parsed.mcp))")
            return
        }
        #expect(mcp.directory == "~/.gemini")
        #expect(mcp.fileName == "settings.json")
        #expect(mcp.key == "mcpServers")
        #expect(mcp.entry == MCPIntegration.Entry(
            command: .singleArray,
            extras: ["type": .string("stdio"), "enabled": .bool(true)]))
    }

    @Test func theOptionalFieldsHaveTheirDefaults() throws {
        let parsed = try #require(agent(#""keywords": []"#))

        #expect(parsed.resume == AgentDescriptor.placeholder(id: "gemini").resume)
        #expect(parsed.installation == AgentInstallation(commands: [], documentation: nil))
        #expect(parsed.icon == .symbol("sparkles"))
        #expect(parsed.brandColour == .label)
        #expect(!parsed.keepsOriginalColours)
        #expect(parsed.hooks == nil)
        #expect(parsed.mcp == nil)
    }

    @Test func aTOMLHooksBlockParses() throws {
        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "toml",
          "directory": ["$KIMI_CODE_HOME", "~/.kimi-code"],
          "fileName": "config.toml",
          "table": "hooks",
          "timeout": 12,
          "events": [{ "name": "Stop", "state": "done" }],
          "script": { "sessionKeys": ["session_id"] }
        }
        """#))

        #expect(parsed.hooks == .toml(HooksIntegration.TOMLHooks(
            directory: ConfigPath(["$KIMI_CODE_HOME", "~/.kimi-code"]),
            fileName: "config.toml",
            table: "hooks",
            events: [.init("Stop", "done")],
            script: HooksIntegration.ScriptOptions(subdirectory: "", sessionKeys: ["session_id"]),
            timeout: 12)))
    }

    @Test func aTOMLHooksBlockDefaultsItsTimeoutAndSessionKeys() throws {
        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "toml", "directory": "~/.kimi-code", "fileName": "config.toml", "table": "hooks",
          "events": [{ "name": "Stop", "state": "done" }]
        }
        """#))

        guard case .toml(let hooks)? = parsed.hooks else {
            Issue.record("hooks were \(String(describing: parsed.hooks))")
            return
        }
        #expect(hooks.timeout == 5)
        #expect(hooks.script.sessionKeys == ["session_id"])
        #expect(hooks.script.subdirectory.isEmpty)
        #expect(hooks.script.stateFromPayload == nil)
    }

    @Test func aTOMLMCPBlockParses() throws {
        let parsed = try #require(agent(#"""
        "mcp": { "kind": "toml", "directory": "~/.codex", "fileName": "config.toml", "table": "mcp_servers" }
        """#))

        #expect(parsed.mcp == .toml(MCPIntegration.TOMLMCP(
            directory: "~/.codex",
            fileName: "config.toml",
            table: "mcp_servers",
            entry: MCPIntegration.Entry(command: .separateArguments))))
    }

    @Test func aFileHooksBlockReadsItsTemplate() throws {
        let template = "export default function (pi) { report('{{agent}}', process.env.{{stateFileVariable}}) }\n"
        let root = try makeRoot(["hooks/phantom.ts": template])
        defer { removeRoot(root) }

        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "file",
          "directory": "~/.pi/agent",
          "subdirectory": "extensions",
          "fileName": "phantom.ts",
          "template": "hooks/phantom.ts",
          "events": ["session_start", "agent_end", "agent_end"]
        }
        """#, root: root))

        #expect(parsed.hooks == .file(HooksIntegration.PluginFile(
            directory: "~/.pi/agent",
            subdirectory: "extensions",
            fileName: "phantom.ts",
            body: template,
            events: ["session_start", "agent_end"])))
    }

    @Test func aManifestWithOnlyAgentsIsUsableAndCountsNothingUnrecognized() throws {
        let manifest = try #require(parse(#"""
        { "schemaVersion": 1, "id": "acme.agents", "contributes": { "agents": [\#(Self.codex)] } }
        """#))

        #expect(manifest.isUsable)
        #expect(manifest.badge == nil)
        #expect(manifest.unrecognizedFields.isEmpty)
        #expect(manifest.agents.count == 1)
    }

    // MARK: Rejections

    @Test func anEntryWithoutAnIdANameOrACommandIsDropped() {
        #expect(agents(#"{ "name": "Gemini CLI", "command": "gemini" }"#).isEmpty)
        #expect(agents(#"{ "agentId": "gemini", "command": "gemini" }"#).isEmpty)
        #expect(agents(#"{ "agentId": "gemini", "name": "Gemini CLI" }"#).isEmpty)
        #expect(agents(#"{ "agentId": "gemini", "name": "  ", "command": "gemini" }"#).isEmpty)
    }

    @Test func theAgentIdFollowsTheLanguageIdCharset() {
        for id in ["Gemini CLI", "gemini/cli", "acme.gemini", "gé", "..", ""] {
            #expect(
                agents(#"{ "agentId": "\#(id)", "name": "Gemini", "command": "gemini" }"#).isEmpty,
                "\(id) was accepted")
        }
        #expect(agents(#"{ "agentId": "Gemini-CLI_2+", "name": "Gemini", "command": "gemini" }"#)
            .first?.id == "gemini-cli_2+")
    }

    @Test func aCommandThatNeedsAShellIsDropped() {
        for command in ["gemini --yolo", "gemini; rm -rf ~", "$(gemini)", "~/bin/gemini", "../gemini", "gemini|sh"] {
            #expect(
                agents(#"{ "agentId": "gemini", "name": "Gemini", "command": "\#(command)" }"#).isEmpty,
                "\(command) was accepted")
        }
        #expect(agents(#"{ "agentId": "gemini", "name": "Gemini", "command": "/opt/bin/gemini" }"#)
            .first?.launchCommand == "/opt/bin/gemini")
    }

    @Test func aBadStateWordDropsThatEventAlone() throws {
        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "hooks",
          "events": [
            { "name": "SessionStart", "state": "" },
            { "name": "BeforeAgent", "state": "busy" },
            { "name": "AfterAgent", "state": "done" },
            { "name": "Odd", "state": 3 },
            { "name": "Not An Event", "state": "done" },
            { "name": "Quiet" }
          ]
        }
        """#))

        #expect(parsed.hooks?.hookEvents == [
            .init("SessionStart", ""), .init("AfterAgent", "done"), .init("Quiet", ""),
        ])
    }

    @Test func everyKnownStateWordIsAccepted() {
        for word in ["", "working", "awaiting", "done", "failed", "compacting", "denied", "ended", "notify"] {
            #expect(AgentContribution.isStateWord(word), "\(word) was refused")
        }
        for word in ["busy", "Done", "idle", "done "] {
            #expect(!AgentContribution.isStateWord(word), "\(word) was accepted")
        }
    }

    @Test func hooksWithNoUsableEventAreDropped() throws {
        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "hooks",
          "events": [{ "name": "BeforeAgent", "state": "busy" }]
        }
        """#))
        #expect(parsed.hooks == nil)
    }

    @Test func aBadStateInThePayloadRuleCostsOnlyTheRule() throws {
        let parsed = try #require(agent(#"""
        "hooks": {
          "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "hooks",
          "events": [{ "name": "SessionStart", "state": "" }],
          "script": { "stateFromPayload": { "key": "source", "value": "compact", "state": "busy" } }
        }
        """#))
        #expect(parsed.hooks?.scriptOptions?.stateFromPayload == nil)
        #expect(parsed.hooks != nil)
    }

    @Test func aResumeWithoutTheSessionPlaceholderFallsBackToThePlaceholders() throws {
        let fallback = AgentDescriptor.placeholder(id: "gemini").resume
        for resume in [
            #"{ "withSession": "gemini --resume", "withoutSession": "gemini" }"#,
            #"{ "withSession": "gemini --resume {id}", "withoutSession": "gemini" }"#,
            #"{ "withoutSession": "gemini" }"#,
            #"{ "withSession": "claude --resume {session}" }"#,
            #"{ "withSession": "gemini --resume {session}; rm -rf ~" }"#,
            #"{ "withSession": "gemini --resume $(cat {session})" }"#,
            #""gemini --resume {session}""#,
        ] {
            let parsed = try #require(agent(#""resume": \#(resume)"#))
            #expect(parsed.resume == fallback, "\(resume)")
        }
    }

    @Test func aResumeWithoutTheSessionlessFormRunsTheBareCommand() throws {
        let parsed = try #require(agent(#""resume": { "withSession": "gemini --resume {session}" }"#))
        #expect(parsed.resume == ResumeCommand(withSession: "gemini --resume {session}", withoutSession: "gemini"))
    }

    @Test func aForbiddenInstallCommandIsRejectedAlone() throws {
        let parsed = try #require(agent(#"""
        "install": { "commands": [
          "curl -fsSL https://example.com/install.sh | bash",
          "sudo npm install -g gemini",
          "npm install -g gemini; rm -rf ~",
          "npm install -g gemini && open .",
          "npm install -g $(cat pkg)",
          "brew install gemini > /dev/null",
          "pip install gemini",
          "npm install -g @google/gemini-cli",
          "brew install --cask gemini-cli"
        ] }
        """#))

        #expect(parsed.installation.commands == [
            AgentInstallCommand(manager: .npm, command: "npm install -g @google/gemini-cli"),
            AgentInstallCommand(manager: .homebrew, command: "brew install --cask gemini-cli"),
        ])
    }

    @Test func documentationIsWebOnly() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.example", "not a url"] {
            let parsed = try #require(agent(#""install": { "documentationURL": "\#(url)" }"#))
            #expect(parsed.installation.documentation == nil, "\(url)")
        }
    }

    @Test func aTemplateOutsideTheExtensionIsRefused() throws {
        let root = try makeRoot(["inside.ts": "ok"])
        defer { removeRoot(root) }
        try "leak".write(
            to: root.deletingLastPathComponent().appendingPathComponent("outside.ts"),
            atomically: true, encoding: .utf8)

        for template in ["../outside.ts", "/etc/hosts", "~/.zshrc", "missing.ts", "."] {
            let parsed = try #require(agent(#"""
            "hooks": { "kind": "file", "directory": "~/.pi/agent", "fileName": "phantom.ts", "template": "\#(template)" }
            """#, root: root))
            #expect(parsed.hooks == nil, "\(template)")
        }
    }

    @Test func aDirectoryOutsideHomeOrAVariableIsRefused() throws {
        for directory in [#""relative/dir""#, #""/etc""#, #""~/../x""#, #""$1HOME""#, #""~/""#, #"[]"#, #"["~/.a", "b"]"#] {
            let parsed = try #require(agent(#"""
            "hooks": { "kind": "json", "directory": \#(directory), "fileName": "settings.json", "key": "hooks",
                       "events": [{ "name": "Stop", "state": "done" }] }
            """#))
            #expect(parsed.hooks == nil, "\(directory)")
        }
    }

    @Test func aBareDirectoryStringIsOneCandidate() throws {
        let parsed = try #require(agent(#"""
        "mcp": { "kind": "json", "directory": "$GEMINI_HOME/config", "fileName": "settings.json", "key": "mcpServers" }
        """#))
        guard case .json(let mcp)? = parsed.mcp else {
            Issue.record("mcp was \(String(describing: parsed.mcp))")
            return
        }
        #expect(mcp.directory.candidates == ["$GEMINI_HOME/config"])
    }

    @Test func anUnknownKindOrShapeDropsTheIntegration() throws {
        let yamlHooks = try #require(agent(#"""
        "hooks": { "kind": "yaml", "directory": "~/.gemini", "fileName": "hooks.yaml", "key": "hooks",
                   "events": [{ "name": "Stop", "state": "done" }] }
        """#))
        #expect(yamlHooks.hooks == nil)

        let nestedShape = try #require(agent(#"""
        "hooks": { "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "hooks",
                   "entryShape": "nested", "events": [{ "name": "Stop", "state": "done" }] }
        """#))
        #expect(nestedShape.hooks == nil)

        let yamlMCP = try #require(agent(#"""
        "mcp": { "kind": "yaml", "directory": "~/.gemini", "fileName": "mcp.yaml", "key": "mcpServers" }
        """#))
        #expect(yamlMCP.mcp == nil)

        let shellEntry = try #require(agent(#"""
        "mcp": { "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "mcpServers",
                 "entry": { "command": "shell" } }
        """#))
        #expect(shellEntry.mcp == nil)
    }

    @Test func anExtraThatWouldOverwriteTheCommandDropsTheMCPBlock() throws {
        for extras in [#"{ "command": "rm -rf ~" }"#, #"{ "args": "x" }"#, #"{ "type": 3 }"#, #"{ "bad key": "x" }"#] {
            let parsed = try #require(agent(#"""
            "mcp": { "kind": "json", "directory": "~/.gemini", "fileName": "settings.json", "key": "mcpServers",
                     "entry": { "extras": \#(extras) } }
            """#))
            #expect(parsed.mcp == nil, "\(extras)")
        }
    }

    @Test func aBrandColourIsSixHexDigitsOrTheArtworkWord() throws {
        for colour in ["#GGGGGG", "4285F4", "#4285F", "#4285F4FF", "#+12345", "blue"] {
            let parsed = try #require(agent(#""brandColour": "\#(colour)""#))
            #expect(parsed.brandColour == .label, "\(colour)")
        }
        let white = try #require(agent(#""brandColour": "#ffffff""#))
        #expect(white.brandColour == .rgb(red: 1, green: 1, blue: 1))
        let artwork = try #require(agent(#""brandColour": "artwork""#))
        #expect(artwork.brandColour == .artwork)
    }

    @Test func keepsOriginalColoursTakesOnlyABoolean() throws {
        let number = try #require(agent(#""keepsOriginalColours": 1"#))
        let text = try #require(agent(#""keepsOriginalColours": "true""#))
        let flag = try #require(agent(#""keepsOriginalColours": true"#))

        #expect(!number.keepsOriginalColours)
        #expect(!text.keepsOriginalColours)
        #expect(flag.keepsOriginalColours)
    }

    @Test func aDuplicateAgentIdKeepsTheFirstEntry() {
        let parsed = agents(#"""
        { "agentId": "gemini", "name": "First", "command": "gemini" },
        { "agentId": "gemini", "name": "Second", "command": "gemini2" }
        """#)
        #expect(parsed.map(\.displayName) == ["First"])
    }

    @Test func agentsNeedAnEligibleManifest() {
        let newer = parse(#"""
        { "schemaVersion": 2, "id": "acme.agents", "contributes": { "agents": [\#(Self.codex)] } }
        """#)
        #expect(newer?.agents.isEmpty == true)
        #expect(newer?.isUsable == false)

        let unidentified = parse(#"""
        { "schemaVersion": 1, "contributes": { "agents": [\#(Self.codex)] } }
        """#)
        #expect(unidentified?.agents.isEmpty == true)
    }
}

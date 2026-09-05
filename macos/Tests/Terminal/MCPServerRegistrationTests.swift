import Foundation
import Testing

@testable import Ghostty

/// Writing Phantom's MCP entry into four configuration files that belong to
/// somebody else.
///
/// The failure these guard against is not "the entry is missing". It is "the
/// reader's file came back smaller than it went in" — a lost sign-in session, a
/// dropped model setting, a comment gone — and every one of those is silent
/// until the agent next fails to start. So each agent gets a fixture holding
/// things Phantom has no business touching, and the assertion is that they are
/// all still there afterwards.
///
/// As in `CodexHooksInstallerTests` and `AntigravityHooksInstallerTests`, the
/// disk half of `register()` and `remove()` is not exercised: both resolve
/// their own path from the reader's home, so running them would mean writing
/// into the developer's real `~/.claude.json`. What is exercised is everything
/// those two functions do between reading and writing, which is where the
/// damage would be.
@MainActor
struct MCPServerRegistrationTests {
    private let claude = JSONMCPInstaller(descriptor: AgentRegistry.claude)
    private let opencode = JSONMCPInstaller(descriptor: AgentRegistry.opencode)
    private let antigravity = JSONMCPInstaller(descriptor: AgentRegistry.antigravity)
    private let codex = TOMLMCPInstaller(descriptor: AgentRegistry.codex)

    // MARK: - Harness

    private func json(_ text: String) throws -> [String: Any] {
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-mcp-\(UUID().uuidString).json")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// A stand-in for `~/.claude.json`: mostly things Phantom must not touch,
    /// including one MCP server that is not Phantom's.
    private func claudeConfig() throws -> [String: Any] {
        try json("""
        {"oauthAccount":{"emailAddress":"someone@example.com"},\
        "machineID":"e2f9","numStartups":412,\
        "projects":{"/Users/someone/work":{"hasTrustDialogAccepted":true}},\
        "mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}
        """)
    }

    // MARK: - The shared merge

    @Test func mergingKeepsEveryOtherTopLevelKey() throws {
        let before = try claudeConfig()
        let after = MCPConfigFile.merged(
            ["command": "/x/ghostty"], named: "phantom", under: "mcpServers", into: before)

        #expect(after["oauthAccount"] != nil)
        #expect(after["machineID"] as? String == "e2f9")
        #expect(after["numStartups"] as? Int == 412)
        #expect(after["projects"] != nil)
        #expect(MCPConfigFile.preserves(before, in: after))
    }

    /// The one an agent-shaped mistake would break: a merge that replaced the
    /// map instead of adding to it would take the reader's other servers with
    /// it, and nothing about the loss names Phantom.
    @Test func mergingKeepsEveryOtherServer() throws {
        let before = try claudeConfig()
        let after = MCPConfigFile.merged(
            ["command": "/x/ghostty"], named: "phantom", under: "mcpServers", into: before)
        let servers = try #require(after["mcpServers"] as? [String: Any])

        #expect(servers["context7"] != nil)
        #expect(servers["phantom"] != nil)
        #expect(servers.count == 2)
    }

    @Test func mergingIntoAFileWithNoServersAtAllCreatesTheMap() {
        let after = MCPConfigFile.merged(
            ["command": "/x/ghostty"], named: "phantom", under: "mcpServers", into: [:])
        let servers = after["mcpServers"] as? [String: Any]

        #expect(servers?.count == 1)
        #expect(servers?["phantom"] != nil)
    }

    @Test func removingTakesOnlyPhantom() throws {
        let before = try claudeConfig()
        let merged = MCPConfigFile.merged(
            ["command": "/x/ghostty"], named: "phantom", under: "mcpServers", into: before)
        let after = MCPConfigFile.removed(
            named: "phantom", under: "mcpServers", from: merged)
        let servers = try #require(after["mcpServers"] as? [String: Any])

        #expect(servers["phantom"] == nil)
        #expect(servers["context7"] != nil)
        #expect(MCPConfigFile.preserves(before, in: after))
    }

    /// The map stays even once it is empty. Removing it would be a second
    /// change the reader did not ask for, and an agent cannot tell an absent
    /// key from an empty one.
    @Test func removingTheLastServerLeavesTheMap() {
        let one = MCPConfigFile.merged(
            ["command": "/x/ghostty"], named: "phantom", under: "mcpServers", into: [:])
        let after = MCPConfigFile.removed(named: "phantom", under: "mcpServers", from: one)

        #expect(after["mcpServers"] is [String: Any])
        #expect((after["mcpServers"] as? [String: Any])?.isEmpty == true)
    }

    @Test func anEntryMatchesOnlyWhenItIsTheSameEntry() {
        let entry: [String: Any] = ["command": "/x/ghostty", "args": ["+mcp-server"]]
        let config = MCPConfigFile.merged(
            entry, named: "phantom", under: "mcpServers", into: [:])

        let same = MCPConfigFile.matches(
            entry, named: "phantom", under: "mcpServers", in: config)
        let moved = MCPConfigFile.matches(
            ["command": "/elsewhere/ghostty", "args": ["+mcp-server"]],
            named: "phantom", under: "mcpServers", in: config)

        #expect(same)
        #expect(!moved)
    }

    @Test func preservationNoticesALostKey() {
        let before: [String: Any] = ["a": 1, "b": 2]
        #expect(!MCPConfigFile.preserves(before, in: ["a": 1]))
        #expect(!MCPConfigFile.preserves(before, in: nil))
        #expect(MCPConfigFile.preserves(before, in: ["a": 1, "b": 2, "c": 3]))
    }

    // MARK: - Telling "nothing here" from "something I don't understand"

    @Test func anAbsentFileReadsAsAnEmptyConfiguration() throws {
        let read = MCPConfigFile.read(at: try temporaryFile(nil))

        #expect(read != nil)
        #expect(read?.isEmpty == true)
    }

    @Test func anEmptyFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile("")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MCPConfigFile.read(at: url)?.isEmpty == true)
    }

    /// The one that matters. `~/.claude.json` holds the reader's sign-in
    /// session; a parse failure that read as "empty" would replace all of it
    /// with one MCP entry, atomically, while reporting success.
    @Test func malformedJSONRefusesToBeRead() throws {
        let url = try temporaryFile(#"{"mcpServers": {"phantom": }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MCPConfigFile.read(at: url) == nil)
    }

    /// OpenCode accepts JSONC and `JSONSerialization` does not, so a reader
    /// with a comment in `opencode.json` is refused rather than rewritten. That
    /// is the right way round: a merge that dropped their comments would be a
    /// change they never asked for.
    @Test func aFileWithCommentsRefusesToBeRead() throws {
        let url = try temporaryFile("{\n  // my settings\n  \"model\": \"x\"\n}")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MCPConfigFile.read(at: url) == nil)
    }

    @Test func aTopLevelArrayRefusesToBeRead() throws {
        let url = try temporaryFile(#"[{"mcpServers":{}}]"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MCPConfigFile.read(at: url) == nil)
    }

    // MARK: - Claude Code

    /// Not `~/.claude/settings.json`, which is where the hooks go. User-scope
    /// MCP servers live at the top level of `~/.claude.json`, a different file
    /// in a different directory, and putting them in the hooks file would
    /// register nothing.
    @Test func claudeWritesToItsOwnConfigurationRatherThanItsSettings() throws {
        let claude = try #require(self.claude)
        let path = claude.configURL.path

        #expect(path.hasSuffix("/.claude.json"))
        #expect(!path.contains("/.claude/"))
        #expect(claude.key == "mcpServers")
    }

    @Test func claudeTakesACommandAndASeparateArgumentList() throws {
        let claude = try #require(self.claude)
        let entry = try #require(claude.entry)

        #expect(entry["command"] is String)
        #expect(entry["args"] as? [String] == MCPServerCommand.arguments)
        #expect(entry["type"] as? String == "stdio")
    }

    @Test func claudeReadsItsOwnEntryBack() throws {
        let claude = try #require(self.claude)
        let entry = try #require(claude.entry)
        let before = try claudeConfig()
        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: claude.key, into: before)

        #expect(claude.isRegistered(in: after))
        #expect(!claude.isStale(in: after))
        #expect(!claude.isRegistered(in: before))
    }

    /// The bundle moves — a reader drags Phantom out of `~/Downloads` — and
    /// every entry then names a path that does not resolve. Nothing the agent
    /// reports about that failure names Phantom, so the app has to notice it
    /// itself.
    @Test func claudeCallsAMovedBundleStale() throws {
        let stale: [String: Any] = [
            "type": "stdio",
            "command": "/Volumes/somebody-elses-disk/Phantom.app/Contents/MacOS/ghostty",
            "args": [MCPServerCommand.action],
        ]
        let claude = try #require(self.claude)
        let config = MCPConfigFile.merged(
            stale, named: MCPServerCommand.name, under: claude.key, into: [:])

        #expect(claude.isRegistered(in: config))
        #expect(claude.isStale(in: config))
    }

    /// Nothing registered is not stale. Otherwise the launch-time repair would
    /// install itself into the configuration of an agent the reader never
    /// mentioned.
    @Test func anAbsentEntryIsNotStale() throws {
        #expect(try #require(self.claude).isStale(in: [:]) == false)
        #expect(try #require(self.claude).isStale(in: nil) == false)
        #expect(try #require(self.opencode).isStale(in: [:]) == false)
        #expect(try #require(self.antigravity).isStale(in: [:]) == false)
        #expect(try #require(self.codex).isStale(in: "") == false)
    }

    // MARK: - OpenCode

    /// The one entry that would have been wrong if it had been guessed by
    /// analogy with the other three. OpenCode's key is `mcp`, its local server
    /// needs `type: "local"`, and the executable and its arguments go in one
    /// `command` array — the schema sets `additionalProperties: false`, so an
    /// `args` or an `env` here fails validation outright rather than being
    /// ignored.
    @Test func openCodeTakesOneCommandArrayAndNoArgumentList() throws {
        let opencode = try #require(self.opencode)
        let entry = try #require(opencode.entry)

        #expect(opencode.key == "mcp")
        #expect(entry["type"] as? String == "local")
        #expect(entry["args"] == nil)
        #expect(entry["env"] == nil)
        #expect(entry["enabled"] as? Bool == true)

        let command = try #require(entry["command"] as? [String])
        #expect(command.count == MCPServerCommand.arguments.count + 1)
        #expect(Array(command.dropFirst()) == MCPServerCommand.arguments)
    }

    @Test func openCodeMergesBesideTheReadersOtherSettings() throws {
        let opencode = try #require(self.opencode)
        let entry = try #require(opencode.entry)
        let before = try json("""
        {"$schema":"https://opencode.ai/config.json","model":"anthropic/claude",\
        "mcp":{"weather":{"type":"local","command":["weather-cli"]}}}
        """)
        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: opencode.key, into: before)
        let servers = try #require(after["mcp"] as? [String: Any])

        #expect(after["model"] as? String == "anthropic/claude")
        #expect(after["$schema"] != nil)
        #expect(servers["weather"] != nil)
        #expect(opencode.isRegistered(in: after))
    }

    @Test func openCodeWritesBesideItsPlugin() throws {
        let opencode = try #require(self.opencode)
        let plugin = try #require(PluginFileInstaller(descriptor: AgentRegistry.opencode))

        #expect(opencode.configURL.path.hasSuffix("/opencode/opencode.json"))
        #expect(opencode.configURL.deletingLastPathComponent() == plugin.directory)
    }

    // MARK: - Antigravity

    /// Beside the hooks, not in them: `hooks.json` and `mcp_config.json` are
    /// two files in `~/.gemini/config`, and the directory comes from the hooks
    /// installer so the two cannot drift into different Antigravity homes.
    @Test func antigravityWritesBesideItsHooks() throws {
        let antigravity = try #require(self.antigravity)
        let hooks = try #require(JSONHooksInstaller(descriptor: AgentRegistry.antigravity))

        #expect(antigravity.configURL.lastPathComponent == "mcp_config.json")
        #expect(antigravity.configURL.deletingLastPathComponent() == hooks.directory)
        #expect(antigravity.configURL.path.hasSuffix("/.gemini/config/mcp_config.json"))
    }

    /// A `command` string and a separate `args` array, and no discriminator:
    /// the transport is chosen by which of `command` and `serverUrl` is
    /// present, so a `type` here would be a field the schema does not define.
    @Test func antigravityTakesACommandAndArgumentsWithNoDiscriminator() throws {
        let antigravity = try #require(self.antigravity)
        let entry = try #require(antigravity.entry)

        #expect(antigravity.key == "mcpServers")
        #expect(entry["command"] is String)
        #expect(entry["args"] as? [String] == MCPServerCommand.arguments)
        #expect(entry["type"] == nil)
        #expect(entry["serverUrl"] == nil)
    }

    /// The file is MCP's alone, but Antigravity's own MCP store and its `/mcp`
    /// command write servers into it, so it is merged rather than replaced.
    @Test func antigravityKeepsServersItDidNotWrite() throws {
        let antigravity = try #require(self.antigravity)
        let entry = try #require(antigravity.entry)
        let before = try json("""
        {"mcpServers":{"sqlite-explorer":{"command":"node",\
        "args":["/usr/local/bin/sqlite-mcp-server.js"]}}}
        """)
        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: antigravity.key, into: before)
        let servers = try #require(after["mcpServers"] as? [String: Any])

        #expect(servers["sqlite-explorer"] != nil)
        #expect(servers.count == 2)
        #expect(antigravity.isRegistered(in: after))
    }

    // MARK: - The four together

    /// Every agent the app knows is accounted for — either it has an
    /// installer or it is on the list of ones that deliberately do not.
    ///
    /// The invariant is coverage, not equality. Equality was the old spelling
    /// and it broke the moment an agent arrived whose MCP configuration
    /// surface is not documented; the useful guarantee is that nobody can add
    /// an agent and leave the question unanswered, which this still enforces.
    @Test func everyAgentIsOffered() {
        let listed = Set(MCPServerRegistration.agents.map(\.id))

        #expect(listed.union(MCPServerRegistration.withoutInstaller)
            == Set(CodingAgent.allCases))
    }

    /// An agent cannot be both offered and excused. Without this, adding one
    /// to the excused set while it still has an installer would pass the test
    /// above and quietly misdescribe what the app does.
    @Test func noAgentIsBothOfferedAndExcused() {
        let listed = Set(MCPServerRegistration.agents.map(\.id))

        #expect(listed.isDisjoint(with: MCPServerRegistration.withoutInstaller))
    }

    @Test func everyAgentIsNamedTheWayTheHooksPaneNamesIt() {
        for agent in MCPServerRegistration.agents {
            #expect(agent.name == agent.id.displayName)
        }
    }

    /// One name across all four installers, and the same word the handshake
    /// answers with — so a reader chasing a server in their agent's output
    /// finds it spelled identically in the listing and in `initialize`.
    ///
    /// No longer the bare `MCPService.serverName`, which is the *base* of it:
    /// the entry carries the build variant so two installed builds cannot
    /// overwrite each other's registration. The invariant that matters is that
    /// the two places agree, and that is what is asserted.
    @Test func theServerIsCalledTheSameThingEverywhere() {
        #expect(MCPServerCommand.name.hasPrefix(MCPService.serverName))
        #expect(MCPServerCommand.action == "+mcp-server")
        #expect(MCPServerCommand.arguments.first == "+mcp-server")
    }

    /// The command is this bundle's own binary, resolved at run time. A path
    /// written down here would name `/Applications` and be wrong for everybody
    /// running a build out of a worktree.
    @Test func theCommandIsThisBundlesOwnBinary() throws {
        let path = try #require(MCPServerCommand.executablePath)
        #expect(path == Bundle.main.executableURL?.path)
        #expect(!path.isEmpty)
    }

    /// A path with a space in it is the common case, not the exotic one, and
    /// every agent here is handed the program and its arguments apart — so a
    /// bundle in a folder with a space in its name never reaches a shell as two
    /// words.
    @Test func noEntryFoldsTheArgumentsIntoTheCommand() throws {
        let claude = try #require(self.claude?.entry)
        let antigravity = try #require(self.antigravity?.entry)
        let openCode = try #require(self.opencode?.entry)

        #expect(claude["command"] as? String == MCPServerCommand.executablePath)
        #expect(antigravity["command"] as? String == MCPServerCommand.executablePath)
        #expect((openCode["command"] as? [String])?.first == MCPServerCommand.executablePath)
    }
}

/// Codex, whose configuration is TOML and is therefore merged as text.
///
/// Everything here is about what survives the round trip. The file holds the
/// reader's model, their approval policy and their own comments, and a
/// parse-and-reserialize would have lost the comments even when it lost nothing
/// else — which is why this edits lines rather than a document.
@MainActor
struct TOMLMCPInstallerTests {
    private let codex = TOMLMCPInstaller(descriptor: AgentRegistry.codex)
    private let kimi = JSONMCPInstaller(descriptor: AgentRegistry.kimi)
    private let pi = JSONMCPInstaller(descriptor: AgentRegistry.pi)

    private let existing = """
    model = "gpt-5"
    approval_policy = "on-request"

    # My own server, please leave it alone.
    [mcp_servers.context7]
    command = "npx"
    args = ["-y", "@upstash/context7-mcp"]

    [mcp_servers.context7.env]
    LOCAL_TOKEN = "abc"
    """

    // MARK: - Where and what

    @Test func codexWritesBesideItsHooks() throws {
        let codex = try #require(self.codex)
        let hooks = try #require(JSONHooksInstaller(descriptor: AgentRegistry.codex))

        #expect(codex.configURL.lastPathComponent == "config.toml")
        #expect(codex.configURL.deletingLastPathComponent() == hooks.directory)
        #expect(codex.configURL.deletingLastPathComponent() == AgentRegistry.codexHome.resolve())
    }

    /// snake_case. `mcpServers` is the other three agents' spelling and would
    /// register nothing here.
    /// Snake case, and the entry's own name — which carries the build
    /// variant, so this cannot be written as a literal without pinning one
    /// build's spelling and failing in the other.
    @Test func theTableIsSnakeCase() throws {
        let codex = try #require(self.codex)

        #expect(codex.table == "mcp_servers.\(MCPServerCommand.name)")
        #expect(codex.table.hasPrefix("mcp_servers."))
    }

    /// The arguments come from `MCPServerCommand` rather than being written
    /// out here, and that is the point rather than convenience: they carry the
    /// socket path, which carries the build. Spelled as a literal, this test
    /// pinned one build's entry and failed in the other — and it failed only
    /// in a full run, because the drift is invisible to the class on its own.
    @Test func theBlockIsACommandAndAnArgumentList() throws {
        let block = try #require(self.codex).block(executable: "/x/Phantom.app/Contents/MacOS/ghostty")
        let args = MCPServerCommand.arguments
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        #expect(block == """
        [mcp_servers.\(MCPServerCommand.name)]
        command = "/x/Phantom.app/Contents/MacOS/ghostty"
        args = [\(args)]
        """)

        /// The two facts the spelling above would otherwise hide: the action
        /// comes first, and the socket is named rather than left to whatever
        /// the environment happens to say.
        #expect(MCPServerCommand.arguments.first == "+mcp-server")
        #expect(MCPServerCommand.arguments.contains { $0.hasPrefix("--socket=") })
    }

    /// A basic TOML string takes exactly two characters badly, and a reader's
    /// path can hold either.
    @Test func aPathWithQuotesInItIsEscaped() throws {
        let block = try #require(self.codex).block(executable: #"/x/a"b\c/ghostty"#)
        #expect(block.contains(#"command = "/x/a\"b\\c/ghostty""#))
    }

    // MARK: - Reading the file as lines

    @Test func aTableHeaderIsRecognisedThroughItsWhitespace() {
        #expect(TOMLMCPInstaller.header(of: "[mcp_servers.phantom]") == "mcp_servers.phantom")
        #expect(TOMLMCPInstaller.header(of: "  [ mcp_servers.phantom ] ") == "mcp_servers.phantom")
        #expect(TOMLMCPInstaller.header(of: "command = \"x\"") == nil)
        #expect(TOMLMCPInstaller.header(of: "# [mcp_servers.phantom]") == nil)
    }

    /// An array of tables is not a table. Treating `[[…]]` as a header would
    /// let the removal below swallow entries that are not Phantom's.
    @Test func anArrayOfTablesIsNotAHeader() {
        #expect(TOMLMCPInstaller.header(of: "[[profiles]]") == nil)
    }

    @Test func aQuotedKeyIsStillTheSameKey() throws {
        let codex = try #require(self.codex)
        let name = MCPServerCommand.name

        #expect(codex.isPhantom("mcp_servers.\(name)"))
        #expect(codex.isPhantom("mcp_servers.\"\(name)\""))
        #expect(codex.isPhantom("mcp_servers.\(name).env"))
        #expect(!codex.isPhantom("mcp_servers.context7"))
        #expect(!codex.isPhantom("mcp_servers"))
        #expect(!codex.isPhantom("hooks.\(name)"))
    }

    // MARK: - Merging

    @Test func mergingKeepsEveryOtherTableAndEveryComment() throws {
        let codex = try #require(self.codex)
        let block = codex.block(executable: "/x/ghostty")
        let after = try #require(codex.merged(block, into: existing))

        #expect(after.contains("model = \"gpt-5\""))
        #expect(after.contains("approval_policy = \"on-request\""))
        #expect(after.contains("# My own server, please leave it alone."))
        #expect(after.contains("[mcp_servers.context7]"))
        #expect(after.contains("[mcp_servers.context7.env]"))
        #expect(after.contains("LOCAL_TOKEN = \"abc\""))
        #expect(after.contains(block))
    }

    @Test func mergingIntoAnEmptyFileWritesOnlyTheBlock() throws {
        let codex = try #require(self.codex)
        let block = codex.block(executable: "/x/ghostty")
        let after = try #require(codex.merged(block, into: ""))

        #expect(after == block + "\n")
    }

    /// Registering twice must not leave two tables: TOML rejects a key defined
    /// twice, so the second registration would be the one that stopped Codex
    /// from starting.
    @Test func registeringTwiceLeavesOneTable() throws {
        let codex = try #require(self.codex)
        let block = codex.block(executable: "/x/ghostty")
        let once = try #require(codex.merged(block, into: existing))
        let twice = try #require(codex.merged(block, into: once))
        let header = "[mcp_servers.\(MCPServerCommand.name)]"
        let headers = twice.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces) == header }

        #expect(headers.count == 1)
    }

    /// Phantom's own sub-tables go with it. A leftover `[mcp_servers.phantom.env]`
    /// under no `[mcp_servers.phantom]` is a table with no parent, which Codex
    /// would accept and nothing would ever clean up.
    @Test func rewritingCarriesPhantomsSubTablesAway() throws {
        let codex = try #require(self.codex)
        /// Built from the entry's own name rather than written as a literal:
        /// the name carries the build variant, so a fixture spelling one
        /// build's table describes a table this build would never find.
        let name = MCPServerCommand.name
        let old = existing + """


        [mcp_servers.\(name)]
        command = "/old/ghostty"
        args = ["+mcp-server"]

        [mcp_servers.\(name).env]
        LEFTOVER = "1"
        """
        let block = codex.block(executable: "/new/ghostty")
        let after = try #require(codex.merged(block, into: old))

        #expect(!after.contains("LEFTOVER"))
        #expect(!after.contains("/old/ghostty"))
        #expect(after.contains("/new/ghostty"))
        #expect(after.contains("[mcp_servers.context7.env]"))
    }

    @Test func removingTakesOnlyPhantom() throws {
        let codex = try #require(self.codex)
        let block = codex.block(executable: "/x/ghostty")
        let merged = try #require(codex.merged(block, into: existing))
        let after = codex.removed(from: merged)

        #expect(!after.contains("[mcp_servers.phantom]"))
        #expect(after.contains("[mcp_servers.context7]"))
        #expect(after.contains("model = \"gpt-5\""))
        #expect(!codex.isRegistered(in: after))
    }

    // MARK: - Refusing rather than corrupting

    /// The whole reason this can be text. A file that already declares
    /// `mcp_servers` as a bare table would have Phantom's `[mcp_servers.phantom]`
    /// appended under it, defining the same key twice — and TOML's answer to a
    /// duplicate key is to reject the entire file, so Codex would stop starting
    /// rather than merely ignore the entry.
    @Test func aBareServersTableIsRefusedRatherThanMergedInto() throws {
        let codex = try #require(self.codex)
        let file = """
        [mcp_servers]
        phantom = { command = "/somewhere/else" }
        """
        let block = codex.block(executable: "/x/ghostty")

        #expect(codex.hasUnownableTable(in: file))
        #expect(codex.merged(block, into: file) == nil)
    }

    @Test func aTopLevelAssignmentIsRefused() throws {
        let codex = try #require(self.codex)
        let file = #"mcp_servers = { phantom = { command = "/x" } }"#
        let block = codex.block(executable: "/x/ghostty")

        #expect(codex.hasUnownableTable(in: file))
        #expect(codex.merged(block, into: file) == nil)
    }

    /// A key of the same name inside somebody else's table is
    /// `that_table.mcp_servers` and collides with nothing, so refusing there
    /// would refuse a file that is perfectly fine.
    @Test func aSimilarKeyInsideAnotherTableIsNotACollision() throws {
        let codex = try #require(self.codex)
        let file = """
        [profiles.work]
        mcp_servers = ["a"]
        """
        #expect(!codex.hasUnownableTable(in: file))
    }

    @Test func theDocumentedShapeIsNotACollision() throws {
        let codex = try #require(self.codex)
        #expect(!codex.hasUnownableTable(in: existing))
    }

    // MARK: - Staleness

    @Test func aMovedBundleIsStale() throws {
        let codex = try #require(self.codex)
        let old = try #require(
            codex.merged(
                codex.block(executable: "/Volumes/gone/ghostty"), into: existing))

        #expect(codex.isRegistered(in: old))
        #expect(codex.isStale(in: old))
    }

    @Test func thisBuildsOwnEntryIsNotStale() throws {
        let codex = try #require(self.codex)
        let block = try #require(codex.block)
        let current = try #require(codex.merged(block, into: existing))

        #expect(codex.isRegistered(in: current))
        #expect(!codex.isStale(in: current))
    }

    @Test func aFileWithNoPhantomTableIsNotRegistered() throws {
        let codex = try #require(self.codex)
        #expect(!codex.isRegistered(in: existing))
        #expect(codex.phantomBlock(in: existing) == nil)
    }

    // MARK: - Disk

    @Test func anAbsentFileReadsAsEmptyText() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-codex-\(UUID().uuidString).toml")
        #expect(TOMLMCPInstaller.read(at: url) == "")
    }

    // MARK: One entry name per build

    /// The release build keeps the plain name, which is what the reader sees
    /// in their agent's own output.
    @Test func theReleaseBuildIsCalledPhantom() {
        #expect(MCPServerCommand.name(forBundleID: "com.ipetinate.phantom") == "phantom")
    }

    /// The bug this exists for. Two builds have different bundle ids and so
    /// different sockets, but they used to write one shared entry name into one
    /// shared configuration, each pointing at its own bundle — so whichever
    /// launched last repaired it to itself and the agent quietly followed the
    /// wrong build. It never looks like a fault: the server connects, answers,
    /// and lists tools for another set of windows.
    @Test func aDebugBuildDoesNotTakeTheReleaseBuildsName() {
        let release = MCPServerCommand.name(forBundleID: "com.ipetinate.phantom")
        let debug = MCPServerCommand.name(forBundleID: "com.ipetinate.phantom.debug")

        #expect(debug == "phantom-debug")
        #expect(debug != release)
    }

    /// Any variant, not a list of the two that exist today.
    @Test func anyBundleVariantGetsItsOwnName() {
        #expect(MCPServerCommand.name(forBundleID: "com.ipetinate.phantom.beta")
            == "phantom-beta")
        #expect(MCPServerCommand.name(forBundleID: "com.ipetinate.phantom.Debug")
            == "phantom-debug")
    }

    /// A bundle with no id at all still gets a usable name rather than a
    /// trailing dash.
    @Test func anEmptyBundleIDFallsBackToThePlainName() {
        #expect(MCPServerCommand.name(forBundleID: "") == "phantom")
    }

    // MARK: One socket per build, named in the entry

    /// The other half of the same bug, and the half the name alone could not
    /// fix. The client resolves the socket from `PHANTOM_MCP_SOCKET`, which
    /// every Phantom exports into the terminals it opens — so an agent started
    /// from a release terminal reached the release app even when the entry it
    /// was running named the debug build's own executable. Measured: a debug
    /// build under test was opening files in the reader's working app.
    @Test func theEntryNamesTheSocketRatherThanTrustingTheEnvironment() {
        let arguments = MCPServerCommand.arguments

        #expect(arguments.first == MCPServerCommand.action)
        #expect(arguments.contains("--socket=\(MCPSocketPath.current.path)"))
    }

    /// One argument, not two. Every agent takes the program and its arguments
    /// apart, so a `--socket path` pair would arrive as a flag with no value
    /// wherever the array is passed through verbatim.
    @Test func theSocketTravelsAsOneArgument() {
        let socket = MCPServerCommand.arguments.filter { $0.hasPrefix("--socket") }

        #expect(socket.count == 1)
        #expect(socket.first?.contains("=") == true)
    }

    /// The two builds name two different sockets, which is what makes the
    /// entry's name true rather than decorative.
    @Test func theTwoBuildsNameDifferentSockets() {
        let home = URL(fileURLWithPath: "/Users/reader")
        let release = MCPSocketPath.url(bundleID: "com.ipetinate.phantom", home: home)
        let debug = MCPSocketPath.url(bundleID: "com.ipetinate.phantom.debug", home: home)

        #expect(release != debug)
        #expect(debug.lastPathComponent == "com.ipetinate.phantom.debug.sock")
    }

    // MARK: Kimi and Pi

    /// Kimi's file is the same shape as Claude Code's and holds nothing else,
    /// which is the whole reason its installer is the shortest here: no login
    /// session, no model setting, no permission mode in the blast radius.
    @Test func kimiTakesACommandAndArgumentsInItsOwnFile() throws {
        let kimi = try #require(self.kimi)
        let entry = try #require(kimi.entry)

        #expect(entry["command"] as? String == MCPServerCommand.executablePath)
        #expect(entry["args"] as? [String] == MCPServerCommand.arguments)
        #expect(kimi.configURL.path.hasSuffix("/mcp.json"))
        #expect(kimi.key == "mcpServers")
    }

    /// Not in `config.toml`. Kimi documents MCP as living in its own file, and
    /// writing the TOML instead would put an entry where nothing reads it while
    /// risking the settings that *are* in there.
    @Test func kimiDoesNotWriteTheTomlConfig() throws {
        #expect(try #require(self.kimi).configURL.path.hasSuffix("config.toml") == false)
    }

    /// `type` is omitted on purpose: Kimi documents an entry with a `command`
    /// as being stdio, so a key its documentation never mentions is a key it
    /// might reject.
    @Test func kimiWritesNoTypeKey() throws {
        let kimi = try #require(self.kimi)
        let entry = try #require(kimi.entry)

        #expect(entry["type"] == nil)
    }

    @Test func piWritesWhereItsExtensionReads() throws {
        let pi = try #require(self.pi)
        let entry = try #require(pi.entry)

        #expect(entry["command"] as? String == MCPServerCommand.executablePath)
        #expect(pi.configURL.path.hasSuffix("/.pi/agent/mcp.json"))
        #expect(pi.key == "mcpServers")
    }

    /// The registry's own note has to say Pi is conditional, because a reader
    /// who registers it and sees nothing appear would otherwise have no way to
    /// find out why.
    @Test func theFooterSaysPiNeedsAnExtension() {
        #expect(MCPServerRegistration.footer.contains("Pi has no MCP client of its own"))
    }

    /// Both entries name this bundle rather than a written-down path, which is
    /// what makes them repairable when the app moves.
    @Test func bothPointAtThisCopyOfPhantom() throws {
        let path = try #require(MCPServerCommand.executablePath)

        #expect(try #require(self.kimi).entry?["command"] as? String == path)
        #expect(try #require(self.pi).entry?["command"] as? String == path)
    }
}

import Foundation

/// Registers Phantom's MCP server with Antigravity.
///
/// **The file is not the one the hooks go in.** `AntigravityHooksInstaller`
/// writes `hooks.json` in `~/.gemini/config`; the MCP servers live beside it in
/// the same directory, in `mcp_config.json`. Antigravity's own MCP page names
/// it twice, once for the CLI — "Global server setups: Configured in
/// `~/.gemini/config/mcp_config.json`" — and once for the IDE, which reads the
/// same path. The workspace half of the pair, `.agents/mcp_config.json`, is
/// left alone for the reason the hooks installer leaves the workspace hooks
/// alone: it belongs to a repository and would follow it into version control.
/// <https://antigravity.google/docs/mcp/>
///
/// **The directory comes from the hooks installer.** One resolver for one
/// agent's home, for the reason `CodexHooksInstaller.codexDir` gives: two of
/// them is one too many, and the failure when they drift — writing into a home
/// the agent never reads — has no symptom to chase.
///
/// **There is a legacy path this deliberately does not chase.** An issue on the
/// CLI's tracker reports an older `agy` reading
/// `~/.gemini/antigravity-cli/mcp_config.json`, and says in the same breath
/// that the post-migration path is the documented one above. A bug report is
/// not documentation, and writing both would leave the reader with two entries
/// and no way to tell which their `agy` uses, so this writes the documented
/// path only.
///
/// Unlike Claude Code's, this file is MCP's alone — but it is still merged
/// rather than replaced, because Antigravity's own MCP store and its `/mcp`
/// command write servers into it.
@MainActor
enum AntigravityMCPInstaller {
    static let key = "mcpServers"

    static var configURL: URL {
        AntigravityHooksInstaller.configDir.appendingPathComponent("mcp_config.json")
    }

    /// A `command` string with a separate `args` array — the same shape Claude
    /// Code takes, and arrived at from a different page.
    ///
    /// No `type`, and none is accepted: the transport is chosen by which of
    /// `command` and `serverUrl` is present. The page also warns that the older
    /// `url` and `httpUrl` fields are gone, which is worth knowing only because
    /// it says how much this schema has moved.
    static var entry: [String: Any]? {
        MCPServerCommand.executablePath.map {
            entry(executable: $0, arguments: MCPServerCommand.arguments)
        }
    }

    static func entry(executable: String, arguments: [String]) -> [String: Any] {
        [
            "command": executable,
            "args": arguments,
        ]
    }

    static private(set) var lastError: String?

    // MARK: Reading

    static func isRegistered(in config: [String: Any]?) -> Bool {
        MCPConfigFile.entry(named: MCPServerCommand.name, under: key, in: config) != nil
    }

    static func isStale(in config: [String: Any]?) -> Bool {
        guard isRegistered(in: config), let entry else { return false }
        return !MCPConfigFile.matches(entry, named: MCPServerCommand.name, under: key, in: config)
    }

    static var isRegistered: Bool { isRegistered(in: MCPConfigFile.read(at: configURL)) }

    // MARK: Writing

    @discardableResult
    static func register() -> Bool {
        guard let entry else { return fail("Phantom could not find its own executable") }
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("mcp_config.json is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: key, into: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing mcp_config.json")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard MCPConfigFile.preserves(before, in: reread) else {
            return fail("mcp_config.json lost keys it had before the write")
        }
        guard isRegistered(in: reread) else {
            return fail("mcp_config.json was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("mcp_config.json is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.removed(
            named: MCPServerCommand.name, under: key, from: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing mcp_config.json")
        }

        guard !isRegistered(in: MCPConfigFile.read(at: configURL)) else {
            return fail("mcp_config.json was written but the server is still registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func repairIfStale() -> Bool {
        let config = MCPConfigFile.read(at: configURL)
        guard isRegistered(in: config), isStale(in: config) else { return false }
        return register()
    }

    private static func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }
}

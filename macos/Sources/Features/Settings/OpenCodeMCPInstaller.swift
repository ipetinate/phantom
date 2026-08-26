import Foundation

/// Registers Phantom's MCP server with OpenCode.
///
/// **The entry is a different shape from the other three, and the schema
/// refuses the ones it is not.** OpenCode's servers live under a top-level
/// `mcp` — not `mcpServers` — and a local one takes `type: "local"` plus a
/// `command` **array** holding the executable and its arguments together. There
/// is no `args` field, and the environment field is spelled `environment`
/// rather than `env`. The published schema sets `additionalProperties: false`
/// on that object, so an entry carrying `args` fails validation outright rather
/// than being ignored — which makes this the one agent where guessing by
/// analogy with the others would have produced a file the reader has to repair.
/// <https://opencode.ai/docs/mcp-servers/> for the example, and
/// <https://opencode.ai/config.json> (`$defs.McpLocalConfig`) for the schema
/// that decides it.
///
/// **The directory comes from the hooks installer**, so the plugin and the
/// server entry cannot end up in two different OpenCode homes.
///
/// **A file with comments in it is left alone.** OpenCode accepts JSONC —
/// comments and trailing commas — and `JSONSerialization` does not. A reader
/// whose `opencode.json` carries a comment therefore gets a refusal here rather
/// than a rewrite, which is the right way round: a merge that dropped their
/// comments would be a change they never asked for and cannot undo.
@MainActor
enum OpenCodeMCPInstaller {
    static let key = "mcp"

    /// `~/.config/opencode/opencode.json`. `OPENCODE_CONFIG` can move it, and
    /// this deliberately does not read that variable: the app is launched from
    /// the Dock and inherits none of the reader's shell environment, so
    /// honouring it here would work in a terminal-launched build and silently
    /// not in the one they use. `CodexHooksInstaller.codexDir` reads
    /// `CODEX_HOME` and has the same exposure; naming the limit is better than
    /// pretending either is covered.
    static var configURL: URL {
        OpenCodeHooksInstaller.configDir.appendingPathComponent("opencode.json")
    }

    /// One local server. `command` carries the executable and the action in one
    /// array, because that is the only place OpenCode takes arguments.
    ///
    /// `enabled` is written rather than left out. It defaults to true, so it
    /// buys nothing on a fresh install — but a reader who turned this server
    /// off by hand and then pressed Register would otherwise get a registration
    /// that reports as installed and does nothing.
    static var entry: [String: Any]? {
        guard let path = MCPServerCommand.executablePath else { return nil }
        return [
            "type": "local",
            "command": [path] + MCPServerCommand.arguments,
            "enabled": true,
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
            return fail("opencode.json is unreadable, or has comments in it")
        }

        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: key, into: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing opencode.json")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard MCPConfigFile.preserves(before, in: reread) else {
            return fail("opencode.json lost keys it had before the write")
        }
        guard isRegistered(in: reread) else {
            return fail("opencode.json was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("opencode.json is unreadable, or has comments in it")
        }

        let after = MCPConfigFile.removed(
            named: MCPServerCommand.name, under: key, from: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing opencode.json")
        }

        guard !isRegistered(in: MCPConfigFile.read(at: configURL)) else {
            return fail("opencode.json was written but the server is still registered")
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

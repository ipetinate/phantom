import Foundation

/// Registers Phantom's MCP server with Claude Code, at user scope.
///
/// **Not `~/.claude/settings.json`.** That is where `ClaudeHooksInstaller`
/// writes, and it is the wrong file for this: user-scope MCP servers live at
/// the top level of `~/.claude.json`, a different file in a different
/// directory. Claude Code's own documentation is explicit — "User-scoped
/// servers are stored in `~/.claude.json`", and the scope table there gives
/// `.mcp.json` in a repository for project scope and the same `~/.claude.json`
/// for local scope, nested under `projects`. User scope is the top-level
/// `mcpServers` and nothing else.
/// <https://code.claude.com/docs/en/mcp>
///
/// **This file is the most dangerous one Phantom writes.** It is not a
/// settings file with a few keys in it. Claude Code's settings documentation
/// describes it as holding "your sign-in session, MCP server configurations,
/// per-project state such as trust decisions, and the global config keys that
/// `/config` writes for you", and on the machine this was written on it was
/// around a hundred kilobytes across seventy top-level keys. A write that
/// dropped one of them could sign the reader out. So every path here refuses
/// rather than guesses: an unparseable file is left alone, and a successful
/// write is read back and checked for the keys that went in.
/// <https://code.claude.com/docs/en/settings>
///
/// **Claude Code writes this file too, while it is running.** It rewrites it
/// when its own state changes, so a read-modify-write here can lose whatever
/// landed in between — the same race `ClaudeHooksInstaller.install` documents
/// for `settings.json`, which is why that one re-reads rather than trusting
/// its own write. The read-back below is the same defence and has the same
/// limit: it catches the loss, it cannot prevent it.
@MainActor
enum ClaudeMCPInstaller {
    /// The top-level key. User scope, deliberately: a project-scope entry would
    /// have to be written once per repository and would follow the repository
    /// into version control, where the path to somebody's Phantom is noise at
    /// best.
    static let key = "mcpServers"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    /// One stdio server, as Claude Code spells it: a `command` string and a
    /// separate `args` array.
    ///
    /// `type` is written even though it is optional — Claude Code reads an
    /// entry with no `type` as stdio anyway — because `claude mcp add-json`
    /// emits it and a file where Phantom's entry is the only one missing it
    /// reads like an entry somebody hand-wrote wrong.
    static var entry: [String: Any]? {
        MCPServerCommand.executablePath.map {
            entry(executable: $0, arguments: MCPServerCommand.arguments)
        }
    }

    static func entry(executable: String, arguments: [String]) -> [String: Any] {
        [
            "type": "stdio",
            "command": executable,
            "args": arguments,
        ]
    }

    static private(set) var lastError: String?

    // MARK: Reading

    static func isRegistered(in config: [String: Any]?) -> Bool {
        MCPConfigFile.entry(named: MCPServerCommand.name, under: key, in: config) != nil
    }

    /// True when there is an entry and it is not the one this build writes —
    /// almost always because the bundle moved. See `MCPConfigFile.matches`.
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
            return fail("~/.claude.json is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: key, into: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing ~/.claude.json")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard MCPConfigFile.preserves(before, in: reread) else {
            return fail("~/.claude.json lost keys it had before the write")
        }
        guard isRegistered(in: reread) else {
            return fail("~/.claude.json was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("~/.claude.json is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.removed(
            named: MCPServerCommand.name, under: key, from: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing ~/.claude.json")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard !isRegistered(in: reread) else {
            return fail("~/.claude.json was written but the server is still registered")
        }

        lastError = nil
        return true
    }

    /// Brings an existing registration up to this build. Never installs
    /// uninvited: an absent entry means the reader never asked for this, the
    /// same rule every hooks installer's `repairIfStale` follows.
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

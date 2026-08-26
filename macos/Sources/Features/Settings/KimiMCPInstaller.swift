import Foundation

/// Registers Phantom's MCP server with Kimi Code.
///
/// The easiest of the four, because Kimi's file is the same shape as Claude
/// Code's — a `mcpServers` object keyed by name, each entry a `command` and a
/// separate `args` array — and unlike Claude's it holds nothing else. Kimi
/// keeps MCP declarations in their own file rather than in `config.toml`, so
/// there is no model setting, no permission mode and no login session in the
/// blast radius of a bad write.
///
/// `type` is deliberately not written. Claude Code's installer includes it
/// because `claude mcp add-json` emits it and an entry missing it looks
/// hand-written; Kimi documents the opposite rule — an entry with a `command`
/// *is* a stdio server — so a key its documentation never mentions is a key it
/// might reject.
@MainActor
enum KimiMCPInstaller {
    static let key = "mcpServers"

    /// `~/.kimi-code/mcp.json`, or the same file under `KIMI_CODE_HOME`. The
    /// project-local `.kimi-code/mcp.json` is not written: a server that
    /// reports this app's own windows is a fact about the machine, not about
    /// one repository, and writing it per project would put the reader's
    /// absolute paths into version control.
    static var configURL: URL {
        KimiHooksInstaller.kimiDir.appendingPathComponent("mcp.json")
    }

    static var entry: [String: Any]? {
        guard let path = MCPServerCommand.executablePath else { return nil }
        return ["command": path, "args": MCPServerCommand.arguments]
    }

    static private(set) var lastError: String?

    static func isRegistered(in config: [String: Any]?) -> Bool {
        MCPConfigFile.entry(named: MCPServerCommand.name, under: key, in: config) != nil
    }

    static func isStale(in config: [String: Any]?) -> Bool {
        guard isRegistered(in: config), let entry else { return false }
        return !MCPConfigFile.matches(entry, named: MCPServerCommand.name, under: key, in: config)
    }

    static var isRegistered: Bool { isRegistered(in: MCPConfigFile.read(at: configURL)) }

    @discardableResult
    static func register() -> Bool {
        guard let entry else { return fail("Phantom could not find its own executable") }

        /// An absent file is an empty configuration rather than a failure: this
        /// file exists only once something has been registered in it, so the
        /// first registration is expected to create it. Claude's installer
        /// cannot make that assumption — `~/.claude.json` holds a login
        /// session, and treating an unreadable one as empty would replace it.
        let before = MCPConfigFile.read(at: configURL) ?? [:]

        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: key, into: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing \(configURL.path)")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard MCPConfigFile.preserves(before, in: reread) else {
            return fail("\(configURL.path) lost keys it had before the write")
        }
        guard isRegistered(in: reread) else {
            return fail("\(configURL.path) was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        guard let before = MCPConfigFile.read(at: configURL) else {
            lastError = nil
            return true
        }

        let after = MCPConfigFile.removed(
            named: MCPServerCommand.name, under: key, from: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing \(configURL.path)")
        }

        guard !isRegistered(in: MCPConfigFile.read(at: configURL)) else {
            return fail("\(configURL.path) was written but the server is still registered")
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

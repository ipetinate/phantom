import Foundation

/// Registers Phantom's MCP server with Pi.
///
/// **Pi has no MCP client of its own.** Its extensibility is TypeScript — a
/// tool is registered by an extension calling `pi.registerTool`, and
/// `settings.json` has no key for MCP servers at all. What reads the file this
/// writes is an extension the reader installs separately, and the widely used
/// one reads `~/.pi/agent/mcp.json` in the same `mcpServers` shape every other
/// agent here uses.
///
/// So this registration is real and it is conditional, and the settings pane
/// says so rather than leaving the reader to wonder why a registered server
/// never appears. Writing the file when no extension is installed costs
/// nothing and breaks nothing: it is a small JSON file that nothing reads,
/// and it becomes live the moment one is.
///
/// The alternative was to leave Pi off the list entirely, which is what this
/// app did first. That reads as "Pi cannot do this" — and the truth is nearer
/// "Pi needs one more piece", which is worth the sentence it costs to say.
@MainActor
enum PiMCPInstaller {
    static let key = "mcpServers"

    /// `~/.pi/agent/mcp.json`, beside the extension directory rather than
    /// inside it. The project-local file is not written, for the reason
    /// `KimiMCPInstaller` gives: absolute paths to somebody's Phantom do not
    /// belong in a repository.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("mcp.json")
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

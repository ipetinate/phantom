import Foundation

@MainActor
final class JSONMCPInstaller: MCPEngine {
    let descriptor: AgentDescriptor
    let mcp: MCPIntegration.JSONMCP
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        mcp: MCPIntegration.JSONMCP,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.descriptor = descriptor
        self.mcp = mcp
        self.directory = mcp.directory.resolve(environment: environment, home: home)
    }

    convenience init?(
        descriptor: AgentDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard case .json(let mcp)? = descriptor.mcp else { return nil }
        self.init(descriptor: descriptor, mcp: mcp, environment: environment, home: home)
    }

    var configURL: URL { directory.appendingPathComponent(mcp.fileName) }

    var key: String { mcp.key }

    private var fileName: String { mcp.fileName }

    var entry: [String: Any]? {
        MCPServerCommand.executablePath.map {
            entry(executable: $0, arguments: MCPServerCommand.arguments)
        }
    }

    func entry(executable: String, arguments: [String]) -> [String: Any] {
        Self.entry(mcp.entry, executable: executable, arguments: arguments)
    }

    static func entry(
        _ shape: MCPIntegration.Entry,
        executable: String,
        arguments: [String]
    ) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch shape.command {
        case .separateArguments:
            entry["command"] = executable
            entry["args"] = arguments
        case .singleArray:
            entry["command"] = [executable] + arguments
        }
        for (name, extra) in shape.extras {
            switch extra {
            case .string(let value): entry[name] = value
            case .bool(let value): entry[name] = value
            }
        }
        return entry
    }

    // MARK: Reading

    func isRegistered(in config: [String: Any]?) -> Bool {
        MCPConfigFile.entry(named: MCPServerCommand.name, under: key, in: config) != nil
    }

    func isStale(in config: [String: Any]?) -> Bool {
        guard isRegistered(in: config), let entry else { return false }
        return !MCPConfigFile.matches(entry, named: MCPServerCommand.name, under: key, in: config)
    }

    var isRegistered: Bool { isRegistered(in: MCPConfigFile.read(at: configURL)) }

    // MARK: Writing

    @discardableResult
    func register() -> Bool {
        guard let entry else { return fail("Phantom could not find its own executable") }
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("\(fileName) is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.merged(
            entry, named: MCPServerCommand.name, under: key, into: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing \(fileName)")
        }

        let reread = MCPConfigFile.read(at: configURL)
        guard MCPConfigFile.preserves(before, in: reread) else {
            return fail("\(fileName) lost keys it had before the write")
        }
        guard isRegistered(in: reread) else {
            return fail("\(fileName) was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    func remove() -> Bool {
        guard let before = MCPConfigFile.read(at: configURL) else {
            return fail("\(fileName) is unreadable or isn't a JSON object")
        }

        let after = MCPConfigFile.removed(
            named: MCPServerCommand.name, under: key, from: before)
        guard MCPConfigFile.write(after, to: configURL) else {
            return fail("writing \(fileName)")
        }

        guard !isRegistered(in: MCPConfigFile.read(at: configURL)) else {
            return fail("\(fileName) was written but the server is still registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    func repairIfStale() -> Bool {
        let config = MCPConfigFile.read(at: configURL)
        guard isRegistered(in: config), isStale(in: config) else { return false }
        return register()
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }
}

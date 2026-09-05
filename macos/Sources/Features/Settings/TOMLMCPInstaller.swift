import Foundation

@MainActor
final class TOMLMCPInstaller: MCPEngine {
    let descriptor: AgentDescriptor
    let mcp: MCPIntegration.TOMLMCP
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        mcp: MCPIntegration.TOMLMCP,
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
        guard case .toml(let mcp)? = descriptor.mcp else { return nil }
        self.init(descriptor: descriptor, mcp: mcp, environment: environment, home: home)
    }

    var configURL: URL { directory.appendingPathComponent(mcp.fileName) }

    var tableName: String { mcp.table }

    var table: String { "\(mcp.table).\(MCPServerCommand.name)" }

    private var fileName: String { mcp.fileName }

    // MARK: The block

    func block(executable: String, arguments: [String], name: String) -> String {
        let args = arguments
            .map { "\"\(Self.escaped($0))\"" }
            .joined(separator: ", ")

        return """
        [\(mcp.table).\(name)]
        command = "\(Self.escaped(executable))"
        args = [\(args)]
        """
    }

    func block(executable: String) -> String {
        block(executable: executable, arguments: MCPServerCommand.arguments, name: MCPServerCommand.name)
    }

    var block: String? {
        MCPServerCommand.executablePath.map(block(executable:))
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Reading the file as lines

    static func header(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[")
        else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    static func parts(of path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let trimmed = String(part).trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote)
                && trimmed.count >= 2 {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
    }

    func isPhantom(_ path: String) -> Bool {
        let parts = Self.parts(of: path)
        guard parts.count >= 2 else { return false }
        return parts[0] == mcp.table && parts[1] == MCPServerCommand.name
    }

    func hasUnownableTable(in text: String) -> Bool {
        var seenHeader = false

        for line in text.components(separatedBy: .newlines) {
            if let path = Self.header(of: line) {
                seenHeader = true
                if Self.parts(of: path) == [mcp.table] { return true }
                continue
            }

            guard !seenHeader else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(mcp.table) else { continue }
            let rest = trimmed.dropFirst(mcp.table.count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return true }
        }

        return false
    }

    // MARK: Merging

    func phantomBlock(in text: String) -> String? {
        var kept: [String] = []
        var inside = false

        for line in text.components(separatedBy: .newlines) {
            if let path = Self.header(of: line) {
                inside = isPhantom(path)
            }
            if inside { kept.append(line) }
        }

        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isRegistered(in text: String) -> Bool {
        phantomBlock(in: text) != nil
    }

    func isStale(in text: String) -> Bool {
        guard let found = phantomBlock(in: text), let block else { return false }
        return found != block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removed(from text: String) -> String {
        var kept: [String] = []
        var inside = false

        for line in text.components(separatedBy: .newlines) {
            if let path = Self.header(of: line) {
                inside = isPhantom(path)
            }
            if !inside { kept.append(line) }
        }

        return kept.joined(separator: "\n")
    }

    func merged(_ block: String, into text: String) -> String? {
        guard !hasUnownableTable(in: text) else { return nil }

        let rest = removed(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return block + "\n" }
        return rest + "\n\n" + block + "\n"
    }

    // MARK: Disk

    static func read(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : ""
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    var isRegistered: Bool {
        Self.read(at: configURL).map(isRegistered(in:)) ?? false
    }

    @discardableResult
    func register() -> Bool {
        guard let block else { return fail("Phantom could not find its own executable") }
        guard let before = Self.read(at: configURL) else {
            return fail("\(fileName) is not readable as text")
        }
        guard let after = merged(block, into: before) else {
            return fail("\(fileName) already declares \(mcp.table) in a shape Phantom can't merge into \u{2014} add [\(table)] by hand")
        }
        guard write(after, to: configURL) else { return fail("writing \(fileName)") }
        guard let reread = Self.read(at: configURL), isRegistered(in: reread) else {
            return fail("\(fileName) was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    func remove() -> Bool {
        guard let before = Self.read(at: configURL) else {
            return fail("\(fileName) is not readable as text")
        }

        let after = removed(from: before).trimmingCharacters(in: .whitespacesAndNewlines)
        guard write(after.isEmpty ? "" : after + "\n", to: configURL) else {
            return fail("writing \(fileName)")
        }
        guard let reread = Self.read(at: configURL), !isRegistered(in: reread) else {
            return fail("\(fileName) was written but the server is still registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard let text = Self.read(at: configURL), isRegistered(in: text), isStale(in: text)
        else { return false }
        return register()
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }
}

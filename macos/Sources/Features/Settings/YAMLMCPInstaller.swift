import Foundation

/// Installs Phantom's one owned extension in Goose's YAML configuration.
///
/// Goose is the only supported agent whose MCP registry is YAML. This is a
/// deliberately small, ownership-aware editor rather than a YAML serializer:
/// it changes only the `extensions.phantom-*` mapping and leaves comments,
/// ordering, and every extension it did not create untouched.
@MainActor
final class YAMLMCPInstaller: MCPEngine {
    let descriptor: AgentDescriptor
    let mcp: MCPIntegration.YAMLMCP
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        mcp: MCPIntegration.YAMLMCP,
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
        guard case .yaml(let mcp)? = descriptor.mcp else { return nil }
        self.init(descriptor: descriptor, mcp: mcp, environment: environment, home: home)
    }

    var configURL: URL { directory.appendingPathComponent(mcp.fileName) }

    var extensionName: String { MCPServerCommand.name }

    var block: String? {
        MCPServerCommand.executablePath.map { block(executable: $0) }
    }

    func block(executable: String, arguments: [String]) -> String {
        let renderedArguments = arguments
            .map { "    - \"\(Self.yamlString($0))\"" }
            .joined(separator: "\n")

        return """
          \(extensionName):
            name: Phantom
            enabled: true
            type: stdio
            cmd: "\(Self.yamlString(executable))"
            args:
        \(renderedArguments)
            timeout: \(mcp.timeout)
        """
    }

    func block(executable: String) -> String {
        block(executable: executable, arguments: MCPServerCommand.arguments)
    }

    // MARK: Reading

    func isRegistered(in text: String) -> Bool {
        ownedRange(in: lines(of: text)) != nil
    }

    func isStale(in text: String) -> Bool {
        guard let expected = block,
              let range = ownedRange(in: lines(of: text))
        else { return false }
        let found = lines(of: text)[range].joined(separator: "\n")
        return found != expected
    }

    var isRegistered: Bool {
        guard let text = readText() else { return false }
        return isRegistered(in: text)
    }

    var isStale: Bool {
        guard let text = readText() else { return false }
        return isStale(in: text)
    }

    // MARK: Writing

    @discardableResult
    func register() -> Bool {
        guard let block else { return fail("Phantom could not find its own executable") }
        guard let before = readText() else {
            return fail("\(mcp.fileName) is unreadable")
        }
        let after = merged(block, into: before)
        guard write(after) else { return fail("writing \(mcp.fileName)") }
        guard isRegistered(in: after) else {
            return fail("\(mcp.fileName) was written but the server is not registered")
        }
        lastError = nil
        return true
    }

    @discardableResult
    func remove() -> Bool {
        guard let before = readText() else {
            return fail("\(mcp.fileName) is unreadable")
        }
        let after = removed(from: before)
        guard write(after) else { return fail("writing \(mcp.fileName)") }
        guard !isRegistered(in: after) else {
            return fail("\(mcp.fileName) was written but the server is still registered")
        }
        lastError = nil
        return true
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard isRegistered, isStale else { return false }
        return register()
    }

    // MARK: Pure line editor, also used by tests

    func merged(_ block: String, into text: String) -> String {
        var source = lines(of: text)
        source = removeOwnedBlock(from: source)
        let blockLines = lines(of: block)

        if let table = topLevelTableIndex(in: source) {
            let insertion = endOfTopLevelTable(in: source, startingAt: table)
            source.insert(contentsOf: blockLines, at: insertion)
        } else {
            if !source.isEmpty, source.last != "" { source.append("") }
            source.append(contentsOf: blockLines)
        }
        return source.joined(separator: "\n") + "\n"
    }

    func removed(from text: String) -> String {
        var source = lines(of: text)
        source = removeOwnedBlock(from: source)
        return source.joined(separator: "\n") + (source.isEmpty ? "" : "\n")
    }

    private func readText() -> String? {
        guard let data = try? Data(contentsOf: configURL) else {
            return FileManager.default.fileExists(atPath: configURL.path) ? nil : ""
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ text: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private func topLevelTableIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            indentation(of: line) == 0 && line.trimmingCharacters(in: .whitespaces) == "\(mcp.table):"
        }
    }

    private func endOfTopLevelTable(in lines: [String], startingAt table: Int) -> Int {
        for index in (table + 1)..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") && indentation(of: line) == 0 {
                return index
            }
        }
        return lines.count
    }

    private func ownedRange(in lines: [String]) -> Range<Int>? {
        guard let table = topLevelTableIndex(in: lines) else { return nil }
        let end = endOfTopLevelTable(in: lines, startingAt: table)
        guard let start = (table + 1..<end).first(where: { lineIndex in
            indentation(of: lines[lineIndex]) == 2
                && lines[lineIndex].trimmingCharacters(in: .whitespaces) == "\(extensionName):"
        }) else { return nil }

        var finish = start + 1
        while finish < end {
            let line = lines[finish]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") && indentation(of: line) <= 2 {
                break
            }
            finish += 1
        }
        return start..<finish
    }

    private func removeOwnedBlock(from lines: [String]) -> [String] {
        guard let range = ownedRange(in: lines) else { return lines }
        var result = lines
        result.removeSubrange(range)
        return result
    }

    private static func yamlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }
}

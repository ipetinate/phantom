import Foundation

@MainActor
final class TOMLHooksInstaller: HooksEngine {
    static let blockHeaderLines = [
        "# Phantom: reports this tab's agent state to the sidebar.",
        "# Managed by Phantom. Edit the app's Settings rather than these blocks.",
    ]

    let descriptor: AgentDescriptor
    let hooks: HooksIntegration.TOMLHooks
    let scriptName: String
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        hooks: HooksIntegration.TOMLHooks,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        self.descriptor = descriptor
        self.hooks = hooks
        self.scriptName = TabStateScript.fileName(forBundleID: bundleID)
        self.directory = hooks.directory.resolve(environment: environment, home: home)
    }

    convenience init?(
        descriptor: AgentDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        guard case .toml(let hooks)? = descriptor.hooks else { return nil }
        self.init(
            descriptor: descriptor, hooks: hooks,
            environment: environment, home: home, bundleID: bundleID)
    }

    var configURL: URL { directory.appendingPathComponent(hooks.fileName) }

    var scriptURL: URL {
        let folder = hooks.script.subdirectory.isEmpty
            ? directory
            : directory.appendingPathComponent(hooks.script.subdirectory, isDirectory: true)
        return folder.appendingPathComponent(scriptName)
    }

    var eventStates: [(event: String, state: String)] {
        hooks.events.map { ($0.name, $0.state) }
    }

    private var tableHeader: String { "[[\(hooks.table)]]" }

    // MARK: The block

    func command(for event: HooksIntegration.Event) -> String {
        command(for: event, scriptPath: scriptURL.path)
    }

    func command(for event: HooksIntegration.Event, scriptPath: String) -> String {
        TabStateScript.commandLine(
            scriptPath: scriptPath,
            arguments: TabStateScript.arguments(
                agent: descriptor.id,
                state: event.state,
                options: hooks.script,
                reply: event.reply))
    }

    var block: String { block(scriptPath: scriptURL.path) }

    func block(scriptPath: String) -> String {
        var lines = Self.blockHeaderLines
        for event in hooks.events {
            lines += [
                "",
                tableHeader,
                "event = \"\(event.name)\"",
                "command = \(Self.tomlString(command(for: event, scriptPath: scriptPath)))",
                "timeout = \(hooks.timeout)",
            ]
        }
        return lines.joined(separator: "\n")
    }

    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    func installed(into text: String, scriptPath: String) -> String {
        let cleaned = removed(from: text)
        let separator = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\n\n"
        return cleaned + separator + block(scriptPath: scriptPath) + "\n"
    }

    // MARK: Reading what is there

    func isPhantomBlock(_ lines: [String]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { return false }
            return trimmed.contains(scriptName)
        }
    }

    private func isTableHeader(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    func removed(from text: String) -> String {
        var kept: [String] = []
        var block: [String] = []
        var inBlock = false

        func flush() {
            if !isPhantomBlock(block) { kept += block }
            block = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == tableHeader {
                flush()
                inBlock = true
                block = [line]
                continue
            }
            if isTableHeader(trimmed) {
                flush()
                inBlock = false
                kept.append(line)
                continue
            }
            if inBlock { block.append(line) } else { kept.append(line) }
        }
        flush()

        return kept
            .filter { line in !Self.blockHeaderLines.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
    }

    func isRegistered(in text: String) -> Bool {
        var block: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == tableHeader {
                if isPhantomBlock(block) { return true }
                inBlock = true
                block = []
                continue
            }
            if isTableHeader(trimmed) {
                if isPhantomBlock(block) { return true }
                inBlock = false
                block = []
                continue
            }
            if inBlock { block.append(line) }
        }
        return isPhantomBlock(block)
    }

    static func read(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: State

    var isInstalled: Bool {
        guard let text = Self.read(at: configURL) else { return false }
        return isRegistered(in: text)
    }

    var isScriptStale: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8) else { return true }
        return onDisk != TabStateScript.body
    }

    var isStale: Bool {
        guard isInstalled else { return false }
        if isScriptStale { return true }
        guard let text = Self.read(at: configURL) else { return true }
        return !text.contains(scriptURL.path)
    }

    @discardableResult
    func install() -> Bool {
        lastError = nil
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TabStateScript.body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return fail("could not write \(scriptURL.path)", error)
        }

        let existing = Self.read(at: configURL) ?? ""
        return write(installed(into: existing, scriptPath: scriptURL.path), to: configURL)
    }

    @discardableResult
    func uninstall() -> Bool {
        lastError = nil
        guard let text = Self.read(at: configURL) else { return true }
        guard write(removed(from: text), to: configURL) else { return false }
        try? FileManager.default.removeItem(at: scriptURL)
        return true
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return install()
    }

    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return fail("could not write \(url.path)", error)
        }
    }

    private func fail(_ message: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(message): \($0.localizedDescription)" } ?? message
        return false
    }
}

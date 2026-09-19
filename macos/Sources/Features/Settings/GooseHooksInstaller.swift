import Foundation

/// Installs Phantom's Open Plugin hook for Goose.
///
/// Goose discovers the plugin as a directory, so unlike the JSON/TOML hook
/// installers this owns a manifest, `hooks/hooks.json`, and the shared tab
/// state script. Each file is checked independently and only these three
/// files are removed on uninstall.
@MainActor
final class GooseHooksInstaller: HooksEngine {
    let descriptor: AgentDescriptor
    let hooks: HooksIntegration.GooseHooks
    let directory: URL
    let pluginName: String

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        hooks: HooksIntegration.GooseHooks,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        self.descriptor = descriptor
        self.hooks = hooks
        self.directory = hooks.directory
            .resolve(environment: environment, home: home)
            .appendingPathComponent(hooks.pluginName, isDirectory: true)
        self.pluginName = hooks.pluginName
        self.scriptName = TabStateScript.fileName(forBundleID: bundleID)
    }

    private let scriptName: String

    convenience init?(
        descriptor: AgentDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        guard case .goose(let hooks)? = descriptor.hooks else { return nil }
        self.init(
            descriptor: descriptor,
            hooks: hooks,
            environment: environment,
            home: home,
            bundleID: bundleID)
    }

    var manifestURL: URL {
        directory.appendingPathComponent(".plugin/plugin.json")
    }

    var hooksURL: URL {
        directory.appendingPathComponent("hooks/hooks.json")
    }

    var scriptURL: URL {
        directory.appendingPathComponent(scriptName)
    }

    var events: [String] { hooks.events.map(\.name) }

    var isInstalled: Bool {
        [manifestURL, hooksURL, scriptURL].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    var isStale: Bool {
        guard isInstalled else { return false }
        return read(manifestURL) != Self.manifestBody(name: pluginName)
            || read(hooksURL) != hooksBody
            || read(scriptURL) != TabStateScript.body
    }

    @discardableResult
    func install() -> Bool {
        do {
            try write(Self.manifestBody(name: pluginName), to: manifestURL)
            try write(hooksBody, to: hooksURL)
            try write(TabStateScript.body, to: scriptURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            lastError = nil
            return true
        } catch {
            return fail("writing Goose plugin", error)
        }
    }

    @discardableResult
    func uninstall() -> Bool {
        do {
            for url in [manifestURL, hooksURL, scriptURL]
                where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            lastError = nil
            return true
        } catch {
            return fail("removing Goose plugin", error)
        }
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return install()
    }

    static func manifestBody(name: String) -> String {
        """
        {
          "name": "\(name)",
          "version": "1.0.0",
          "description": "Phantom terminal state integration"
        }
        """
    }

    var hooksBody: String {
        var registered: [String: [[String: Any]]] = [:]
        for event in hooks.events {
            var arguments: [String] = []
            if !event.state.isEmpty { arguments.append(event.state) }
            arguments += ["--agent", descriptor.id]
            arguments += hooks.sessionKeys.flatMap { ["--session-key", $0] }
            let shellCommand = (["${PLUGIN_ROOT}/\(scriptName)"] + arguments)
                .enumerated()
                .map { index, value in
                    index == 0 ? value : TabStateScript.shellWord(value)
                }
                .joined(separator: " ")
            registered[event.name] = [[
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": shellCommand,
                ]],
            ]]
        }

        let object: [String: Any] = ["hooks": registered]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]) else {
            return "{}\n"
        }
        return String(data: data, encoding: .utf8).map { $0 + "\n" } ?? "{}\n"
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fail(_ stage: String, _ error: Error) -> Bool {
        lastError = "\(stage): \(error.localizedDescription)"
        return false
    }
}

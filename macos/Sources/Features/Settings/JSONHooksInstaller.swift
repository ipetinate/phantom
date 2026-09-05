import Foundation

@MainActor
final class JSONHooksInstaller: HooksEngine {
    let descriptor: AgentDescriptor
    let hooks: HooksIntegration.JSONHooks
    let scriptName: String
    let legacyScriptNames: [String]
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        hooks: HooksIntegration.JSONHooks,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        self.descriptor = descriptor
        self.hooks = hooks
        self.scriptName = TabStateScript.fileName(forBundleID: bundleID)
        self.legacyScriptNames = PhantomBuild.variant(forBundleID: bundleID) == nil
            ? hooks.legacyScriptNames
            : []
        self.directory = hooks.directory.resolve(environment: environment, home: home)
    }

    convenience init?(
        descriptor: AgentDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        guard case .json(let hooks)? = descriptor.hooks else { return nil }
        self.init(
            descriptor: descriptor, hooks: hooks,
            environment: environment, home: home, bundleID: bundleID)
    }

    var settingsURL: URL { directory.appendingPathComponent(hooks.fileName) }

    var scriptURL: URL {
        let folder = hooks.script.subdirectory.isEmpty
            ? directory
            : directory.appendingPathComponent(hooks.script.subdirectory, isDirectory: true)
        return folder.appendingPathComponent(scriptName)
    }

    var eventStates: [(event: String, state: String)] {
        hooks.events.map { ($0.name, $0.state) }
    }

    // MARK: The registration

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

    private func entry(for event: HooksIntegration.Event, scriptPath: String) -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": command(for: event, scriptPath: scriptPath),
        ]
        switch hooks.entryShape {
        case .grouped: return ["hooks": [handler]]
        case .flat: return handler
        }
    }

    private func commands(in entry: [String: Any]) -> [String] {
        switch hooks.entryShape {
        case .grouped:
            return (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        case .flat:
            return (entry["command"] as? String).map { [$0] } ?? []
        }
    }

    private func names(_ command: String, scriptName: String) -> Bool {
        command.contains(scriptName) || legacyScriptNames.contains { command.contains($0) }
    }

    func registered(into settings: [String: Any]) -> [String: Any] {
        registered(into: settings, scriptPath: scriptURL.path)
    }

    func registered(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        let scriptName = (scriptPath as NSString).lastPathComponent
        var settings = settings
        var events: [String: Any]

        switch hooks.ownership {
        case .shared:
            events = settings[hooks.key] as? [String: Any] ?? [:]
            for event in hooks.events {
                var entries = events[event.name] as? [[String: Any]] ?? []
                entries.removeAll { entry in
                    commands(in: entry).contains { names($0, scriptName: scriptName) }
                }
                entries.append(entry(for: event, scriptPath: scriptPath))
                events[event.name] = entries
            }
        case .owned:
            events = [:]
            for event in hooks.events {
                events[event.name] = [entry(for: event, scriptPath: scriptPath)]
            }
        }

        settings[hooks.key] = events
        return settings
    }

    func removed(from settings: [String: Any]) -> [String: Any] {
        removed(from: settings, scriptName: scriptName)
    }

    func removed(from settings: [String: Any], scriptName: String) -> [String: Any] {
        var settings = settings

        switch hooks.ownership {
        case .shared:
            guard var events = settings[hooks.key] as? [String: Any] else { return settings }
            for (name, value) in events {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    commands(in: entry).contains { names($0, scriptName: scriptName) }
                }
                events[name] = entries
            }
            settings[hooks.key] = events
        case .owned:
            settings.removeValue(forKey: hooks.key)
        }

        return settings
    }

    // MARK: Reading what is there

    func commands(in settings: [String: Any]?, event: String) -> [String] {
        guard let events = settings?[hooks.key] as? [String: Any],
              let entries = events[event] as? [[String: Any]]
        else { return [] }
        return entries.flatMap(commands(in:))
    }

    func isRegistered(in settings: [String: Any]?) -> Bool {
        guard settings?[hooks.key] is [String: Any] else { return false }
        return hooks.events.allSatisfy { event in
            commands(in: settings, event: event.name).contains { $0.contains(scriptName) }
        }
    }

    func isRegisteredForAnyEvent(in settings: [String: Any]?) -> Bool {
        guard let events = settings?[hooks.key] as? [String: Any] else { return false }
        return events.keys.contains { event in
            commands(in: settings, event: event).contains { $0.contains(scriptName) }
        }
    }

    static func readSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : [:]
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readSettings() -> [String: Any]? {
        Self.readSettings(at: settingsURL)
    }

    private func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: State

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path) && isRegistered(in: readSettings())
    }

    var isScriptStale: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8) else { return false }
        return onDisk != TabStateScript.body
    }

    var isStale: Bool {
        isScriptStale || !isRegistered(in: readSettings())
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              isRegisteredForAnyEvent(in: readSettings()),
              isStale
        else { return false }

        let repaired = install()
        log(repaired ? "repaired stale hook install" : "failed repairing stale hook install")
        return repaired
    }

    @discardableResult
    func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TabStateScript.body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return fail("writing the hook script", error)
        }

        guard let before = readSettings() else {
            return fail("\(hooks.fileName) is unreadable or isn't a JSON object")
        }
        guard writeSettings(registered(into: before)) else {
            return fail("writing \(hooks.fileName)")
        }
        guard isInstalled else {
            return fail("\(hooks.fileName) was written but the hooks are not registered")
        }

        lastError = nil
        log("install ok")
        return true
    }

    @discardableResult
    func uninstall() -> Bool {
        guard let before = readSettings() else {
            return fail("\(hooks.fileName) is unreadable or isn't a JSON object")
        }

        try? FileManager.default.removeItem(at: scriptURL)
        guard writeSettings(removed(from: before)) else {
            return fail("writing \(hooks.fileName)")
        }
        guard !isRegisteredForAnyEvent(in: readSettings()) else {
            return fail("\(hooks.fileName) was written but the hooks are still registered")
        }

        lastError = nil
        log("uninstall ok")
        return true
    }

    func logStatus() {
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)
        let readable = (try? Data(contentsOf: settingsURL)) != nil
        log("status script=\(scriptExists) settingsRead=\(readable) registered=\(isRegistered(in: readSettings())) home=\(directory.path)")
    }

    private func fail(_ stage: String, _ error: Error? = nil) -> Bool {
        let detail = error.map { "\(stage): \($0.localizedDescription)" } ?? stage
        lastError = detail
        log("FAIL \(detail)")
        return false
    }

    private func log(_ message: String) {
        let line = "\(Date()) [\(descriptor.id)] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/phantom-hooks.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

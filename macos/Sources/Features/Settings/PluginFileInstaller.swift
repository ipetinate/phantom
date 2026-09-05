import Foundation

@MainActor
final class PluginFileInstaller: HooksEngine {
    let descriptor: AgentDescriptor
    let plugin: HooksIntegration.PluginFile
    let fileName: String
    let directory: URL

    private(set) var lastError: String?

    init(
        descriptor: AgentDescriptor,
        plugin: HooksIntegration.PluginFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        self.descriptor = descriptor
        self.plugin = plugin
        self.fileName = PhantomBuild.fileName(plugin.fileName, forBundleID: bundleID)
        self.directory = plugin.directory.resolve(environment: environment, home: home)
    }

    convenience init?(
        descriptor: AgentDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? PhantomBuild.releaseBundleID
    ) {
        guard case .file(let plugin)? = descriptor.hooks else { return nil }
        self.init(
            descriptor: descriptor, plugin: plugin,
            environment: environment, home: home, bundleID: bundleID)
    }

    static func body(of descriptor: AgentDescriptor) -> String? {
        guard case .file(let plugin)? = descriptor.hooks else { return nil }
        return body(of: plugin, agent: descriptor.id)
    }

    var fileURL: URL {
        let folder = plugin.subdirectory.isEmpty
            ? directory
            : directory.appendingPathComponent(plugin.subdirectory, isDirectory: true)
        return folder.appendingPathComponent(fileName)
    }

    var events: [String] { plugin.events }

    var body: String { Self.body(of: plugin, agent: descriptor.id) }

    static func body(of plugin: HooksIntegration.PluginFile, agent: String) -> String {
        plugin.body
            .replacingOccurrences(of: HooksIntegration.PluginFile.agentPlaceholder, with: agent)
            .replacingOccurrences(
                of: HooksIntegration.PluginFile.stateFileVariablePlaceholder,
                with: TabStateScript.stateFileVariable)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var isStale: Bool {
        guard let onDisk = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return onDisk != body
    }

    @discardableResult
    func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            lastError = nil
            return true
        } catch {
            return fail("writing \(fileURL.path)", error)
        }
    }

    @discardableResult
    func uninstall() -> Bool {
        guard isInstalled else {
            lastError = nil
            return true
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            lastError = nil
            return true
        } catch {
            return fail("removing \(fileURL.path)", error)
        }
    }

    @discardableResult
    func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return install()
    }

    private func fail(_ stage: String, _ error: Error) -> Bool {
        lastError = "\(stage): \(error.localizedDescription)"
        return false
    }
}

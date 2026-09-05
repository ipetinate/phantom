import Foundation

struct InstalledExtension: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let root: URL
}

enum ExtensionState: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(installed: String, available: String)
}

enum ExtensionActivity: Equatable, Sendable {
    case downloading(fraction: Double?)
    case verifying
    case installing
    case removing
}

@MainActor
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    static let indexURL = URL(
        string: "https://github.com/ipetinate/phantom-extensions/releases/download/index/index.json"
    )!

    @Published private(set) var index: ExtensionIndex?
    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var activity: [String: ExtensionActivity] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    private let extensionsDirOverride: URL?

    init(extensionsDir: URL? = nil) {
        self.extensionsDirOverride = extensionsDir
        reloadInstalled()
    }

    var extensionsDir: URL {
        extensionsDirOverride ?? GuiConfigStore.shared.extensionsDirURL
    }

    func refresh() async {}

    func reloadInstalled() {
        installed = Self.scanInstalled(in: extensionsDir)
    }

    func install(_ entry: ExtensionIndex.Entry) async {}

    func remove(id: String) async {}

    func state(for entry: ExtensionIndex.Entry) -> ExtensionState {
        Self.state(
            installedVersion: installed.first { $0.id == entry.id }?.version,
            available: entry.version
        )
    }

    nonisolated static func state(installedVersion: String?, available: String) -> ExtensionState {
        guard let installedVersion else { return .notInstalled }
        guard let have = SemanticVersion(installedVersion),
              let offered = SemanticVersion(available),
              offered > have
        else { return .installed(version: installedVersion) }
        return .updateAvailable(installed: installedVersion, available: available)
    }

    nonisolated static func scanInstalled(in directory: URL) -> [InstalledExtension] {
        let manifests = LanguageCatalog.load(directory: directory, scope: .user)
            .filter { !$0.id.isEmpty }
            .sorted { $0.root.lastPathComponent < $1.root.lastPathComponent }

        var seen: Set<String> = []
        return manifests
            .filter { seen.insert($0.id).inserted }
            .map { InstalledExtension(id: $0.id, name: $0.name, version: $0.version, root: $0.root) }
            .sorted(by: displayOrder)
    }

    nonisolated private static func displayOrder(_ lhs: InstalledExtension, _ rhs: InstalledExtension) -> Bool {
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}

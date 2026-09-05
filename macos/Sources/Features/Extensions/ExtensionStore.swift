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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            index = try await Self.fetchIndex()
            lastRefreshError = nil
        } catch {
            lastRefreshError = Self.refreshMessage(for: error)
        }
    }

    func reloadInstalled() {
        installed = Self.scanInstalled(in: extensionsDir)
    }

    func install(_ entry: ExtensionIndex.Entry) async {
        guard activity[entry.id] == nil else { return }
        errors[entry.id] = nil
        activity[entry.id] = .downloading(fraction: nil)
        defer { activity[entry.id] = nil }

        let directory = extensionsDir
        do {
            try await ExtensionInstaller.install(entry, into: directory) { [weak self] step in
                self?.activity[entry.id] = step
            }
            noteInstalledChanged()
        } catch {
            errors[entry.id] = Self.message(for: error)
            reloadInstalled()
        }
    }

    func remove(id: String) async {
        guard activity[id] == nil else { return }
        errors[id] = nil
        activity[id] = .removing
        defer { activity[id] = nil }

        let directory = extensionsDir
        let candidate = installed.first { $0.id == id }?.root
            ?? directory.appendingPathComponent(id, isDirectory: true)
        let outcome = await Task.detached(priority: .utility) {
            Result { try ExtensionInstaller.remove(at: candidate, in: directory) }
        }.value

        switch outcome {
        case .success:
            noteInstalledChanged()
        case .failure(let error):
            errors[id] = Self.message(for: error)
            reloadInstalled()
        }
    }

    private func noteInstalledChanged() {
        reloadInstalled()
        guard extensionsDirOverride == nil else { return }
        LanguageResolver.shared.reload()
        LSPCenter.shared.noteAvailabilityChanged()
    }

    // MARK: Registry

    static let refreshTimeout: TimeInterval = 15

    nonisolated static func fetchIndex() async throws -> ExtensionIndex {
        let request = URLRequest(
            url: indexURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: refreshTimeout
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExtensionInstaller.Failure.download("the server did not answer over HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtensionInstaller.Failure.httpStatus(http.statusCode)
        }
        return try ExtensionIndex.parse(data)
    }

    nonisolated static func refreshMessage(for error: Error) -> String {
        switch error {
        case let parse as ExtensionIndex.ParseError:
            return "The registry could not be read: \(parse.message)."
        case ExtensionInstaller.Failure.httpStatus(let code):
            return "Could not reach the registry: the server answered \(code)."
        default:
            return "Could not reach the registry: \(error.localizedDescription)"
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if let failure = error as? ExtensionInstaller.Failure { return failure.message }
        return error.localizedDescription
    }

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

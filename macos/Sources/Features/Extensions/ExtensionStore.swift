import Foundation

struct InstalledExtension: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let root: URL
    var publisher: String = ""
    var iconURL: URL?
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

enum PreviewState: Equatable, Sendable {
    case loading
    case ready(document: URL, base: URL)
    case unavailable(String)
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
    @Published private(set) var previews: [String: PreviewState] = [:]
    @Published private(set) var viewerHTML: URL?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    private let extensionsDirOverride: URL?
    private let cachesDirOverride: URL?
    private var stagings: [String: Task<URL, Error>] = [:]

    init(extensionsDir: URL? = nil, cachesDir: URL? = nil) {
        self.extensionsDirOverride = extensionsDir
        self.cachesDirOverride = cachesDir
        reloadInstalled()

        guard cachesDir != nil || extensionsDir == nil else { return }
        let root = previewRoot
        Task.detached(priority: .utility) { ExtensionPreviewCache.evict(root: root) }
    }

    var extensionsDir: URL {
        extensionsDirOverride ?? GuiConfigStore.shared.extensionsDirURL
    }

    var cachesDir: URL {
        cachesDirOverride ?? GuiConfigStore.shared.cachesDirURL
    }

    var previewRoot: URL {
        ExtensionPreviewCache.root(cachesDir: cachesDir)
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
        activity[entry.id] = .verifying
        defer { activity[entry.id] = nil }

        let directory = extensionsDir
        do {
            let staged = try await stagedDirectory(for: entry)
            activity[entry.id] = .installing
            try await Task.detached(priority: .utility) {
                try ExtensionInstaller.install(from: staged, as: entry, into: directory)
            }.value
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

    // MARK: Preview

    func preview(_ entry: ExtensionIndex.Entry) async {
        let root = previewRoot
        let expected = ExtensionPreviewCache.directory(for: entry, root: root)
        guard shouldPreview(id: entry.id, expecting: expected) else { return }
        previews[entry.id] = .loading

        do {
            try await prepareViewer(in: root)
            let directory = try await stagedDirectory(for: entry)
            try await Task.detached(priority: .utility) {
                try ExtensionMediaGate.check(directory: directory)
            }.value
            previews[entry.id] = Self.previewState(directory: directory, root: root, preferring: entry.card?.document)
        } catch {
            previews[entry.id] = .unavailable(Self.message(for: error))
        }
    }

    func preview(installed: InstalledExtension) async {
        let root = previewRoot
        guard let manifest = LanguageManifest.load(directory: installed.root, scope: .user) else {
            previews[installed.id] = .unavailable(ExtensionPreviewCache.Failure.unreadableManifest.message)
            return
        }
        let expected = ExtensionPreviewCache.localDirectory(
            id: installed.id, version: installed.version, manifestDigest: manifest.digest, root: root)
        guard shouldPreview(id: installed.id, expecting: expected) else { return }
        previews[installed.id] = .loading

        do {
            try await prepareViewer(in: root)
            let digest = manifest.digest
            let directory = try await Task.detached(priority: .utility) {
                try ExtensionPreviewCache.mirror(installed: installed, manifestDigest: digest, root: root)
            }.value
            previews[installed.id] = Self.previewState(directory: directory, root: root)
        } catch {
            previews[installed.id] = .unavailable(Self.message(for: error))
        }
    }

    func forgetPreview(id: String) {
        previews[id] = nil
    }

    func iconURL(for entry: ExtensionIndex.Entry) -> URL? {
        let onDisk = installed.first { $0.id == entry.id }
        guard let icon = entry.card?.icon else { return onDisk?.iconURL }
        if case .ready(let document, _)? = previews[entry.id],
           let url = LanguageContribution.containedURL(icon, root: document.deletingLastPathComponent()) {
            return url
        }
        if let root = onDisk?.root, let url = LanguageContribution.containedURL(icon, root: root) {
            return url
        }
        return onDisk?.iconURL
    }

    private func shouldPreview(id: String, expecting directory: URL) -> Bool {
        switch previews[id] {
        case .loading:
            return false
        case .ready(let document, _):
            return document.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL
        case .unavailable, .none:
            return true
        }
    }

    private func prepareViewer(in root: URL) async throws {
        let viewer = try await Task.detached(priority: .utility) {
            try ExtensionViewerBundle.copyIfNeeded(into: root)
        }.value
        viewerHTML = ExtensionViewerBundle.html(in: viewer)
    }

    private func stagedDirectory(for entry: ExtensionIndex.Entry) async throws -> URL {
        if let running = stagings[entry.id] { return try await running.value }

        let root = previewRoot
        let verified = await Task.detached(priority: .utility) {
            ExtensionPreviewCache.verified(entry, root: root)
        }.value
        if let verified { return verified }

        let report: @MainActor @Sendable (ExtensionActivity) -> Void = { [weak self] step in
            guard let self, self.activity[entry.id] != nil else { return }
            self.activity[entry.id] = step
        }
        let staging = Task<URL, Error>.detached(priority: .utility) {
            try await ExtensionPreviewCache.stage(entry, root: root, progress: report)
        }
        stagings[entry.id] = staging
        defer { stagings[entry.id] = nil }
        return try await staging.value
    }

    nonisolated static func previewState(directory: URL, root: URL, preferring name: String? = nil) -> PreviewState {
        let names = [name].compactMap { $0 } + ExtensionCard.documentFileNames
        for candidate in names {
            let document = directory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: document.path) {
                return .ready(document: document, base: root)
            }
        }
        return .unavailable("The extension ships no document.")
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
        switch error {
        case let failure as ExtensionInstaller.Failure: return failure.message
        case let violation as ExtensionMediaGate.Violation: return violation.message
        case let failure as ExtensionPreviewCache.Failure: return failure.message
        case let failure as ExtensionViewerBundle.Failure: return failure.message
        default: return error.localizedDescription
        }
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
            .map {
                InstalledExtension(
                    id: $0.id, name: $0.name, version: $0.version, root: $0.root,
                    publisher: $0.publisher, iconURL: $0.languages.first?.iconURL)
            }
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

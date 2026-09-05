import Foundation

enum ExtensionPreviewCache {
    struct Marker: Codable, Equatable, Sendable {
        let sha256: String
        let bytes: Int
        let verifiedAt: Date
    }

    struct Cached: Equatable, Sendable {
        enum Area: Equatable, Sendable {
            case registry
            case local
        }

        let area: Area
        let id: String
        let directory: URL
        let marker: URL?
        let verifiedAt: Date
        let bytes: Int
    }

    enum Failure: Error, Equatable {
        case staging(String)
        case marker(String)
        case mirror(String)
        case unreadableManifest

        var message: String {
            switch self {
            case .staging(let reason):
                return "The extension could not be kept for preview: \(reason)"
            case .marker(let reason):
                return "The extension's verification record could not be written: \(reason)"
            case .mirror(let reason):
                return "The installed extension could not be copied for preview: \(reason)"
            case .unreadableManifest:
                return "The installed extension's manifest could not be read."
            }
        }
    }

    static let directoryName = "extensions"
    static let viewerDirectoryName = "viewer"
    static let registryDirectoryName = "registry"
    static let localDirectoryName = "local"
    static let stagingPrefix = ".staging-"
    static let markerExtension = "json"

    static let registryBudgetBytes = 256 * 1024 * 1024
    static let digestPrefixLength = 12
    static let staleStagingAge: TimeInterval = 24 * 60 * 60

    // MARK: Paths

    static func root(cachesDir: URL) -> URL {
        cachesDir.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func viewerDirectory(version: String, root: URL) -> URL {
        root.appendingPathComponent(viewerDirectoryName, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    static func registryDirectory(root: URL) -> URL {
        root.appendingPathComponent(registryDirectoryName, isDirectory: true)
    }

    static func localDirectory(root: URL) -> URL {
        root.appendingPathComponent(localDirectoryName, isDirectory: true)
    }

    static func registryName(for entry: ExtensionIndex.Entry) -> String {
        "\(entry.id)-\(entry.version)"
    }

    static func directory(for entry: ExtensionIndex.Entry, root: URL) -> URL {
        registryDirectory(root: root).appendingPathComponent(registryName(for: entry), isDirectory: true)
    }

    static func markerURL(for entry: ExtensionIndex.Entry, root: URL) -> URL {
        registryDirectory(root: root).appendingPathComponent(registryName(for: entry))
            .appendingPathExtension(markerExtension)
    }

    static func localName(id: String, version: String, manifestDigest: String) -> String {
        "\(id)-\(version)-\(manifestDigest.prefix(digestPrefixLength))"
    }

    static func localDirectory(id: String, version: String, manifestDigest: String, root: URL) -> URL {
        localDirectory(root: root)
            .appendingPathComponent(localName(id: id, version: version, manifestDigest: manifestDigest), isDirectory: true)
    }

    static func identity(ofRegistryName name: String) -> (id: String, version: String)? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let id = String(name[..<dash])
        let version = String(name[name.index(after: dash)...])
        guard LanguageManifest.validID(id) == id, SemanticVersion.isValid(version) else { return nil }
        return (id, version)
    }

    static func identity(ofLocalName name: String) -> (id: String, version: String, digest: String)? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let digest = String(name[name.index(after: dash)...])
        guard digest.count == digestPrefixLength, digest.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              let registry = identity(ofRegistryName: String(name[..<dash]))
        else { return nil }
        return (registry.id, registry.version, digest)
    }

    // MARK: Markers

    static func write(_ marker: Marker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(marker).write(to: url, options: .atomic)
        } catch {
            throw Failure.marker(error.localizedDescription)
        }
    }

    static func readMarker(_ url: URL) -> Marker? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(Marker.self, from: data),
              ExtensionIndex.Entry.digest(marker.sha256) == marker.sha256,
              marker.bytes > 0
        else { return nil }
        return marker
    }

    // MARK: Staging

    static func stage(
        _ entry: ExtensionIndex.Entry,
        root: URL,
        progress: @escaping @MainActor @Sendable (ExtensionActivity) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let registry = registryDirectory(root: root)
        let staging = registry.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw Failure.staging(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }

        await progress(.downloading(fraction: nil))
        let archive = staging.appendingPathComponent("archive.zip")
        try await ExtensionInstaller.fetch(entry, to: archive, progress: progress)

        await progress(.verifying)
        let tree = staging.appendingPathComponent("tree", isDirectory: true)
        try await ExtensionInstaller.stage(archive: archive, expecting: entry, into: tree)

        let destination = directory(for: entry, root: root)
        let marker = markerURL(for: entry, root: root)
        do {
            try? fileManager.removeItem(at: marker)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tree, to: destination)
        } catch {
            throw Failure.staging(error.localizedDescription)
        }
        try write(Marker(sha256: entry.sha256, bytes: entry.bytes, verifiedAt: Date()), to: marker)

        evict(root: root, keeping: [destination])
        return destination
    }

    static func verified(_ entry: ExtensionIndex.Entry, root: URL) -> URL? {
        let directory = directory(for: entry, root: root)
        guard let marker = readMarker(markerURL(for: entry, root: root)),
              marker.sha256 == entry.sha256,
              marker.bytes == entry.bytes,
              isDirectory(directory),
              (try? ExtensionInstaller.inspect(directory)) != nil,
              let manifest = LanguageManifest.load(directory: directory, scope: .user),
              manifest.id == entry.id,
              manifest.version == entry.version
        else { return nil }
        return directory
    }

    static func mirror(installed: InstalledExtension, manifestDigest: String, root: URL) throws -> URL {
        let destination = localDirectory(
            id: installed.id, version: installed.version, manifestDigest: manifestDigest, root: root)
        if isDirectory(destination), (try? ExtensionInstaller.inspect(destination)) != nil {
            return destination
        }

        try ExtensionInstaller.inspect(installed.root)
        try ExtensionMediaGate.check(directory: installed.root)

        let fileManager = FileManager.default
        let local = localDirectory(root: root)
        let staging = local.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: local, withIntermediateDirectories: true)
            try fileManager.copyItem(at: installed.root, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw Failure.mirror(error.localizedDescription)
        }

        evict(root: root, keeping: [destination])
        return destination
    }

    // MARK: Eviction

    static func evictionPlan(entries: [Cached], keeping: Set<URL>, budget: Int) -> [URL] {
        var doomed: [Cached] = []
        var survivors: [Cached] = []

        for area in [Cached.Area.registry, .local] {
            let inArea = entries.filter { $0.area == area }
            for (_, versions) in Dictionary(grouping: inArea, by: \.id) {
                let protected = versions.filter { keeping.contains($0.directory) }
                let usable = versions.filter { area == .local || $0.marker != nil }
                let kept = protected.isEmpty ? Array(usable.sorted(by: newestFirst).prefix(1)) : protected
                survivors += kept
                doomed += versions.filter { !kept.contains($0) }
            }
        }

        var total = survivors.filter { $0.area == .registry }.reduce(0) { $0 + $1.bytes }
        for cached in survivors.filter({ $0.area == .registry }).sorted(by: oldestFirst) where total > budget {
            guard !keeping.contains(cached.directory) else { continue }
            doomed.append(cached)
            total -= cached.bytes
        }

        return doomed
            .flatMap { [$0.directory] + ($0.marker.map { [$0] } ?? []) }
            .sorted { $0.path < $1.path }
    }

    static func scan(root: URL) -> [Cached] {
        scanRegistry(registryDirectory(root: root)) + scanLocal(localDirectory(root: root))
    }

    static func evict(root: URL, keeping: Set<URL> = []) {
        let fileManager = FileManager.default
        for url in evictionPlan(entries: scan(root: root), keeping: keeping, budget: registryBudgetBytes) {
            try? fileManager.removeItem(at: url)
        }
        removeOrphanMarkers(in: registryDirectory(root: root))
        for area in [registryDirectory(root: root), localDirectory(root: root),
                     root.appendingPathComponent(viewerDirectoryName, isDirectory: true)] {
            removeStaleStaging(in: area)
        }
    }

    private static func scanRegistry(_ registry: URL) -> [Cached] {
        subdirectories(of: registry).compactMap { directory in
            let name = directory.lastPathComponent
            guard let identity = identity(ofRegistryName: name) else { return nil }
            let markerURL = registry.appendingPathComponent(name).appendingPathExtension(markerExtension)
            guard let marker = readMarker(markerURL) else {
                return Cached(area: .registry, id: identity.id, directory: directory, marker: nil,
                              verifiedAt: .distantPast, bytes: 0)
            }
            return Cached(area: .registry, id: identity.id, directory: directory, marker: markerURL,
                          verifiedAt: marker.verifiedAt, bytes: marker.bytes)
        }
    }

    private static func scanLocal(_ local: URL) -> [Cached] {
        subdirectories(of: local).compactMap { directory in
            guard let identity = identity(ofLocalName: directory.lastPathComponent) else { return nil }
            let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Cached(area: .local, id: identity.id, directory: directory, marker: nil,
                          verifiedAt: modified, bytes: 0)
        }
    }

    private static func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { isDirectory($0) }
    }

    private static func removeOrphanMarkers(in registry: URL) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: registry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension == markerExtension && !isDirectory(url) {
            let directory = url.deletingPathExtension()
            if !isDirectory(directory) { try? fileManager.removeItem(at: url) }
        }
    }

    private static func removeStaleStaging(in directory: URL) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        let cutoff = Date().addingTimeInterval(-staleStagingAge)
        for url in entries where url.lastPathComponent.hasPrefix(stagingPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func newestFirst(_ lhs: Cached, _ rhs: Cached) -> Bool {
        if lhs.verifiedAt != rhs.verifiedAt { return lhs.verifiedAt > rhs.verifiedAt }
        return lhs.directory.lastPathComponent > rhs.directory.lastPathComponent
    }

    private static func oldestFirst(_ lhs: Cached, _ rhs: Cached) -> Bool {
        newestFirst(rhs, lhs)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

import Foundation

enum ExtensionViewerBundle {
    enum Failure: Error, Equatable {
        case missing
        case unreadableVersion
        case copy(String)

        var message: String {
            switch self {
            case .missing:
                return "This build has no document viewer."
            case .unreadableVersion:
                return "This build's document viewer does not say which version it is."
            case .copy(let reason):
                return "The document viewer could not be prepared: \(reason)"
            }
        }
    }

    static let directoryName = "extension-viewer"
    static let htmlFileName = "viewer.html"
    static let fileNames = ["viewer.html", "viewer.js", "viewer.css"]
    static let versionFileName = "VERSION"

    static var url: URL? {
        Bundle.main.url(forResource: "viewer", withExtension: "html", subdirectory: directoryName)
    }

    static var directory: URL? {
        url?.deletingLastPathComponent()
    }

    static var version: String? {
        version(in: directory)
    }

    static func version(in directory: URL?) -> String? {
        guard let directory,
              let text = try? String(contentsOf: directory.appendingPathComponent(versionFileName), encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SemanticVersion.isValid(trimmed) ? trimmed : nil
    }

    static func copyIfNeeded(into cacheRoot: URL) throws -> URL {
        guard let source = directory else { throw Failure.missing }
        guard let version = version(in: source) else { throw Failure.unreadableVersion }
        return try copy(from: source, version: version, into: cacheRoot)
    }

    static func copy(from source: URL, version: String, into cacheRoot: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = ExtensionPreviewCache.viewerDirectory(version: version, root: cacheRoot)
        if fileNames.allSatisfy({ fileManager.fileExists(atPath: destination.appendingPathComponent($0).path) }) {
            return destination
        }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ExtensionPreviewCache.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in fileNames {
                try fileManager.copyItem(
                    at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw Failure.copy(error.localizedDescription)
        }
        return destination
    }

    static func html(in viewerDirectory: URL) -> URL {
        viewerDirectory.appendingPathComponent(htmlFileName)
    }
}

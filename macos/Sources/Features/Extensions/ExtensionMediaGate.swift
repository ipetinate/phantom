import Foundation

enum ExtensionMediaGate {
    enum Kind: Equatable, Sendable {
        case image
        case animation
        case video
        case vector
    }

    enum Violation: Error, Equatable, Sendable {
        case unknownKind(String)
        case vectorOutsideIcon(String)
        case oversized(String, bytes: Int, limit: Int)
        case tooManyFiles(Int)
        case totalOversized(Int)
        case documentOversized(Int)
        case unreadable(String)

        var message: String {
            switch self {
            case .unknownKind(let path):
                return "The extension's media has a file type this app will not show: \(ExtensionArchive.shown(path))."
            case .vectorOutsideIcon(let path):
                return "The extension's media has an SVG that is not its icon: \(ExtensionArchive.shown(path))."
            case .oversized(let path, let bytes, let limit):
                return "\(ExtensionArchive.shown(path)) is \(bytes) bytes; the limit for its type is \(limit)."
            case .tooManyFiles(let count):
                return "The extension ships \(count) media files; the limit is \(ExtensionMediaGate.maxFiles)."
            case .totalOversized(let bytes):
                return "The extension's media adds up to \(bytes) bytes; the limit is \(ExtensionMediaGate.maxTotalBytes)."
            case .documentOversized(let bytes):
                return "The extension's document is \(bytes) bytes; the limit is \(ExtensionMediaGate.maxDocumentBytes)."
            case .unreadable(let path):
                return "The extension's media could not be read: \(ExtensionArchive.shown(path))."
            }
        }
    }

    static let mediaDirectoryName = "media"

    static let maxDocumentBytes = 256 * 1024
    static let maxImageBytes = 2 * 1024 * 1024
    static let maxAnimationBytes = 5 * 1024 * 1024
    static let maxVideoBytes = 12 * 1024 * 1024
    static let maxTotalBytes = 24 * 1024 * 1024
    static let maxFiles = 32

    static func kind(ofPath path: String) -> Kind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp": return .image
        case "gif": return .animation
        case "mp4", "webm": return .video
        case "svg": return .vector
        default: return nil
        }
    }

    static func limit(for kind: Kind) -> Int {
        switch kind {
        case .image, .vector: return maxImageBytes
        case .animation: return maxAnimationBytes
        case .video: return maxVideoBytes
        }
    }

    static func violation(media: [ExtensionCard.Media], icon: String?) -> Violation? {
        guard media.count <= maxFiles else { return .tooManyFiles(media.count) }

        var total = 0
        for item in media {
            guard let kind = kind(ofPath: item.path) else { return .unknownKind(item.path) }
            if kind == .vector, item.path != icon { return .vectorOutsideIcon(item.path) }
            let limit = limit(for: kind)
            guard item.bytes >= 0, item.bytes <= limit else {
                return .oversized(item.path, bytes: item.bytes, limit: limit)
            }
            total += item.bytes
        }
        guard total <= maxTotalBytes else { return .totalOversized(total) }
        return nil
    }

    static func check(directory: URL, icon: String?) throws {
        let document = directory.appendingPathComponent(ExtensionCard.documentFileName)
        if let size = fileSize(document), size > maxDocumentBytes {
            throw Violation.documentOversized(size)
        }

        let mediaDirectory = directory.appendingPathComponent(mediaDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { return }

        if let violation = violation(media: try listing(of: mediaDirectory), icon: icon) {
            throw violation
        }
    }

    static func listing(of mediaDirectory: URL) throws -> [ExtensionCard.Media] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: mediaDirectory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw Violation.unreadable(mediaDirectoryName) }

        let root = mediaDirectory.standardizedFileURL.path
        let prefixLength = root.count + 1
        var media: [ExtensionCard.Media] = []
        for case let item as URL in enumerator {
            let relative = mediaDirectoryName + "/" + String(item.standardizedFileURL.path.dropFirst(prefixLength))
            guard let values = try? item.resourceValues(forKeys: keys) else {
                throw Violation.unreadable(relative)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let bytes = values.fileSize else {
                throw Violation.unreadable(relative)
            }
            media.append(ExtensionCard.Media(path: relative, bytes: bytes))
        }
        return media.sorted { $0.path < $1.path }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

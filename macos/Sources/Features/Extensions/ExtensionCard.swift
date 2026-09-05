import Foundation

struct ExtensionCard: Equatable, Sendable {
    struct Author: Equatable, Sendable {
        let name: String
        let url: URL?
    }

    struct Media: Equatable, Sendable {
        let path: String
        let bytes: Int
    }

    let title: String
    let tagline: String
    let license: String
    let author: Author
    let created: Date
    let updated: Date?
    let icon: String?
    let cover: String?
    let tags: [String]
    let screenshots: [String]
    let document: String
    let documentBytes: Int
    let media: [Media]
    let mediaBytes: Int
}

extension ExtensionCard {
    static let documentFileName = "extension.mdx"
    static let documentFileNames = ["extension.mdx", "extension.md"]

    static let maxTags = 8
    static let maxScreenshots = 8
    static let maxMedia = 64

    static let maxTitleLength = 128
    static let maxTaglineLength = 512
    static let maxLicenseLength = 64
    static let maxTagLength = 32
    static let maxPathLength = 256

    static func parse(_ json: [String: Any]) -> ExtensionCard? {
        guard let title = text(json["title"], limit: maxTitleLength),
              let authorJSON = json["author"] as? [String: Any],
              let authorName = text(authorJSON["name"], limit: maxTitleLength),
              let created = date(json["created"]),
              let document = LanguageManifest.string(json["document"]),
              documentFileNames.contains(document),
              let documentBytes = ExtensionIndex.integer(json["documentBytes"]),
              documentBytes > 0, documentBytes <= ExtensionMediaGate.maxDocumentBytes,
              let mediaBytes = ExtensionIndex.integer(json["mediaBytes"]),
              mediaBytes >= 0, mediaBytes <= ExtensionMediaGate.maxTotalBytes
        else { return nil }

        guard let icon = optionalPath(json["icon"]),
              let cover = optionalPath(json["cover"]),
              let screenshots = pathList(json["screenshots"], limit: maxScreenshots),
              let media = mediaList(json["media"])
        else { return nil }

        guard ([icon, cover].compactMap { $0 } + screenshots).allSatisfy({ ExtensionMediaGate.kind(ofPath: $0) != nil }),
              ExtensionMediaGate.violation(media: media) == nil
        else { return nil }

        return ExtensionCard(
            title: title,
            tagline: text(json["tagline"], limit: maxTaglineLength) ?? "",
            license: text(json["license"], limit: maxLicenseLength) ?? "",
            author: Author(name: authorName, url: ExtensionIndex.Entry.secureURL(authorJSON["url"])),
            created: created,
            updated: date(json["updated"]),
            icon: icon,
            cover: cover,
            tags: tagList(json["tags"]),
            screenshots: screenshots,
            document: document,
            documentBytes: documentBytes,
            media: media,
            mediaBytes: mediaBytes
        )
    }

    static func relativePath(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= maxPathLength else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.hasSuffix("/"),
              !raw.contains(".."), !raw.contains("\\"),
              !raw.split(separator: "/").contains("."),
              ExtensionArchive.rejection(forEntry: raw) == nil
        else { return nil }
        return raw
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = LanguageManifest.string(value) else { return nil }
        if let instant = ISO8601DateFormatter().date(from: text) { return instant }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        return dayOnly.date(from: text)
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let raw = LanguageManifest.displayString(value) else { return nil }
        return String(raw.prefix(limit))
    }

    private static func optionalPath(_ value: Any?) -> String?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let path = relativePath(value) else { return nil }
        return .some(path)
    }

    private static func pathList(_ value: Any?, limit: Int) -> [String]? {
        guard let value, !(value is NSNull) else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var seen: Set<String> = []
        var paths: [String] = []
        for item in raw.prefix(limit) {
            guard let path = relativePath(item) else { return nil }
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    private static func mediaList(_ value: Any?) -> [Media]? {
        guard let value, !(value is NSNull) else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var seen: Set<String> = []
        var media: [Media] = []
        for item in raw.prefix(maxMedia) {
            guard let object = item as? [String: Any],
                  let path = relativePath(object["path"]),
                  let bytes = ExtensionIndex.integer(object["bytes"]),
                  bytes >= 0
            else { return nil }
            if seen.insert(path).inserted { media.append(Media(path: path, bytes: bytes)) }
        }
        return media
    }

    private static func tagList(_ value: Any?) -> [String] {
        let raw = (value as? [Any]) ?? []
        var seen: Set<String> = []
        return raw
            .compactMap { text($0, limit: maxTagLength) }
            .filter { seen.insert($0).inserted }
            .prefix(maxTags)
            .map { $0 }
    }
}

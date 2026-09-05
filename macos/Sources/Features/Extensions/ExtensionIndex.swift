import Foundation

struct ExtensionIndex: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let version: String
        let publisher: String
        let summary: String
        let homepage: URL?
        let minimumPhantomVersion: String?
        let contributes: [String]
        let languages: [String]
        let downloadURL: URL
        let sha256: String
        let bytes: Int
    }

    let generatedAt: Date?
    let repository: URL?
    let extensions: [Entry]
}

extension ExtensionIndex {
    enum ParseError: Error, Equatable {
        case notAnObject
        case missingSchemaVersion
        case unsupportedSchemaVersion(String)

        var message: String {
            switch self {
            case .notAnObject:
                return "its index is not a JSON object"
            case .missingSchemaVersion:
                return "its index declares no schema version"
            case .unsupportedSchemaVersion(let declared):
                return "its index uses schema version \(declared), which this Phantom cannot read"
            }
        }
    }

    static let currentSchemaVersion = 1

    static let maxBytes = 4 * 1024 * 1024

    static let maxArchiveBytes = 64 * 1024 * 1024

    static let maxEntries = 2048

    static func parse(_ data: Data) throws -> ExtensionIndex {
        guard data.count <= maxBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw ParseError.notAnObject }

        guard let declared = json["schemaVersion"] else { throw ParseError.missingSchemaVersion }
        guard integer(declared) == currentSchemaVersion else {
            throw ParseError.unsupportedSchemaVersion(String(describing: declared))
        }

        let rawEntries = json["extensions"] as? [Any] ?? []
        var seen: Set<String> = []
        let entries = rawEntries
            .prefix(maxEntries)
            .compactMap { $0 as? [String: Any] }
            .compactMap(Entry.parse)
            .filter { seen.insert($0.id).inserted }

        return ExtensionIndex(
            generatedAt: date(json["generatedAt"]),
            repository: LanguageServerContribution.documentationURL(json["repository"]),
            extensions: entries
        )
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = LanguageManifest.string(value) else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

extension ExtensionIndex.Entry {
    static let maxListItems = 64

    static func parse(_ json: [String: Any]) -> ExtensionIndex.Entry? {
        guard let id = LanguageManifest.validID(json["id"]),
              let name = LanguageManifest.displayString(json["name"]),
              let version = LanguageManifest.string(json["version"]),
              SemanticVersion.isValid(version),
              let publisher = LanguageManifest.displayString(json["publisher"]),
              let download = json["download"] as? [String: Any],
              let downloadURL = secureURL(download["url"]),
              let sha256 = digest(download["sha256"]),
              let bytes = ExtensionIndex.integer(download["bytes"]),
              bytes > 0, bytes <= ExtensionIndex.maxArchiveBytes
        else { return nil }

        return ExtensionIndex.Entry(
            id: id,
            name: name,
            version: version,
            publisher: publisher,
            summary: LanguageManifest.displayString(json["description"]) ?? "",
            homepage: LanguageServerContribution.documentationURL(json["homepage"]),
            minimumPhantomVersion: LanguageManifest.string(json["phantom"])
                .flatMap { SemanticVersion.isValid($0) ? $0 : nil },
            contributes: displayList(json["contributes"]),
            languages: languageList(json["languages"]),
            downloadURL: downloadURL,
            sha256: sha256,
            bytes: bytes
        )
    }

    static func secureURL(_ value: Any?) -> URL? {
        guard let url = LanguageServerContribution.documentationURL(value),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    static func digest(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value)?.lowercased(), raw.count == 64 else { return nil }
        guard raw.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return raw
    }

    private static func displayList(_ value: Any?) -> [String] {
        let raw = (value as? [Any]) ?? []
        var seen: Set<String> = []
        return raw
            .compactMap { LanguageManifest.displayString($0) }
            .filter { seen.insert($0).inserted }
            .prefix(maxListItems)
            .map { $0 }
    }

    private static func languageList(_ value: Any?) -> [String] {
        let raw = (value as? [Any]) ?? []
        var seen: Set<String> = []
        return raw
            .compactMap { LanguageContribution.validLanguageID($0) }
            .filter { seen.insert($0).inserted }
            .prefix(maxListItems)
            .map { $0 }
    }
}

import Foundation

enum ExtensionViewerMessage: Equatable, Sendable {
    case ready(version: String)
    case rendered(warnings: [String])
    case failed(message: String, line: Int?, column: Int?)
    case open(URL)

    static let maxWarnings = 32
    static let maxMessageLength = 512

    static func parse(_ body: Any) -> ExtensionViewerMessage? {
        guard let object = body as? [String: Any],
              let type = LanguageManifest.string(object["type"])
        else { return nil }

        switch type {
        case "ready":
            guard let version = LanguageManifest.string(object["version"]), SemanticVersion.isValid(version) else {
                return nil
            }
            return .ready(version: version)

        case "rendered":
            let raw = (object["warnings"] as? [Any]) ?? []
            let warnings = raw.prefix(maxWarnings).compactMap { text($0) }
            return .rendered(warnings: warnings)

        case "failed":
            guard let message = text(object["message"]) else { return nil }
            return .failed(message: message, line: position(object["line"]), column: position(object["column"]))

        case "open":
            guard let href = openableURL(object["href"]) else { return nil }
            return .open(href)

        default:
            return nil
        }
    }

    static func openableURL(_ value: Any?) -> URL? {
        if let secure = ExtensionIndex.Entry.secureURL(value) { return secure }
        guard let raw = LanguageManifest.string(value),
              case .allow(let url) = UntrustedURL(raw).decision,
              url.scheme?.lowercased() == "mailto"
        else { return nil }
        return url
    }

    private static func text(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.displayString(value) else { return nil }
        return String(raw.prefix(maxMessageLength))
    }

    private static func position(_ value: Any?) -> Int? {
        guard let number = ExtensionIndex.integer(value), number >= 0 else { return nil }
        return number
    }
}

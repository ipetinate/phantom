import Foundation

enum ExtensionArchive {
    enum EntryRejection: Equatable, Sendable {
        case empty
        case absolute(String)
        case parentReference(String)
        case unsafeCharacter(String)

        var message: String {
            switch self {
            case .empty:
                return "The archive lists an entry with no name."
            case .absolute(let path):
                return "The archive contains an absolute path: \(ExtensionArchive.shown(path))."
            case .parentReference(let path):
                return "The archive contains a path that leaves its root: \(ExtensionArchive.shown(path))."
            case .unsafeCharacter(let path):
                return "The archive contains a path this app will not write: \(ExtensionArchive.shown(path))."
            }
        }
    }

    static let manifestFileName = LanguageManifest.fileName

    static func rejection(forEntry path: String) -> EntryRejection? {
        guard !path.isEmpty else { return .empty }
        guard !path.hasPrefix("/") else { return .absolute(path) }
        guard !path.contains("\\"),
              !path.unicodeScalars.contains(where: UntrustedURL.isUnsafeDisplayScalar)
        else { return .unsafeCharacter(path) }
        guard !path.split(separator: "/").contains("..") else { return .parentReference(path) }
        return nil
    }

    static func firstRejection(in entries: [String]) -> EntryRejection? {
        for entry in entries {
            if let rejection = rejection(forEntry: entry) { return rejection }
        }
        return nil
    }

    static func hasManifestAtRoot(_ entries: [String]) -> Bool {
        entries.contains { entry in
            entry == manifestFileName || entry == "./" + manifestFileName
        }
    }

    static func entries(fromListing text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func isContained(path: String, inDirectory root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    static func shown(_ path: String) -> String {
        let escaped = UntrustedURL.escapingUnsafeScalars(path)
        return escaped.count <= 80 ? escaped : String(escaped.prefix(77)) + "..."
    }
}

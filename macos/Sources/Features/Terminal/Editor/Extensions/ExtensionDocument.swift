import Foundation

struct ExtensionDocument: Identifiable, Equatable, Sendable {
    static let scheme = "phantom-extension"
    static let symbol = "puzzlepiece.extension"

    let extensionID: String
    let title: String

    init(extensionID: String, title: String) {
        self.extensionID = extensionID
        self.title = title
    }

    init(entry: ExtensionIndex.Entry) {
        self.init(extensionID: entry.id, title: entry.card?.title ?? entry.name)
    }

    init(installed: InstalledExtension) {
        self.init(extensionID: installed.id, title: installed.name)
    }

    var id: String { path }

    var path: String { Self.path(for: extensionID) }

    var tab: EditorTab { EditorTab(path: path, title: title, symbol: Self.symbol) }

    static func path(for extensionID: String) -> String {
        scheme + "://" + extensionID
    }

    static func extensionID(fromPath path: String) -> String? {
        let prefix = scheme + "://"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        return LanguageManifest.validID(id) == id ? id : nil
    }
}

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

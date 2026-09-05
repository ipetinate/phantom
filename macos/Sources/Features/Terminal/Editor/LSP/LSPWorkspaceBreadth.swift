import Foundation

enum LSPWorkspaceBreadth {
    static let childScanLimit = 200

    nonisolated static func isTooBroad(_ path: String, children: [String]? = nil) -> Bool {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        if folder == "/" { return true }
        if folder == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return true
        }
        if isRepository(folder) { return false }

        let names = children ?? directChildren(of: folder)
        return names.prefix(childScanLimit).contains { name in
            isRepository(folder + "/" + name)
        }
    }

    nonisolated private static func isRepository(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: folder + "/.git")
    }

    nonisolated private static func directChildren(of folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }
}

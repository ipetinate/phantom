import Foundation

/// Why a file operation failed, as a string a person can read.
struct FileExplorerError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// The file operations the explorer offers: rename, move, delete, create.
///
/// Pure and synchronous so the model can call them directly and hand the
/// result straight to the UI. Each returns a user-readable message on
/// failure rather than throwing, because every call site wants the same
/// thing — show the error — and that keeps the model from needing its own
/// error vocabulary.
enum FileExplorerFilesystem {
    /// Renames the file or folder at `url` to `newName`, keeping it in the
    /// same directory. Returns the new URL.
    static func rename(_ url: URL, to newName: String) -> Result<URL, FileExplorerError> {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard validate(name: name) else {
            return .failure(FileExplorerError("“\(newName)” isn't a valid name."))
        }

        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != url.path else { return .success(url) }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileExplorerError("A file or folder named “\(name)” already exists."))
        }

        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// Moves the file or folder at `url` into `directory`, keeping its name.
    /// Returns the new URL.
    static func move(_ url: URL, into directory: URL) -> Result<URL, FileExplorerError> {
        let target = directory.appendingPathComponent(url.lastPathComponent)
        guard target.path != url.path else { return .success(url) }

        // Dropping a folder into itself (or into one of its own children)
        // would destroy it. The filesystem would eventually refuse, but
        // only after having moved some of the tree — check first.
        if isDirectory(url), target.path.hasPrefix(url.path + "/") {
            return .failure(FileExplorerError("A folder can't be moved inside itself."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileExplorerError(
                "A file or folder named “\(url.lastPathComponent)” already exists there."
            ))
        }

        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// Sends the item to the Trash, the macOS-correct delete: recoverable,
    /// which is what a stray delete key in a sidebar should be.
    static func delete(_ url: URL) -> Result<Void, FileExplorerError> {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .success(())
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// Creates an empty file.
    static func createFile(at url: URL) -> Result<URL, FileExplorerError> {
        guard validate(name: url.lastPathComponent) else {
            return .failure(FileExplorerError("“\(url.lastPathComponent)” isn't a valid name."))
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return .failure(FileExplorerError(
                "A file or folder named “\(url.lastPathComponent)” already exists."
            ))
        }

        do {
            try Data().write(to: url, options: [])
            return .success(url)
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// Creates an empty folder.
    static func createFolder(at url: URL) -> Result<URL, FileExplorerError> {
        guard validate(name: url.lastPathComponent) else {
            return .failure(FileExplorerError("“\(url.lastPathComponent)” isn't a valid name."))
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return .failure(FileExplorerError(
                "A file or folder named “\(url.lastPathComponent)” already exists."
            ))
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .success(url)
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// The first unused variant of `url`: "untitled.txt" becomes
    /// "untitled 2.txt" when the first already exists, and so on.
    static func uniqueName(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = url.pathExtension

        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// The name the explorer should prefill when creating an item.
    static func proposedName(isFolder: Bool) -> String {
        isFolder ? "untitled folder" : "untitled.txt"
    }

    private static func validate(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains(":")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}

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
        guard !FileManager.default.fileExists(atPath: target.path) || isSameFile(url, target) else {
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

    /// Copies the file or folder at `url` into `directory`, keeping its
    /// name and leaving the original where it was. Returns the new URL.
    ///
    /// What a drag from outside the tree does. See `isInside(_:root:)`.
    static func copy(_ url: URL, into directory: URL) -> Result<URL, FileExplorerError> {
        let target = directory.appendingPathComponent(url.lastPathComponent)
        guard target.path != url.path else { return .success(url) }

        if isDirectory(url), target.path.hasPrefix(url.path + "/") {
            return .failure(FileExplorerError("A folder can't be copied inside itself."))
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .failure(FileExplorerError(
                "A file or folder named “\(url.lastPathComponent)” already exists there."
            ))
        }

        do {
            try FileManager.default.copyItem(at: url, to: target)
            return .success(target)
        } catch {
            return .failure(FileExplorerError(error.localizedDescription))
        }
    }

    /// Whether a dropped item already belongs to the tree it was dropped
    /// into.
    ///
    /// Dragging within the tree is a move: rearranging a project is the
    /// whole point of the gesture. Dragging in from Finder is a copy —
    /// nothing about dropping a file into a sidebar says "and take it out
    /// of my Downloads folder", and a move there is a change to somebody
    /// else's window that nobody asked for and no one confirmed.
    static func isInside(_ url: URL, root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let base = root.hasSuffix("/") ? root : root + "/"
        return url.path == root || url.path.hasPrefix(base)
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

    /// Creates an empty file called `name` inside `directory`.
    ///
    /// The name is checked *before* it becomes a URL. `appendingPathComponent`
    /// consumes the separators — "../escape.txt" arrives at `createFile(at:)`
    /// with a `lastPathComponent` of "escape.txt", which passes every check
    /// while pointing one directory above the tree. The typed string is the
    /// only place the traversal is still visible.
    static func createFile(named name: String, in directory: URL) -> Result<URL, FileExplorerError> {
        guard case .success(let url) = target(named: name, in: directory) else {
            return .failure(FileExplorerError("“\(name)” isn't a valid name."))
        }
        return createFile(at: url)
    }

    /// Creates an empty folder called `name` inside `directory`. Same
    /// name-before-URL rule as `createFile(named:in:)`.
    static func createFolder(named name: String, in directory: URL) -> Result<URL, FileExplorerError> {
        guard case .success(let url) = target(named: name, in: directory) else {
            return .failure(FileExplorerError("“\(name)” isn't a valid name."))
        }
        return createFolder(at: url)
    }

    private static func target(named name: String, in directory: URL) -> Result<URL, FileExplorerError> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard validate(name: trimmed) else {
            return .failure(FileExplorerError("“\(name)” isn't a valid name."))
        }
        return .success(directory.appendingPathComponent(trimmed))
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

    /// Whether two paths name the very same file on disk.
    ///
    /// The default macOS volume is case-insensitive, so "readme.md" and
    /// "README.md" are two spellings of one file: the existence check alone
    /// reads a case-only rename as a collision with itself and refuses the
    /// one rename Finder performs happily. Identity — the volume's own file
    /// id — is what "already taken" has to mean here, not spelling.
    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return left.isEqual(right)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}

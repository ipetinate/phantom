import Foundation

/// Answers "does git have changes for this file", which is what decides
/// whether a document is offered a diff.
///
/// Pure statics over values the caller already holds, rather than a lookup
/// inside `GitCenter`: this runs from `body`, and the rule about which
/// repository owns a path is the kind of thing that deserves a test more
/// than it deserves a home next to the process spawning.
enum EditorChangeLookup {
    /// Which of the known repository roots owns a path.
    ///
    /// The **longest** match wins, which is the whole reason this is not a
    /// one-line `first(where:)`. A workspace with a submodule has a file
    /// under both roots, and it is the inner repository that knows the file
    /// changed — the outer one reports the submodule as one lump. Picking
    /// the first match would answer correctly or not depending on
    /// dictionary order, which is to say: differently on each launch.
    static func owningRoot(forPath path: String, amongRoots roots: [String]) -> String? {
        roots
            .filter { isDescendant(path: path, ofRoot: $0) }
            .max(by: { $0.count < $1.count })
    }

    /// Prefix comparison at a path-component boundary, so `/tmp/app` does
    /// not claim `/tmp/apple/main.swift`.
    static func isDescendant(path: String, ofRoot root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == base || path.hasPrefix(base + "/")
    }

    /// The path as git names it: relative to the repository root.
    static func relativePath(forPath path: String, root: String) -> String? {
        guard isDescendant(path: path, ofRoot: root) else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path != base else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// The repository a file is in, found by walking up from it.
    ///
    /// Needed because `owningRoot` can only choose among roots git has
    /// already been asked about, and until the Git panel is opened that
    /// list is empty. Without this, whether a file offers a diff would
    /// depend on whether the reader had happened to look at the sidebar
    /// first.
    ///
    /// `.git` is tested for existence rather than for being a directory: in
    /// a worktree or a submodule it is a *file* containing a `gitdir:`
    /// pointer, and treating those as "not a repository" would quietly
    /// exclude exactly the checkouts people do parallel work in.
    ///
    /// - Parameter maximumDepth: a walk that cannot run away. A path is
    ///   arbitrary user input and this runs from `body`.
    static func repositoryRoot(
        forPath path: String,
        maximumDepth: Int = 64,
        fileManager: FileManager = .default
    ) -> String? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()

        for _ in 0..<maximumDepth {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }

        return nil
    }

    /// The entry git holds for this path, and which side of the index it
    /// is on.
    ///
    /// Unstaged is preferred when a file is in both lists — an `MM` file
    /// has two different diffs, and the working tree is the one the reader
    /// is looking at in the pane beside it.
    static func change(relativePath: String, in status: GitStatus) -> (change: GitFileChange, side: GitDiffSide)? {
        if let unstaged = status.unmerged.first(where: { matches($0, relativePath) }) {
            return (unstaged, .unstaged)
        }
        if let unstaged = status.unstaged.first(where: { matches($0, relativePath) && !$0.isUntracked }) {
            return (unstaged, .unstaged)
        }
        if let staged = status.staged.first(where: { matches($0, relativePath) }) {
            return (staged, .staged)
        }
        return nil
    }

    private static func matches(_ change: GitFileChange, _ relativePath: String) -> Bool {
        change.path == relativePath || change.originalPath == relativePath
    }

    /// Whether the status reports this path as changed in any way that a
    /// diff could show.
    ///
    /// Untracked files are **excluded** deliberately: there is no revision
    /// to compare against, so "show me the changes" would render the whole
    /// file as additions, which tells the reader nothing they were not
    /// already looking at.
    ///
    /// A renamed file matches on `originalPath` too — after `git mv` the
    /// entry names the destination, and it is precisely then that a reader
    /// wants to see what else changed along with the move.
    static func hasChanges(relativePath: String, in status: GitStatus) -> Bool {
        let candidates = status.staged + status.unstaged + status.unmerged
        return candidates.contains { change in
            guard !change.isUntracked else { return false }
            return change.path == relativePath || change.originalPath == relativePath
        }
    }
}

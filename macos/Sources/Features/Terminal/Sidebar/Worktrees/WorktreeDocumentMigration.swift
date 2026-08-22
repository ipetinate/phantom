import Foundation

/// What happens to each open document when a terminal moves from one
/// worktree to another.
///
/// A pure decision, taken before anything is closed or reopened, because the
/// answer is the whole contract the flow promises the reader: *files you
/// saved come with you; files you didn't stay behind*. That sentence has to
/// be true of every document on screen, and a rule spread across a view's
/// `onChange` handlers is one nobody can check.
///
/// The switch is a `cd` in a shell — the same file, one directory tree over.
/// Nothing moves on disk and nothing is written here.
enum WorktreeDocumentMigration {
    enum Outcome: Equatable {
        /// Clean, and the same relative path exists under the new root. The
        /// tab follows the terminal.
        case migrate(from: String, to: String)

        /// Has unsaved edits, so it stays open on the file it was edited
        /// against.
        ///
        /// Never migrated, and this is the one rule with teeth. The buffer
        /// holds work written against *this* checkout; carrying it to the
        /// other one and saving there would write one branch's edits into
        /// another branch's file, silently, with no diff to explain it. A
        /// reader who wants those edits on the new branch saves first — the
        /// popover offers exactly that, one row per file.
        case stayDirty(path: String)

        /// Clean, but the new root has no such file: it was added on the
        /// branch this tab is already on.
        ///
        /// Stays open, read-only. Reopening at the missing path would show
        /// an empty buffer that saves into existence a file the reader never
        /// created.
        case stayMissing(path: String)

        /// Open from somewhere else entirely — another repository, another
        /// worktree, a scratch file in `/tmp`. Outside the promise, and
        /// untouched.
        case unrelated(path: String)

        /// The document this outcome is about, whichever case it is.
        var path: String {
            switch self {
            case .migrate(let from, _): return from
            case .stayDirty(let path), .stayMissing(let path), .unrelated(let path):
                return path
            }
        }
    }

    /// - Parameters:
    ///   - documents: every open document, dirty flag included. Passed in
    ///     rather than read off `EditorCenter` so the rule can be exercised
    ///     without an editor.
    ///   - sourceRoot: the worktree the terminal is leaving.
    ///   - targetRoot: the worktree it is going to.
    ///
    /// Returns one outcome per document, in the order given, so a caller can
    /// pair them back up positionally as well as by path.
    ///
    /// An empty answer means there is no work: no roots, or a target that is
    /// where the terminal already is. That second case is worth short-
    /// circuiting rather than letting it fall through as a migration from a
    /// path to itself — the mechanism would close and reopen every tab to
    /// arrive exactly where it started, losing scroll position and undo
    /// history to accomplish nothing.
    nonisolated static func plan(
        documents: [(path: String, isDirty: Bool)],
        from sourceRoot: String,
        to targetRoot: String,
        fileManager: FileManager = .default
    ) -> [Outcome] {
        let source = normalized(sourceRoot)
        let target = normalized(targetRoot)
        guard !source.isEmpty, !target.isEmpty, source != target else { return [] }

        return documents.map { document in
            guard let relative = EditorChangeLookup.relativePath(
                forPath: document.path, root: source)
            else { return .unrelated(path: document.path) }

            /// Dirty is checked before the destination exists, because the
            /// answer does not depend on it. A file with unsaved edits stays
            /// whether or not the other branch has one by that name, and
            /// reporting `stayMissing` for it would offer the reader a
            /// read-only banner about a buffer they are still typing into.
            if document.isDirty { return .stayDirty(path: document.path) }

            let destination = (target as NSString).appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: destination) else {
                return .stayMissing(path: document.path)
            }

            return .migrate(from: document.path, to: destination)
        }
    }

    /// The documents that will actually be reopened, which is what the
    /// caller loops over once the reader confirms.
    nonisolated static func migrations(in outcomes: [Outcome]) -> [(from: String, to: String)] {
        outcomes.compactMap {
            guard case .migrate(let from, let to) = $0 else { return nil }
            return (from: from, to: to)
        }
    }

    /// The documents the popover has to say something about before the
    /// switch: the ones staying behind for a reason the reader chose, and
    /// the ones staying behind because the branch has nothing to show.
    ///
    /// `unrelated` is deliberately absent. A file open from another
    /// repository is not affected by this switch, and listing it would ask
    /// the reader to make a decision about something that is not changing.
    nonisolated static func staying(in outcomes: [Outcome]) -> [Outcome] {
        outcomes.filter {
            switch $0 {
            case .stayDirty, .stayMissing: return true
            case .migrate, .unrelated: return false
            }
        }
    }

    /// Trailing separators removed so `/repo/` and `/repo` are one root.
    ///
    /// Only that, and on purpose: `standardizedFileURL` and
    /// `resolvingSymlinksInPath` both rewrite `/private/var` paths, in
    /// opposite directions, and these roots come from `git worktree list`,
    /// which has its own spelling. Comparing what git said against what git
    /// said needs no normalization beyond the slash.
    private static func normalized(_ root: String) -> String {
        root.hasSuffix("/") ? String(root.dropLast()) : root
    }
}

import Foundation

/// Whether the file on screen belongs to a different checkout than the
/// terminal it is being read beside.
///
/// The state this describes is what ``WorktreeDocumentMigration`` leaves
/// behind. A terminal moves from one worktree to another, the clean
/// documents follow it, and two kinds do not: `stayDirty`, because the
/// buffer holds work written against the checkout being left, and
/// `stayMissing`, because the checkout being entered has no file at that
/// path. Both end in the same place — a tab showing one branch's file above
/// another branch's shell — and neither is visible on screen without being
/// told.
///
/// A type of its own, rather than a computed property on the pane, because
/// of the one case that must *not* fire: a file open from an unrelated
/// repository. That file is also "not from the terminal's worktree", and
/// warning about it would be wrong twice over — nothing switched, and there
/// is no other copy of it to offer. Two checkouts are the same repository
/// when ``GitCommonDir/resolve(from:fileManager:)`` gives them the same
/// answer, and telling that apart from "two different repositories" is a
/// rule with a right and a wrong answer, so it lives somewhere it can be
/// tested.
enum WorktreeDivergence {
    /// A document and its terminal, in two checkouts of one repository.
    struct Verdict: Equatable {
        /// The checkout the document is in.
        let documentRoot: String

        /// Its branch, or nil when git could not name one — a detached HEAD
        /// or an unreadable `HEAD`.
        let documentBranch: String?

        /// The checkout the terminal is in now.
        let terminalRoot: String

        let terminalBranch: String?

        /// The document's path relative to its own checkout: the one thing
        /// the two checkouts have in common, and the only honest way to talk
        /// about "the same file over there".
        let relativePath: String

        /// That same relative path under the terminal's checkout, when a
        /// file is actually there.
        ///
        /// Nil is the `stayMissing` situation: the file exists on the branch
        /// this tab came from and nowhere else. Existence is resolved here
        /// rather than by the view because it decides two separate things —
        /// whether there is a copy to offer, and whether this buffer may be
        /// edited at all — and those two must never disagree.
        let counterpart: String?

        /// Whether the buffer must be shown read-only.
        ///
        /// True exactly when there is no counterpart. A document that
        /// reached this state was *clean* — a dirty one is `stayDirty`,
        /// which keeps a file that does exist under its own root — so
        /// letting it be edited would create unsaved work on a branch the
        /// reader has already walked away from, invisible from the terminal
        /// beside it, and impossible to carry forward: the branch they are
        /// now on has no file for those edits to land in.
        var isReadOnly: Bool { counterpart == nil }

        /// What to call the document's checkout in a sentence.
        var documentName: String {
            WorktreeDivergence.name(ofRoot: documentRoot, branch: documentBranch)
        }

        var terminalName: String {
            WorktreeDivergence.name(ofRoot: terminalRoot, branch: terminalBranch)
        }
    }

    /// - Parameters:
    ///   - documentPath: the open file.
    ///   - terminalDirectory: the working directory of the terminal that
    ///     owns this pane, or nil while it has not reported one. A surface
    ///     that has never sent OSC 7 has no working directory, and there is
    ///     nothing to compare against.
    ///
    /// Nil means "say nothing", which is the answer in every ordinary
    /// situation: the file is in the tree the shell is in, or it is a scratch
    /// file, or it belongs to another project entirely.
    ///
    /// Branch names come from ``SidebarTabManager/gitInfo(for:)`` — the same
    /// reader the sidebar's tab rows use, walking up to `.git` and reading
    /// `HEAD` with no git execution. Deliberately that one and not a second
    /// implementation: a banner naming a branch and a tab row naming a
    /// branch must not be able to disagree, and this runs from `body`.
    nonisolated static func verdict(
        documentPath: String,
        terminalDirectory: String?,
        fileManager: FileManager = .default
    ) -> Verdict? {
        guard let terminalDirectory, !terminalDirectory.isEmpty, !documentPath.isEmpty
        else { return nil }

        /// The ordinary case, settled without touching the disk. A file
        /// inside the directory the shell is in cannot be in another
        /// checkout of that directory — the worst it can be is a nested
        /// repository or a submodule, and neither of those shares an object
        /// store with the tree it sits in, so neither is divergent either.
        /// Worth a string comparison: this runs for every open tab on every
        /// update of the tab bar, and it is the answer nearly every time.
        guard !EditorChangeLookup.isDescendant(path: documentPath, ofRoot: terminalDirectory)
        else { return nil }

        let documentDirectory = (documentPath as NSString).deletingLastPathComponent
        guard let document = SidebarTabManager.gitInfo(for: documentDirectory),
              let terminal = SidebarTabManager.gitInfo(for: terminalDirectory),
              document.root != terminal.root
        else { return nil }

        /// The family test, and the whole reason this is not a path
        /// comparison. Two roots differing proves only that they are two
        /// checkouts; it takes the shared git directory to say they are two
        /// checkouts *of the same repository*, which is the difference
        /// between a worktree switch the reader just performed and a file
        /// they happen to have open from another project.
        guard let family = GitCommonDir.resolve(from: document.root, fileManager: fileManager),
              family == GitCommonDir.resolve(from: terminal.root, fileManager: fileManager),
              let relative = EditorChangeLookup.relativePath(
                forPath: documentPath, root: document.root)
        else { return nil }

        let counterpart = (terminal.root as NSString).appendingPathComponent(relative)

        return Verdict(
            documentRoot: document.root,
            documentBranch: document.branch,
            terminalRoot: terminal.root,
            terminalBranch: terminal.branch,
            relativePath: relative,
            counterpart: fileManager.fileExists(atPath: counterpart) ? counterpart : nil)
    }

    /// A checkout named the way a reader thinks of it: its branch, or its
    /// folder when there is no branch to give.
    ///
    /// The folder rather than nothing for a detached HEAD, and rather than
    /// the abbreviated hash `gitInfo` would hand over for one. A worktree's
    /// folder name is `<repo>-<branch>` by construction here — see
    /// ``WorktreePath/folderName(mainCheckout:branch:)`` — so it still tells
    /// the reader which checkout is meant, where seven hex characters would
    /// only tell them that something is wrong.
    nonisolated static func name(ofRoot root: String, branch: String?) -> String {
        if let branch, !branch.isEmpty, !isAbbreviatedHash(branch) { return branch }
        return (root as NSString).lastPathComponent
    }

    /// Whether a "branch" is really the short hash `gitInfo` falls back to
    /// on a detached HEAD. Seven lowercase hex characters, which is the
    /// prefix length it takes.
    private static func isAbbreviatedHash(_ branch: String) -> Bool {
        branch.count == 7 && branch.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

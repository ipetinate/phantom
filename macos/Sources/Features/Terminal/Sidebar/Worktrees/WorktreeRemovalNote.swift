import Foundation

/// What removing a worktree costs, said so a person can find each cost.
///
/// One line per consequence, bulleted, with the folder on a line of its own.
/// The version this replaces joined four sentences with single newlines and
/// led with an absolute path that wrapped over three lines — technically
/// complete, and read as a block nobody could pick apart under a dialog they
/// wanted to dismiss.
///
/// Pure so the wording and the plurals can be checked without a repository:
/// every clause here counts something, and "1 terminals are working" is the
/// kind of thing that survives a hundred manual passes.
enum WorktreeRemovalNote {
    /// - Parameters:
    ///   - path: the worktree's folder. Only its last component is shown —
    ///     the panel is already listing this worktree, and the enclosing
    ///     directories are the same for every row in it.
    ///   - isDirty: the working tree has uncommitted changes.
    ///   - terminalCount: how many terminals are working in it.
    ///   - unsavedFiles: open documents with unsaved edits, by full path.
    static func message(
        path: String,
        isDirty: Bool,
        terminalCount: Int,
        unsavedFiles: [String]
    ) -> String {
        var bullets: [String] = []

        if isDirty {
            bullets.append("• It has uncommitted changes.")
        }

        /// The terminals are not named. Their names come from the working
        /// directory, so in this worktree they are all the folder this
        /// dialog already names — three repetitions of the title.
        if terminalCount > 0 {
            let noun = terminalCount == 1 ? "terminal stays" : "terminals stay"
            bullets.append(
                "• \(terminalCount) \(noun) open, in a folder that no longer exists.")
        }

        /// Named rather than offered a Save button, which is the one thing
        /// this must not do: saving writes into the folder about to be
        /// deleted, so it would look like rescuing the edits while changing
        /// nothing about their fate.
        if !unsavedFiles.isEmpty {
            let names = unsavedFiles.map { ($0 as NSString).lastPathComponent }
            let shown = names.prefix(3).joined(separator: ", ")
            let rest = names.count > 3 ? " and \(names.count - 3) more" : ""
            let verb = names.count == 1 ? "has" : "have"
            bullets.append(
                "• \(shown)\(rest) \(verb) unsaved edits. Removing discards them.")
        }

        let folder = (path as NSString).lastPathComponent
        guard !bullets.isEmpty else { return folder }
        return folder + "\n\n" + bullets.joined(separator: "\n")
    }
}

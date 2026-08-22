import Foundation

/// Moving one terminal to another worktree.
///
/// Two things happen, and the order is the point: the shell `cd`s, then the
/// editor tabs that can follow, follow. Nothing is stored anywhere about
/// which worktree the tab "is in" — that fact lives in the shell's working
/// directory and is read back from it, which is what keeps the panel, the
/// chip and this flow from ever disagreeing.
enum WorktreeMigrate {
    /// - Parameter plan: the outcomes the reader saw and confirmed. Passed
    ///   through rather than recomputed here, so what happens is what the
    ///   popover said would happen.
    @MainActor
    static func perform(
        to worktree: GitWorktree,
        plan: [WorktreeDocumentMigration.Outcome],
        tab: SidebarTabModel,
        editorCenter: EditorCenter
    ) {
        guard let surface = AgentLauncher.surface(for: tab) else { return }

        /// The terminal first, because that is the thing the reader asked
        /// for and the slower of the two: `ClaudeSession.run` waits for the
        /// shell to have a foreground process before typing, since a command
        /// sent to a shell that has not finished starting is dropped.
        ///
        /// It types `cd` at a prompt, which is why the button that gets here
        /// is hidden unless the terminal is at one — see
        /// `WorktreeEntryRule`.
        ClaudeSession.run("cd \(FileOpener.shellQuoted(worktree.path))", in: surface)

        editorCenter.applyMigration(plan)
    }
}

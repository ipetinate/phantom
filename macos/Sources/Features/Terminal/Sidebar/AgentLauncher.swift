import AppKit

/// Starts an agent in a tab that already exists.
///
/// Distinct from the sidebar's and the group's agent buttons, which ask
/// `TerminalController` for a *new* tab running one. Nothing is being created
/// here, so there is no controller decision to make: the command goes into a
/// shell that is already open, which is why this is a small named place of its
/// own rather than another callback threaded through the sidebar.
@MainActor
enum AgentLauncher {
    static func start(_ agent: CodingAgent, in tab: SidebarTabModel) {
        guard let surface = surface(for: tab) else { return }

        /// Recorded before the command is typed, for the reason
        /// `TabStateCenter.recordAgentStart` gives: we know which agent this is
        /// and the hook might never say so, and a tab with no record leaves a
        /// restore nothing to resume. It also clears an `end=user` mark from a
        /// session the reader quit earlier in this same tab — see
        /// `TabStateCenter.startWord`.
        TabStateCenter.shared.recordAgentStart(surfaceId: surface.id, agent: agent)

        /// The same helper the new-tab path uses, which waits for the shell to
        /// have a foreground process before sending. Typing into a shell that
        /// has not finished starting drops the command.
        ClaudeSession.run(agent.launchCommand, in: surface)
    }

    /// The surface behind a sidebar row.
    ///
    /// Matched by id rather than by taking the window's focused surface,
    /// because a split window holds several and the row stands for exactly one
    /// of them — sending to the focused one would start the agent in whichever
    /// pane the reader last clicked.
    ///
    /// The fallback covers a row whose id has not caught up yet, and prefers
    /// doing the thing in the likely-right pane over doing nothing.
    private static func surface(for tab: SidebarTabModel) -> Ghostty.SurfaceView? {
        guard let controller = tab.window.windowController as? BaseTerminalController
        else { return nil }

        if let surfaceId = tab.surfaceId,
           let match = controller.surfaceTree.first(where: { $0.id == surfaceId }) {
            return match
        }

        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }
}

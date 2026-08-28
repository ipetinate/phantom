import Foundation

/// Where in the sidebar the worktree button can appear.
///
/// Three places, because the panel answers the question the other way
/// round. Going to the panel means starting from *where you want to work*;
/// these mean starting from *what you are working on*, which is where you
/// already are when the thought occurs.
enum WorktreeEntry: String, CaseIterable {
    /// The row of one terminal.
    case tabRow

    /// The header of a group of terminals.
    case groupHeader

    /// The sidebar's own chrome, above everything.
    case chrome

    /// The `@AppStorage` key of the setting that hides it.
    ///
    /// Named after the place, following the prefixes already in use rather
    /// than a scheme of my own: row actions are `SidebarTabShow…`
    /// (`SidebarTabShowClaude`), group actions `SidebarGroupShow…`, and the
    /// chrome's are `SidebarChrome…`. A fourth convention would make the
    /// Settings list read as three unrelated features.
    var defaultsKey: String {
        switch self {
        case .tabRow: return "SidebarTabShowWorktree"
        case .groupHeader: return "SidebarGroupShowWorktree"
        case .chrome: return "SidebarChromeShowWorktree"
        }
    }
}

enum WorktreeEntryAction: Equatable {
    /// This terminal moves: the shell `cd`s, and the editor tabs that can
    /// follow, follow. One tab, one worktree, no second terminal appearing
    /// for a switch the reader thinks of as going somewhere.
    case migrate

    /// A new terminal opens in the worktree and this one is left alone.
    case newTab
}

/// What a place can reach, and whether the answer is in yet.
///
/// A folder is one of three things and the button used to know only two of
/// them. `~/Projects/Aurora` is not a checkout, so the group header standing
/// for it counted as "not in a repository" — and it was handed the folder as
/// a repository root anyway, which is how pressing the button produced
/// "Couldn't read this repository's worktrees" over six perfectly readable
/// repositories.
///
/// The fourth case is the one worth stating separately: a scan that has not
/// come back has said nothing, and hiding the button on the strength of
/// nothing is a button that is missing exactly when the folder is cold.
enum WorktreeEntryReach: Equatable {
    /// The folder is a checkout. One family.
    case repository

    /// The folder is not a checkout, but repositories were found under it.
    /// One section each — even when there is only one, because which shape
    /// the chooser takes is `WorktreeScope`'s decision, not this one's.
    case workspace

    /// The scan under the folder has not answered yet.
    case searching

    /// No checkout here, and none underneath.
    case nothing

    /// - Parameters:
    ///   - repoRoot: the enclosing repository, already computed without a
    ///     subprocess by `SidebarTabManager.gitInfo`. Asked first, and that
    ///     order matters: a terminal inside a checkout is looking at that
    ///     checkout, while a scan of its working directory could answer with
    ///     a vendored repository two folders down.
    ///   - scanRoot: a folder to look inside when there is no enclosing
    ///     repository — a workspace such as `~/Projects/Aurora`, or a
    ///     project group's declared root.
    ///   - discovered: `GitCenter.workspaceRepos[scanRoot]`. Nil and `[]`
    ///     mean different things, and this is the type that keeps them
    ///     apart: the first is "still looking".
    ///
    /// Deliberately free of filesystem work. It is asked from `body`, for
    /// every row, on every sidebar update — resolving each repository to its
    /// family reads files, and that is deferred to the moment something is
    /// opened.
    static func resolve(
        repoRoot: String?,
        scanRoot: String?,
        discovered: [String]?
    ) -> WorktreeEntryReach {
        if let repoRoot, !repoRoot.isEmpty { return .repository }
        guard let scanRoot, !scanRoot.isEmpty else { return .nothing }
        guard let discovered else { return .searching }
        return discovered.isEmpty ? .nothing : .workspace
    }
}

/// Whether a place offers the button, and what pressing it means.
///
/// Pure, and separate from every view that asks it, because the interesting
/// part is the *absence*: the button has to be gone — not disabled — in the
/// cases where using it would type into something that is not a shell. A
/// rule spread across three `if` statements in three views is one that will
/// be right in two of them.
enum WorktreeEntryRule {
    /// - Parameters:
    ///   - isEnabled: the Settings toggle for this place. The row, the group
    ///     header and the chrome already carry a lot of actions, so each is
    ///     switchable on its own.
    ///   - reach: what this place's folder can reach. Nothing to switch
    ///     between when it reaches nothing, and an icon that opens an empty
    ///     list is worse than no icon.
    ///   - isIdle: `TerminalIdleCheck.isIdle` — the foreground process is a
    ///     shell.
    ///   - hasLiveAgent: `SidebarTabModel.liveAgent` is set.
    ///
    /// Returns nil when the place shows nothing at all.
    static func action(
        at entry: WorktreeEntry,
        isEnabled: Bool,
        reach: WorktreeEntryReach,
        isIdle: Bool,
        hasLiveAgent: Bool
    ) -> WorktreeEntryAction? {
        guard isEnabled, reach != .nothing else { return nil }

        switch entry {
        case .tabRow:
            /// A workspace folder is not a worktree to leave, and migrating
            /// needs somewhere to leave. The group header one row up stands
            /// for the whole folder and does offer its repositories.
            guard reach == .repository else { return nil }

            /// Migrating means typing `cd` at a prompt. A terminal running a
            /// build takes that as input to the build, and a terminal
            /// running an agent takes it as a message to the agent — which
            /// is the same reason `TabRowAgentActions` hides its buttons,
            /// stated there as "these buttons type into a shell".
            ///
            /// Hidden rather than disabled, and hidden rather than falling
            /// back to opening a new tab: a button that silently means
            /// something else depending on what the terminal is doing is one
            /// nobody can predict. The group header is one row away and does
            /// mean that.
            guard isIdle, !hasLiveAgent else { return nil }
            return .migrate

        case .groupHeader, .chrome:
            /// Never migrate from here. A group header stands for several
            /// terminals and the chrome for all of them, so there is no
            /// single tab a switch could be about.
            return .newTab
        }
    }
}

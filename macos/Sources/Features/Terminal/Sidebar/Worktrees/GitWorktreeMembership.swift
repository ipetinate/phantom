import Foundation

/// Which checkout a working directory belongs to, and therefore which tabs
/// belong to a checkout.
///
/// The single answer to that question, because it gets asked from two places
/// that must never disagree: the worktree pane, deciding whether a checkout
/// is in use, and the tab chip, deciding which checkout to name. A tab
/// counted by one and not the other would offer to remove a worktree
/// somebody is sitting in.
///
/// The containment rule is `SidebarGroup.claims(pwd:)`'s, deliberately —
/// exact match, or a prefix ending in a path separator. The separator is the
/// whole point: without it `~/code/feat-x` claims `~/code/feat-x2`, which is
/// a sibling worktree and a different branch.
enum GitWorktreeMembership {
    /// Whether `pwd` is inside `root`, or is `root`.
    ///
    /// Both paths are compared as given. Callers hand in git's own absolute
    /// paths, or a managed root already tilde-expanded by
    /// ``WorktreeSettings/expand(_:)``; nothing here expands anything,
    /// because a half-expanded comparison silently answers no.
    nonisolated static func contains(pwd: String?, root: String) -> Bool {
        guard let pwd, !pwd.isEmpty, !root.isEmpty else { return false }
        return pwd == root || pwd.hasPrefix(root + "/")
    }

    /// The checkout a working directory sits in, longest root first.
    ///
    /// Nesting happens: a worktree of repository A can live under the
    /// managed root that also holds repository B's main checkout, and a
    /// submodule's worktree lives under its superproject's. Shortest-match
    /// would answer with the outer repository for every tab in the inner
    /// one, so the deepest root that still contains the path wins.
    nonisolated static func worktree(containing pwd: String?, in list: [GitWorktree]) -> GitWorktree? {
        list
            .filter { contains(pwd: pwd, root: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    /// Every tab grouped under the checkout it is in, keyed by that
    /// checkout's path. Tabs in no checkout at all are simply absent, so an
    /// empty value never has to be told apart from a missing one.
    nonisolated static func tabsByWorktree(
        tabs: [(id: UUID, pwd: String?)],
        worktrees: [GitWorktree]
    ) -> [String: [UUID]] {
        var grouped: [String: [UUID]] = [:]
        for tab in tabs {
            guard let match = worktree(containing: tab.pwd, in: worktrees) else { continue }
            grouped[match.path, default: []].append(tab.id)
        }
        return grouped
    }
}

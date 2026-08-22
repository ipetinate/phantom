import Foundation

/// Which refs the create sheet may offer as a base.
///
/// Only refs that exist. The first version also offered `origin/main`,
/// `origin/master`, `main` and `master` unconditionally — and on a healthy
/// repository with no remote, or a fresh `git init` with no commits, Create
/// failed with git's `fatal: invalid reference`, which reads as the app being
/// broken rather than the guess being wrong. The honest sources are two: the
/// base the review machinery already *validated* with merge-base, and the
/// branches git itself lists.
enum WorktreeBases {
    /// Ordered: the caller's request first (branching from a specific row),
    /// then the validated base, then every local branch. Deduplicated,
    /// empties dropped.
    ///
    /// The request only passes if it is a branch git actually lists. The row
    /// it came from can carry a branch that does not exist: on a repository
    /// with no commits, `git worktree list` still prints the *symbolic* HEAD
    /// — `branch refs/heads/main` over an all-zero HEAD — and offering that
    /// name reproduces the exact `invalid reference` this type was written
    /// to end.
    nonisolated static func candidates(
        initialBase: String?,
        resolvedBase: String?,
        localBranches: [String]
    ) -> [String] {
        var ordered: [String] = []
        if let initialBase, localBranches.contains(initialBase) {
            ordered.append(initialBase)
        }
        if let resolvedBase { ordered.append(resolvedBase) }
        ordered.append(contentsOf: localBranches)

        var seen = Set<String>()
        return ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether a fetch button has anything to fetch from.
    ///
    /// The validated base is the one signal about remotes this code can trust
    /// without running more git: `resolveBase` only answers `origin/…` when
    /// that ref exists and shares history.
    nonisolated static func hasRemote(resolvedBase: String?) -> Bool {
        resolvedBase?.contains("/") == true
    }
}

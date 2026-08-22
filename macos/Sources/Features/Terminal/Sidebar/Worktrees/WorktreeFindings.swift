import Foundation

/// Something about a worktree worth telling the user, and why.
enum WorktreeFinding: Equatable {
    /// A managed worktree nobody has a tab in.
    case orphan(GitWorktree)

    /// A worktree whose branch has already landed on the base.
    case merged(GitWorktree)

    /// A worktree git can no longer reach. The path is carried on its own
    /// because there may be nothing left to describe but the path.
    case broken(path: String, reason: String)
}

/// Reads a repository's worktree list and says which entries are finished
/// with, so the pane can offer to clean up instead of waiting to be asked.
///
/// Pure: every judgement is made from the list, the merged set and the tab
/// grouping handed in, plus one `fileExists` per worktree. No git.
enum WorktreeFindings {
    /// Every finding for a repository, most actionable first.
    ///
    /// One finding per worktree, and the order of the checks is the order of
    /// severity: broken, then merged, then orphan. A worktree that is both
    /// merged and unused is reported as merged, because "its branch is in
    /// the base" is the fact that makes deleting it safe — "nobody has it
    /// open" only makes it quiet.
    ///
    /// The `merged` set is trusted exactly as given. It is
    /// ``WorktreeCenter``'s job to have already excluded a branch that
    /// merely sits at the base's tip — a branch cut an hour ago and never
    /// committed to, which `git branch --merged` reports as merged because
    /// it adds nothing. Re-deriving that here would need the base's tip,
    /// which means running git, which this must not do.
    ///
    /// A merged worktree with tabs in it is still listed. Suppressing it
    /// would leave the branch to rot unmentioned; the remove flow is where
    /// the open tabs get their warning.
    nonisolated static func derive(
        worktrees: [GitWorktree],
        merged: Set<String>,
        tabsByPath: [String: [UUID]],
        managedRoot: String,
        fileManager: FileManager = .default
    ) -> [WorktreeFinding] {
        var broken: [WorktreeFinding] = []
        var mergedFindings: [WorktreeFinding] = []
        var orphans: [WorktreeFinding] = []

        for worktree in worktrees {
            let onDisk = fileManager.fileExists(atPath: worktree.path)

            if worktree.isPrunable || !onDisk {
                broken.append(.broken(path: worktree.path, reason: worktree.prunableReason ?? lostReason))
                continue
            }

            if !worktree.isMain, let branch = worktree.branch, merged.contains(branch) {
                mergedFindings.append(.merged(worktree))
                continue
            }

            let claimed = tabsByPath[worktree.path]?.isEmpty == false
            if !worktree.isMain,
               !claimed,
               GitWorktreeMembership.contains(pwd: worktree.path, root: managedRoot) {
                orphans.append(.orphan(worktree))
            }
        }

        return broken + mergedFindings + orphans
    }

    /// What a worktree whose folder has gone missing is called.
    ///
    /// Deliberately not an error: a folder can be gone because it was moved
    /// with Finder, because it lived on a volume that isn't mounted, or
    /// because somebody deleted it by hand — none of which is a fault, and
    /// all of which are fixed by the same removal.
    private static let lostReason = "The folder is no longer on disk"
}

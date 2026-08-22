import Foundation
@testable import Ghostty
import Testing

/// What the worktrees panel is looking at, and what a tick of its timer is
/// allowed to cost.
///
/// The *here or below* half of the question belongs to `GitPanelScope` and is
/// covered by `GitPanelScopeTests`; what these guard is the conversion from
/// repositories to **families**, where the panel's own two traps live: a
/// discovered repository that is itself a linked worktree, and several
/// discovered repositories that turn out to be the same one.
struct WorktreeScopeTests {
    /// `GitCommonDir.resolve` as a lookup table. Injecting it is what lets
    /// every case here run without a repository on disk.
    private func families(_ table: [String: String]) -> (String) -> String? {
        { table[$0] }
    }

    // MARK: Deriving

    @Test func aTerminalInsideARepositoryGetsItsFamily() {
        let scope = WorktreeScope.resolve(
            .repository("/Projects/phantom"),
            commonRoot: families(["/Projects/phantom": "/Projects/phantom"])
        )
        #expect(scope == .repository("/Projects/phantom"))
    }

    /// The reason the panel resolves at all: a tab in a linked worktree
    /// describes the family, not the one member it sits in.
    @Test func aTabInsideALinkedWorktreeResolvesToTheMainCheckout() {
        let scope = WorktreeScope.resolve(
            .repository("/Worktrees/phantom-fix"),
            commonRoot: families(["/Worktrees/phantom-fix": "/Projects/phantom"])
        )
        #expect(scope == .repository("/Projects/phantom"))
    }

    /// A submodule, or a `.git` that can't be read: `GitCommonDir` declines
    /// to guess, and a panel keyed on a guess would list another
    /// repository's worktrees under this one's name.
    @Test func aRepositoryWithNoFamilyToResolveIsNothing() {
        let scope = WorktreeScope.resolve(
            .repository("/Projects/app/vendor/lib"),
            commonRoot: families([:])
        )
        #expect(scope == .none)
    }

    @Test func aWorkspaceBecomesOneSectionPerRepository() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Projects", repos: ["/Projects/api", "/Projects/web"]),
            commonRoot: families([
                "/Projects/api": "/Projects/api",
                "/Projects/web": "/Projects/web",
            ])
        )
        #expect(scope == .workspace(["/Projects/api", "/Projects/web"]))
    }

    /// Every repository is resolved separately because any one of them can
    /// be a linked worktree of something outside the folder being scanned.
    @Test func eachDiscoveredRepositoryIsResolvedOnItsOwn() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Work", repos: ["/Work/api", "/Work/web-fix"]),
            commonRoot: families([
                "/Work/api": "/Work/api",
                "/Work/web-fix": "/Projects/web",
            ])
        )
        #expect(scope == .workspace(["/Work/api", "/Projects/web"]))
    }

    /// A folder kept full of worktrees of one repository — which is what
    /// `WorktreeSettings.managedRoot` is — must not become five identical
    /// sections listing the same five checkouts.
    @Test func aFolderOfWorktreesOfOneRepositoryIsOneFamily() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Worktrees", repos: [
                "/Worktrees/phantom-a",
                "/Worktrees/phantom-b",
                "/Worktrees/phantom-c",
            ]),
            commonRoot: families([
                "/Worktrees/phantom-a": "/Projects/phantom",
                "/Worktrees/phantom-b": "/Projects/phantom",
                "/Worktrees/phantom-c": "/Projects/phantom",
            ])
        )
        #expect(scope == .repository("/Projects/phantom"))
    }

    /// Deduplication keeps the order the scan found things in, because that
    /// order is what the sections are drawn in.
    @Test func duplicatesCollapseOntoTheirFirstAppearance() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Work", repos: [
                "/Work/api",
                "/Work/phantom-a",
                "/Work/web",
                "/Work/phantom-b",
            ]),
            commonRoot: families([
                "/Work/api": "/Work/api",
                "/Work/phantom-a": "/Projects/phantom",
                "/Work/web": "/Work/web",
                "/Work/phantom-b": "/Projects/phantom",
            ])
        )
        #expect(scope == .workspace(["/Work/api", "/Projects/phantom", "/Work/web"]))
    }

    /// The requirement that keeps the validated single-repository panel
    /// intact: one family renders flat however few of many repositories it
    /// was left with.
    @Test func aWorkspaceWhereOnlyOneRepositoryResolvesStaysFlat() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Projects", repos: ["/Projects/api", "/Projects/notes"]),
            commonRoot: families(["/Projects/api": "/Projects/api"])
        )
        #expect(scope == .repository("/Projects/api"))
    }

    @Test func aWorkspaceWhereNothingResolvesIsNothing() {
        let scope = WorktreeScope.resolve(
            .workspace(root: "/Projects", repos: ["/Projects/a", "/Projects/b"]),
            commonRoot: families([:])
        )
        #expect(scope == .none)
    }

    /// An empty answer is no answer. It reaches here from a bare repository
    /// whose common directory came back blank, and treating it as a key
    /// would make a section named after nothing.
    @Test func anEmptyCommonRootIsNotAFamily() {
        let scope = WorktreeScope.resolve(
            .repository("/Projects/phantom"),
            commonRoot: families(["/Projects/phantom": ""])
        )
        #expect(scope == .none)
    }

    @Test func nothingToLookAtStaysNothing() {
        #expect(WorktreeScope.resolve(.none, commonRoot: families(["/a": "/a"])) == .none)
    }

    /// The distinction `GitPanelScope` exists for has to survive the
    /// conversion, or the empty state flashes on every switch to a workspace
    /// tab while its scan is still running.
    @Test func anUnfinishedScanIsStillNotAnEmptyWorkspace() {
        let resolver = families(["/Projects/api": "/Projects/api"])

        let pending = WorktreeScope.resolve(
            GitPanelScope.resolve(repoRoot: nil, pwd: "/Projects", discovered: nil),
            commonRoot: resolver)
        let answered = WorktreeScope.resolve(
            GitPanelScope.resolve(
                repoRoot: nil, pwd: "/Projects", discovered: ["/Projects/api"]),
            commonRoot: resolver)

        #expect(pending == .none)
        #expect(answered == .repository("/Projects/api"))
    }

    @Test func scopeReportsEveryFamilyItCovers() {
        #expect(WorktreeScope.repository("/a").roots == ["/a"])
        #expect(WorktreeScope.workspace(["/a", "/b"]).roots == ["/a", "/b"])
        #expect(WorktreeScope.none.roots.isEmpty)
    }

    // MARK: Polling

    /// The flat panel is the thing on screen. There is nothing to collapse
    /// and nothing to save by not asking.
    @Test func theFlatCaseIsAlwaysPolled() {
        #expect(WorktreeScope.repository("/a").polled(expanded: []) == ["/a"])
        #expect(WorktreeScope.repository("/a").polled(expanded: ["/b"]) == ["/a"])
    }

    /// The mitigation itself: with N repositories of M worktrees each, a tick
    /// that polled everything would cost N `worktree list` plus N×M
    /// `git status` to keep headers nobody has opened up to date.
    @Test func onlyExpandedSectionsArePolled() {
        let scope = WorktreeScope.workspace(["/a", "/b", "/c"])
        #expect(scope.polled(expanded: ["/b"]) == ["/b"])
        #expect(scope.polled(expanded: ["/a", "/c"]) == ["/a", "/c"])
    }

    @Test func aWorkspaceWithNothingOpenCostsNothing() {
        #expect(WorktreeScope.workspace(["/a", "/b"]).polled(expanded: []).isEmpty)
    }

    /// Polling follows the section order rather than the set's, so the
    /// requests go out in the order the reader sees them.
    @Test func pollingFollowsTheSectionOrder() {
        let scope = WorktreeScope.workspace(["/z", "/y", "/x"])
        #expect(scope.polled(expanded: ["/x", "/y", "/z"]) == ["/z", "/y", "/x"])
    }

    /// An expansion left over from the previous folder must not spend a
    /// process on a repository this scope no longer shows.
    @Test func anExpansionOutsideTheScopeIsIgnored() {
        #expect(WorktreeScope.workspace(["/a"]).polled(expanded: ["/gone"]).isEmpty)
        #expect(WorktreeScope.none.polled(expanded: ["/gone"]).isEmpty)
    }
}

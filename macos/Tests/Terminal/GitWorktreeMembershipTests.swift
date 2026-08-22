import Foundation
@testable import Ghostty
import Testing

/// Which worktree a working directory belongs to.
///
/// The whole cleanup story is built on this: a worktree with no tab in it is
/// offered for removal. So a containment rule that is one character too
/// loose doesn't produce a cosmetic bug, it produces an offer to delete the
/// branch the user is standing in — which is why the sibling-prefix case
/// gets a test of its own.
struct GitWorktreeMembershipTests {
    private func worktree(_ path: String, branch: String? = "b", isMain: Bool = false) -> GitWorktree {
        GitWorktree(
            path: path,
            head: "9f0e1b7",
            branch: branch,
            isMain: isMain,
            isBare: false,
            isDetached: branch == nil,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }

    // MARK: contains

    @Test func aWorktreeContainsItsOwnRoot() {
        #expect(GitWorktreeMembership.contains(pwd: "/Users/dev/wt/feat-x", root: "/Users/dev/wt/feat-x"))
    }

    @Test func aWorktreeContainsADirectoryBeneathIt() {
        #expect(GitWorktreeMembership.contains(pwd: "/Users/dev/wt/feat-x/macos/Sources", root: "/Users/dev/wt/feat-x"))
    }

    /// The reason the prefix has to end in a separator. `feat-x2` is a
    /// sibling worktree on a different branch; a bare `hasPrefix` puts every
    /// tab in it under `feat-x`, and `feat-x` then looks unused.
    @Test func aSiblingSharingAPrefixIsNotInside() {
        #expect(!GitWorktreeMembership.contains(pwd: "/Users/dev/wt/feat-x2", root: "/Users/dev/wt/feat-x"))
        #expect(!GitWorktreeMembership.contains(pwd: "/Users/dev/wt/feat-x2/src", root: "/Users/dev/wt/feat-x"))
    }

    @Test func nothingContainsANilOrEmptyDirectory() {
        #expect(!GitWorktreeMembership.contains(pwd: nil, root: "/Users/dev/wt/feat-x"))
        #expect(!GitWorktreeMembership.contains(pwd: "", root: "/Users/dev/wt/feat-x"))
    }

    /// An empty root would otherwise claim every absolute path in
    /// existence, since every one of them starts with "/".
    @Test func anEmptyRootClaimsNothing() {
        #expect(!GitWorktreeMembership.contains(pwd: "/Users/dev/wt/feat-x", root: ""))
    }

    // MARK: worktree(containing:)

    @Test func findsTheWorktreeATabIsIn() {
        let list = [worktree("/Users/dev/Projects/phantom", isMain: true), worktree("/Users/dev/wt/phantom/feat-x")]

        #expect(GitWorktreeMembership.worktree(containing: "/Users/dev/wt/phantom/feat-x/macos", in: list)?.path
            == "/Users/dev/wt/phantom/feat-x")
    }

    /// Nesting is ordinary: a managed root can sit inside a checkout of
    /// another repository, and a submodule's worktree always sits inside its
    /// superproject's. Shortest-match answers with the outer repository for
    /// every tab in the inner one.
    @Test func theLongestMatchingRootWins() {
        let list = [
            worktree("/Users/dev/Projects/mono", isMain: true),
            worktree("/Users/dev/Projects/mono/vendor/lib"),
        ]

        #expect(GitWorktreeMembership.worktree(containing: "/Users/dev/Projects/mono/vendor/lib/src", in: list)?.path
            == "/Users/dev/Projects/mono/vendor/lib")
        #expect(GitWorktreeMembership.worktree(containing: "/Users/dev/Projects/mono/macos", in: list)?.path
            == "/Users/dev/Projects/mono")
    }

    @Test func aTabOutsideEveryWorktreeMatchesNone() {
        let list = [worktree("/Users/dev/Projects/phantom", isMain: true)]

        #expect(GitWorktreeMembership.worktree(containing: "/Users/dev/Documents", in: list) == nil)
        #expect(GitWorktreeMembership.worktree(containing: nil, in: list) == nil)
    }

    // MARK: tabsByWorktree

    @Test func groupsTabsUnderTheWorktreeTheyAreIn() {
        let main = UUID()
        let featOne = UUID()
        let featTwo = UUID()
        let elsewhere = UUID()

        let grouped = GitWorktreeMembership.tabsByWorktree(
            tabs: [
                (id: main, pwd: "/Users/dev/Projects/phantom"),
                (id: featOne, pwd: "/Users/dev/wt/phantom/feat-x"),
                (id: featTwo, pwd: "/Users/dev/wt/phantom/feat-x/macos/Sources"),
                (id: elsewhere, pwd: "/Users/dev/Documents"),
            ],
            worktrees: [
                worktree("/Users/dev/Projects/phantom", isMain: true),
                worktree("/Users/dev/wt/phantom/feat-x"),
            ]
        )

        #expect(grouped["/Users/dev/Projects/phantom"] == [main])
        #expect(grouped["/Users/dev/wt/phantom/feat-x"] == [featOne, featTwo])
        #expect(grouped.count == 2)
    }

    /// A worktree nobody has open is absent from the grouping rather than
    /// present with an empty list, so a caller never has to tell one from
    /// the other.
    @Test func aWorktreeWithNoTabsIsAbsent() {
        let grouped = GitWorktreeMembership.tabsByWorktree(
            tabs: [(id: UUID(), pwd: "/Users/dev/Projects/phantom")],
            worktrees: [
                worktree("/Users/dev/Projects/phantom", isMain: true),
                worktree("/Users/dev/wt/phantom/feat-x"),
            ]
        )

        #expect(grouped["/Users/dev/wt/phantom/feat-x"] == nil)
    }

    /// A tab with no working directory yet — one still starting up — must
    /// not be counted against any worktree.
    @Test func aTabWithNoDirectoryIsGroupedNowhere() {
        let grouped = GitWorktreeMembership.tabsByWorktree(
            tabs: [(id: UUID(), pwd: nil)],
            worktrees: [worktree("/Users/dev/Projects/phantom", isMain: true)]
        )

        #expect(grouped.isEmpty)
    }
}

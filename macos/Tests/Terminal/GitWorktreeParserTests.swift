import Foundation
@testable import Ghostty
import Testing

/// `GitWorktree.parse` against real `git worktree list --porcelain` output.
///
/// The fixtures are transcripts of the command rather than invented ones,
/// because the format's details are where a hand-rolled parser goes wrong:
/// a block's fields are optional and vary by kind, the markers `detached`,
/// `bare` and `locked` may carry no value at all, and one fact the model
/// depends on — which checkout is the main one — is not in the text but in
/// the order of the blocks.
struct GitWorktreeParserTests {
    // MARK: Shape

    /// A repository nobody has added a worktree to still lists one: itself.
    @Test func readsASingleMainCheckout() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        """)

        #expect(list.count == 1)
        #expect(list[0].path == "/Users/dev/Projects/phantom")
        #expect(list[0].head == "9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f")
        #expect(list[0].branch == "main")
        #expect(list[0].isMain)
        #expect(!list[0].isDetached)
        #expect(!list[0].isBare)
        #expect(!list[0].isLocked)
        #expect(!list[0].isPrunable)
    }

    @Test func readsAMainCheckoutAndTwoLinkedOnes() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        worktree /Users/dev/.phantom/worktrees/phantom/feat-worktrees
        HEAD 4c2a0f3e7b5d19aa8c6e0f2d4b8a1c7e3f905d6b
        branch refs/heads/feat/worktrees

        worktree /Users/dev/.phantom/worktrees/phantom/fix-editor
        HEAD 1a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b
        branch refs/heads/fix/editor

        """)

        #expect(list.count == 3)
        #expect(list.map(\.branch) == ["main", "feat/worktrees", "fix/editor"])
        #expect(list.map(\.isMain) == [true, false, false])
    }

    /// The one thing this parser knows that the text does not say. Git
    /// prints the main checkout first, always, and that position is the only
    /// signal there is — a change that sorted the blocks before building
    /// them would silently promote a linked worktree to main and let the
    /// pane offer to remove the repository the user is working in.
    @Test func theFirstBlockIsTheMainCheckoutRegardlessOfName() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/.phantom/worktrees/phantom/feat-a
        HEAD 4c2a0f3e7b5d19aa8c6e0f2d4b8a1c7e3f905d6b
        branch refs/heads/feat/a

        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        """)

        #expect(list[0].isMain)
        #expect(list[0].branch == "feat/a")
        #expect(!list[1].isMain)
    }

    // MARK: Fields

    /// `refs/heads/` is git's full ref name; every label, every comparison
    /// against a merged-branch set and every `git branch -d` uses the short
    /// one.
    @Test func stripsTheRefsHeadsPrefix() {
        let list = GitWorktree.parse(porcelain: """
        worktree /tmp/repo
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/feature/nested/name

        """)

        #expect(list[0].branch == "feature/nested/name")
    }

    /// A detached worktree has no branch line at all — the absence *is* the
    /// fact, and it must not arrive as an empty string that then reads as a
    /// branch with no name.
    @Test func aDetachedWorktreeHasNoBranch() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        worktree /tmp/inspect
        HEAD 1a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b
        detached

        """)

        #expect(list[1].isDetached)
        #expect(list[1].branch == nil)
        #expect(list[1].head == "1a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b")
    }

    /// A bare repository's entry has neither `HEAD` nor a branch, because
    /// there is no working tree to be on a commit.
    @Test func aBareRepositoryHasNoHeadAndNoBranch() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/mirrors/phantom.git
        bare

        worktree /Users/dev/mirrors/checkouts/main
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        """)

        #expect(list[0].isBare)
        #expect(list[0].head == nil)
        #expect(list[0].branch == nil)
        #expect(list[0].isMain)
        #expect(!list[1].isBare)
    }

    @Test func readsALockReason() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Volumes/Archive/phantom/old
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/old
        locked on an external drive

        """)

        #expect(list[0].isLocked)
        #expect(list[0].lockReason == "on an external drive")
    }

    /// `git worktree lock` without `--reason` prints the bare marker. The
    /// worktree is just as locked, and the reason has to be nil rather than
    /// "" so the UI shows no explanation instead of an empty one.
    @Test func aLockWithNoReasonIsStillALock() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Volumes/Archive/phantom/old
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/old
        locked

        """)

        #expect(list[0].isLocked)
        #expect(list[0].lockReason == nil)
    }

    /// Git's own words, kept verbatim: they name which of several ways the
    /// checkout went missing, and the pane has nothing better to say.
    @Test func readsAPrunableReason() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/.phantom/worktrees/phantom/gone
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        detached
        prunable gitdir file points to non-existent location

        """)

        #expect(list[0].isPrunable)
        #expect(list[0].prunableReason == "gitdir file points to non-existent location")
    }

    /// The value is the untouched remainder of the line, so a path with
    /// spaces in it survives — the same discipline the status porcelain
    /// parser applies, and for the same reason: people name folders
    /// "My Projects".
    @Test func readsAPathWithSpaces() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/My Projects/phantom fork
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main

        """)

        #expect(list.count == 1)
        #expect(list[0].path == "/Users/dev/My Projects/phantom fork")
    }

    // MARK: Degenerate input

    /// No git, or a folder that stopped being a repository between the
    /// check and the call. An empty list is the honest answer; the caller
    /// tells it apart from a failure by the command's exit status, not by
    /// this.
    @Test func emptyOutputYieldsNoWorktrees() {
        #expect(GitWorktree.parse(porcelain: "").isEmpty)
        #expect(GitWorktree.parse(porcelain: "\n\n").isEmpty)
    }

    /// Git's last block is followed by a blank line, but a caller that
    /// trimmed the output would drop the final worktree if the parser only
    /// committed a block on a separator.
    @Test func theLastBlockSurvivesAMissingTrailingBlankLine() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main
        """)

        #expect(list.count == 1)
        #expect(list[0].branch == "main")
    }

    /// A keyword this parser has never heard of — git gained `prunable`
    /// after `locked`, and will gain more — is skipped without taking the
    /// block down with it.
    @Test func anUnknownKeywordIsIgnored() {
        let list = GitWorktree.parse(porcelain: """
        worktree /Users/dev/Projects/phantom
        HEAD 9f0e1b7f0d0d63d1c33f77a3ee6b2be9c1de5a4f
        branch refs/heads/main
        somethingnew whatever it means

        """)

        #expect(list.count == 1)
        #expect(list[0].branch == "main")
    }
}

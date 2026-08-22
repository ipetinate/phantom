import Foundation
@testable import Ghostty
import Testing

/// What the create sheet may offer to branch from — pinned because the first
/// version guessed, and the guess was the bug.
struct WorktreeBasesTests {
    /// The report that forced this type: a healthy repository with no remote
    /// was offered `origin/main`, and Create died on git's
    /// `fatal: invalid reference`. Nothing may appear that was not given.
    @Test func nothingIsEverInventedForARepoWithNoRemote() {
        let candidates = WorktreeBases.candidates(
            initialBase: nil, resolvedBase: nil, localBranches: ["main", "feat/x"])
        #expect(candidates == ["main", "feat/x"])
        #expect(!candidates.contains("origin/main"))
    }

    /// A fresh `git init` has no commits, so it has no refs at all — the
    /// sheet's honest answer is an empty list, which it renders as a
    /// sentence and a disabled Create, never as a guess that will fail.
    @Test func anUnbornRepositoryOffersNothing() {
        #expect(WorktreeBases.candidates(
            initialBase: nil, resolvedBase: nil, localBranches: []).isEmpty)
    }

    @Test func theValidatedBaseComesBeforeTheLocalBranches() {
        let candidates = WorktreeBases.candidates(
            initialBase: nil, resolvedBase: "origin/main", localBranches: ["main", "dev"])
        #expect(candidates == ["origin/main", "main", "dev"])
    }

    /// Branching from a row arrives first, so the sheet opens already on the
    /// branch the user pointed at.
    @Test func theRequestedBaseWinsTheFirstSlot() {
        let candidates = WorktreeBases.candidates(
            initialBase: "feat/base", resolvedBase: "origin/main",
            localBranches: ["main", "feat/base"])
        #expect(candidates.first == "feat/base")
        #expect(candidates.filter { $0 == "feat/base" }.count == 1)
    }

    /// The second half of the same report: the row's ⑂ button handed over
    /// "main" from a repository with no commits — a name `git worktree list`
    /// prints for the symbolic HEAD, with no ref behind it. A request that
    /// is not a real local branch is dropped, not trusted.
    @Test func aRequestedBaseThatIsNotARealBranchIsDropped() {
        #expect(WorktreeBases.candidates(
            initialBase: "main", resolvedBase: nil, localBranches: []).isEmpty)
        #expect(WorktreeBases.candidates(
            initialBase: "ghost", resolvedBase: "origin/main",
            localBranches: ["main"]) == ["origin/main", "main"])
    }

    @Test func emptiesAndDuplicatesAreDropped() {
        let candidates = WorktreeBases.candidates(
            initialBase: "", resolvedBase: "main", localBranches: ["main", "", "main"])
        #expect(candidates == ["main"])
    }

    /// The fetch button exists only where a remote provably does: the
    /// validated base is remote-qualified exactly when `resolveBase` proved
    /// an `origin/…` ref shares history.
    @Test func theFetchButtonNeedsARemoteQualifiedBase() {
        #expect(WorktreeBases.hasRemote(resolvedBase: "origin/main"))
        #expect(!WorktreeBases.hasRemote(resolvedBase: "main"))
        #expect(!WorktreeBases.hasRemote(resolvedBase: nil))
    }
}

import Foundation
@testable import Ghostty
import Testing

/// The states ``GitBranchReview`` has to be able to *say*, rather than
/// crash on or lie about.
@Suite struct GitBranchReviewTests {
    private func file(
        _ path: String,
        added: Int?,
        removed: Int?,
        status: GitFileDiff.Status = .modified
    ) -> GitReviewFile {
        GitReviewFile(
            path: path,
            previousPath: nil,
            status: status,
            addedLines: added,
            removedLines: removed
        )
    }

    private let base = GitReviewBase(ref: "origin/main", mergeBase: "abc123", source: .remoteHead)

    @Test func totalsSkipTheFilesGitCountedNoLinesIn() {
        let review = GitBranchReview(
            branch: "feat/x",
            head: "deadbee",
            base: base,
            files: [
                file("a.txt", added: 3, removed: 1),
                file("logo.png", added: nil, removed: nil, status: .added),
                file("b.txt", added: 10, removed: 2),
            ]
        )

        #expect(review.addedLines == 13)
        #expect(review.removedLines == 3)

        /// A binary file changed and contributed nothing to the totals, so
        /// the count of them is the only way a "+13 −3" is honest.
        #expect(review.binaryFileCount == 1)
    }

    @Test func aDetachedHeadHasNoBranchButStillHasACommit() {
        let review = GitBranchReview(branch: nil, head: "deadbee", base: base)

        #expect(review.isDetached)
        #expect(!review.isUnborn)
    }

    /// The two absences are different: a repository with no commits still
    /// has a branch name, it just has nothing under it.
    @Test func anUnbornRepositoryHasABranchButNoCommit() {
        let review = GitBranchReview(branch: "main", head: nil, base: nil)

        #expect(!review.isDetached)
        #expect(review.isUnborn)
        #expect(review.isEmpty)
        #expect(review.base == nil)
    }

    /// Both look empty and they are not the same sentence: one branch has
    /// nothing to review, the other has nothing to review it *against*.
    @Test func havingNoBaseIsDistinctFromHavingNothingToShow() {
        let baseless = GitBranchReview(branch: "main", head: "deadbee", base: nil)
        let identical = GitBranchReview(branch: "feat/x", head: "deadbee", base: base)

        #expect(baseless.isEmpty)
        #expect(baseless.base == nil)

        #expect(identical.isEmpty)
        #expect(identical.base != nil)
    }

    @Test func aFileKnowsItsNameAndItsDirectory() {
        let nested = file("macos/Sources/App.swift", added: 1, removed: 0)
        #expect(nested.name == "App.swift")
        #expect(nested.directory == "macos/Sources")

        let root = file("README.md", added: 1, removed: 0)
        #expect(root.name == "README.md")
        #expect(root.directory.isEmpty)
    }

    @Test func aCommitAbbreviatesItsShaTheWayGitDoes() {
        let commit = GitReviewCommit(
            sha: "1234567890abcdef1234567890abcdef12345678",
            subject: "do the thing",
            author: "Someone",
            relativeDate: "2 hours ago"
        )

        #expect(commit.shortSha == "1234567")
        #expect(commit.id == commit.sha)
    }
}

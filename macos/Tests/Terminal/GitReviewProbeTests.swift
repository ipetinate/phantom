import Foundation
@testable import Ghostty
import Testing

/// Reading what git and `gh` say about a branch under review.
struct GitReviewProbeTests {
    // MARK: Conflicts

    /// `merge-tree` prints the tree it wrote first, then the paths. That first
    /// line is a path's shape as far as a string is concerned, so it has to be
    /// recognised rather than trusted.
    @Test func theTreeObjectIsNotReportedAsAConflictedFile() {
        let output = """
            a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0

            src/main.swift
            README.md
            """

        #expect(GitReviewProbe.conflictedPaths(in: output) == ["src/main.swift", "README.md"])
    }

    @Test func anObjectIdIsToldApartFromAPath() {
        #expect(GitReviewProbe.isObjectID("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"))
        #expect(GitReviewProbe.isObjectID("src/main.swift") == false)
        #expect(GitReviewProbe.isObjectID("deadbeef") == false)
    }

    /// A path with spaces is one path. Splitting on whitespace anywhere here
    /// would report two files that do not exist.
    @Test func aPathWithSpacesSurvives() {
        let output = "abc\n\nsrc/My Folder/file name.ts"

        #expect(GitReviewProbe.conflictedPaths(in: output) == ["src/My Folder/file name.ts"])
    }

    @Test func silenceIsNotAPromiseOfSafety() {
        #expect(GitReviewConflictCheck.unknown.isConflicting == false)
        #expect(GitReviewConflictCheck.unknown.summary.contains("unavailable"))
        #expect(GitReviewConflictCheck.clean.isConflicting == false)
        #expect(GitReviewConflictCheck.conflicting(["a"]).isConflicting)
    }

    @Test func theConflictSummaryCountsFiles() {
        #expect(GitReviewConflictCheck.conflicting(["a"]).summary == "1 file would conflict")
        #expect(GitReviewConflictCheck.conflicting(["a", "b"]).summary == "2 files would conflict")
    }

    // MARK: Authors

    /// Ordered by how much each wrote, because the question is "whose work is
    /// this" and the answer is usually the first name.
    @Test func authorsAreOrderedByHowMuchTheyWrote() {
        let log = """
            Isac Petinate
            Someone Else
            Isac Petinate
            Isac Petinate
            """

        let authors = GitReviewProbe.tally(authorLines: log)

        #expect(authors.map(\.name) == ["Isac Petinate", "Someone Else"])
        #expect(authors.first?.commits == 3)
    }

    /// A tie must not reorder itself between two refreshes.
    @Test func aTieIsBrokenByName() {
        let authors = GitReviewProbe.tally(authorLines: "Bea\nAna\nBea\nAna")

        #expect(authors.map(\.name) == ["Ana", "Bea"])
    }

    @Test func blankLinesAreNotAuthors() {
        #expect(GitReviewProbe.tally(authorLines: "\n\n  \n").isEmpty)
    }

    // MARK: Branches to compare against

    /// `origin/main` and a local `main` are one decision to a reader picking a
    /// target, so the local one wins.
    @Test func aRemoteBranchWithALocalTwinIsNotOfferedTwice() {
        let output = """
            main
            feat/thing
            origin/main
            origin/feat/thing
            origin/only-on-remote
            """

        let names = GitReviewProbe.branchNames(in: output)

        #expect(names.filter { $0.hasSuffix("main") } == ["main"])
        #expect(names.contains("origin/only-on-remote"))
    }

    /// Git prints a symbolic ref for the remote's default. It is not a branch
    /// anybody can compare against.
    @Test func theSymbolicHeadIsNotABranch() {
        let names = GitReviewProbe.branchNames(in: "main\norigin/HEAD -> origin/main\n")

        #expect(names == ["main"])
    }

    @Test func localBranchesComeFirst() {
        let names = GitReviewProbe.branchNames(in: "zeta\norigin/alpha\n")

        #expect(names == ["zeta", "origin/alpha"])
    }

    // MARK: The default branch

    /// `main` and `master` are both wrong often enough to matter, and a repo
    /// can name it anything.
    @Test func theDefaultBranchIsReadRatherThanGuessed() {
        #expect(GitReviewProbe.defaultBranch(in: "origin/HEAD -> origin/trunk") == "trunk")
        #expect(GitReviewProbe.defaultBranch(in: "  HEAD branch: develop") == "develop")
    }

    @Test func withNothingToReadItFallsBack() {
        #expect(GitReviewProbe.defaultBranch(in: "") == "main")
        #expect(GitReviewProbe.defaultBranch(in: "noise", fallbacks: ["trunk"]) == "trunk")
    }

    // MARK: The pull request's description

    /// A body that opens with a heading would otherwise be previewed as half a
    /// line of markdown syntax.
    @Test func thePreviewSkipsAHeadingToFindTheSentence() {
        let body = "## Summary\n\nThis changes the thing that was broken.\n\n## Notes\n\nmore"

        #expect(GitReviewPullRequest.preview(of: body)
            == "This changes the thing that was broken.")
    }

    @Test func aCommentTemplateIsSkippedToo() {
        let body = "<!-- please fill this in -->\n\nReal description here."

        #expect(GitReviewPullRequest.preview(of: body) == "Real description here.")
    }

    @Test func aLongParagraphIsCutWithAnEllipsis() throws {
        let body = String(repeating: "word ", count: 200)

        let preview = try #require(GitReviewPullRequest.preview(of: body, limit: 40))

        #expect(preview.count <= 41)
        #expect(preview.hasSuffix("\u{2026}"))
    }

    @Test func aBodyWithNothingInItPreviewsAsNothing() {
        #expect(GitReviewPullRequest.preview(of: nil) == nil)
        #expect(GitReviewPullRequest.preview(of: "## Only a heading") == nil)
        #expect(GitReviewPullRequest.preview(of: "   \n\n  ") == nil)
    }

    /// Newlines inside the paragraph become spaces: a card draws one line, and
    /// a hard-wrapped body would otherwise arrive with breaks in it.
    @Test func aWrappedParagraphBecomesOneLine() {
        let body = "First line\nsecond line"

        #expect(GitReviewPullRequest.preview(of: body) == "First line second line")
    }

    // MARK: Where the comparison came from

    /// The reason is shown, because a reader needs to know whether they are
    /// seeing what the pull request will merge or what somebody picked.
    @Test func everyTargetSaysWhereItCameFrom() {
        #expect(GitReviewTargetChoice.pullRequestBase("main").ref == "main")
        #expect(GitReviewTargetChoice.pullRequestBase("main").provenance.contains("pull request"))
        #expect(GitReviewTargetChoice.repositoryDefault("trunk").provenance.contains("default"))
        #expect(GitReviewTargetChoice.chosen("release/1").provenance == "chosen")
    }

    // MARK: What `gh` says

    private let ghOutput = """
        {
          "number": 19,
          "title": "Give the agents a way to drive the app",
          "url": "https://github.com/ipetinate/phantom/pull/19",
          "baseRefName": "main",
          "author": { "login": "ipetinate" },
          "assignees": [{ "login": "ipetinate" }, { "login": "someone" }],
          "isDraft": false,
          "body": "## Summary\\n\\nWhat this does.",
          "state": "OPEN"
        }
        """

    @Test func thePullRequestIsReadWithItsBase() throws {
        let request = try #require(GitReviewGitHub.parse(ghOutput))

        #expect(request.number == 19)
        #expect(request.baseRef == "main")
        #expect(request.author == "ipetinate")
        #expect(request.assignees == ["ipetinate", "someone"])
        #expect(request.isDraft == false)
        #expect(request.bodyPreview == "What this does.")
    }

    /// A closed or merged pull request is not what this branch will merge
    /// into, so it must not become the target.
    @Test func aClosedPullRequestIsNotUsed() {
        let closed = ghOutput.replacingOccurrences(of: "\"OPEN\"", with: "\"MERGED\"")

        #expect(GitReviewGitHub.parse(closed) == nil)
    }

    /// Every field but the number is allowed to be missing. A card that hid
    /// itself over an absent assignee would hide the number with it.
    @Test func aSparseAnswerStillProducesAPullRequest() throws {
        let sparse = """
            { "number": 7, "state": "OPEN", "baseRefName": "trunk" }
            """

        let request = try #require(GitReviewGitHub.parse(sparse))

        #expect(request.number == 7)
        #expect(request.baseRef == "trunk")
        #expect(request.author == nil)
        #expect(request.assignees.isEmpty)
        #expect(request.bodyPreview == nil)
    }

    @Test func nonsenseFromGhIsNoPullRequest() {
        #expect(GitReviewGitHub.parse("") == nil)
        #expect(GitReviewGitHub.parse("not json") == nil)
        #expect(GitReviewGitHub.parse("{}") == nil)
    }

    /// The base is the field this screen exists for: it is what makes the
    /// comparison show what will be merged rather than a guess.
    @Test func theFieldsAskedForIncludeTheBase() {
        #expect(GitReviewGitHub.fields.contains("baseRefName"))
        #expect(GitReviewGitHub.fields.contains("assignees"))
        #expect(GitReviewGitHub.fields.contains("state"))
    }

    // MARK: When it happened

    /// `gh` prints ISO 8601 with a `Z` and no fractional seconds, and an
    /// `ISO8601DateFormatter` configured for one shape rejects the other in
    /// silence — a nil date then looks exactly like a missing field.
    @Test func githubsTimestampsAreRead() throws {
        let plain = try #require(
            GitReviewPullRequest.date(fromISO8601: "2026-08-26T09:14:05Z"))
        let fractional = try #require(
            GitReviewPullRequest.date(fromISO8601: "2026-08-26T09:14:05.123Z"))

        #expect(plain.timeIntervalSince1970 > 0)
        #expect(abs(fractional.timeIntervalSince(plain)) < 1)
    }

    @Test func aMissingTimestampIsNil() {
        #expect(GitReviewPullRequest.date(fromISO8601: nil) == nil)
        #expect(GitReviewPullRequest.date(fromISO8601: "") == nil)
        #expect(GitReviewPullRequest.date(fromISO8601: "yesterday") == nil)
    }

    @Test func theDatesArriveWithThePullRequest() throws {
        let output = """
            {
              "number": 19, "state": "OPEN", "baseRefName": "main",
              "createdAt": "2026-08-25T20:02:00Z",
              "updatedAt": "2026-08-26T09:14:05Z"
            }
            """

        let request = try #require(GitReviewGitHub.parse(output))

        #expect(request.createdAt != nil)
        #expect(request.updatedAt != nil)
        #expect(request.updatedAt! > request.createdAt!)
    }

    /// Both are asked for, because they answer different questions: how long
    /// this has been waiting, and whether anything happened lately.
    @Test func bothDatesAreAskedOfGh() {
        #expect(GitReviewGitHub.fields.contains("createdAt"))
        #expect(GitReviewGitHub.fields.contains("updatedAt"))
    }

    // MARK: The degenerate case

    private func context(
        branch: String,
        target: GitReviewTargetChoice,
        commits: Int = 3,
        files: Int = 2
    ) -> GitReviewContext {
        GitReviewContext(
            branch: branch,
            target: target,
            pullRequest: nil,
            conflicts: .clean,
            authors: [],
            commitCount: commits,
            addedLines: 10,
            removedLines: 2,
            fileCount: files
        )
    }

    /// On the default branch with nothing ahead, the review reports zero of
    /// everything and "no conflicts with the target" — true, trivially, and it
    /// reads as a green light on work that does not exist. A reader glancing at
    /// a check mark does not stop to notice the zeros, so the case is named.
    @Test func beingOnTheTargetIsRecognised() {
        let onTarget = context(
            branch: "main", target: .repositoryDefault("main"), commits: 0, files: 0)

        #expect(onTarget.isOnTarget)
        #expect(onTarget.isEmpty)
    }

    @Test func aBranchAheadOfItsTargetIsNotOnIt() {
        let ahead = context(branch: "feat/thing", target: .repositoryDefault("main"))

        #expect(ahead.isOnTarget == false)
        #expect(ahead.isEmpty == false)
    }

    /// Empty and on-target are different facts: a branch can be pointed at
    /// another branch and still have nothing to show, which is what a freshly
    /// created branch looks like.
    @Test func emptyAndOnTargetAreNotTheSameThing() {
        let freshBranch = context(
            branch: "feat/new", target: .repositoryDefault("main"), commits: 0, files: 0)

        #expect(freshBranch.isEmpty)
        #expect(freshBranch.isOnTarget == false)
    }
}

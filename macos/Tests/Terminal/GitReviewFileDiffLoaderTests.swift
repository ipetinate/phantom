import Foundation
@testable import Ghostty
import Testing

/// Loading one file's diff for the review.
///
/// The test that matters here is the one that runs it **off the main actor**,
/// because that is where it runs in the app and because the first version of
/// it reached for a `@MainActor` singleton from there. That is not a race — it
/// is `MainActor.assumeIsolated`, a precondition, so it aborted the process the
/// moment a reader expanded a file card. A signature that takes the target
/// instead cannot do it, and this is what proves the call survives the trip.
struct GitReviewFileDiffLoaderTests {
    /// This repository, which the test bundle is always run inside.
    private var root: String {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
        }
        return FileManager.default.currentDirectoryPath
    }

    @Test func loadingOffTheMainActorDoesNotTrap() async {
        let root = root
        let scope = GitReviewScope.branch(root: root)

        /// Detached, like the card's own load. If this reaches for anything
        /// main-actor-isolated it does not fail — it kills the test process.
        let loaded = await Task.detached(priority: .userInitiated) {
            GitReviewFileDiffLoader.load(
                path: "README.md",
                previousPath: nil,
                scope: scope,
                target: "HEAD"
            )
        }.value

        /// Any outcome is a pass — the repository's README may or may not
        /// differ from HEAD, and neither answer is this test's business. What
        /// is asserted is that the call *returned* instead of aborting.
        #expect(isAnswer(loaded.outcome))
    }

    @Test func aCommitScopeAlsoSurvivesTheTrip() async {
        let root = root
        let head = GitCommand.output(["rev-parse", "HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
        let scope = GitReviewScope.commit(root: root, sha: head, subject: "whatever")

        let loaded = await Task.detached(priority: .userInitiated) {
            GitReviewFileDiffLoader.load(
                path: "README.md",
                previousPath: nil,
                scope: scope,
                target: "HEAD"
            )
        }.value

        #expect(isAnswer(loaded.outcome))
    }

    /// Every case of the outcome counts, which is the point: this test is
    /// about surviving the call, not about what git said.
    private func isAnswer(_ outcome: GitDiffOutcome) -> Bool {
        switch outcome {
        case .diff, .unchanged, .conflicted, .tooLarge, .failed: return true
        }
    }

    // MARK: The commit line under a file's name

    /// Four fields separated by a unit separator, because a commit subject can
    /// hold a tab, a pipe or a comma and every one of those has been
    /// somebody's separator once.
    @Test func aCommitLineIsTakenApart() throws {
        let line = [
            "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            "Give the gutter its marks back",
            "Isac Petinate",
            "2 hours ago",
        ].joined(separator: "\u{1f}")

        let commit = try #require(GitReviewFileDiffLoader.parse(line))

        #expect(commit.shortSha == "a1b2c3d")
        #expect(commit.subject == "Give the gutter its marks back")
        #expect(commit.author == "Isac Petinate")
        #expect(commit.relativeDate == "2 hours ago")
    }

    /// A subject with a tab in it is one subject.
    @Test func aSubjectWithATabSurvives() throws {
        let line = "abc123\u{1f}fix:\tthe thing\u{1f}Someone\u{1f}now"

        let commit = try #require(GitReviewFileDiffLoader.parse(line))

        #expect(commit.subject == "fix:\tthe thing")
    }

    @Test func nothingUsefulIsNoCommit() {
        #expect(GitReviewFileDiffLoader.parse("") == nil)
        #expect(GitReviewFileDiffLoader.parse("only-one-field") == nil)
        #expect(GitReviewFileDiffLoader.parse("\u{1f}\u{1f}\u{1f}") == nil)
    }

    // MARK: The scope

    @Test func aCommitScopeNamesItselfBySubject() {
        let scope = GitReviewScope.commit(root: "/tmp", sha: "abcdef1234", subject: "Do a thing")

        #expect(scope.title == "Do a thing")
        #expect(scope.isCommit)
        #expect(scope.root == "/tmp")
    }

    /// A commit with no subject still has to be nameable on screen.
    @Test func aSubjectlessCommitFallsBackToItsSha() {
        let scope = GitReviewScope.commit(root: "/tmp", sha: "abcdef1234", subject: "")

        #expect(scope.title == "abcdef1")
    }

    /// The id is what the panel keys its reload on, so two scopes that mean
    /// different things must not share one.
    @Test func everyScopeHasItsOwnIdentity() {
        let branch = GitReviewScope.branch(root: "/tmp")
        let one = GitReviewScope.commit(root: "/tmp", sha: "aaa", subject: "x")
        let two = GitReviewScope.commit(root: "/tmp", sha: "bbb", subject: "x")

        #expect(branch.id != one.id)
        #expect(one.id != two.id)
        #expect(branch.isCommit == false)
    }
}

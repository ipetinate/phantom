import Foundation
@testable import Ghostty
import Testing

/// ``GitBranchReviewLoader`` against a real `git`, in repositories these
/// tests build and delete.
///
/// Everything here is a claim about git's *behaviour* — which range answers
/// which question, which ref wins when several could be the base, what a
/// repository looks like before its first commit. A fixture cannot check
/// any of that, because a fixture is only this file's opinion written down
/// twice. The repositories are created under the system temporary
/// directory, used, and removed; no repository of the user's is read or run
/// against, and nothing here reaches the network — the one test that needs
/// a remote clones over a local path.
///
/// Skipped outright on a machine with no git, rather than failed.
@Suite(.serialized, .enabled(if: GitCommand.path != nil))
struct GitBranchReviewLoaderTests {
    /// A throwaway repository.
    ///
    /// Configured locally against the user's global settings: a global
    /// `commit.gpgsign` would make every commit here wait on a signing key,
    /// and a global `core.hooksPath` would run their hooks against a
    /// repository they have never seen. The branch name is forced too — a
    /// user whose `init.defaultBranch` is `trunk` would otherwise be
    /// testing something else.
    private final class Repo {
        let root: String

        init() {
            root = Self.reserve()
            git("init", "-b", "main")
            configure()
        }

        /// A clone over a local path — no network, and it gets the two
        /// things a fresh clone has that a bare `git init` doesn't: an
        /// `origin` remote and `origin/HEAD`.
        init(cloning origin: Repo) {
            let destination = Self.reserve()
            try? FileManager.default.removeItem(atPath: destination)
            _ = GitCommand.run(
                ["clone", origin.root, destination],
                in: FileManager.default.temporaryDirectory.path,
                timeout: 60
            )
            root = destination
            configure()
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        private static func reserve() -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-review-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }

        private func configure() {
            git("config", "user.name", "Review Test")
            git("config", "user.email", "review@test.invalid")
            git("config", "commit.gpgsign", "false")
            git("config", "core.hooksPath", URL(fileURLWithPath: root).appendingPathComponent("no-hooks").path)
        }

        @discardableResult
        func git(_ arguments: String...) -> ShellCommand.Result {
            GitCommand.run(arguments, in: root, timeout: 30)
        }

        func write(_ contents: String, to path: String) {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func commit(_ message: String) {
            git("add", "-A")
            git("commit", "-m", message)
        }

        func sha(of revision: String) -> String {
            git("rev-parse", revision).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func expectReview(
        _ outcome: GitBranchReviewOutcome,
        _ location: SourceLocation = #_sourceLocation
    ) throws -> GitBranchReview {
        guard case .review(let review) = outcome else {
            Issue.record("expected a review, got \(outcome)", sourceLocation: location)
            throw CancellationError()
        }
        return review
    }

    /// A branch forked from `main`, with `main` moved on underneath it.
    private func forkedRepository() -> Repo {
        let repo = Repo()
        repo.write("shared\n", to: "shared.txt")
        repo.commit("base: first")

        repo.git("switch", "-c", "feat/x")
        repo.write("branch work\n", to: "branch.txt")
        repo.commit("branch: add branch.txt")

        repo.git("switch", "main")
        repo.write("landed while you were away\n", to: "base-only.txt")
        repo.commit("base: moved on")

        repo.git("switch", "feat/x")
        return repo
    }

    // The three-dot rule

    /// **The test this feature lives or dies by.**
    ///
    /// `main` gained a commit after the branch forked. Three dots compare
    /// against the merge base and report only this branch's work; two dots
    /// compare the two tips and would additionally report `base-only.txt`
    /// — as a *deletion*, since the branch doesn't have a file that only
    /// exists on `main` — crediting this branch with undoing somebody
    /// else's commit.
    @Test func showsOnlyTheBranchesOwnWorkWhenTheBaseMovedOn() throws {
        let repo = forkedRepository()

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.files.map(\.path) == ["branch.txt"])
        #expect(review.commits.map(\.subject) == ["branch: add branch.txt"])

        #expect(!review.files.contains { $0.path == "base-only.txt" })
        #expect(!review.commits.contains { $0.subject == "base: moved on" })
    }

    /// The other half of the same rule: what the file list was compared
    /// against is the fork point, not the base's tip.
    @Test func theBaseIsTheForkPointRatherThanTheBasesTip() throws {
        let repo = forkedRepository()
        let forkPoint = repo.sha(of: "main~1")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.base?.mergeBase == forkPoint)
        #expect(review.base?.mergeBase != repo.sha(of: "main"))
    }

    /// A branch that merged its base back in is the case where two dots
    /// looks most convincingly right and still isn't: the merge brings the
    /// base's commits into `HEAD`, and only a merge-base comparison keeps
    /// them out of the branch's own work.
    @Test func mergingTheBaseInDoesNotMakeItsFilesThisBranchesWork() throws {
        let repo = forkedRepository()
        repo.git("merge", "--no-edit", "main")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(!review.files.contains { $0.path == "base-only.txt" })
        #expect(!review.commits.contains { $0.subject == "base: moved on" })
        #expect(review.files.map(\.path) == ["branch.txt"])
    }

    // Finding the base

    @Test func fallsBackToAWellKnownNameWhenThereIsNoRemote() throws {
        let repo = forkedRepository()

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.base?.ref == "main")
        #expect(review.base?.source == .wellKnown)
        #expect(review.branch == "feat/x")
    }

    /// A branch that has been pushed tracks its own copy on the remote.
    /// Taking that as the base would answer "what haven't I pushed", and
    /// the question here is what the pull request will contain — so the
    /// search steps over it and lands on the remote's default branch.
    @Test func aPushedBranchIsNotComparedAgainstItsOwnRemoteCopy() throws {
        let origin = Repo()
        origin.write("shared\n", to: "shared.txt")
        origin.commit("base: first")

        let clone = Repo(cloning: origin)
        clone.git("switch", "-c", "feat/x")
        clone.write("branch work\n", to: "branch.txt")
        clone.commit("branch: add branch.txt")
        clone.git("push", "-u", "origin", "feat/x")

        /// The upstream really is the branch's own copy — otherwise this
        /// test proves nothing about the rule it is named after.
        let upstream = clone.git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(upstream == "origin/feat/x")

        let review = try expectReview(GitBranchReviewLoader.load(in: clone.root))

        #expect(review.base?.ref == "origin/main")
        #expect(review.base?.source == .remoteHead)
        #expect(review.files.map(\.path) == ["branch.txt"])
    }

    /// An upstream that is somebody's deliberate answer to "what is this
    /// branch for" wins over every guess below it.
    @Test func aConfiguredUpstreamWinsOverTheGuesses() throws {
        let origin = Repo()
        origin.write("shared\n", to: "shared.txt")
        origin.commit("base: first")
        origin.git("switch", "-c", "develop")
        origin.write("release lane\n", to: "develop.txt")
        origin.commit("develop: lane")
        origin.git("switch", "main")

        let clone = Repo(cloning: origin)
        clone.git("switch", "-c", "feat/x", "origin/develop")
        clone.git("branch", "--set-upstream-to=origin/develop", "feat/x")
        clone.write("branch work\n", to: "branch.txt")
        clone.commit("branch: add branch.txt")

        let review = try expectReview(GitBranchReviewLoader.load(in: clone.root))

        #expect(review.base?.ref == "origin/develop")
        #expect(review.base?.source == .upstream)
        #expect(review.files.map(\.path) == ["branch.txt"])
    }

    @Test func usesWhateverOriginHeadPointsAt() throws {
        let origin = Repo()
        origin.write("shared\n", to: "shared.txt")
        origin.commit("base: first")

        let clone = Repo(cloning: origin)
        clone.git("switch", "-c", "feat/x")
        clone.write("branch work\n", to: "branch.txt")
        clone.commit("branch: add branch.txt")

        let review = try expectReview(GitBranchReviewLoader.load(in: clone.root))

        #expect(review.base?.ref == "origin/main")
        #expect(review.base?.source == .remoteHead)
    }

    /// One branch, no remote, nothing to compare against. An ordinary
    /// repository to open, and the answer is a review that says it has no
    /// base — not a failure, and not an empty list that reads as a clean
    /// branch.
    @Test func aRepositoryWithOneBranchAndNoRemoteHasNoBase() throws {
        let repo = Repo()
        repo.write("only\n", to: "file.txt")
        repo.commit("first")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.base == nil)
        #expect(review.branch == "main")
        #expect(review.isEmpty)
        #expect(!review.isUnborn)
    }

    @Test func aBranchIdenticalToItsBaseHasABaseAndNothingElse() throws {
        let repo = Repo()
        repo.write("shared\n", to: "shared.txt")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.base?.ref == "main")
        #expect(review.commits.isEmpty)
        #expect(review.files.isEmpty)
        #expect(review.base?.mergeBase == repo.sha(of: "HEAD"))
    }

    // The states that are not errors

    @Test func aDetachedHeadHasNoBranchAndStillReviews() throws {
        let repo = forkedRepository()
        repo.git("switch", "--detach", "HEAD")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.isDetached)
        #expect(review.branch == nil)
        #expect(review.base?.ref == "main")
        #expect(review.files.map(\.path) == ["branch.txt"])
    }

    /// Before the first commit there is no `HEAD` to resolve and no base to
    /// find, and git's own exit status separates that from a directory that
    /// isn't a repository at all.
    @Test func aRepositoryWithNoCommitsIsAReviewRatherThanAnError() throws {
        let repo = Repo()
        repo.write("staged but never committed\n", to: "file.txt")
        repo.git("add", "-A")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.isUnborn)
        #expect(review.head == nil)
        #expect(review.branch == "main")
        #expect(review.base == nil)
        #expect(review.isEmpty)
    }

    @Test func aDirectoryThatIsNotARepositoryFails() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-review-plain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .failed = GitBranchReviewLoader.load(in: url.path) else {
            Issue.record("expected a failure outside a repository")
            return
        }
    }

    @Test func anExplicitBaseThatDoesNotExistIsAFailureRatherThanAGuess() {
        let repo = forkedRepository()

        guard case .failed(let failure) = GitBranchReviewLoader.load(in: repo.root, base: "origin/nope") else {
            Issue.record("expected a failure for an unknown base")
            return
        }
        #expect(failure.raw.contains("origin/nope"))
    }

    @Test func anExplicitBaseIsUsedAsGiven() throws {
        let repo = forkedRepository()

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root, base: "main"))

        #expect(review.base?.ref == "main")
        #expect(review.base?.source == .explicit)
    }

    // What the branch changed

    @Test func carriesTheCommitsMetadataAndTheirOrder() throws {
        let repo = Repo()
        repo.write("shared\n", to: "shared.txt")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")
        repo.write("one\n", to: "one.txt")
        repo.commit("branch: with\ttab and \"quotes\" and | pipe")
        repo.write("two\n", to: "two.txt")
        repo.commit("branch: second")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.commits.map(\.subject) == [
            "branch: second",
            "branch: with\ttab and \"quotes\" and | pipe",
        ])
        #expect(review.commits[0].sha == repo.sha(of: "HEAD"))
        #expect(review.commits[0].shortSha.count == 7)
        #expect(review.commits.allSatisfy { $0.author == "Review Test" })
        #expect(review.commits.allSatisfy { !$0.relativeDate.isEmpty })
        #expect(!review.hasMoreCommits)
    }

    /// A rename has to arrive as a rename — `old → new` is what the row
    /// shows — and an accented path has to arrive as itself rather than as
    /// `"arquivo-a\303\247\303\243o.ts"`.
    @Test func reportsARenameWithItsPreviousPathAndKeepsTheAccents() throws {
        let repo = Repo()
        repo.write(String(repeating: "line\n", count: 20), to: "arquivo-ação.ts")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")
        repo.git("mv", "arquivo-ação.ts", "renomeado-ação.ts")
        repo.commit("branch: rename")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.files.count == 1)
        #expect(review.files[0].path == "renomeado-ação.ts")
        #expect(review.files[0].previousPath == "arquivo-ação.ts")
        #expect(review.files[0].status == .renamed)
    }

    @Test func countsLinesAndLeavesBinaryFilesUncounted() throws {
        let repo = Repo()
        repo.write("shared\n", to: "shared.txt")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")
        repo.write("one\ntwo\nthree\n", to: "added.txt")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: URL(fileURLWithPath: repo.root).appendingPathComponent("blob.bin"))
        repo.commit("branch: content")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        let text = try #require(review.files.first { $0.path == "added.txt" })
        #expect(text.status == .added)
        #expect(text.addedLines == 3)
        #expect(text.removedLines == 0)

        let binary = try #require(review.files.first { $0.path == "blob.bin" })
        #expect(binary.isBinary)
        #expect(binary.addedLines == nil)

        /// The totals count the lines they know about and say how many
        /// files they had nothing to count.
        #expect(review.addedLines == 3)
        #expect(review.binaryFileCount == 1)
    }

    @Test func reportsADeletedFileAsADeletion() throws {
        let repo = Repo()
        repo.write("gone soon\n", to: "doomed.txt")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")
        repo.git("rm", "doomed.txt")
        repo.commit("branch: delete")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.files.map(\.status) == [.deleted])
        #expect(review.files[0].removedLines == 1)
    }

    /// The working tree is the Git panel's subject, not this one's: an
    /// uncommitted edit belongs to neither the commit list nor the file
    /// list here.
    @Test func ignoresTheWorkingTree() throws {
        let repo = forkedRepository()
        repo.write("uncommitted\n", to: "scratch.txt")
        repo.write("edited but not committed\n", to: "shared.txt")

        let review = try expectReview(GitBranchReviewLoader.load(in: repo.root))

        #expect(review.files.map(\.path) == ["branch.txt"])
    }

    /// A list that silently stops at a round number tells the reader a lie
    /// about their own branch.
    @Test func saysWhenItStoppedReadingCommits() throws {
        let repo = Repo()
        repo.write("shared\n", to: "shared.txt")
        repo.commit("base: first")
        repo.git("switch", "-c", "feat/x")
        for index in 1...3 {
            repo.write("\(index)\n", to: "file-\(index).txt")
            repo.commit("branch: \(index)")
        }

        let limited = try expectReview(GitBranchReviewLoader.load(in: repo.root, commitLimit: 2))
        #expect(limited.commits.count == 2)
        #expect(limited.hasMoreCommits)
        /// Truncating the list does not truncate the files.
        #expect(limited.files.count == 3)

        let whole = try expectReview(GitBranchReviewLoader.load(in: repo.root, commitLimit: 3))
        #expect(whole.commits.count == 3)
        #expect(!whole.hasMoreCommits)
    }
}

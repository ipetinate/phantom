import Foundation
@testable import Ghostty
import Testing

/// A review goes stale when the commits it describes move, and the branch's
/// name is not one of those commits.
///
/// Reported with numbers: a pull request GitHub showed as 5 commits and 4
/// files was reported by the branch review as 39 commits and 161 files. The
/// numbers had been right when they were computed — reproduced exactly by
/// comparing against where `main` sat before that morning's fetch — and the
/// base had moved forward since. Nothing told the screen, because the only
/// thing being watched was the branch's name and that had not changed.
///
/// These tests build real repositories, because the rule is about what git
/// answers and a fake would only assert the shape of the question.
struct GitReviewStalenessTests {
    private func run(_ arguments: [String], in root: String) {
        _ = GitCommand.run(arguments, in: root)
    }

    /// A repository with a `main` and a feature branch one commit ahead.
    private func repository() -> String {
        let root = NSTemporaryDirectory() + "review-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)

        run(["init", "--initial-branch=main", "."], in: root)
        run(["config", "user.email", "t@t.t"], in: root)
        run(["config", "user.name", "T"], in: root)
        try? "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        run(["add", "-A"], in: root)
        run(["commit", "-m", "base"], in: root)

        run(["checkout", "-b", "feature"], in: root)
        try? "one\ntwo\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        run(["add", "-A"], in: root)
        run(["commit", "-m", "the branch's own work"], in: root)
        return root
    }

    private func remove(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func sha(_ ref: String, in root: String) -> String? {
        GitCommand.output(["rev-parse", "--verify", "--quiet", ref], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitCount(base: String, in root: String) -> Int {
        Int(GitCommand.output(["rev-list", "--count", "\(base)..HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
    }

    // MARK: The reported case

    /// The base moving is invisible to anything watching the branch name, and
    /// it changes every number on the screen.
    @Test func aBaseThatMovedChangesTheAnswerWithoutRenamingAnything() throws {
        let root = repository()
        defer { remove(root) }

        let branchBefore = GitCommand.output(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
        let headBefore = try #require(sha("HEAD", in: root))
        let baseBefore = try #require(sha("main", in: root))
        #expect(commitCount(base: "main", in: root) == 1)

        /// What a fetch does: `main` gains commits the branch does not have.
        run(["checkout", "main"], in: root)
        for index in 0..<3 {
            try? "main \(index)\n".write(
                toFile: root + "/m\(index).txt", atomically: true, encoding: .utf8)
            run(["add", "-A"], in: root)
            run(["commit", "-m", "main moved \(index)"], in: root)
        }
        run(["checkout", "feature"], in: root)

        let branchAfter = GitCommand.output(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
        #expect(branchAfter == branchBefore, "the name is the same, which is the trap")
        #expect(sha("HEAD", in: root) == headBefore, "and HEAD never moved")
        #expect(sha("main", in: root) != baseBefore, "but the base did")

        /// The branch still contributes one commit. A review that cached the
        /// old base would keep reporting against a commit that is no longer
        /// where `main` points.
        #expect(commitCount(base: "main", in: root) == 1)
        #expect(commitCount(base: baseBefore, in: root) == 1)
    }

    /// The other end. A commit on the branch moves HEAD, and the name does not
    /// change for that either.
    @Test func aCommitOnTheBranchMovesTheOtherEnd() throws {
        let root = repository()
        defer { remove(root) }

        let headBefore = try #require(sha("HEAD", in: root))
        #expect(commitCount(base: "main", in: root) == 1)

        try? "one\ntwo\nthree\n".write(
            toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        run(["add", "-A"], in: root)
        run(["commit", "-m", "more work"], in: root)

        #expect(sha("HEAD", in: root) != headBefore)
        #expect(commitCount(base: "main", in: root) == 2, "the review is now wrong by one")
    }

    // MARK: What the check has to be able to read

    /// Both endpoints in one call, which is what makes checking them on every
    /// status tick affordable.
    @Test func bothEndpointsComeBackFromOneCall() throws {
        let root = repository()
        defer { remove(root) }

        let output = try #require(GitCommand.output(["rev-parse", "HEAD", "main"], in: root))
        let lines = output.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0] == sha("HEAD", in: root))
        #expect(lines[1] == sha("main", in: root))
    }

    /// `--verify` takes one revision. Given two it prints nothing and still
    /// exits zero, so a check written that way answers "cannot tell" forever
    /// and never invalidates anything. Pinned because it is a silent failure
    /// and the next person to add a flag here deserves to be stopped.
    @Test func verifyRefusesTwoRevisionsWithoutSayingSo() {
        let root = repository()
        defer { remove(root) }

        let output = GitCommand.output(
            ["rev-parse", "--verify", "--quiet", "HEAD", "main"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output?.isEmpty != false, "two revisions past --verify produce nothing")
    }

    /// A base that cannot be resolved must read as "cannot tell", never as
    /// "moved" — otherwise the review reloads on every tick for as long as the
    /// ref stays unreadable.
    @Test func anUnreadableBaseIsNotAMove() throws {
        let root = repository()
        defer { remove(root) }

        let hashes = (GitCommand.output(["rev-parse", "HEAD", "no-such-branch"], in: root) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }

        /// git prints the good hash before complaining, so a count alone
        /// would take a partial answer for a whole one.
        #expect(hashes.count != 2)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// `GitDiffLoader` against a real `git`, in a repository these tests build
/// and delete.
///
/// Everything here is a claim about git's *behaviour* rather than about
/// parsing — which flags produce which output, and which exit status means
/// what. Those cannot be checked against a fixture, because a fixture is
/// only this file's opinion written down twice. The repository is created
/// under the system temporary directory, used, and removed; no repository
/// of the user's is read or run against.
///
/// Skipped outright on a machine with no git, rather than failed.
@Suite(.serialized, .enabled(if: GitCommand.path != nil))
struct GitDiffLoaderTests {
    /// A throwaway repository.
    ///
    /// Configured locally against the user's global settings: a global
    /// `commit.gpgsign` would make every commit here wait on a signing key,
    /// and a global `core.hooksPath` would run their hooks against a
    /// repository they have never seen.
    private final class Repo {
        let root: String

        init() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-diff-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = url.path

            git("init")
            git("config", "user.name", "Diff Test")
            git("config", "user.email", "diff@test.invalid")
            git("config", "commit.gpgsign", "false")
            git("config", "core.hooksPath", url.appendingPathComponent("no-hooks").path)
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
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

        func status() -> GitStatus {
            GitStatus.parse(porcelainV2: git("status", "--porcelain=v2", "--branch").stdout)
        }
    }

    private func expectDiff(_ outcome: GitDiffOutcome, _ location: SourceLocation = #_sourceLocation) throws -> GitDiffDocument {
        guard case .diff(let document) = outcome else {
            Issue.record("expected a diff, got \(outcome)", sourceLocation: location)
            throw CancellationError()
        }
        return document
    }

    // MARK: The two sides

    @Test func readsTheWorkingTreeAgainstTheIndex() throws {
        let repo = Repo()
        repo.write("one\ntwo\nthree\n", to: "file.txt")
        repo.commit("first")
        repo.write("one\nTWO\nthree\n", to: "file.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root))

        #expect(document.file.path == "file.txt")
        #expect(document.file.status == .modified)
        #expect(document.file.addedCount == 1)
        #expect(document.file.removedCount == 1)
        #expect(document.rows.contains { $0.left?.text == "two" && $0.right?.text == "TWO" })
    }

    @Test func readsTheIndexAgainstHead() throws {
        let repo = Repo()
        repo.write("one\n", to: "file.txt")
        repo.commit("first")
        repo.write("one\ntwo\n", to: "file.txt")
        repo.git("add", "file.txt")

        // Staged and unstaged are different questions about the same file,
        // and after staging only one of them has an answer.
        let staged = try expectDiff(GitDiffLoader.load(path: "file.txt", side: .staged, in: repo.root))
        #expect(staged.file.addedCount == 1)
        #expect(GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root) == .unchanged)
    }

    /// `git diff --cached` on a repository with no commits at all still
    /// works: there is no `HEAD` to compare against and git uses the empty
    /// tree instead. Worth pinning, because the obvious alternative
    /// spelling — `git diff HEAD` — fails outright here.
    @Test func aStagedFileInARepositoryWithNoCommitsIsAnAddition() throws {
        let repo = Repo()
        repo.write("a\nb\n", to: "new.txt")
        repo.git("add", "new.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "new.txt", side: .staged, in: repo.root))
        #expect(document.file.status == .added)
        #expect(document.rows.count == 2)
        #expect(document.rows.allSatisfy { $0.left == nil })
    }

    @Test func aCleanPathReportsNothingRatherThanAnEmptyDiff() {
        let repo = Repo()
        repo.write("stable\n", to: "file.txt")
        repo.commit("first")

        #expect(GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root) == .unchanged)
        #expect(GitDiffLoader.load(path: "file.txt", side: .staged, in: repo.root) == .unchanged)
    }

    // MARK: Untracked files

    /// `git diff` has nothing to say about a path that is not in the index,
    /// so a viewer that only runs it shows a blank pane for every new file.
    /// `--no-index` is what makes one readable.
    @Test func anUntrackedFileIsReadThroughNoIndex() throws {
        let repo = Repo()
        repo.write("seed\n", to: "seed.txt")
        repo.commit("first")
        repo.write("x\ny\n", to: "fresh.txt")

        let change = GitFileChange(
            path: "fresh.txt",
            originalPath: nil,
            index: ".",
            worktree: "?",
            isUntracked: true,
            isUnmerged: false
        )

        let document = try expectDiff(GitDiffLoader.load(change, side: .unstaged, in: repo.root))
        #expect(document.file.status == .added)
        #expect(document.file.path == "fresh.txt")
        #expect(document.rows.count == 2)
        #expect(document.rows.map { $0.right?.text } == ["x", "y"])
    }

    /// `--no-index` reports a difference through its exit status, the way
    /// `diff(1)` does. Read as a failure, every untracked file in the panel
    /// becomes an error message.
    @Test func exitStatusOneFromNoIndexIsADifferenceNotAFailure() throws {
        let repo = Repo()
        repo.write("content\n", to: "fresh.txt")

        let raw = GitCommand.run(
            ["diff", "--no-index", "--no-color", "--", "/dev/null", "fresh.txt"],
            in: repo.root
        )
        #expect(raw.status == 1, "the premise: git says 1 here")
        #expect(!raw.succeeded)

        let document = try expectDiff(GitDiffLoader.loadUntracked(path: "fresh.txt", in: repo.root))
        #expect(document.rows.count == 1)
    }

    @Test func anUntrackedFileHasNoStagedSide() {
        let repo = Repo()
        repo.write("x\n", to: "fresh.txt")

        let change = GitFileChange(
            path: "fresh.txt",
            originalPath: nil,
            index: ".",
            worktree: "?",
            isUntracked: true,
            isUnmerged: false
        )

        #expect(GitDiffLoader.load(change, side: .staged, in: repo.root) == .unchanged)
    }

    // MARK: Deleted files

    /// A deleted file is the case a diff viewer is *most* useful for: it is
    /// the only way left to see what was in it. The loader never touches
    /// the filesystem — the pathspec is matched against the index, not the
    /// working tree — so a path that no longer exists on disk diffs
    /// perfectly well.
    @Test func aFileDeletedFromTheWorkingTreeStillHasAReadableDiff() throws {
        let repo = Repo()
        repo.write("alpha\nbeta\ngamma\n", to: "doomed.txt")
        repo.commit("first")
        try FileManager.default.removeItem(atPath: repo.root + "/doomed.txt")
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/doomed.txt"), "the premise")

        let change = try #require(repo.status().unstaged.first)
        #expect(change.worktree == "D", "the premise: porcelain v2 calls this a worktree deletion")

        let document = try expectDiff(GitDiffLoader.load(change, side: .unstaged, in: repo.root))
        #expect(document.file.status == .deleted)
        #expect(document.file.path == "doomed.txt", "named by the path it had")
        #expect(document.rows.count == 3)
        #expect(document.rows.allSatisfy { $0.right == nil }, "the new side of a deletion is all blank")
        #expect(document.rows.map { $0.left?.text } == ["alpha", "beta", "gamma"])
        #expect(document.rows.map { $0.left?.oldNumber } == [1, 2, 3])
    }

    @Test func aStagedDeletionDiffsAgainstHead() throws {
        let repo = Repo()
        repo.write("alpha\nbeta\n", to: "doomed.txt")
        repo.commit("first")
        repo.git("rm", "-q", "doomed.txt")

        let change = try #require(repo.status().staged.first)
        #expect(change.index == "D", "the premise: porcelain v2 calls this a staged deletion")

        let document = try expectDiff(GitDiffLoader.load(change, side: .staged, in: repo.root))
        #expect(document.file.status == .deleted)
        #expect(document.rows.allSatisfy { $0.right == nil })
    }

    // MARK: Renames

    /// Why ``GitDiffLoader/load(path:previousPath:side:in:context:)`` takes
    /// a second path.
    ///
    /// A pathspec filters the comparison *before* rename detection runs, so
    /// naming only the new path hides the deletion detection needs to see.
    /// Git then reports a whole-file addition, and a renamed thousand-line
    /// file reads as a thousand added lines with the actual edit invisible
    /// among them.
    @Test func renameDetectionNeedsBothEndsOfTheRename() throws {
        let repo = Repo()
        repo.write("one\ntwo\nthree\n", to: "before.txt")
        repo.commit("first")
        repo.git("mv", "before.txt", "after.txt")

        let withBoth = try expectDiff(
            GitDiffLoader.load(path: "after.txt", previousPath: "before.txt", side: .staged, in: repo.root)
        )
        #expect(withBoth.file.status == .renamed)
        #expect(withBoth.file.previousPath == "before.txt")
        #expect(withBoth.file.isPureRename)

        let withOnlyTheNewPath = try expectDiff(
            GitDiffLoader.load(path: "after.txt", side: .staged, in: repo.root)
        )
        #expect(
            withOnlyTheNewPath.file.status == .added,
            "git cannot see a rename whose other end the pathspec filtered out"
        )
    }

    /// And a ``GitFileChange`` from the panel already carries that other
    /// end, which is why the change-based entry point is the one to prefer.
    @Test func aChangeFromTheStatusPanelCarriesTheOldPathItself() throws {
        let repo = Repo()
        repo.write("one\ntwo\nthree\n", to: "before.txt")
        repo.commit("first")
        repo.git("mv", "before.txt", "after.txt")

        let change = try #require(repo.status().staged.first)
        #expect(change.originalPath == "before.txt", "the premise: porcelain v2 says so")

        let document = try expectDiff(GitDiffLoader.load(change, side: .staged, in: repo.root))
        #expect(document.file.status == .renamed)
    }

    // MARK: Conflicts

    @Test func aConflictedPathIsReportedRatherThanMisread() throws {
        let repo = Repo()
        repo.write("base\nvalue\n", to: "conf.txt")
        repo.commit("first")
        repo.git("checkout", "-b", "other")
        repo.write("base\nTHEIRS\n", to: "conf.txt")
        repo.commit("theirs")
        repo.git("checkout", "-")
        repo.write("base\nOURS\n", to: "conf.txt")
        repo.commit("ours")
        repo.git("merge", "other")

        let change = try #require(repo.status().unmerged.first)
        #expect(GitDiffLoader.load(change, side: .unstaged, in: repo.root) == .conflicted)

        // And by raw path too, where there is no `GitFileChange` to say so:
        // git answers with a combined diff on one side and a one-line
        // notice on the other.
        #expect(GitDiffLoader.load(path: "conf.txt", side: .unstaged, in: repo.root) == .conflicted)
        #expect(GitDiffLoader.load(path: "conf.txt", side: .staged, in: repo.root) == .conflicted)
    }

    // MARK: Flags

    /// A user with `color.ui = always` gets ANSI escapes in piped output
    /// too. They would land inside the line text and be drawn.
    @Test func colorConfiguredAlwaysDoesNotLeakIntoTheLines() throws {
        let repo = Repo()
        repo.git("config", "color.ui", "always")
        repo.git("config", "color.diff", "always")
        repo.write("one\n", to: "file.txt")
        repo.commit("first")
        repo.write("ONE\n", to: "file.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root))
        #expect(document.file.lines.allSatisfy { !$0.text.contains("\u{1B}") })
        #expect(document.file.lines.map(\.text) == ["one", "ONE"])
    }

    /// `diff.external` replaces git's output wholesale with whatever the
    /// tool prints. Anything can come back, including nothing at all.
    @Test func anExternalDiffToolIsNotConsulted() throws {
        let repo = Repo()
        repo.git("config", "diff.external", "/usr/bin/true")
        repo.write("one\n", to: "file.txt")
        repo.commit("first")
        repo.write("ONE\n", to: "file.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root))
        #expect(document.file.hunks.count == 1)
    }

    /// Non-ASCII paths arrive C-escaped unless `core.quotePath` is turned
    /// off, and an escaped path matches nothing the panel asked about.
    @Test func anAccentedPathComesBackAsItself() throws {
        let repo = Repo()
        repo.write("um\n", to: "coração.txt")
        repo.commit("first")
        repo.write("dois\n", to: "coração.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "coração.txt", side: .unstaged, in: repo.root))
        #expect(document.file.path == "coração.txt")
    }

    @Test func aPathWithASpaceComesBackWithoutGitsTrailingTab() throws {
        let repo = Repo()
        repo.write("um\n", to: "my file.txt")
        repo.commit("first")
        repo.write("dois\n", to: "my file.txt")

        let document = try expectDiff(GitDiffLoader.load(path: "my file.txt", side: .unstaged, in: repo.root))
        #expect(document.file.path == "my file.txt")
    }

    /// Context is a parameter because the two useful settings are far
    /// apart: a few lines gives islands with gap bands between them, and a
    /// number larger than the file gives a whole-file view. Git has no
    /// spelling for "all".
    @Test func theContextSettingReachesGit() throws {
        let repo = Repo()
        repo.write((1...40).map { "line \($0)\n" }.joined(), to: "file.txt")
        repo.commit("first")
        repo.write((1...40).map { $0 == 20 ? "CHANGED\n" : "line \($0)\n" }.joined(), to: "file.txt")

        let tight = try expectDiff(
            GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root, context: 1)
        )
        #expect(tight.file.hunks[0].lines.count == 4, "one line either side, plus the swap")

        let whole = try expectDiff(
            GitDiffLoader.load(path: "file.txt", side: .unstaged, in: repo.root, context: 10_000)
        )
        #expect(whole.file.hunks[0].lines.count == 41, "40 lines, one of them replaced")
    }

    // MARK: Binary

    @Test func aBinaryFileSaysSoRatherThanShowingAnEmptyPane() throws {
        let repo = Repo()
        let url = URL(fileURLWithPath: repo.root).appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: url)
        repo.commit("first")
        try Data([0x00, 0x01, 0x03, 0xFE]).write(to: url)

        let document = try expectDiff(GitDiffLoader.load(path: "blob.bin", side: .unstaged, in: repo.root))
        #expect(document.file.isBinary)
        #expect(document.rows.isEmpty)
        #expect(!document.file.isEmpty, "there is something to say, just not lines")
    }

    // MARK: Too much to draw

    /// A checked-in bundle or a generated lockfile produces megabytes of
    /// unified diff. Parsing it is the cheap part; laying out a million
    /// rows is not, and nobody is reading it either way.
    @Test func aDiffTooBigToDrawIsRefusedRatherThanRendered() throws {
        let repo = Repo()
        let line = String(repeating: "x", count: 79) + "\n"
        repo.write(String(repeating: line, count: 60_000), to: "huge.txt")
        repo.git("add", "huge.txt")

        guard case .tooLarge(let bytes) = GitDiffLoader.load(path: "huge.txt", side: .staged, in: repo.root)
        else {
            Issue.record("expected the size guard to fire")
            return
        }
        #expect(bytes > GitDiffLoader.maximumOutputBytes)
    }

    // MARK: Failure

    @Test func aDirectoryThatIsNotARepositoryFailsWithSomethingReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .failed(let failure) = GitDiffLoader.load(path: "x", side: .unstaged, in: url.path) else {
            Issue.record("expected a failure outside a repository")
            return
        }
        #expect(failure.title == "Not a git repository")
    }
}

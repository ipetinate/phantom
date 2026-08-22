import Foundation
@testable import Ghostty
import Testing

/// `WorktreeCenter.loadMerged` against a real `git`.
///
/// The whole point of the merged check is to say "this branch has landed,
/// the folder can go" — an offer that, wrong once, deletes work. So none of
/// it is testable against fixtures: `git branch --merged` has its own
/// definition of merged, and the case that matters most is the one where
/// git's answer is technically right and useless. A branch cut from the base
/// and not yet committed to *is* merged, vacuously, and the whole tip rule
/// exists because of it.
///
/// The remote is a bare clone over a local path — no network. The
/// repositories are created under the system temporary directory, used, and
/// removed; no repository of the user's is read or run against.
///
/// Skipped outright on a machine with no git, rather than failed.
@Suite(.serialized, .enabled(if: GitCommand.path != nil))
struct WorktreeMergedTests {
    /// A throwaway repository, plus the worktrees added to it.
    ///
    /// Configured locally against the user's global settings: a global
    /// `commit.gpgsign` would make every commit here wait on a signing key,
    /// and a global `core.hooksPath` would run their hooks against a
    /// repository they have never seen. The branch name is forced too — a
    /// user whose `init.defaultBranch` is `trunk` would otherwise be
    /// testing something else.
    private final class Repo {
        let root: String
        private var worktreePaths: [String] = []

        init() {
            root = Self.reserve()
            git("init", "-b", "main")
            configure()
        }

        /// A bare clone over a local path, standing in for the remote. Bare
        /// because a checked-out branch cannot be pushed to, and the point
        /// of this remote is to receive the merge that makes a branch
        /// merged.
        init(bareCloning origin: Repo) {
            let destination = Self.reserve()
            try? FileManager.default.removeItem(atPath: destination)
            _ = GitCommand.run(
                ["clone", "--bare", origin.root, destination],
                in: FileManager.default.temporaryDirectory.path,
                timeout: 60
            )
            root = Self.real(destination)
            configure()
        }

        /// An ordinary clone — which is where `origin/HEAD` comes from, and
        /// `origin/HEAD` is what the base resolution falls back to once the
        /// branch's own remote copy has been stepped over.
        init(cloning origin: Repo) {
            let destination = Self.reserve()
            try? FileManager.default.removeItem(atPath: destination)
            _ = GitCommand.run(
                ["clone", origin.root, destination],
                in: FileManager.default.temporaryDirectory.path,
                timeout: 60
            )
            root = Self.real(destination)
            configure()
        }

        deinit {
            for path in worktreePaths { try? FileManager.default.removeItem(atPath: path) }
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Resolved, because git prints resolved paths in the worktree
        /// list. Every derived path inherits the resolution from here.
        private static func reserve() -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-merged-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return real(url.path)
        }

        /// The real path, symlinks and all.
        ///
        /// Git prints fully resolved paths in the worktree list, and the
        /// system temporary directory is behind a symlink (`/var` is
        /// `/private/var`). `URL.resolvingSymlinksInPath` cannot be used to
        /// meet it there: Foundation resolves the symlink and then
        /// deliberately strips the leading `/private` back off, so the two
        /// spellings never converge and every path assertion fails for a
        /// reason that has nothing to do with worktrees.
        ///
        /// Same call, in the same place, as `EditorFolderRepathTests`'
        /// `workspace()` — resolved once when the directory is created, so
        /// that every path derived from it is already in git's spelling and
        /// no assertion has to remember to convert.
        private static func real(_ path: String) -> String {
            var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &buffer) != nil else { return path }
            return String(cString: buffer)
        }

        private func configure() {
            git("config", "user.name", "Merged Test")
            git("config", "user.email", "merged@test.invalid")
            git("config", "commit.gpgsign", "false")
            git("config", "core.hooksPath", URL(fileURLWithPath: root).appendingPathComponent("no-hooks").path)
        }

        @discardableResult
        func git(_ arguments: String...) -> ShellCommand.Result {
            GitCommand.run(arguments, in: root, timeout: 60)
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

        func reserveWorktree(_ name: String) -> String {
            let path = URL(fileURLWithPath: root)
                .deletingLastPathComponent()
                .appendingPathComponent("\(URL(fileURLWithPath: root).lastPathComponent)-\(name)")
                .path
            worktreePaths.append(path)
            return path
        }

        @discardableResult
        func addWorktree(_ name: String, branch: String) -> String {
            let path = reserveWorktree(name)
            git("worktree", "add", path, "-b", branch)
            return path
        }

        /// A commit made inside one of this repository's worktrees, so the
        /// branch it is on moves rather than the main checkout's.
        func commitInWorktree(_ path: String, file: String, message: String) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(file)
            try? message.write(to: url, atomically: true, encoding: .utf8)
            _ = GitCommand.run(["add", "-A"], in: path, timeout: 60)
            _ = GitCommand.run(["commit", "-m", message], in: path, timeout: 60)
        }
    }

    /// A clone whose remote already carries `feat/landed`, with three more
    /// branches in worktrees: one landed, one still open, one cut from the
    /// base a moment ago.
    private struct Fixture {
        let seed: Repo
        let origin: Repo
        let work: Repo
        let landed: String
        let open: String
        let fresh: String
    }

    private func fixture() -> Fixture {
        let seed = Repo()
        seed.write("one\n", to: "file.txt")
        seed.commit("first")

        let origin = Repo(bareCloning: seed)
        let work = Repo(cloning: origin)

        let landed = work.addWorktree("landed", branch: "feat/landed")
        work.commitInWorktree(landed, file: "landed.txt", message: "landed work")

        let open = work.addWorktree("open", branch: "feat/open")
        work.commitInWorktree(open, file: "open.txt", message: "open work")

        land("feat/landed", into: work)

        let fresh = work.addWorktree("fresh", branch: "feat/fresh")

        return Fixture(seed: seed, origin: origin, work: work, landed: landed, open: open, fresh: fresh)
    }

    /// Merges a branch into `main` and pushes, so the remote's default
    /// branch really contains it.
    ///
    /// `--no-ff` on purpose. A fast-forward would leave `main` and the
    /// branch on the same commit, the tip rule would then exclude the very
    /// branch the fixture needs to be merged, and the test would pass while
    /// checking nothing.
    private func land(_ branch: String, into work: Repo) {
        work.git("merge", "--no-ff", "-m", "merge \(branch)", branch)
        work.git("push", "origin", "main")
    }

    // MARK: The base

    /// The base is resolved the same way the branch review pane resolves it:
    /// the branch's own remote copy is stepped over, and `origin/HEAD` — the
    /// remote's default branch, recorded at clone — answers.
    @Test func resolvesTheBaseFromTheRemotesDefaultBranch() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(commonRoot: fixture.work.root, worktrees: list))

        #expect(load.base == "origin/main")
    }

    /// A cached base is used as given, without resolving again — the
    /// resolution is several git calls and its answer changes about as often
    /// as a remote's default branch does.
    @Test func aKnownBaseIsUsedWithoutResolvingAgain() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(
            commonRoot: fixture.work.root,
            worktrees: list,
            knownBase: "origin/main"
        ))

        #expect(load.base == "origin/main")
        #expect(load.merged.contains("feat/landed"))
    }

    // MARK: What counts as merged

    @Test func aBranchThatLandedOnTheBaseIsMerged() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(commonRoot: fixture.work.root, worktrees: list))

        #expect(load.merged.contains("feat/landed"))
    }

    @Test func aBranchWithUnmergedCommitsIsNotMerged() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(commonRoot: fixture.work.root, worktrees: list))

        #expect(!load.merged.contains("feat/open"))
    }

    /// The rule the whole thing turns on. A branch cut from the base and not
    /// committed to yet is merged by git's definition — it adds nothing to
    /// merge — and without the tip rule, making a worktree would
    /// immediately offer to delete it, which is the one moment the user
    /// certainly does not want that.
    @Test func aFreshBranchSittingAtTheBasesTipIsNotMerged() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(commonRoot: fixture.work.root, worktrees: list))

        #expect(!load.merged.contains("feat/fresh"))
    }

    /// And the other half of that claim: git really does call the fresh
    /// branch merged, so the exclusion is this code's work and not something
    /// git was going to do anyway. Without this, the assertion above would
    /// pass just as well if the tip rule were deleted.
    @Test func gitItselfCallsTheFreshBranchMerged() throws {
        let fixture = fixture()
        let raw = try #require(GitCommand.output(
            ["branch", "--merged", "origin/main", "--format=%(refname:short)"],
            in: fixture.work.root
        ))

        let names = Set(raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })

        #expect(names.contains("feat/fresh"))
        #expect(names.contains("feat/landed"))
        #expect(!names.contains("feat/open"))
    }

    /// The main checkout's own branch falls out of the set by the same tip
    /// rule once it has been pushed, which is the ordinary state of a repo
    /// somebody just merged something into. Nothing depends on it — the
    /// findings exclude the main checkout anyway — but it is worth pinning
    /// that the two rules agree instead of fighting.
    @Test func theBasesOwnBranchIsNotReportedAsMerged() throws {
        let fixture = fixture()
        let list = try #require(WorktreeCenter.loadList(commonRoot: fixture.work.root))

        let load = try #require(WorktreeCenter.loadMerged(commonRoot: fixture.work.root, worktrees: list))

        #expect(!load.merged.contains("main"))
    }

    /// A repository with no remote and nothing to compare against has no
    /// base, and therefore no merged branches — an ordinary repository
    /// rather than a broken one, and one where the pane must simply not
    /// offer the merged cleanup.
    @Test func aRepositoryWithNoBaseHasNoMergedBranches() throws {
        let repo = Repo()
        repo.write("one\n", to: "file.txt")
        repo.commit("first")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))

        #expect(WorktreeCenter.loadMerged(commonRoot: repo.root, worktrees: list) == nil)
    }
}

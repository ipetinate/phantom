import Foundation
@testable import Ghostty
import Testing

/// `WorktreeCenter.loadList` and `GitCommonDir.resolve` against a real
/// `git`, in repositories these tests build and delete.
///
/// Everything here is a claim about git's *behaviour* — which line it prints
/// for a detached worktree, what it says about one whose folder was deleted,
/// where it writes the pointer files a worktree is found by. A fixture
/// cannot check any of that, because a fixture is only this file's opinion
/// written down twice: the parser tests already hold the transcripts, and
/// these hold the reason to believe them.
///
/// The repositories are created under the system temporary directory, used,
/// and removed; no repository of the user's is read or run against, and
/// nothing here reaches the network.
///
/// Skipped outright on a machine with no git, rather than failed.
@Suite(.serialized, .enabled(if: GitCommand.path != nil))
struct WorktreeGitTests {
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

        deinit {
            for path in worktreePaths { try? FileManager.default.removeItem(atPath: path) }
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Resolved, because git prints resolved paths in the worktree
        /// list. Every derived path inherits the resolution from here, which
        /// is why nothing else in this file has to think about it.
        private static func reserve() -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-worktree-\(UUID().uuidString)")
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
            git("config", "user.name", "Worktree Test")
            git("config", "user.email", "worktree@test.invalid")
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

        /// A path beside the repository, never inside it — a worktree in the
        /// repository's own tree would show up in its status as an
        /// untracked folder and change what every other test sees.
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

        @discardableResult
        func addDetachedWorktree(_ name: String, at revision: String) -> String {
            let path = reserveWorktree(name)
            git("worktree", "add", "--detach", path, revision)
            return path
        }
    }

    private func seeded() -> Repo {
        let repo = Repo()
        repo.write("one\n", to: "file.txt")
        repo.commit("first")
        return repo
    }

    // MARK: The list

    /// A repository with no worktrees added still has one, and it is the
    /// main checkout.
    @Test func listsTheMainCheckoutOfARepositoryWithNoWorktrees() throws {
        let repo = seeded()

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))

        #expect(list.count == 1)
        #expect(list[0].path == repo.root)
        #expect(list[0].branch == "main")
        #expect(list[0].isMain)
        #expect(list[0].head == repo.sha(of: "HEAD"))
    }

    /// The main checkout comes first no matter when the others were added or
    /// what they are called — the fact `isMain` is built on.
    @Test func theMainCheckoutIsListedFirst() throws {
        let repo = seeded()
        let alpha = repo.addWorktree("alpha", branch: "aaa-first-alphabetically")
        let omega = repo.addWorktree("omega", branch: "zzz-last-alphabetically")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))

        #expect(list.count == 3)
        #expect(list[0].path == repo.root)
        #expect(list[0].isMain)
        #expect(list.filter(\.isMain).count == 1)
        #expect(Set(list.dropFirst().map(\.path)) == Set([alpha, omega]))
    }

    /// Branch names with slashes are the normal case, and the short name is
    /// what every label and every `git branch -d` needs.
    @Test func readsBranchNamesWithSlashes() throws {
        let repo = seeded()
        let path = repo.addWorktree("feature", branch: "feat/worktrees")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let added = try #require(list.first { $0.path == path })

        #expect(added.branch == "feat/worktrees")
        #expect(!added.isDetached)
        #expect(!added.isMain)
    }

    @Test func readsADetachedWorktree() throws {
        let repo = seeded()
        let path = repo.addDetachedWorktree("inspect", at: "HEAD")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let added = try #require(list.first { $0.path == path })

        #expect(added.isDetached)
        #expect(added.branch == nil)
        #expect(added.head == repo.sha(of: "HEAD"))
    }

    @Test func readsALockAndItsReason() throws {
        let repo = seeded()
        let path = repo.addWorktree("archived", branch: "old")
        repo.git("worktree", "lock", path, "--reason", "on an external drive")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let locked = try #require(list.first { $0.path == path })

        #expect(locked.isLocked)
        #expect(locked.lockReason == "on an external drive")
    }

    @Test func readsALockWithNoReason() throws {
        let repo = seeded()
        let path = repo.addWorktree("archived", branch: "old")
        repo.git("worktree", "lock", path)

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let locked = try #require(list.first { $0.path == path })

        #expect(locked.isLocked)
        #expect(locked.lockReason == nil)
    }

    /// Deleting the folder is what actually happens — with Finder, with a
    /// `rm -rf`, by unmounting the volume it was on. Git keeps listing the
    /// worktree and marks it prunable, which is the signal the pane's
    /// "broken" finding is built on.
    @Test func aWorktreeWhoseFolderWasDeletedBecomesPrunable() throws {
        let repo = seeded()
        let path = repo.addWorktree("gone", branch: "abandoned")
        try FileManager.default.removeItem(atPath: path)

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let gone = try #require(list.first { $0.path == path })

        #expect(gone.isPrunable)
        #expect(gone.prunableReason?.isEmpty == false)
    }

    /// A healthy worktree is not prunable, which is the other half of the
    /// claim above — without it, a flag stuck at true would pass.
    @Test func aHealthyWorktreeIsNotPrunable() throws {
        let repo = seeded()
        let path = repo.addWorktree("alive", branch: "feat/alive")

        let list = try #require(WorktreeCenter.loadList(commonRoot: repo.root))
        let alive = try #require(list.first { $0.path == path })

        #expect(!alive.isPrunable)
        #expect(alive.prunableReason == nil)
    }

    /// A folder that is not a repository is a failure, not an empty list.
    /// The pane tells the two apart: one is a spinner that stops with
    /// nothing, the other never stops.
    @Test func aFolderThatIsNotARepositoryLoadsNothing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-not-a-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(WorktreeCenter.loadList(commonRoot: url.path) == nil)
    }

    // MARK: The common directory

    /// The claim `GitCommonDir` exists for: every worktree of a repository,
    /// asked separately, answers with the same main checkout — the key the
    /// whole center is dictionaried by.
    @Test func everyWorktreeResolvesToTheSameMainCheckout() throws {
        let repo = seeded()
        let feature = repo.addWorktree("feature", branch: "feat/x")
        let detached = repo.addDetachedWorktree("inspect", at: "HEAD")

        #expect(GitCommonDir.resolve(from: repo.root) == repo.root)
        #expect(GitCommonDir.resolve(from: feature) == repo.root)
        #expect(GitCommonDir.resolve(from: detached) == repo.root)
    }

    /// The resolver reads the same files git would and reaches the same
    /// answer, which is what licenses it never to run git at all.
    @Test func resolvingMatchesWhatGitItselfReports() throws {
        let repo = seeded()
        let feature = repo.addWorktree("feature", branch: "feat/x")

        let reported = GitCommand.output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: feature)
        let common = try #require(reported?.trimmingCharacters(in: .whitespacesAndNewlines))
        let expected = URL(fileURLWithPath: common).deletingLastPathComponent().path

        #expect(GitCommonDir.resolve(from: feature) == expected)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// `WorktreeCenter`'s mutations against a real `git`.
///
/// Every one of these ends in a folder being created, moved or deleted, so
/// none of it is testable against fixtures — the questions that matter are
/// git's own: what it refuses, what it refuses *until forced*, and what it
/// leaves behind when the second step of a two-step operation is the one
/// that fails. A fixture would only record this file's guesses about all
/// three.
///
/// The repositories are created under the system temporary directory, used,
/// and removed; no repository of the user's is read or run against, and
/// nothing here reaches the network.
///
/// Skipped outright on a machine with no git, rather than failed.
@Suite(.serialized, .enabled(if: GitCommand.path != nil))
struct WorktreeMutationTests {
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
            write("one\n", to: "file.txt")
            commit("first")
        }

        deinit {
            for path in worktreePaths { try? FileManager.default.removeItem(atPath: path) }
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Resolved, because git prints resolved paths in the worktree list.
        /// Every derived path inherits the resolution from here. Same call,
        /// in the same place, as `EditorFolderRepathTests`' `workspace()`.
        private static func reserve() -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-mutation-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return real(url.path)
        }

        static func real(_ path: String) -> String {
            var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &buffer) != nil else { return path }
            return String(cString: buffer)
        }

        private func configure() {
            git("config", "user.name", "Mutation Test")
            git("config", "user.email", "mutation@test.invalid")
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

        /// A path beside the repository, never inside it — a worktree in the
        /// repository's own tree would show up in its status as an untracked
        /// folder and change what every other assertion sees.
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

        func branchExists(_ branch: String) -> Bool {
            git("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)").succeeded
        }

        /// Git's own answer, asked again until there is one.
        ///
        /// A read that failed used to arrive here as an empty list, and an
        /// empty list is a claim — "this repository has no checkouts" —
        /// that git never makes, since the main one is always in it. It
        /// made every `contains` assertion below a coin flip and let every
        /// `!contains` one pass without proving anything, both at once and
        /// both invisibly.
        ///
        /// The read fails for a reason that has nothing to do with the
        /// repository: a mutation forces three more git calls the moment
        /// it finishes, and a machine with few cores can leave one of
        /// their pipe readers unscheduled long enough to lose its output.
        /// So the answer is asked for again, and a repository git never
        /// answers about fails the test instead of reading as empty.
        func list() -> [GitWorktree] {
            for attempt in 1...Self.readAttempts {
                if let list = WorktreeCenter.loadList(commonRoot: root) { return list }
                if attempt < Self.readAttempts { Thread.sleep(forTimeInterval: 0.2) }
            }

            Issue.record("git never answered `worktree list` for \(root)")
            return []
        }

        func paths() -> [String] { list().map(\.path) }

        /// Enough to outlast a machine too busy to schedule a pipe reader,
        /// and few enough that a folder git really cannot read fails in
        /// under a second rather than at some later assertion.
        private static let readAttempts = 5
    }

    // MARK: Harness

    /// Bridges a mutation's completion handler to `await`.
    @MainActor
    private func mutate(
        _ start: (@escaping @MainActor (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            start { outcome in continuation.resume(returning: outcome) }
        }
    }

    /// Polls until the condition holds, up to a deadline expressed as a
    /// fraction of the cache's own lifetime rather than a wall-clock guess.
    @MainActor
    private func settles(
        within deadline: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Creating

    @Test @MainActor func addsAWorktreeForAnExistingBranch() async {
        let repo = Repo()
        repo.git("branch", "feat/x")
        let path = repo.reserveWorktree("existing")

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.add(path: path, branch: "feat/x", commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(repo.paths().contains(path))
        #expect(center.lastError == nil)
    }

    @Test @MainActor func addsAWorktreeAndItsBranchTogether() async {
        let repo = Repo()
        let path = repo.reserveWorktree("fresh")

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.add(path: path, newBranch: "feat/new", from: "main", commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(repo.paths().contains(path))
        #expect(repo.branchExists("feat/new"))
    }

    /// A branch can only be checked out in one worktree at a time, and the
    /// pane's create flow has to be able to say so. The failure has to reach
    /// `lastError` — a mutation that fails silently leaves the user looking
    /// at a folder that never appeared.
    @Test @MainActor func addingABranchAlreadyCheckedOutFails() async {
        let repo = Repo()
        repo.addWorktree("first", branch: "feat/x")
        let second = repo.reserveWorktree("second")

        let center = WorktreeCenter.shared
        center.lastError = nil
        let succeeded = await mutate { done in
            center.add(path: second, branch: "feat/x", commonRoot: repo.root, completion: done)
        }

        #expect(!succeeded)
        #expect(!repo.paths().contains(second))

        let error = center.lastError
        #expect(error?.operation == "Create Worktree")
        #expect(error?.failure.raw.contains("already used by worktree") == true)
        #expect(error?.failure.title.isEmpty == false)
    }

    /// The same refusal, read straight off the step runner. This is the part
    /// that has no actor in it: the transcript git produced is what
    /// `GitFailure` is handed, so a change that dropped one of git's two
    /// streams would show up here rather than in a sheet nobody screenshots.
    @Test func theStepRunnerReturnsGitsOwnTranscript() throws {
        let repo = Repo()
        repo.addWorktree("first", branch: "feat/x")
        let second = repo.reserveWorktree("second")

        let failure = try #require(WorktreeCenter.run(
            steps: [["worktree", "add", second, "feat/x"]],
            in: repo.root
        ))

        let transcript = WorktreeCenter.transcript(failure)
        #expect(transcript.contains("already used by worktree"))
        #expect(!GitFailure(operation: "Create Worktree", output: transcript).raw.isEmpty)
    }

    /// The runner stops at the first failure, so a later step never runs
    /// against the state an earlier one left behind.
    @Test func theStepRunnerStopsAtTheFirstFailure() {
        let repo = Repo()

        let failure = WorktreeCenter.run(
            steps: [
                ["worktree", "add", repo.reserveWorktree("never"), "no-such-branch"],
                ["branch", "should-not-exist"],
            ],
            in: repo.root
        )

        #expect(failure != nil)
        #expect(!repo.branchExists("should-not-exist"))
    }

    @Test func theStepRunnerReturnsNilWhenEveryStepPasses() {
        let repo = Repo()

        let failure = WorktreeCenter.run(
            steps: [["branch", "one"], ["branch", "two"]],
            in: repo.root
        )

        #expect(failure == nil)
        #expect(repo.branchExists("one"))
        #expect(repo.branchExists("two"))
    }

    // MARK: Removing

    @Test @MainActor func removesACleanWorktree() async {
        let repo = Repo()
        let path = repo.addWorktree("clean", branch: "feat/x")

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.remove(path: path, force: false, commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(!repo.paths().contains(path))
    }

    /// Uncommitted work is the one thing a cleanup gesture must not throw
    /// away without asking. Git refuses; `force` is what the user chose
    /// after being told, which is why it is a parameter and not a default.
    @Test @MainActor func refusesToRemoveADirtyWorktreeUnlessForced() async {
        let repo = Repo()
        let path = repo.addWorktree("dirty", branch: "feat/x")
        try? "uncommitted\n".write(
            toFile: URL(fileURLWithPath: path).appendingPathComponent("file.txt").path,
            atomically: true,
            encoding: .utf8
        )

        let center = WorktreeCenter.shared
        center.lastError = nil

        let refused = await mutate { done in
            center.remove(path: path, force: false, commonRoot: repo.root, completion: done)
        }
        #expect(!refused)
        #expect(repo.paths().contains(path))
        #expect(center.lastError?.failure.raw.contains("use --force") == true)

        let forced = await mutate { done in
            center.remove(path: path, force: true, commonRoot: repo.root, completion: done)
        }
        #expect(forced)
        #expect(!repo.paths().contains(path))
        #expect(center.lastError == nil)
    }

    /// Removing the worktree leaves the branch, which is the whole reason
    /// there is a second method for taking both.
    @Test @MainActor func removingAWorktreeKeepsItsBranch() async {
        let repo = Repo()
        let path = repo.addWorktree("kept", branch: "feat/x")

        let center = WorktreeCenter.shared
        _ = await mutate { done in
            center.remove(path: path, force: false, commonRoot: repo.root, completion: done)
        }

        #expect(repo.branchExists("feat/x"))
    }

    /// Both steps, under one lock. Two separate calls could not do this: the
    /// second would arrive while the first still held the lock and be
    /// dropped, leaving the worktree gone and the branch behind with nothing
    /// to explain it.
    @Test @MainActor func removesAWorktreeAndDeletesItsBranch() async {
        let repo = Repo()
        let path = repo.addWorktree("done", branch: "feat/merged")

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.removeAndDeleteBranch(
                path: path,
                branch: "feat/merged",
                commonRoot: repo.root,
                completion: done
            )
        }

        #expect(succeeded)
        #expect(!repo.paths().contains(path))
        #expect(!repo.branchExists("feat/merged"))
    }

    /// `branch -d` and not `-D`, pinned by its consequence: an unmerged
    /// branch survives the attempt. The worktree is gone by then — the
    /// remove step passed — and that partial outcome is the deliberate
    /// trade. Recoverable beats tidy: `-D` would have taken the commits
    /// with it.
    @Test @MainActor func anUnmergedBranchSurvivesTheCombinedRemove() async {
        let repo = Repo()
        let path = repo.addWorktree("wip", branch: "feat/wip")
        try? "work\n".write(
            toFile: URL(fileURLWithPath: path).appendingPathComponent("wip.txt").path,
            atomically: true,
            encoding: .utf8
        )
        _ = GitCommand.run(["add", "-A"], in: path, timeout: 60)
        _ = GitCommand.run(["commit", "-m", "unmerged work"], in: path, timeout: 60)

        let center = WorktreeCenter.shared
        center.lastError = nil
        let succeeded = await mutate { done in
            center.removeAndDeleteBranch(
                path: path,
                branch: "feat/wip",
                commonRoot: repo.root,
                completion: done
            )
        }

        #expect(!succeeded)
        #expect(repo.branchExists("feat/wip"))
        #expect(center.lastError?.operation == "Remove Worktree and Branch")
        #expect(center.lastError?.failure.raw.contains("not fully merged") == true)
    }

    // MARK: Moving, repairing, pruning

    @Test @MainActor func movesAWorktreeAndTheListFollows() async {
        let repo = Repo()
        let from = repo.addWorktree("before", branch: "feat/x")
        let to = repo.reserveWorktree("after")

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.move(path: from, to: to, commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(repo.paths().contains(to))
        #expect(!repo.paths().contains(from))
    }

    /// A folder moved in Finder leaves git pointing at nothing, and the
    /// worktree reads as broken until somebody tells git where it went.
    @Test @MainActor func repairsAWorktreeMovedBehindGitsBack() async throws {
        let repo = Repo()
        let from = repo.addWorktree("original", branch: "feat/x")
        let to = repo.reserveWorktree("relocated")
        try FileManager.default.moveItem(atPath: from, toPath: to)

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.repair(path: to, commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(repo.paths().contains(to))
        #expect(!repo.paths().contains(from))
    }

    @Test @MainActor func prunesWorktreesWhoseFoldersAreGone() async throws {
        let repo = Repo()
        let path = repo.addWorktree("deleted", branch: "feat/x")
        try FileManager.default.removeItem(atPath: path)
        #expect(repo.list().contains { $0.isPrunable })

        let center = WorktreeCenter.shared
        let succeeded = await mutate { done in
            center.prune(commonRoot: repo.root, completion: done)
        }

        #expect(succeeded)
        #expect(!repo.paths().contains(path))
    }

    // MARK: Locking

    /// Proved as a pair, because an unlock on its own proves nothing: git
    /// reports success for it whether or not anything was standing in the
    /// way. So first the refusal the lock exists to produce — and note that
    /// `remove` refuses even though the pane can force it, since a single
    /// `--force` does not override a lock — then the same remove going
    /// through, with the unlock as the only thing that changed between them.
    @Test @MainActor func unlockingClearsTheRemovalGitRefused() async {
        let repo = Repo()
        let path = repo.addWorktree("pinned", branch: "feat/x")
        repo.git("worktree", "lock", path)

        let center = WorktreeCenter.shared
        center.lastError = nil

        let refused = await mutate { done in
            center.remove(path: path, force: true, commonRoot: repo.root, completion: done)
        }
        #expect(!refused)
        #expect(repo.paths().contains(path))
        #expect(center.lastError?.failure.raw.contains("locked") == true)

        let unlocked = await mutate { done in
            center.unlock(path: path, commonRoot: repo.root, completion: done)
        }
        #expect(unlocked)
        #expect(center.lastError == nil)
        #expect(!repo.list().contains { $0.isLocked })

        let removed = await mutate { done in
            center.remove(path: path, force: false, commonRoot: repo.root, completion: done)
        }
        #expect(removed)
        #expect(!repo.paths().contains(path))
    }

    /// Unlocking something nobody locked is git's to refuse, and the pane
    /// has to say so rather than report a success it did not have — the
    /// gesture is offered on a row whose lock somebody else may have lifted
    /// in a terminal a second earlier.
    @Test @MainActor func unlockingAnUnlockedWorktreeSurfacesGitsRefusal() async {
        let repo = Repo()
        let path = repo.addWorktree("open", branch: "feat/x")

        let center = WorktreeCenter.shared
        center.lastError = nil
        let succeeded = await mutate { done in
            center.unlock(path: path, commonRoot: repo.root, completion: done)
        }

        #expect(!succeeded)
        #expect(center.lastError?.operation == "Unlock Worktree")
        #expect(center.lastError?.failure.raw.contains("not locked") == true)
        #expect(center.lastError?.failure.title.isEmpty == false)
    }

    // MARK: The lock

    /// A second mutation arriving while one is running is refused, and —
    /// unlike `GitCenter`, whose callers are fire and forget — it is told
    /// so. A caller holding a sheet open until the completion arrives would
    /// otherwise wait forever.
    @Test @MainActor func aBusyRepositoryRefusesASecondMutationAndSaysSo() async {
        let repo = Repo()
        let first = repo.reserveWorktree("first")
        let second = repo.reserveWorktree("second")

        let center = WorktreeCenter.shared
        var refusedOutcome: Bool?

        let accepted = await mutate { done in
            center.add(path: first, newBranch: "feat/one", from: "main", commonRoot: repo.root, completion: done)

            /// Fired while the first still holds the lock: `add` takes it
            /// synchronously, before the git work is dispatched.
            center.add(path: second, newBranch: "feat/two", from: "main", commonRoot: repo.root) { outcome in
                refusedOutcome = outcome
            }
        }

        #expect(accepted)
        #expect(refusedOutcome == false)
        #expect(repo.paths().contains(first))
        #expect(!repo.paths().contains(second))
        #expect(!repo.branchExists("feat/two"))
    }

    /// The lock is released whether the mutation passed or failed, or the
    /// pane would be stuck on the first thing that went wrong.
    @Test @MainActor func theLockIsReleasedAfterAFailure() async {
        let repo = Repo()
        let path = repo.reserveWorktree("attempt")

        let center = WorktreeCenter.shared
        _ = await mutate { done in
            center.add(path: path, branch: "no-such-branch", commonRoot: repo.root, completion: done)
        }
        #expect(center.busy[repo.root] == nil)

        let succeeded = await mutate { done in
            center.add(path: path, newBranch: "feat/after", from: "main", commonRoot: repo.root, completion: done)
        }
        #expect(succeeded)
    }

    // MARK: The refresh

    /// The bug this pins is the one every worktree tool has: you delete a
    /// worktree, the list keeps showing it, and you learn not to trust the
    /// panel.
    ///
    /// Proved as a pair, so that no assertion depends on a stopwatch. First
    /// the negative control: with the list freshly stamped, a change made
    /// behind the center's back is invisible to an ordinary request, because
    /// the cache is still warm. Then the mutation: the same cache, the same
    /// window, and the list converges — the only difference between the two
    /// halves being the forced refresh the mutation performs.
    @Test @MainActor func aMutationRefreshesTheListPastItsCache() async {
        let repo = Repo()
        let path = repo.addWorktree("doomed", branch: "feat/x")

        let center = WorktreeCenter.shared
        center.requestList(commonRoot: repo.root, force: true)
        let loaded = await settles(within: WorktreeCenter.listTTL) {
            center.worktrees[repo.root]?.count == 2
        }
        #expect(loaded)

        /// Behind the center's back: the world changes, the cache does not
        /// know, and nothing has asked it to find out.
        #expect(WorktreeCenter.run(steps: [["worktree", "remove", path]], in: repo.root) == nil)

        center.requestList(commonRoot: repo.root, force: false)
        let sawItEarly = await settles(within: WorktreeCenter.listTTL / 10) {
            center.worktrees[repo.root]?.count == 1
        }
        #expect(!sawItEarly, "a warm cache must not be re-read without force")

        let succeeded = await mutate { done in
            center.prune(commonRoot: repo.root, completion: done)
        }
        #expect(succeeded)
        let converged = await settles(within: WorktreeCenter.listTTL) {
            center.worktrees[repo.root]?.count == 1
        }
        #expect(converged, "a mutation must force the list past its cache")
    }

    /// A successful mutation clears the previous failure, so a stale error
    /// cannot outlive the problem it described.
    @Test @MainActor func aSuccessClearsTheLastError() async {
        let repo = Repo()

        let center = WorktreeCenter.shared
        _ = await mutate { done in
            center.add(
                path: repo.reserveWorktree("bad"),
                branch: "no-such-branch",
                commonRoot: repo.root,
                completion: done
            )
        }
        #expect(center.lastError != nil)

        _ = await mutate { done in
            center.add(
                path: repo.reserveWorktree("good"),
                newBranch: "feat/ok",
                from: "main",
                commonRoot: repo.root,
                completion: done
            )
        }
        #expect(center.lastError == nil)
    }
}

import Combine
import Foundation

/// The worktree state behind the worktree pane.
///
/// Keyed by **common root** — the main checkout's path, as
/// ``GitCommonDir/resolve(from:fileManager:)`` gives it — never by the
/// checkout a tab happens to be in. Every worktree of a repository asks the
/// same question and gets the same answer from one entry, which is the only
/// way the list is stable while the user moves between tabs in three
/// different worktrees of the same repo.
///
/// Same shape as ``GitCenter``: staleness is decided on the main actor
/// before dispatching, `inflight` is inserted before the hop and removed in
/// the hop that writes the result, and the freshness stamp is written on
/// completion rather than on dispatch so a slow call doesn't buy itself a
/// free TTL window. A forced refresh arriving mid-flight is remembered
/// rather than dropped — see ``GitCenter/requestStatus(root:force:)`` for
/// the failure that shape exists to prevent.
///
/// Read-only. Nothing here changes a repository, and the per-worktree dirty
/// state and ahead/behind counts are not loaded here either: they are
/// `GitCenter.statuses`, already kept for every root the panel has seen,
/// and a second poller for the same numbers would double the git spawns to
/// disagree with the first one half the time.
@MainActor
final class WorktreeCenter: ObservableObject {
    static let shared = WorktreeCenter()

    /// A failed mutation, shaped exactly like ``GitCenter/Failure`` so the
    /// pane presents it with the same sheet rather than a second one that
    /// would drift away from it.
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let operation: String
        let failure: GitFailure
    }

    /// What a mutation is called, in the two places it has to be named.
    ///
    /// One string cannot do both jobs. The pane shows progress, which wants
    /// "Removing worktree…"; ``GitFailure`` builds sentences around the
    /// name — "<name> failed", "A git hook rejected the <name>" — which
    /// wants a noun phrase. `GitCenter` reuses one string for both and
    /// lives with "Publish Branch failed"; these operations have longer
    /// names and the seam shows sooner.
    private struct Operation {
        /// Present tense with an ellipsis, for the progress row.
        let label: String

        /// A noun phrase, for ``GitFailure``.
        let name: String
    }

    /// Every checkout of a repository, main first, as git listed them.
    @Published private(set) var worktrees: [String: [GitWorktree]] = [:]

    /// Branches already contained in the repository's base, with the
    /// at-the-base-tip case filtered out. Short names, matching
    /// ``GitWorktree/branch``.
    @Published private(set) var mergedBranches: [String: Set<String>] = [:]

    /// The ref each repository's merged check compared against, kept both
    /// to show the user what "merged" meant and to avoid resolving it again
    /// on every refresh — the resolution is several git calls and its answer
    /// changes about as often as a remote's default branch does.
    @Published private(set) var baseRefs: [String: String] = [:]

    /// The mutation currently running, keyed by common root, as a phrase
    /// the pane shows while it waits. Only one at a time per repository —
    /// a create and a remove racing each other on the same repo is never
    /// what anyone wanted.
    @Published private(set) var busy: [String: String] = [:]

    /// The last failed mutation, cleared by the next success.
    @Published var lastError: Failure?

    /// Repositories whose first list has come back, success or failure.
    /// Distinguishing "hasn't answered yet" from "answered, and there is
    /// one worktree" is what lets the pane show a spinner without spinning
    /// forever on a repo git can't read.
    @Published private(set) var loadedRoots: Set<String> = []

    private var inflightList: Set<String> = []
    private var pendingListRefresh: Set<String> = []
    private var listCheckedAt: [String: Date] = [:]

    private var inflightMerged: Set<String> = []
    private var pendingMergedRefresh: Set<String> = []
    private var mergedCheckedAt: [String: Date] = [:]

    /// Short: the pane is visible and the user is acting on it. The
    /// sidebar's 5s metadata timer asks about this often, and gets cache
    /// most times.
    ///
    /// Not private so a test can express its deadlines as a fraction of the
    /// real value instead of a wall-clock guess that rots the moment this
    /// number changes.
    static let listTTL: TimeInterval = 5

    /// Long, because the answer is expensive and nearly static. A branch
    /// becomes merged when somebody merges a pull request, which is not
    /// something that happens while the user watches the pane — and the
    /// check costs a base resolution plus two more git calls.
    static let mergedTTL: TimeInterval = 60

    private init() {}

    // MARK: Reading

    func list(forRoot root: String) -> [GitWorktree] { worktrees[root] ?? [] }

    func merged(forRoot root: String) -> Set<String> { mergedBranches[root] ?? [] }

    func baseRef(forRoot root: String) -> String? { baseRefs[root] }

    /// Whether a first list has come back for this repository.
    func hasLoaded(_ root: String) -> Bool { loadedRoots.contains(root) }

    // MARK: Requesting

    /// Refreshes the worktree list if stale. Cheap no-op otherwise, so it is
    /// safe to call from a timer and from every view update.
    func requestList(commonRoot: String, force: Bool = false) {
        guard !commonRoot.isEmpty else { return }
        let stale = force
            || Date().timeIntervalSince(listCheckedAt[commonRoot] ?? .distantPast) > Self.listTTL
        guard stale else { return }

        guard !inflightList.contains(commonRoot) else {
            if force { pendingListRefresh.insert(commonRoot) }
            return
        }
        inflightList.insert(commonRoot)

        Task.detached(priority: .utility) {
            let list = Self.loadList(commonRoot: commonRoot)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let list { self.worktrees[commonRoot] = list }
                self.listCheckedAt[commonRoot] = Date()
                self.inflightList.remove(commonRoot)
                if !self.loadedRoots.contains(commonRoot) { self.loadedRoots.insert(commonRoot) }

                if self.pendingListRefresh.remove(commonRoot) != nil {
                    self.requestList(commonRoot: commonRoot, force: true)
                }
            }
        }
    }

    /// Refreshes which branches have landed, if stale.
    ///
    /// Needs the worktree list, and does nothing without it: the base is
    /// resolved against the main checkout's branch, and the tip rule reads
    /// each worktree's `HEAD`. The pane asks for the list first and this
    /// after, so the ordinary case has it; the guard is what keeps a
    /// merged check from running against an empty list and publishing an
    /// empty answer that then sits in cache for a minute.
    func requestMerged(commonRoot: String, force: Bool = false) {
        guard !commonRoot.isEmpty else { return }
        let list = worktrees[commonRoot] ?? []
        guard !list.isEmpty else { return }

        let stale = force
            || Date().timeIntervalSince(mergedCheckedAt[commonRoot] ?? .distantPast) > Self.mergedTTL
        guard stale else { return }

        guard !inflightMerged.contains(commonRoot) else {
            if force { pendingMergedRefresh.insert(commonRoot) }
            return
        }
        inflightMerged.insert(commonRoot)

        let knownBase = baseRefs[commonRoot]

        Task.detached(priority: .utility) {
            let load = Self.loadMerged(commonRoot: commonRoot, worktrees: list, knownBase: knownBase)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let load {
                    self.baseRefs[commonRoot] = load.base
                    self.mergedBranches[commonRoot] = load.merged
                }
                self.mergedCheckedAt[commonRoot] = Date()
                self.inflightMerged.remove(commonRoot)

                if self.pendingMergedRefresh.remove(commonRoot) != nil {
                    self.requestMerged(commonRoot: commonRoot, force: true)
                }
            }
        }
    }

    // MARK: Loading (background)

    /// Every checkout of the repository at `commonRoot`.
    ///
    /// `nil` means git couldn't answer — a folder that isn't a repository
    /// any more, or no git at all — and is kept apart from an empty list,
    /// which git never returns for a real repository since the main
    /// checkout is always in it.
    nonisolated static func loadList(commonRoot: String) -> [GitWorktree]? {
        let result = GitCommand.run(["worktree", "list", "--porcelain"], in: commonRoot)
        guard result.succeeded else { return nil }
        return GitWorktree.parse(porcelain: result.stdout)
    }

    /// Which branches have already landed on the repository's base.
    ///
    /// One `git branch --merged` call, plus a `rev-parse` for the base's tip,
    /// plus the base resolution when `knownBase` isn't cached yet.
    ///
    /// The tip rule is why the `rev-parse` is here. `git branch --merged X`
    /// answers "is X an ancestor of this branch's tip", and for a branch cut
    /// from the base five minutes ago and not yet committed to, it is —
    /// vacuously, because the branch adds nothing. Without the rule, making
    /// a worktree would immediately list it as merged and offer to delete
    /// it, which is the one moment the user certainly does not want that.
    /// So any worktree sitting exactly at the base's tip keeps its branch
    /// out of the set.
    ///
    /// The accepted cost is the other direction: a branch that was
    /// squash-merged or rebase-merged has no commit in common with what
    /// landed, `--merged` says nothing about it, and it never shows up as
    /// merged. A worktree nobody has open still surfaces as an orphan, so
    /// it is a weaker prompt rather than no prompt — and the alternative,
    /// guessing at patch equivalence, is how a tool ends up offering to
    /// delete unmerged work.
    nonisolated static func loadMerged(
        commonRoot: String,
        worktrees: [GitWorktree],
        knownBase: String? = nil
    ) -> (base: String, merged: Set<String>)? {
        guard let base = knownBase ?? resolvedBase(commonRoot: commonRoot, worktrees: worktrees)
        else { return nil }

        guard let output = GitCommand.output(
            ["branch", "--merged", base, "--format=%(refname:short)"],
            in: commonRoot
        ) else { return nil }

        var merged = Set(
            output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        if let tip = GitCommand.output(["rev-parse", base], in: commonRoot)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
            !tip.isEmpty {
            for worktree in worktrees where worktree.head == tip {
                if let branch = worktree.branch { merged.remove(branch) }
            }
        }

        return (base: base, merged: merged)
    }

    /// The ref the merged check compares against, resolved from the main
    /// checkout's branch.
    ///
    /// Reuses ``GitBranchReviewLoader/resolveBase(in:branch:)`` rather than
    /// picking `main` by name, so "merged" here means merged into whatever
    /// the branch review pane also calls the base — the configured upstream,
    /// then the remote's default branch, then the well-known names. A
    /// repository where none of those exists has no base and no merged
    /// branches, which is an ordinary repository rather than a broken one.
    nonisolated private static func resolvedBase(
        commonRoot: String,
        worktrees: [GitWorktree]
    ) -> String? {
        let mainBranch = worktrees.first { $0.isMain }?.branch
        return GitBranchReviewLoader.resolveBase(in: commonRoot, branch: mainBranch)?.ref
    }

    // MARK: Mutations

    /// Checks out an existing branch into a new worktree.
    func add(
        path: String,
        branch: String,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        perform(
            Operation(label: "Creating worktree…", name: "Create Worktree"),
            commonRoot: commonRoot,
            steps: [["worktree", "add", path, branch]],
            affected: [path],
            completion: completion
        )
    }

    /// Creates a branch and a worktree for it in one step.
    ///
    /// `worktree add -b` rather than a `branch` call followed by an `add`:
    /// git refuses the whole thing if the branch already exists, so the
    /// two-call version could leave a new branch behind after the checkout
    /// failed — a branch nobody asked for and nothing would clean up.
    func add(
        path: String,
        newBranch: String,
        from base: String,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        perform(
            Operation(label: "Creating worktree…", name: "Create Worktree"),
            commonRoot: commonRoot,
            steps: [["worktree", "add", "-b", newBranch, path, base]],
            affected: [path],
            completion: completion
        )
    }

    /// Removes a worktree, leaving its branch alone.
    ///
    /// Git refuses a worktree with uncommitted changes unless forced, which
    /// is the check the pane wants: `force` is what the user chose after
    /// being told, never a default.
    func remove(
        path: String,
        force: Bool,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)

        perform(
            Operation(label: "Removing worktree…", name: "Remove Worktree"),
            commonRoot: commonRoot,
            steps: [arguments],
            completion: completion
        )
    }

    /// Removes a worktree and deletes the branch it was on.
    ///
    /// Two steps under one lock. Separate calls would not work: every
    /// mutation takes the `busy` lock, so firing the remove and then the
    /// branch delete meant the second hit the lock the first still held and
    /// was dropped — the worktree went and the branch stayed, with no error
    /// to explain it. That is the lesson `GitCenter.commit` records about
    /// stage-then-commit, and it applies unchanged here.
    ///
    /// `branch -d`, never `-D`: git's refusal to delete an unmerged branch
    /// is the last thing standing between a cleanup gesture and lost work.
    /// If the branch turns out not to be merged after all, the worktree is
    /// gone and the branch is still there — recoverable, which `-D` would
    /// not be.
    func removeAndDeleteBranch(
        path: String,
        branch: String,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        perform(
            Operation(label: "Removing worktree…", name: "Remove Worktree and Branch"),
            commonRoot: commonRoot,
            steps: [
                ["worktree", "remove", path],
                ["branch", "-d", branch],
            ],
            completion: completion
        )
    }

    /// Moves a worktree to a new path, keeping git's pointers in step.
    func move(
        path: String,
        to newPath: String,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        perform(
            Operation(label: "Moving worktree…", name: "Move Worktree"),
            commonRoot: commonRoot,
            steps: [["worktree", "move", path, newPath]],
            affected: [newPath],
            completion: completion
        )
    }

    /// Reconnects a worktree whose folder was moved behind git's back.
    func repair(
        path: String,
        commonRoot: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        perform(
            Operation(label: "Repairing worktree…", name: "Repair Worktree"),
            commonRoot: commonRoot,
            steps: [["worktree", "repair", path]],
            affected: [path],
            completion: completion
        )
    }

    /// Drops the administrative entries of worktrees whose folders are gone.
    func prune(commonRoot: String, completion: @escaping @MainActor (Bool) -> Void) {
        perform(
            Operation(label: "Pruning worktrees…", name: "Prune Worktrees"),
            commonRoot: commonRoot,
            steps: [["worktree", "prune"]],
            completion: completion
        )
    }

    // MARK: Running mutations

    /// Runs a mutation's steps in order, under one lock, and refreshes.
    ///
    /// Structural copy of `GitCenter.perform(_:in:steps:timeout:)`: the lock
    /// is taken on the main actor before the hop, one lock covers the whole
    /// sequence so a multi-step mutation can't be interleaved with anything
    /// else, and a later step never runs against the state an earlier
    /// failure left behind.
    ///
    /// A busy repository refuses the mutation, as it does there — but the
    /// refusal calls back with `false` rather than returning silently.
    /// `GitCenter` can afford the silence because its callers are fire and
    /// forget; a caller holding a sheet open until the completion arrives
    /// would wait forever.
    private func perform(
        _ operation: Operation,
        commonRoot: String,
        steps: [[String]],
        affected: [String] = [],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !commonRoot.isEmpty, !steps.isEmpty else {
            completion(false)
            return
        }

        guard busy[commonRoot] == nil else {
            completion(false)
            return
        }
        busy[commonRoot] = operation.label

        Task.detached(priority: .userInitiated) {
            let failure = Self.run(steps: steps, in: commonRoot)

            await MainActor.run { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                self.finish(operation, commonRoot: commonRoot, affected: affected, failure: failure)
                completion(failure == nil)
            }
        }
    }

    /// Releases the lock, records the outcome, and forces every cached
    /// answer about this repository to be re-read.
    ///
    /// The refresh is unconditional — success or failure — and forced past
    /// both TTLs. A mutation that failed can still have changed something:
    /// the two-step remove leaves the worktree gone when the branch delete
    /// is what refused. Trusting the 5s list cache after a mutation is how
    /// a pane ends up showing a worktree the user just deleted, which is
    /// the behaviour this exists to avoid.
    private func finish(
        _ operation: Operation,
        commonRoot: String,
        affected: [String],
        failure: ShellCommand.Result?
    ) {
        busy[commonRoot] = nil

        lastError = failure.map {
            Failure(
                operation: operation.name,
                failure: GitFailure(operation: operation.name, output: Self.transcript($0))
            )
        }

        requestList(commonRoot: commonRoot, force: true)
        requestMerged(commonRoot: commonRoot, force: true)

        for root in [commonRoot] + affected {
            GitCenter.shared.requestStatus(root: root, force: true)
        }
    }

    /// Runs the steps, stopping at the first failure and returning it.
    /// `nil` means every step passed.
    ///
    /// Separated from the actor state so the whole failure path is testable
    /// against real git without a MainActor dance — the same split the read
    /// side uses for ``loadList(commonRoot:)``.
    nonisolated static func run(steps: [[String]], in commonRoot: String) -> ShellCommand.Result? {
        for step in steps {
            let result = GitCommand.run(step, in: commonRoot, timeout: GitCommand.mutateTimeout)
            guard result.succeeded else { return result }
        }
        return nil
    }

    /// Both of git's streams, joined for ``GitFailure``.
    ///
    /// Git splits a single explanation across them routinely, so reading
    /// only one loses half the story — `worktree remove` on a dirty tree
    /// names the files on one stream and the refusal on the other.
    nonisolated static func transcript(_ result: ShellCommand.Result) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

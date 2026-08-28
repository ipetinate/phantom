import Combine
import Foundation

/// Assembles what the review screen shows, and remembers it per repository.
///
/// The screen is the local answer to a pull request's Files-changed tab: what
/// this branch will take to its target, before it is taken. So the target is
/// resolved rather than assumed, in the order a reader would: the pull
/// request's own base if there is one, since that is literally what will be
/// merged; the repository's default branch otherwise; and whatever they pick
/// over either.
@MainActor
final class GitReviewCenter: ObservableObject {
    static let shared = GitReviewCenter()

    /// What is on screen per repository root, ready or loading.
    @Published private(set) var states: [String: State] = [:]

    /// The branches a reader may compare against, per root. Empty until asked
    /// for, because listing them is cheap and fetching them is not.
    @Published private(set) var branches: [String: [String]] = [:]

    /// A target the reader chose, which outlives a reload of the review.
    private var chosen: [String: String] = [:]

    /// Which reviews are open as tabs, per window, and which one each window
    /// is looking at.
    ///
    /// Pushed in by every window's `EditorCenter` rather than read out of it.
    /// The commit list that needs this is drawn deep in the sidebar and is
    /// handed a repository root, not the window's editor, so this is the seam
    /// where the two meet.
    ///
    /// It is what makes the list's highlight follow the *tab* rather than a
    /// click the list remembers. With two commit tabs open, the row that
    /// lights up is the one whose tab is in front, and it changes when the
    /// reader switches tabs — a list holding its own `@State` would keep
    /// pointing at the last row clicked, which is the thing that reads as
    /// broken the moment a second tab exists.
    ///
    /// Per window, keyed weakly by the centre that reported it. One shared
    /// entry would let a second window's empty report erase the first
    /// window's marks; a weak owner lets a closed window's entry fall away on
    /// the next report, which a `deinit` could not do — it cannot reach this
    /// actor.
    @Published private(set) var reviewTabs: [ObjectIdentifier: OpenReviewTabs] = [:]

    /// One window's review tabs, as that window last reported them.
    struct OpenReviewTabs {
        /// The window that reported it, weakly, so a closed one stops
        /// marking rows.
        weak var owner: AnyObject?

        /// Every review open in it, by ``GitReviewScope/id``.
        var open: Set<String>

        /// The one its focused cell is showing.
        var front: String?
    }

    enum State: Equatable {
        case loading
        case ready(GitReviewContext, GitBranchReview)
        case failed(String)
    }

    private var loading: Set<String> = []

    /// The branch each root's state was read on, so a checkout can be noticed.
    private var branchesSeen: [String: String] = [:]

    /// What the cached review was measured between, per repository.
    ///
    /// A review is a statement about two commits, and the branch's *name* is
    /// not either of them. Keying the cache on the name alone meant a review
    /// stayed on screen after both of its endpoints had moved — reported with
    /// a header claiming 39 commits and 161 files for a pull request GitHub
    /// showed as 5 and 4. The numbers were right when they were computed and
    /// the base had been fetched forward since; nothing told the screen.
    ///
    /// Both ends move without the branch being renamed: a `fetch` or `pull`
    /// moves the base, a commit or an amend moves HEAD. So both are recorded
    /// and both are checked.
    private var measuredBetween: [String: Measurement] = [:]

    /// What a cached review was measured from, and between.
    private struct Measurement {
        /// The ref the comparison used, so the check re-reads the same one
        /// rather than guessing at the default again.
        let baseRef: String
        let endpoints: Endpoints
    }

    /// The two commits a cached review describes.
    private struct Endpoints: Equatable {
        let head: String
        let base: String
    }

    private var subscription: AnyCancellable?

    private init() {
        /// A review is about one branch, and the cache was keyed only by
        /// repository — so checking out another branch left the previous
        /// branch's review on screen under the new branch's name. It reported
        /// `main \u{2192} main` on a feature branch, which is not a stale number
        /// but a wrong comparison, and it looks like a working screen.
        ///
        /// The signal is the one the app already has. `GitCenter` refreshes a
        /// root's status on its own schedule and after every operation it runs,
        /// and the branch is in it.
        subscription = GitCenter.shared.$statuses
            .sink { [weak self] statuses in
                MainActor.assumeIsolated { self?.noticeBranches(statuses) }
            }
    }

    private func noticeBranches(_ statuses: [String: GitStatus]) {
        for (root, status) in statuses {
            guard let branch = status.branch else { continue }
            guard let seen = branchesSeen[root] else {
                branchesSeen[root] = branch
                continue
            }
            guard seen != branch else { continue }

            branchesSeen[root] = branch
            /// The reader's chosen target went with the old branch. Keeping it
            /// would compare a new branch against something picked for another
            /// one, which is worse than starting from the default again.
            chosen.removeValue(forKey: root)
            forget(root)
        }

        /// The other way a review goes stale, and the one that has no name
        /// change to notice: the commits themselves moved.
        dropReviewsWhoseEndpointsMoved(in: statuses.keys)
    }

    /// Throws away a cached review once either end of its comparison has
    /// moved.
    ///
    /// Checked here rather than on a timer because this already runs whenever
    /// `GitCenter` refreshes a root — which is on its own schedule and after
    /// every git operation the app performs, including the fetch that moves a
    /// base. One `rev-parse` per repository that has a review open, and none
    /// at all for the ones that do not.
    private func dropReviewsWhoseEndpointsMoved(in roots: some Sequence<String>) {
        for root in roots {
            guard let measured = measuredBetween[root], states[root] != nil else { continue }
            guard let now = Self.endpoints(baseRef: measured.baseRef, in: root) else { continue }
            guard now != measured.endpoints else { continue }
            forget(root)
        }
    }

    /// Drops everything cached about a repository's review, leaving the
    /// reader's chosen target alone — that is a preference, not a measurement.
    private func forget(_ root: String) {
        states.removeValue(forKey: root)
        measuredBetween.removeValue(forKey: root)
    }

    /// Where HEAD and the base point right now, in one call.
    ///
    /// **No `--verify`.** It takes one revision, and given two it prints
    /// nothing at all and still exits zero — so the check silently answered
    /// "cannot tell" every time and no review was ever invalidated. Caught by
    /// the test rather than by the screen, which is the only reason it is not
    /// in this comment as another reported bug.
    ///
    /// Both lines are checked for the shape of a hash instead. Without
    /// `--verify`, an unresolvable ref makes git print the *good* one to
    /// stdout and complain on stderr, so a count alone would take a partial
    /// answer for a whole one.
    ///
    /// Nil means "cannot tell", never "moved": a base that has been deleted,
    /// or a repository mid-rebase, must not throw the review away — that would
    /// reload it on every status tick for as long as the ref stayed
    /// unreadable.
    nonisolated private static func endpoints(
        baseRef: String,
        in root: String
    ) -> Endpoints? {
        guard let output = GitCommand.output(["rev-parse", "HEAD", baseRef], in: root)
        else { return nil }

        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isObjectName($0) }

        guard lines.count == 2 else { return nil }
        return Endpoints(head: lines[0], base: lines[1])
    }

    /// Whether a line is a full object name rather than git's commentary.
    nonisolated private static func isObjectName(_ line: String) -> Bool {
        line.count == 40 && line.allSatisfy(\.isHexDigit)
    }

    func state(for root: String) -> State? { states[root] }

    /// Loads, or reloads, everything the screen needs.
    ///
    /// One pass rather than a property per fact: the header is assembled from
    /// four git calls and one `gh` call, and a header whose parts arrive
    /// separately reads as a screen still loading long after it has settled.
    func load(root: String, force: Bool = false) {
        if !force, states[root] != nil, !loading.contains(root) { return }
        guard !loading.contains(root) else { return }

        loading.insert(root)
        if states[root] == nil { states[root] = .loading }
        branchesSeen[root] = GitCenter.shared.statuses[root]?.branch ?? branchesSeen[root]

        let chosenTarget = chosen[root]
        Task.detached(priority: .userInitiated) {
            let outcome = Self.assemble(root: root, chosenTarget: chosenTarget)

            /// Read *after* the review, so the pair recorded is the pair the
            /// numbers describe. Reading it first would leave a window in
            /// which a fetch landed between the two, and the review would then
            /// be remembered as measuring something it did not.
            let measurement: Measurement?
            if case .ready(let context, _) = outcome,
               let endpoints = Self.endpoints(baseRef: context.target.ref, in: root) {
                measurement = Measurement(baseRef: context.target.ref, endpoints: endpoints)
            } else {
                measurement = nil
            }

            await MainActor.run {
                self.loading.remove(root)
                self.states[root] = outcome
                self.measuredBetween[root] = measurement
            }
        }
    }

    /// Points the comparison at another branch and reloads.
    func choose(target: String, root: String) {
        chosen[root] = target
        load(root: root, force: true)
    }

    /// Whether the reader has overridden the target for this repository.
    func chosenTarget(for root: String) -> String? { chosen[root] }

    /// Fills ``branches`` for the picker.
    ///
    /// `fetch` first when asked, because a list of targets that predates the
    /// last push is a list missing the branch somebody just made. Network, so
    /// it is only ever on this path — never on the one that draws the screen.
    func loadBranches(root: String, fetching: Bool) {
        Task.detached(priority: .utility) {
            if fetching { _ = GitCommand.run(["fetch", "--quiet"], in: root, timeout: 60) }
            let listed = GitCommand.output(
                ["branch", "--all", "--format=%(refname:short)"], in: root) ?? ""
            let names = GitReviewProbe.branchNames(in: listed)
            await MainActor.run { self.branches[root] = names }
        }
    }

    // MARK: Which reviews are open as tabs

    /// Records what one window has open, replacing whatever it reported
    /// before and dropping the windows that have closed.
    ///
    /// Silent when nothing changed. Every mutation that touches a cell ends
    /// here — a dirty dot included — and publishing on each of them would
    /// redraw the Git panel while somebody is typing.
    func noteReviewTabs(open: [String], front: String?, from owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        var next = reviewTabs.filter { $0.key == key || $0.value.owner != nil }
        next[key] = OpenReviewTabs(owner: owner, open: Set(open), front: front)

        guard !Self.same(next, reviewTabs) else { return }
        reviewTabs = next
    }

    /// Whether this review is open as a tab in some window.
    func isOpen(_ scope: GitReviewScope) -> Bool {
        live.contains { $0.open.contains(scope.id) }
    }

    /// Whether it is the tab a window is showing.
    ///
    /// Two windows on one repository can both answer yes, for two different
    /// commits: the list that asks is drawn per window but reaches this
    /// object knowing only a root. Marking a row in both is the harmless half
    /// of that trade; the other half — one window's tabs erasing the other's
    /// — is what keying by window prevents.
    func isFront(_ scope: GitReviewScope) -> Bool {
        live.contains { $0.front == scope.id }
    }

    private var live: [OpenReviewTabs] {
        reviewTabs.values.filter { $0.owner != nil }
    }

    private static func same(
        _ lhs: [ObjectIdentifier: OpenReviewTabs],
        _ rhs: [ObjectIdentifier: OpenReviewTabs]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            return other.open == value.open && other.front == value.front
        }
    }

    // MARK: Off the main actor

    private nonisolated static func assemble(
        root: String,
        chosenTarget: String?
    ) -> State {
        let pullRequest = GitReviewGitHub.pullRequest(in: root)

        /// The order the reader would use, and the reason `chosen` comes first
        /// is that it is the only one they asked for out loud.
        let target: GitReviewTargetChoice
        if let chosenTarget {
            target = .chosen(chosenTarget)
        } else if let base = pullRequest?.baseRef {
            target = .pullRequestBase(base)
        } else {
            let listed = GitCommand.output(["branch", "--remotes"], in: root) ?? ""
            target = .repositoryDefault(GitReviewProbe.defaultBranch(in: listed) ?? "main")
        }

        switch GitBranchReviewLoader.load(in: root, base: target.ref) {
        case .failed(let failure):
            return .failed(failure.title)
        case .tooLarge(let bytes):
            return .failed("This branch changes more than the reviewer will draw (\(bytes) bytes).")
        case .review(let review):
            let branch = review.branch ?? "HEAD"
            /// Two dots, not three. Three is the **symmetric difference** —
            /// it includes the commits the target has and the branch does not,
            /// so the header credited everyone who had worked on `main` since
            /// the branch left it. Reported: four commits on screen, all by
            /// one person, under a byline reading "Bernardo Hazin (25), Isac
            /// Petinate (12), Jefferson Daniel (8), Karina Crispim (7)" — the
            /// 63 commits of `main...HEAD`, exactly.
            ///
            /// `git log a...b` and `git diff a...b` do not mean the same
            /// thing, which is the whole trap: for `diff` three dots means
            /// "against the merge base", and that is the right one there.
            let range = "\(target.ref)..\(branch)"

            let context = GitReviewContext(
                branch: branch,
                target: target,
                pullRequest: pullRequest,
                conflicts: GitReviewProbe.conflicts(
                    branch: branch, target: target.ref, in: root),
                authors: GitReviewProbe.authors(range: range, in: root),
                commitCount: review.commits.count,
                addedLines: review.files.compactMap(\.addedLines).reduce(0, +),
                removedLines: review.files.compactMap(\.removedLines).reduce(0, +),
                fileCount: review.files.count
            )
            return .ready(context, review)
        }
    }
}

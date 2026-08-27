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
            states.removeValue(forKey: root)
        }
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
            await MainActor.run {
                self.loading.remove(root)
                self.states[root] = outcome
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
            let range = "\(target.ref)...\(branch)"

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

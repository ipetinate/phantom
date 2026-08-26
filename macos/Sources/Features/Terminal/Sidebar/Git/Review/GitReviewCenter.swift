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

    enum State: Equatable {
        case loading
        case ready(GitReviewContext, GitBranchReview)
        case failed(String)
    }

    private var loading: Set<String> = []

    private init() {}

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

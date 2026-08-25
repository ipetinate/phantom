import Combine
import Foundation

/// The committed text of the files the editor has open.
///
/// What the margin's `+` and `-` are measured against. Kept here rather than
/// on the document because it is not the document's: it is a fact about the
/// repository that happens to be about this path, it is fetched by running
/// git, and it goes stale for reasons — a commit, a checkout, a stage — that
/// have nothing to do with anybody editing the file.
///
/// One entry per path, and `nil` is a real answer meaning "nothing to compare
/// against": an untracked file, a file outside a repository, or one added in
/// this working tree and never committed. All three are files whose every line
/// is new, and marking every line `+` would be true and useless.
@MainActor
final class EditorGitBaseline: ObservableObject {
    static let shared = EditorGitBaseline()

    /// Committed text, split into lines, by absolute path.
    @Published private(set) var baselines: [String: [String]] = [:]

    /// Paths asked about and answered with "there is no baseline", so the
    /// question is not asked again on every keystroke. Cleared by the same
    /// invalidation that clears an answer.
    private var withoutBaseline: Set<String> = []

    private var loading: Set<String> = []

    /// What HEAD looked like when a root's baselines were fetched, so a
    /// commit, a checkout or a pull can be noticed.
    private var heads: [String: String] = [:]

    private var subscription: AnyCancellable?

    /// Files past this are not fetched.
    ///
    /// The comparison has its own budget in ``EditorDiffMarks``; this one is
    /// about the fetch. Reading a 50 MB blob out of git to then decline to
    /// compare it is work with a guaranteed empty result.
    static let byteBudget = 4_000_000

    private init() {
        /// The signal already in the app rather than a `rev-parse` of its
        /// own on a timer. `GitCenter` refreshes a root's status on its own
        /// schedule and after every operation it runs, and both the branch
        /// and the tip commit's subject move when HEAD does.
        ///
        /// It is a fingerprint and not an identity, and the gap is worth
        /// naming: amending a commit without changing its message leaves both
        /// halves the same, so the baseline stays as it was until something
        /// else moves. The cost of being wrong there is a `+` on a line that
        /// now matches HEAD, which the next commit corrects.
        subscription = GitCenter.shared.$lastCommits
            .sink { [weak self] commits in
                MainActor.assumeIsolated { self?.noticeHeads(commits) }
            }
    }

    private func noticeHeads(_ commits: [String: String]) {
        for (root, commit) in commits {
            let branch = GitCenter.shared.statuses[root]?.branch ?? ""
            let fingerprint = "\(branch)\u{1}\(commit)"
            guard heads[root] != nil, heads[root] != fingerprint else {
                heads[root] = fingerprint
                continue
            }
            heads[root] = fingerprint
            invalidate(root: root)
        }
    }

    func baseline(for path: String) -> [String]? { baselines[path] }

    /// Asks for a path's committed text, at most once until it is invalidated.
    ///
    /// Safe to call on every view update, which is how it is called: the two
    /// sets below are what turn a question asked sixty times a second into one
    /// `git show`.
    func request(path: String) {
        guard baselines[path] == nil,
              !withoutBaseline.contains(path),
              !loading.contains(path)
        else { return }

        guard let root = EditorChangeLookup.repositoryRoot(forPath: path) else {
            withoutBaseline.insert(path)
            return
        }

        if heads[root] == nil {
            let branch = GitCenter.shared.statuses[root]?.branch ?? ""
            heads[root] = "\(branch)\u{1}\(GitCenter.shared.lastCommits[root] ?? "")"
        }

        loading.insert(path)
        Task.detached(priority: .utility) {
            let text = Self.committedText(of: path, in: root)
            await MainActor.run {
                self.loading.remove(path)
                guard let text else {
                    self.withoutBaseline.insert(path)
                    return
                }
                self.baselines[path] = EditorDiffMarks.lines(of: text)
            }
        }
    }

    /// Forgets what was known about a path, so the next request refetches.
    ///
    /// Called when the repository moves under the file — a commit, a checkout,
    /// a stage — rather than when the file is edited. An edit changes the
    /// buffer, and the buffer is the *other* side of the comparison.
    func invalidate(path: String) {
        baselines.removeValue(forKey: path)
        withoutBaseline.remove(path)
    }

    /// Forgets everything under a repository root, for the same reasons at
    /// the scale a branch switch happens at.
    func invalidate(root: String) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for path in baselines.keys where path.hasPrefix(prefix) {
            baselines.removeValue(forKey: path)
        }
        withoutBaseline = withoutBaseline.filter { !$0.hasPrefix(prefix) }
    }

    /// `git show HEAD:<path>`, or nil when there is nothing committed to show.
    ///
    /// Off the main actor: it is a subprocess. A failure is not distinguished
    /// from an untracked file on purpose — both mean the same thing here, and
    /// the difference between "never committed" and "git could not answer"
    /// would change nothing the margin does.
    private nonisolated static func committedText(of path: String, in root: String) -> String? {
        let relative = EditorChangeLookup.relativePath(forPath: path, root: root) ?? path
        guard let output = GitCommand.output(["show", "HEAD:\(relative)"], in: root),
              output.utf8.count <= byteBudget
        else { return nil }
        return output
    }
}

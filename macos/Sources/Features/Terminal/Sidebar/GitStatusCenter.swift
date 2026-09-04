import Foundation
import Combine

/// Async git/GitHub enrichment for sidebar tabs, keyed by repository
/// root: whether the worktree has uncommitted changes, and the open
/// pull request for the current branch (via the `gh` CLI when present).
///
/// Everything runs off the main thread with per-repo TTLs so the
/// sidebar refresh loop never blocks on subprocesses.
@MainActor
final class GitStatusCenter: ObservableObject {
    static let shared = GitStatusCenter()

    struct RepoInfo: Equatable {
        var isDirty: Bool?

        /// How many paths git reports as unmerged, or nil while nothing is
        /// known about this repository yet.
        ///
        /// A count rather than a flag, because the chip that shows it says how
        /// many — "3 conflicts" is a different size of problem from one, and a
        /// reader deciding whether to finish now wants the number.
        var conflicts: Int?
        var prNumber: Int?
        var prURL: String?

        var dirtyCheckedAt: Date = .distantPast
        var prCheckedAt: Date = .distantPast
        var prBranch: String?
    }

    struct PullRequest: Identifiable, Equatable {
        let number: Int
        let title: String
        let url: String
        let author: String?

        /// Who the pull request was handed to, by login. Empty on a
        /// repository nobody assigns anything in, which is most of them.
        let assignees: [String]

        var id: Int { number }

        /// Whether this pull request is the reader's: they opened it, or
        /// somebody put their name on it.
        ///
        /// Assignment counts. A pull request assigned to you is one you are
        /// expected to move, which is the same reason you look for the ones
        /// you opened — and it is the half a "your pull request" badge on the
        /// author alone never showed.
        ///
        /// Compared without case. GitHub logins are case-insensitive, and
        /// `gh` prints the canonical spelling in one place and whatever was
        /// typed in another.
        func belongs(to login: String) -> Bool {
            let wanted = login.lowercased()
            if author?.lowercased() == wanted { return true }
            return assignees.contains { $0.lowercased() == wanted }
        }
    }

    /// The signed-in `gh` user's login, once it is known.
    ///
    /// Published rather than read straight from the static below, because
    /// reading that runs `gh api user` on whichever thread touches it first
    /// — and a row body touching it froze the popover while it opened. Nil
    /// until the answer lands, which the list treats as "no pull request is
    /// mine yet" rather than guessing.
    @Published private(set) var userLogin: String?

    private var isLoadingUserLogin = false

    /// The signed-in `gh` user's login, fetched once and cached — compared
    /// against each PR's author and assignees so the list can put the
    /// viewer's own work first.
    nonisolated static let currentUserLogin: String? = {
        guard let gh = ghPath else { return nil }
        guard let output = run(gh, ["api", "user", "--jq", ".login"], timeout: 10)
        else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    @Published private(set) var repos: [String: RepoInfo] = [:]

    /// All open PRs per repository root (not just the current branch),
    /// fetched on demand for the group PR list.
    @Published private(set) var repoPRLists: [String: [PullRequest]] = [:]

    private var inflight: Set<String> = []
    private var prListInflight: Set<String> = []
    private var prListFetchedAt: [String: Date] = [:]

    private static let dirtyTTL: TimeInterval = 15
    private static let prTTL: TimeInterval = 300
    private static let prListTTL: TimeInterval = 180

    func info(forRoot root: String?) -> RepoInfo? {
        root.flatMap { repos[$0] }
    }

    /// Refreshes stale data for a repo in the background; cheap no-op
    /// while fresh or already in flight.
    func requestRefresh(root: String, branch: String?) {
        let now = Date()
        let info = repos[root] ?? RepoInfo()
        let needsDirty = now.timeIntervalSince(info.dirtyCheckedAt) > Self.dirtyTTL
        let needsPR = now.timeIntervalSince(info.prCheckedAt) > Self.prTTL
            || info.prBranch != branch

        guard needsDirty || needsPR, !inflight.contains(root) else { return }
        inflight.insert(root)

        Task.detached(priority: .utility) {
            let status = needsDirty ? Self.checkStatus(root: root) : nil
            let pr = needsPR ? Self.checkPullRequest(root: root) : nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                var info = self.repos[root] ?? RepoInfo()
                if needsDirty {
                    info.isDirty = status?.dirty
                    info.conflicts = status?.conflicts
                    info.dirtyCheckedAt = Date()
                }
                if needsPR {
                    info.prNumber = pr?.number
                    info.prURL = pr?.url
                    info.prCheckedAt = Date()
                    info.prBranch = branch
                }
                self.repos[root] = info
                self.inflight.remove(root)
            }
        }
    }

    /// Asks `gh` who is signed in, off the main thread, once per launch.
    func requestUserLogin() {
        guard userLogin == nil, !isLoadingUserLogin else { return }
        isLoadingUserLogin = true

        Task.detached(priority: .utility) {
            let login = Self.currentUserLogin
            await MainActor.run { [weak self] in
                self?.userLogin = login
                self?.isLoadingUserLogin = false
            }
        }
    }

    /// Fetches the repo's open PR list in the background; no-op while
    /// fresh or in flight. `repoPRLists` publishes when results land.
    func requestPRList(root: String) {
        let now = Date()
        if let fetched = prListFetchedAt[root],
           now.timeIntervalSince(fetched) < Self.prListTTL {
            return
        }
        guard !prListInflight.contains(root) else { return }
        prListInflight.insert(root)

        Task.detached(priority: .userInitiated) {
            let prs = Self.fetchPRList(root: root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.repoPRLists[root] = prs ?? []
                self.prListFetchedAt[root] = Date()
                self.prListInflight.remove(root)
            }
        }
    }

    nonisolated private static func fetchPRList(root: String) -> [PullRequest]? {
        guard let gh = ghPath else { return nil }
        guard let output = run(
            gh,
            ["pr", "list", "--json", "number,title,url,author,assignees", "--limit", "25"],
            cwd: root,
            timeout: 15
        ) else { return nil }

        guard let data = output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return list.compactMap { entry in
            guard let number = entry["number"] as? Int,
                  let title = entry["title"] as? String,
                  let url = entry["url"] as? String
            else { return nil }
            let author = (entry["author"] as? [String: Any])?["login"] as? String
            let assignees = (entry["assignees"] as? [[String: Any]] ?? [])
                .compactMap { $0["login"] as? String }
            /// Rendered here rather than at the view, which is what the
            /// review card already does — so the two cannot come to disagree
            /// about whether `:rocket:` is a rocket.
            return PullRequest(
                number: number,
                title: GitHubEmoji.render(title),
                url: url,
                author: author,
                assignees: assignees)
        }
    }

    // MARK: Subprocess checks

    /// Whether the tree is dirty and how many paths are unmerged, from one
    /// `git status`.
    ///
    /// Both facts out of the same command rather than two, because they are in
    /// the same output: porcelain marks an unmerged path with a pair of status
    /// letters holding a `U`, or with `AA` and `DD` for the two cases where
    /// both sides did the same thing. A second `git` process to count what the
    /// first already printed would be a second process on a timer.
    nonisolated private static func checkStatus(root: String) -> (dirty: Bool, conflicts: Int)? {
        guard let output = run(
            "/usr/bin/git",
            ["-C", root, "status", "--porcelain", "--untracked-files=no"],
            timeout: 5
        ) else { return nil }

        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return (dirty: !lines.isEmpty, conflicts: lines.count(where: isUnmerged))
    }

    /// Whether a porcelain line describes a path git could not merge.
    ///
    /// The rule git documents: either letter is `U`, or the pair is `AA` or
    /// `DD`. Checking only for `U` misses the two cases where both sides added
    /// the same path or both deleted it, which are conflicts the reader has to
    /// resolve like any other.
    nonisolated static func isUnmerged(_ line: String) -> Bool {
        let letters = Array(line.prefix(2))
        guard letters.count == 2 else { return false }
        if letters[0] == "U" || letters[1] == "U" { return true }
        return (letters[0] == "A" && letters[1] == "A")
            || (letters[0] == "D" && letters[1] == "D")
    }

    nonisolated private static let ghPath: String? = {
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }()

    nonisolated private static func checkPullRequest(root: String) -> (number: Int, url: String)? {
        guard let gh = ghPath else { return nil }
        guard let output = run(
            gh,
            ["pr", "view", "--json", "number,url,state"],
            cwd: root,
            timeout: 10
        ) else { return nil }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int,
              let url = json["url"] as? String,
              (json["state"] as? String) == "OPEN"
        else { return nil }

        return (number, url)
    }

    nonisolated private static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval
    ) -> String? {
        ShellCommand.run(launchPath, arguments, cwd: cwd, timeout: timeout)
    }
}

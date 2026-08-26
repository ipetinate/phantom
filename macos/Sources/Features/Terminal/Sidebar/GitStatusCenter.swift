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

        var id: Int { number }
    }

    /// The signed-in `gh` user's login, fetched once and cached — compared
    /// against each PR's author so the list can flag the viewer's own work
    /// without a per-row lookup.
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
            ["pr", "list", "--json", "number,title,url,author", "--limit", "25"],
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
            return PullRequest(number: number, title: title, url: url, author: author)
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

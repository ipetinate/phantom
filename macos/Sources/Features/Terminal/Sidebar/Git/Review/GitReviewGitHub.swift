import Foundation

/// The pull request behind the current branch, as `gh` describes it.
///
/// **Absent is a normal answer, not an error.** No `gh` on the machine, `gh`
/// not signed in, a repository with no remote, a branch nobody has opened a
/// pull request for — all four mean the same thing to the review screen, which
/// is that it compares against the default branch instead. Distinguishing them
/// would produce four error messages for a screen that works fine in all four
/// cases.
enum GitReviewGitHub {
    /// Where `gh` tends to be. The same three paths `GitStatusCenter` looks
    /// in, for the same reason: a GUI-launched app does not inherit the
    /// login shell's PATH.
    private static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    nonisolated static let path: String? = candidates.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// The fields asked for, spelled once.
    ///
    /// `baseRefName` is the one that matters — it is what makes this screen
    /// show what will actually be merged rather than a guess — and the rest is
    /// what the card puts around it.
    static let fields =
        "number,title,url,baseRefName,author,assignees,isDraft,body,state,createdAt,updatedAt"

    nonisolated static func pullRequest(in root: String) -> GitReviewPullRequest? {
        guard let path else { return nil }
        let result = ShellCommand.runResult(
            path,
            ["pr", "view", "--json", fields],
            cwd: root,
            environment: LoginEnvironment.environment(),
            timeout: 15
        )
        guard result.succeeded else { return nil }
        return parse(result.stdout)
    }

    /// `gh`'s JSON, taken apart.
    ///
    /// Every field except the number and the title is allowed to be missing:
    /// a repository with no assignees, a fork whose author `gh` cannot
    /// resolve, an empty body. A card that hid itself over a missing assignee
    /// would hide the number with it.
    static func parse(_ output: String) -> GitReviewPullRequest? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int,
              (json["state"] as? String) == "OPEN"
        else { return nil }

        let assignees = (json["assignees"] as? [[String: Any]] ?? [])
            .compactMap { $0["login"] as? String }

        /// GitHub's shortcodes are rendered here rather than at the two places
        /// that draw them, so the card and the panel cannot come to disagree
        /// about whether `:rocket:` is a rocket.
        return GitReviewPullRequest(
            number: number,
            title: GitHubEmoji.render(json["title"] as? String ?? ""),
            url: json["url"] as? String ?? "",
            baseRef: json["baseRefName"] as? String ?? "",
            author: (json["author"] as? [String: Any])?["login"] as? String,
            assignees: assignees,
            isDraft: json["isDraft"] as? Bool ?? false,
            bodyPreview: GitReviewPullRequest.preview(of: json["body"] as? String)
                .map(GitHubEmoji.render),
            createdAt: GitReviewPullRequest.date(fromISO8601: json["createdAt"] as? String),
            updatedAt: GitReviewPullRequest.date(fromISO8601: json["updatedAt"] as? String)
        )
    }
}

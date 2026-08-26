import Foundation

/// One file's diff for the review, plus the commit that is credited with it.
///
/// The two together because they are asked at the same moment and thrown away
/// at the same moment: a card that opens wants both, and a card that never
/// opens wants neither. Two calls with two caches would be two things to
/// invalidate for one row.
enum GitReviewFileDiffLoader {
    struct Loaded {
        let outcome: GitDiffOutcome
        let commit: GitReviewCommit?
    }

    /// Blocking — both halves run `git`. Call it off the main actor.
    nonisolated static func load(
        path: String,
        previousPath: String?,
        scope: GitReviewScope
    ) -> Loaded {
        switch scope {
        case .branch(let root):
            return Loaded(
                outcome: GitDiffLoader.load(
                    path: path,
                    previousPath: previousPath,
                    side: .branch(base: mergeBaseArgument(in: root)),
                    in: root),
                commit: lastCommit(touching: path, in: root)
            )

        case .commit(let root, let sha, _):
            /// One commit compared against its own parent. `sha^!` is git's
            /// shorthand for exactly that and it works on a root commit, where
            /// `sha^..sha` does not — a first commit has no parent to name.
            return Loaded(
                outcome: GitDiffLoader.load(
                    path: path,
                    previousPath: previousPath,
                    side: .branch(base: "\(sha)^!"),
                    in: root),
                commit: commit(sha, in: root)
            )
        }
    }

    /// What the branch is compared against, for the file-level diff.
    ///
    /// Read back from the review that is already on screen rather than
    /// resolved again: the header and the file rows must agree about the
    /// target, and asking twice is how they come to disagree the moment a
    /// reader changes it.
    private nonisolated static func mergeBaseArgument(in root: String) -> String {
        MainActor.assumeIsolated {
            guard case .ready(let context, _)? = GitReviewCenter.shared.state(for: root)
            else { return "HEAD" }
            return context.target.ref
        }
    }

    /// The last commit to touch a path in this range.
    ///
    /// The *last*, which is what a pull request's file list credits: it is the
    /// one whose version lands on the target. The earlier ones are visible in
    /// the commit strip, and each has its own review a click away.
    private nonisolated static func lastCommit(
        touching path: String,
        in root: String
    ) -> GitReviewCommit? {
        guard let output = GitCommand.output(
            ["log", "-1", "--format=%H%x1f%s%x1f%an%x1f%ar", "--", path],
            in: root
        ) else { return nil }
        return parse(output)
    }

    private nonisolated static func commit(_ sha: String, in root: String) -> GitReviewCommit? {
        guard let output = GitCommand.output(
            ["show", "-s", "--format=%H%x1f%s%x1f%an%x1f%ar", sha],
            in: root
        ) else { return nil }
        return parse(output)
    }

    /// Four fields separated by a unit separator.
    ///
    /// `%x1f` rather than a character anybody types: a commit subject can hold
    /// a tab, a pipe or a comma, and every one of those has been somebody's
    /// separator once.
    static func parse(_ output: String) -> GitReviewCommit? {
        let line = output.components(separatedBy: "\n").first { !$0.isEmpty } ?? ""
        let parts = line.components(separatedBy: "\u{1f}")
        guard parts.count >= 4, !parts[0].isEmpty else { return nil }

        return GitReviewCommit(
            sha: parts[0],
            subject: parts[1],
            author: parts[2],
            relativeDate: parts[3]
        )
    }
}

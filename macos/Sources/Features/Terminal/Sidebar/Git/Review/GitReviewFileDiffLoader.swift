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
    ///
    /// - Parameter target: what the branch is compared against, handed in
    ///   rather than looked up. It lives on `GitReviewCenter`, which is
    ///   `@MainActor`, and reaching for it from here is a crash and not a race:
    ///   `MainActor.assumeIsolated` is a precondition, so calling it off the
    ///   main actor aborts the process rather than returning something wrong.
    ///   It is also the honest shape — the header and the file rows have to
    ///   agree about the target, and one value passed down cannot disagree
    ///   with itself.
    nonisolated static func load(
        path: String,
        previousPath: String?,
        scope: GitReviewScope,
        target: String
    ) -> Loaded {
        switch scope {
        case .branch(let root):
            return Loaded(
                outcome: GitDiffLoader.load(
                    path: path,
                    previousPath: previousPath,
                    side: .branch(base: target),
                    in: root),
                commit: lastCommit(touching: path, in: root)
            )

        case .commit(let root, let sha, _):
            /// One commit compared against its own parent. The reasoning for
            /// `^!` now lives with `GitDiffSide.commit`, which is also what
            /// stops it being appended to a range: passed as a branch base, it
            /// became `<sha>^!...HEAD` and git refused every one of them.
            return Loaded(
                outcome: GitDiffLoader.load(
                    path: path,
                    previousPath: previousPath,
                    side: .commit(sha: sha),
                    in: root),
                commit: commit(sha, in: root)
            )
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

import Foundation

/// What asking for a branch review produced.
///
/// Only two things can go wrong that aren't part of the answer: git refused
/// to run, or the branch is bigger than anything worth drawing. Every other
/// awkward state — no base, no commits, a detached `HEAD` — is a
/// ``GitBranchReview`` that says so.
enum GitBranchReviewOutcome: Equatable {
    case review(GitBranchReview)

    /// More output than the panel will lay out.
    case tooLarge(bytes: Int)

    case failed(GitFailure)
}

/// Reads what a branch adds to its base out of git.
///
/// Blocking, like everything else that runs `git` here; call it from a
/// background task. Goes through ``GitCommand``, so it inherits the login
/// shell's `PATH` and the timeout policy.
///
/// ## Two dots and three dots
///
/// The two ranges below look like typos of each other and ask opposite
/// questions, so both are spelled out once here:
///
/// - `git log base..HEAD` — two dots — lists the commits reachable from
///   `HEAD` and not from `base`: exactly the ones this branch adds.
/// - `git diff base...HEAD` — three dots — diffs against the **merge
///   base**, the commit the branch left `base` at. This is what a pull
///   request shows.
///
/// The trap is `git diff base..HEAD` with two dots, which compares the two
/// commits as they stand today. Everything that landed on `base` after the
/// branch forked then shows up in the review, inverted — somebody else's
/// added line reported as this branch's deletion — as though the branch had
/// written it. A review that does that is worse than no review, because it
/// is confidently wrong about who wrote what.
enum GitBranchReviewLoader {
    /// How many commits are read before the list is called long enough.
    ///
    /// A branch whose base is years behind it has thousands, and nobody
    /// reads past the first screen. The review says when it stopped rather
    /// than quietly ending the list — see ``GitBranchReview/hasMoreCommits``.
    static let maximumCommits = 500

    /// Past this much output, the file list is not something to draw.
    ///
    /// The same ceiling ``GitDiffLoader`` uses for one file's diff. This
    /// output is one line per file rather than per line of content, so
    /// reaching it takes a branch that touches on the order of a hundred
    /// thousand paths — a vendored tree, or a base guessed catastrophically
    /// wrong.
    static let maximumOutputBytes = 4 * 1024 * 1024

    /// The names tried, in order, when nothing better identifies the base.
    ///
    /// `origin/…` first: the remote's copy is the thing a pull request will
    /// actually be opened against, and a local `main` left unpulled for a
    /// month would credit this branch with everyone else's commits.
    static let wellKnownBases = ["origin/main", "origin/master", "main", "master"]

    /// Everything the branch adds to its base.
    ///
    /// - Parameter base: a ref to compare against, when the caller knows
    ///   better than the search does. Naming one that doesn't exist, or one
    ///   with no history in common with `HEAD`, is a failure rather than a
    ///   silent fallback: the caller asked a specific question and deserves
    ///   to hear that it couldn't be answered.
    /// - Parameter commitLimit: how many commits to read. See
    ///   ``maximumCommits``.
    nonisolated static func load(
        in root: String,
        base explicitBase: String? = nil,
        commitLimit: Int = maximumCommits
    ) -> GitBranchReviewOutcome {
        /// `--verify --quiet` separates the two reasons `HEAD` has no
        /// commit: a repository whose first commit hasn't happened exits 1
        /// and says nothing, while a path that isn't a repository at all
        /// exits 128 with a message. Reading them the same way would report
        /// a broken working directory as an empty branch.
        let headResult = GitCommand.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)
        guard headResult.succeeded || headResult.status == 1 else {
            return .failed(failure(from: headResult))
        }
        let head = firstLine(of: headResult.stdout)

        /// Absent for a detached `HEAD`, and *present* in a repository with
        /// no commits: an unborn branch has a name, it just has nothing
        /// under it yet.
        let branch = GitCommand.output(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
            .flatMap(firstLine)

        guard head != nil else {
            return .review(GitBranchReview(branch: branch, head: nil, base: nil))
        }

        let base: GitReviewBase?
        if let explicitBase {
            guard exists(explicitBase, in: root) else {
                return .failed(
                    GitFailure(operation: "Review", output: "fatal: unknown revision '\(explicitBase)'")
                )
            }
            guard let named = resolve(explicitBase, source: .explicit, in: root) else {
                return .failed(
                    GitFailure(
                        operation: "Review",
                        output: "fatal: '\(explicitBase)' has no history in common with HEAD"
                    )
                )
            }
            base = named
        } else {
            base = resolveBase(in: root, branch: branch)
        }

        guard let base else {
            return .review(GitBranchReview(branch: branch, head: head, base: nil))
        }

        let limit = max(1, commitLimit)
        let logResult = GitCommand.run(commitArguments(base: base.ref, limit: limit), in: root)
        guard logResult.succeeded else { return .failed(failure(from: logResult)) }

        let nameStatus = GitCommand.run(diffArguments(base: base.ref, mode: "--name-status"), in: root)
        guard nameStatus.succeeded else { return .failed(failure(from: nameStatus)) }

        let numstat = GitCommand.run(diffArguments(base: base.ref, mode: "--numstat"), in: root)
        guard numstat.succeeded else { return .failed(failure(from: numstat)) }

        let bytes = nameStatus.stdout.utf8.count + numstat.stdout.utf8.count
        guard bytes <= maximumOutputBytes else { return .tooLarge(bytes: bytes) }

        /// One more than the limit is read so the difference between "this
        /// is all of them" and "this is where we stopped" is measured
        /// rather than assumed.
        let read = GitBranchReviewParser.parseCommits(logResult.stdout)

        return .review(
            GitBranchReview(
                branch: branch,
                head: head,
                base: base,
                commits: Array(read.prefix(limit)),
                files: GitBranchReviewParser.files(
                    nameStatus: nameStatus.stdout,
                    numstat: numstat.stdout
                ),
                hasMoreCommits: read.count > limit
            )
        )
    }

    /// What this branch is compared against, guessed in order of how much
    /// the guess can be trusted.
    ///
    /// 1. The branch's own upstream, which somebody configured on purpose.
    /// 2. `origin/HEAD` — the remote's default branch, recorded at clone.
    /// 3. ``wellKnownBases``, tried by name.
    ///
    /// Returns nil when none of them exists or none shares any history with
    /// `HEAD`. A repository with one branch and no remote lands there, and
    /// it is an ordinary repository rather than a broken one.
    nonisolated static func resolveBase(in root: String, branch: String?) -> GitReviewBase? {
        if let upstream = GitCommand.output(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            in: root
        ).flatMap(firstLine),
            !isOwnRemoteBranch(upstream, of: branch),
            let base = resolve(upstream, source: .upstream, in: root) {
            return base
        }

        if let remoteHead = GitCommand.output(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: root
        ).flatMap(firstLine),
            let base = resolve(remoteHead, source: .remoteHead, in: root) {
            return base
        }

        for candidate in wellKnownBases where candidate != branch {
            if let base = resolve(candidate, source: .wellKnown, in: root) { return base }
        }

        return nil
    }

    /// Whether an upstream is just this branch's own copy on the remote.
    ///
    /// A pushed branch tracks `origin/<itself>`, and comparing a branch
    /// against its own remote copy answers "what haven't I pushed yet" —
    /// which the panel's ahead/behind count already says, and which is not
    /// the question this feature asks. The search steps over it and carries
    /// on to the remote's default branch, so a branch that was pushed
    /// before the pull request was opened still shows the pull request.
    ///
    /// Only the remote name is stripped, so `origin/feature/x` is the
    /// branch `feature/x` and not the branch `x`.
    nonisolated static func isOwnRemoteBranch(_ upstream: String, of branch: String?) -> Bool {
        guard let branch else { return false }
        let withoutRemote = upstream
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "/")
        return withoutRemote == branch
    }

    private static func resolve(
        _ ref: String,
        source: GitReviewBaseSource,
        in root: String
    ) -> GitReviewBase? {
        /// `merge-base` fails both for a ref that doesn't exist and for one
        /// with no common ancestor, and neither is a base — so this one
        /// call decides both, and the search moves to the next candidate
        /// either way.
        guard let mergeBase = GitCommand.output(["merge-base", ref, "HEAD"], in: root)
            .flatMap(firstLine) else { return nil }

        return GitReviewBase(ref: ref, mergeBase: mergeBase, source: source)
    }

    private static func exists(_ ref: String, in root: String) -> Bool {
        GitCommand.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: root).succeeded
    }

    /// - `-z` so each commit is NUL-terminated and a subject can hold
    ///   anything, newlines included, without ending the record early.
    /// - `--format` with `%x1f` between fields, for the same reason.
    /// - `--no-color` because a user with `color.ui = always` gets escapes
    ///   in piped output too, and they would land in the subject text.
    /// - `core.quotePath=false` to match the rest of the Git panel; `-z`
    ///   already suppresses the quoting, and the setting costs nothing.
    /// - `--` because a ref range is also a legal path, and a repository
    ///   holding a file named like one would otherwise be ambiguous.
    private static func commitArguments(base: String, limit: Int) -> [String] {
        [
            "-c", "core.quotePath=false",
            "log",
            "-z",
            "--no-color",
            "--format=\(GitBranchReviewParser.commitFormat)",
            "-n", "\(limit + 1)",
            "\(base)..HEAD",
            "--",
        ]
    }

    /// The file list, in the two shapes git will only give separately:
    /// `--name-status` knows what happened to each file, `--numstat` knows
    /// how many lines it cost.
    ///
    /// Three dots. See this type's note; it is the difference between this
    /// branch's work and everyone else's.
    ///
    /// The rest matches ``GitDiffLoader``: no color, no external difftool,
    /// no textconv — a textconv filter would count lines in a *rendering*
    /// of the file rather than in the file.
    private static func diffArguments(base: String, mode: String) -> [String] {
        [
            "-c", "core.quotePath=false",
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "-z",
            "--find-renames",
            mode,
            "\(base)...HEAD",
            "--",
        ]
    }

    /// The first line of git's output, or nil when there is none.
    ///
    /// Split by scalar rather than by `Character`, for the reason
    /// ``GitFailure`` documents: a CRLF payload has no `\n` *Character* in
    /// it at all.
    private static func firstLine(of output: String) -> String? {
        let line = output.splitIntoLines()
            .first?
            .droppingTrailingCarriageReturn
            .trimmingCharacters(in: .whitespaces)
        guard let line, !line.isEmpty else { return nil }
        return line
    }

    private static func failure(from result: ShellCommand.Result) -> GitFailure {
        GitFailure(
            operation: "Review",
            output: [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
    }
}

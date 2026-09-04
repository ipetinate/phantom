import Foundation

/// Which two versions of a file a diff compares.
///
/// The same two the Git panel already separates into lists, named the same
/// way: a file edited after it was staged is in both, and its two diffs are
/// different.
enum GitDiffSide: Equatable {
    /// Working tree against the index — plain `git diff`.
    case unstaged

    /// Index against `HEAD` — `git diff --cached`.
    case staged

    /// This branch against where it left the base — `git diff base...HEAD`,
    /// with three dots.
    ///
    /// Three, not two, and the difference is the whole point. Two dots
    /// compares the two commits, so everything that landed on the base branch
    /// since you forked shows up as though you had written it. Three dots
    /// compares against the **merge base**, which is what a pull request
    /// shows and what somebody reviewing their own branch means to see.
    case branch(base: String)

    /// One commit against its own parent — `git diff <sha>^!`.
    ///
    /// Its own case because `^!` is a *revision*, not a range, and the branch
    /// case appends `...HEAD` to whatever it is given. Smuggled through there,
    /// this produced `<sha>^!...HEAD`, which git refuses outright — so a
    /// commit opened from the branch review showed no diff at all, for every
    /// file, with no error anywhere the reader could see.
    ///
    /// `^!` rather than `<sha>^..<sha>` because it works on a root commit,
    /// which has no parent to name.
    case commit(sha: String)
}

/// What asking for a diff produced.
///
/// "No hunks" is not one answer, it is five, and a viewer that collapses
/// them shows a blank pane and lets the user guess which one happened.
enum GitDiffOutcome: Equatable {
    case diff(GitDiffDocument)

    /// Git found nothing to report for this path on this side.
    case unchanged

    /// A conflicted path. Git answers with a combined diff, or with
    /// `* Unmerged path` and nothing else.
    case conflicted

    /// Bigger than the viewer will draw.
    case tooLarge(bytes: Int)

    case failed(GitFailure)
}

/// Reads a file's diff out of git.
///
/// Blocking, like everything else that runs `git` here; call it from a
/// background task. Goes through ``GitCommand``, so it inherits the login
/// shell's `PATH` and the timeout policy.
enum GitDiffLoader {
    /// Lines of unchanged context around each change.
    ///
    /// Git's own default. It keeps the output small and turns a file with
    /// two distant edits into two islands with a gap band between them,
    /// which is how a side-by-side viewer wants to show it. Pass something
    /// enormous for a whole-file view — git has no "all", and a number
    /// larger than the file is how everyone asks for one.
    static let defaultContext = 3

    /// Past this, the diff is not something to draw.
    ///
    /// A generated lockfile or a checked-in bundle produces megabytes of
    /// unified diff. Parsing it is the cheap part; laying out a million
    /// rows is not, and no one is reading it either way.
    static let maximumOutputBytes = 4 * 1024 * 1024

    /// The diff for one file the Git panel is showing.
    ///
    /// Prefer this over ``load(path:previousPath:side:in:context:)``: a
    /// ``GitFileChange`` already knows the two things the raw call has to
    /// be told, namely whether the file is untracked and what it was called
    /// before it was renamed.
    nonisolated static func load(
        _ change: GitFileChange,
        side: GitDiffSide,
        in root: String,
        context: Int = defaultContext
    ) -> GitDiffOutcome {
        if change.isUnmerged { return .conflicted }

        if change.isUntracked {
            /// Nothing about an untracked file is in the index, so there is
            /// no staged side of it to show.
            /// An untracked file is only ever a working-tree fact: it is in
            /// no index and in no commit, so neither the staged side nor a
            /// branch range has anything to say about it.
            guard side == .unstaged else { return .unchanged }
            return loadUntracked(path: change.path, in: root, context: context)
        }

        return load(
            path: change.path,
            previousPath: change.originalPath,
            side: side,
            in: root,
            context: context
        )
    }

    /// The diff for a tracked path.
    ///
    /// - Parameter previousPath: what the file was called before it was
    ///   renamed, when it was. Git only detects a rename it can see both
    ///   ends of, and a pathspec that names one end filters the other out
    ///   of the comparison before detection runs — asking about the new
    ///   path alone reports a whole-file addition and loses the diff
    ///   entirely. Naming both is what makes `--find-renames` work here.
    nonisolated static func load(
        path: String,
        previousPath: String? = nil,
        side: GitDiffSide,
        in root: String,
        context: Int = defaultContext
    ) -> GitDiffOutcome {
        var arguments = baseArguments(context: context)
        arguments.append(contentsOf: rangeArguments(for: side))
        arguments.append("--find-renames")
        arguments.append("--")
        arguments.append(path)
        if let previousPath, previousPath != path { arguments.append(previousPath) }

        let result = GitCommand.run(arguments, in: root)
        guard result.succeeded else { return .failed(failure(from: result)) }

        return outcome(for: result.stdout, path: path) { file in
            guard GitDiffHighlight.needsWholeFile(file) else { return .none }
            return wholeFile(of: file, side: side, in: root)
        }
    }

    /// The diff for a file git has never seen.
    ///
    /// `git diff` has nothing to say about an untracked path — it is not in
    /// the index, so there is no pair to compare — and the panel still
    /// wants to show what is in it. `--no-index` against `/dev/null` asks
    /// git to diff two files directly, which gives the whole file as
    /// additions in the same format, with git's own binary detection
    /// instead of a guess.
    nonisolated static func loadUntracked(
        path: String,
        in root: String,
        context: Int = defaultContext
    ) -> GitDiffOutcome {
        var arguments = baseArguments(context: context)
        arguments.append("--no-index")
        arguments.append("--")
        arguments.append("/dev/null")
        arguments.append(path)

        let result = GitCommand.run(arguments, in: root)

        /// `--no-index` reports through the exit status the way `diff(1)`
        /// does: 0 identical, 1 differ, anything else an actual error.
        /// Treating 1 as failure rejects every untracked file there is.
        guard result.status == 0 || result.status == 1 else {
            return .failed(failure(from: result))
        }

        return outcome(for: result.stdout, path: path)
    }

    // MARK: Plumbing

    /// - `--no-color` because a user with `color.ui = always` gets ANSI
    ///   escapes in piped output too, and they would land in the line text.
    /// - `--no-ext-diff` because `diff.external` replaces the output
    ///   wholesale with whatever a GUI difftool prints, which is not this
    ///   format and often not text.
    /// - `--no-textconv` because a `.gitattributes` textconv filter diffs a
    ///   *rendering* of the file. The line numbers it produces are numbers
    ///   in that rendering, and this viewer's gutter promises numbers in
    ///   the file.
    /// - `core.quotePath=false` for the same reason ``GitStatus`` sets it:
    ///   without it every non-ASCII path arrives as C-escaped octal and
    ///   matches nothing.
    ///
    /// The diff algorithm is deliberately not set, so `diff.algorithm` from
    /// the user's own config decides it and the viewer agrees with what
    /// they see in their terminal.
    private static func baseArguments(context: Int) -> [String] {
        [
            "-c", "core.quotePath=false",
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--unified=\(max(0, context))",
        ]
    }

    /// What a side adds to `git diff`, before the pathspec.
    ///
    /// Kept beside `baseArguments` so the three shapes of this command are
    /// read together: nothing at all for the working tree, `--cached` for the
    /// index, and a three-dot range for a branch.
    static func rangeArguments(for side: GitDiffSide) -> [String] {
        switch side {
        case .unstaged: []
        case .staged: ["--cached"]
        case .branch(let base): ["\(base)...HEAD"]
        case .commit(let sha): ["\(sha)^!"]
        }
    }

    /// - Parameter source: asked for the parsed diff, and only once there is
    ///   one. It runs `git` again, so a diff that turns out to be unchanged,
    ///   conflicted or too large must not pay for it.
    private static func outcome(
        for output: String,
        path: String,
        source: (GitFileDiff) -> GitDiffSource = { _ in .none }
    ) -> GitDiffOutcome {
        /// `git diff --cached` on a conflicted path prints this one line and
        /// no diff at all.
        if output.hasPrefix("* Unmerged path") { return .conflicted }

        let bytes = output.utf8.count
        guard bytes <= maximumOutputBytes else { return .tooLarge(bytes: bytes) }

        let files = GitDiffParser.parse(unified: output)
        guard let file = match(path, in: files) else { return .unchanged }
        if file.isCombined { return .conflicted }

        return .diff(GitDiffDocument(file: file, source: source(file)))
    }

    // MARK: The versions themselves

    /// Both versions of a file, for a highlighter that cannot work from the
    /// hunks alone — argued in full on ``GitDiffHighlight``.
    ///
    /// Nil on either side rather than an error: a version that cannot be read
    /// is a column that colours the way it did before, which is the same
    /// degradation the text budget already has.
    static func wholeFile(
        of file: GitFileDiff,
        side: GitDiffSide,
        in root: String
    ) -> GitDiffSource {
        guard let revisions = revisions(for: side, in: root) else { return .none }
        return GitDiffSource(
            old: blob(revisions.old, at: file.previousPath ?? file.path, in: root),
            new: blob(revisions.new, at: file.path, in: root)
        )
    }

    /// The two versions a side compares, named the way `git show` can ask for
    /// them.
    ///
    /// `nil` for the new side of a working-tree diff, which is the file on
    /// disk and not an object in the repository at all — git prints a hash for
    /// it in the diff header, and that hash names nothing `git cat-file` can
    /// find.
    ///
    /// Nil for the whole answer where a side names no revision this can
    /// resolve. The three-dot range compares against the merge base, so that
    /// is the version the old column's line numbers belong to, and `git show`
    /// cannot be handed the range — it is resolved here, and a base that is
    /// not a revision at all comes back as no source rather than as the wrong
    /// one.
    static func revisions(for side: GitDiffSide, in root: String) -> (old: String, new: String?)? {
        switch side {
        case .unstaged:
            return (old: ":0", new: nil)
        case .staged:
            return (old: "HEAD", new: ":0")
        case .branch(let base):
            guard let merged = GitCommand.output(["merge-base", base, "HEAD"], in: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !merged.isEmpty
            else { return nil }
            return (old: merged, new: "HEAD")
        case .commit(let sha):
            /// A root commit has no `^`, so the old side comes back nil from
            /// `blob` and that column keeps the colour it had. Which is right:
            /// there is no previous version of a file that arrives with the
            /// first commit.
            return (old: "\(sha)^", new: sha)
        }
    }

    /// One version of a file, or nil for a version the highlighter would
    /// refuse anyway.
    ///
    /// The budget is checked here as well as where it is spent, so a minified
    /// bundle is not carried through the document to be dropped at the far
    /// end.
    private static func blob(_ revision: String?, at path: String, in root: String) -> String? {
        let text: String?
        if let revision {
            text = GitCommand.output(["show", "\(revision):\(path)"], in: root)
        } else {
            let file = (root as NSString).appendingPathComponent(path)
            text = try? String(contentsOfFile: file, encoding: .utf8)
        }

        guard let text, !text.isEmpty, text.utf16.count <= GitDiffHighlight.textBudget else {
            return nil
        }
        return text
    }

    /// Picks the file the caller asked about.
    ///
    /// Naming two paths so rename detection can work means git may answer
    /// with two file diffs when the two paths turn out to be unrelated
    /// changes rather than one rename.
    private static func match(_ path: String, in files: [GitFileDiff]) -> GitFileDiff? {
        files.first { $0.path == path }
            ?? files.first { $0.previousPath == path }
            ?? files.first
    }

    private static func failure(from result: ShellCommand.Result) -> GitFailure {
        GitFailure(
            operation: "Diff",
            output: [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        )
    }
}

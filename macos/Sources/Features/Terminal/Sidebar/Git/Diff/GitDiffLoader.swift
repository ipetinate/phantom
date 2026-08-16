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
            // Nothing about an untracked file is in the index, so there is
            // no staged side of it to show.
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
        if side == .staged { arguments.append("--cached") }
        arguments.append("--find-renames")
        arguments.append("--")
        arguments.append(path)
        if let previousPath, previousPath != path { arguments.append(previousPath) }

        let result = GitCommand.run(arguments, in: root)
        guard result.succeeded else { return .failed(failure(from: result)) }

        return outcome(for: result.stdout, path: path)
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

        // `--no-index` reports through the exit status the way `diff(1)`
        // does: 0 identical, 1 differ, anything else an actual error.
        // Treating 1 as failure rejects every untracked file there is.
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

    private static func outcome(for output: String, path: String) -> GitDiffOutcome {
        // `git diff --cached` on a conflicted path prints this one line and
        // no diff at all.
        if output.hasPrefix("* Unmerged path") { return .conflicted }

        let bytes = output.utf8.count
        guard bytes <= maximumOutputBytes else { return .tooLarge(bytes: bytes) }

        let files = GitDiffParser.parse(unified: output)
        guard let file = match(path, in: files) else { return .unchanged }
        if file.isCombined { return .conflicted }

        return .diff(GitDiffDocument(file: file))
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

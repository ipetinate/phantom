import Foundation

/// One checkout of a repository, as `git worktree list --porcelain` reports it.
///
/// A repository has one main checkout — the folder holding `.git` — plus any
/// number of *linked* ones, each a full working tree of its own sharing the
/// single object store. Everything the panel needs about a checkout comes
/// from this one command, which is why the model mirrors git's own fields
/// rather than a friendlier arrangement of them.
struct GitWorktree: Equatable, Identifiable {
    /// Absolute, as git prints it.
    let path: String

    /// The commit the checkout is on. Absent only for a bare repository,
    /// which has no working tree to be on a commit.
    let head: String?

    /// Short name, with `refs/heads/` stripped. `nil` means detached — and
    /// the two are the same fact told twice, because a caller asking "which
    /// branch" and one asking "is this detached" both read naturally.
    let branch: String?

    /// Whether this is the repository's main checkout.
    ///
    /// Not a field git prints: git prints the main checkout *first*, always,
    /// and that position is the only signal there is. Everything downstream
    /// leans on it — the main checkout can't be removed, isn't an orphan,
    /// and is never the merged branch offered for deletion.
    let isMain: Bool

    let isBare: Bool
    let isDetached: Bool

    /// Locked worktrees are ones git has been told not to prune, typically
    /// because they live on removable media.
    let isLocked: Bool

    /// The reason passed to `git worktree lock --reason`, when there was one.
    let lockReason: String?

    /// Whether `git worktree prune` would drop this entry — the folder is
    /// gone, or its administrative files no longer point anywhere.
    let isPrunable: Bool

    /// Git's own words for why. Worth keeping verbatim: they name which of
    /// several ways the checkout went missing.
    let prunableReason: String?

    var id: String { path }
}

extension GitWorktree {
    /// Parses `git worktree list --porcelain`.
    ///
    /// The format is one block per checkout, blocks separated by a blank
    /// line, each line a keyword and an optional value: `worktree <path>`,
    /// `HEAD <sha>`, `branch refs/heads/<name>`, and the bare markers
    /// `detached`, `bare`, `locked[ <reason>]`, `prunable[ <reason>]`.
    ///
    /// Values are split with an explicit `maxSplits: 1`, so a path with
    /// spaces and a lock reason that is a whole sentence both survive as
    /// the untouched remainder — the same discipline `GitStatus.parse` uses
    /// on the status porcelain.
    ///
    /// Order is preserved because it carries meaning: git prints the main
    /// checkout first, and that is where ``GitWorktree/isMain`` comes from.
    ///
    /// One case it cannot survive: a path containing a newline, which splits
    /// one block into two and yields a checkout at a truncated path. Git
    /// itself has no escaping in this format to offer a way out — the
    /// `-z` variant exists but replaces line endings, not the ambiguity —
    /// so this accepts the same limit the rest of the Git panel does.
    nonisolated static func parse(porcelain output: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var block = Block()

        func flush() {
            defer { block = Block() }
            guard !block.path.isEmpty else { return }
            worktrees.append(block.build(isMain: worktrees.isEmpty))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
                continue
            }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count > 1 ? String(parts[1]) : nil

            switch parts[0] {
            case "worktree":
                block.path = value ?? ""
            case "HEAD":
                block.head = value
            case "branch":
                block.branch = value.map(shortBranchName)
            case "detached":
                block.isDetached = true
            case "bare":
                block.isBare = true
            case "locked":
                block.isLocked = true
                block.lockReason = reason(value)
            case "prunable":
                block.isPrunable = true
                block.prunableReason = reason(value)
            default:
                continue
            }
        }

        flush()
        return worktrees
    }

    /// One block's fields as they accumulate, before the block ends and its
    /// position in the output decides ``GitWorktree/isMain``.
    private struct Block {
        var path = ""
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        func build(isMain: Bool) -> GitWorktree {
            GitWorktree(
                path: path,
                head: head,
                branch: branch,
                isMain: isMain,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                lockReason: lockReason,
                isPrunable: isPrunable,
                prunableReason: prunableReason
            )
        }
    }

    /// `locked` and `prunable` carry an optional reason. Git omits the
    /// value entirely when there is none, but an empty one would mean the
    /// same thing and must not reach the UI as a blank explanation.
    private static func reason(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func shortBranchName(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }
}

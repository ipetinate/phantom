import Foundation

/// The git and `gh` calls the review header is built from, and the parsing of
/// their output.
///
/// Split from the loading so the parsing can be tested: every function here
/// that reads text is `static` and takes the text. The commands themselves are
/// one line each and are the part a test would have to fake anyway.
enum GitReviewProbe {
    // MARK: Conflicts

    /// Whether merging `branch` into `target` would conflict.
    ///
    /// `git merge-tree --write-tree` computes the merge in memory: it touches
    /// neither the index nor the working tree, which is the whole point. A
    /// check that had to stage something to answer would be the thing it is
    /// warning about.
    ///
    /// Its exit status carries the answer — 0 for a clean merge, 1 for
    /// conflicts — and conflicted paths are printed after a blank line. Older
    /// git does not support `--write-tree` at all, and that is `unknown`
    /// rather than `clean`: silence is not a promise.
    nonisolated static func conflicts(
        branch: String,
        target: String,
        in root: String
    ) -> GitReviewConflictCheck {
        let result = GitCommand.run(
            ["merge-tree", "--write-tree", "--name-only", target, branch],
            in: root
        )

        guard let status = result.status else { return .unknown }
        if status == 0 { return .clean }
        guard status == 1 else { return .unknown }

        let paths = conflictedPaths(in: result.stdout)
        return paths.isEmpty ? .conflicting(["(unnamed)"]) : .conflicting(paths)
    }

    /// The paths out of `merge-tree`'s output.
    ///
    /// The first line is the tree object it wrote; the conflicted paths follow
    /// after a blank line. Anything that looks like an object id is dropped
    /// rather than trusted to be a path, because that first line is a path's
    /// shape as far as a string is concerned.
    static func conflictedPaths(in output: String) -> [String] {
        var paths: [String] = []
        var pastHeader = false

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                pastHeader = true
                continue
            }
            guard pastHeader else { continue }
            guard !isObjectID(trimmed) else { continue }
            paths.append(trimmed)
        }

        return paths
    }

    /// Whether a line is a git object id rather than a path.
    static func isObjectID(_ text: String) -> Bool {
        text.count >= 40 && text.allSatisfy(\.isHexDigit)
    }

    // MARK: Authors

    /// Who wrote the commits in a range, by how many they wrote.
    ///
    /// `%an` and not `%ae`: the header shows names, and one person with two
    /// email addresses would otherwise appear twice in a list whose whole job
    /// is to say who worked on this.
    nonisolated static func authors(
        range: String,
        in root: String
    ) -> [GitReviewAuthor] {
        guard let output = GitCommand.output(["log", "--format=%an", range], in: root)
        else { return [] }
        return tally(authorLines: output)
    }

    /// Counting, ordered by count and then by name.
    ///
    /// The name tiebreak is what keeps the header from reordering itself
    /// between two refreshes when two people have written the same number.
    static func tally(authorLines output: String) -> [GitReviewAuthor] {
        var counts: [String: Int] = [:]
        for line in output.components(separatedBy: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }

        return counts
            .map { GitReviewAuthor(name: $0.key, commits: $0.value) }
            .sorted {
                $0.commits == $1.commits ? $0.name < $1.name : $0.commits > $1.commits
            }
    }

    // MARK: Branches to compare against

    /// Every branch a reader could pick, local and remote, without duplicates.
    ///
    /// `origin/main` and a local `main` are the same name to a reader choosing
    /// a target, so the local one wins and the remote is dropped — comparing
    /// against a local branch is what they meant, and a list with both reads
    /// as two options where there is one decision.
    static func branchNames(in output: String) -> [String] {
        var seen: Set<String> = []
        var locals: [String] = []
        var remotes: [String] = []

        for line in output.components(separatedBy: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("HEAD ->"), !name.hasSuffix("/HEAD")
            else { continue }

            if name.hasPrefix("origin/") || name.contains("/") && !name.hasPrefix("refs/") {
                remotes.append(name)
            } else {
                locals.append(name)
                seen.insert(name)
            }
        }

        /// A remote branch with no local counterpart is still worth offering —
        /// comparing against something you have not checked out is the normal
        /// case for a target.
        let extras = remotes.filter { remote in
            guard let bare = remote.split(separator: "/").last else { return true }
            return !seen.contains(String(bare))
        }

        return locals.sorted() + extras.sorted()
    }

    /// The default branch, asked of the remote rather than guessed.
    ///
    /// `main` and `master` are both wrong often enough to matter, and a repo
    /// can name it anything. Falls back to the pair only when git has nothing
    /// to say — a repository with no remote, most often.
    static func defaultBranch(in output: String, fallbacks: [String] = ["main", "master"]) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("origin/HEAD ->") || trimmed.hasPrefix("HEAD branch:")
            else { continue }
            guard let last = trimmed.split(separator: " ").last else { continue }
            let name = String(last)
            return name.contains("/") ? String(name.split(separator: "/").last ?? "") : name
        }
        return fallbacks.first
    }
}

import Foundation

/// Everything the review screen puts in its header, as one value.
///
/// A snapshot rather than a set of live properties: it is assembled from four
/// git calls and one `gh` call, and a header whose parts arrive separately
/// reads as a screen still loading long after it has settled.
struct GitReviewContext: Equatable {
    /// The branch being reviewed.
    let branch: String

    /// What it is compared against, and where that came from.
    let target: GitReviewTargetChoice

    /// The pull request, when there is one open for this branch.
    let pullRequest: GitReviewPullRequest?

    /// Whether merging into the target would conflict, and where.
    let conflicts: GitReviewConflictCheck

    /// Everyone who authored a commit in the range, most commits first.
    ///
    /// Ordered by count rather than alphabetically, because the question this
    /// answers is "whose work is this" and the answer is usually the first
    /// name.
    let authors: [GitReviewAuthor]

    let commitCount: Int
    let addedLines: Int
    let removedLines: Int
    let fileCount: Int
}

/// The base of the comparison, and why it is that one.
///
/// A named case rather than a string plus a flag, because the *reason* is
/// shown: a reader looking at a review needs to know whether they are seeing
/// what the pull request will merge or what somebody picked from a list.
enum GitReviewTargetChoice: Equatable {
    /// The base branch an open pull request names. Preferred over everything,
    /// because it is literally what will be merged.
    case pullRequestBase(String)

    /// The repository's default branch, found rather than assumed.
    case repositoryDefault(String)

    /// A branch the reader chose.
    case chosen(String)

    var ref: String {
        switch self {
        case .pullRequestBase(let ref), .repositoryDefault(let ref), .chosen(let ref):
            return ref
        }
    }

    /// What the header says about where this came from.
    var provenance: String {
        switch self {
        case .pullRequestBase: return "pull request base"
        case .repositoryDefault: return "default branch"
        case .chosen: return "chosen"
        }
    }
}

/// A pull request, as much of it as `gh` will say.
///
/// Fields are optional one by one rather than the whole thing being optional,
/// because `gh` answers with what the host has: a repository with no
/// assignees, a pull request with an empty body, a fork whose author `gh`
/// cannot resolve. A header that hid itself over a missing assignee would hide
/// the number and the title with it.
struct GitReviewPullRequest: Equatable {
    let number: Int
    let title: String
    let url: String
    let baseRef: String
    let author: String?
    let assignees: [String]
    let isDraft: Bool

    /// The description, cut to something a card can hold.
    let bodyPreview: String?

    /// How the body is shortened.
    ///
    /// The first paragraph rather than the first N characters: a body that
    /// opens with a heading or a checklist would otherwise be previewed as
    /// half a line of markdown syntax. Whitespace-only paragraphs are skipped,
    /// which is what makes a body that starts with `## Summary` show the
    /// sentence under it instead of the heading.
    static func preview(of body: String?, limit: Int = 220) -> String? {
        guard let body else { return nil }

        let paragraphs = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = paragraphs.first(where: { paragraph in
            !paragraph.isEmpty
                && !paragraph.hasPrefix("#")
                && !paragraph.hasPrefix("<!--")
        }) else { return nil }

        let flattened = first
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// Who wrote the commits, and how many each.
struct GitReviewAuthor: Equatable, Identifiable {
    let name: String
    let commits: Int

    var id: String { name }
}

/// Whether this branch can be merged into its target as it stands.
///
/// Asked with `git merge-tree`, which computes the merge in memory and
/// touches neither the index nor the working tree. That matters more than the
/// speed: the whole point of asking is to find out *before* doing anything,
/// and a check that stages something to answer would be the thing it is
/// warning about.
enum GitReviewConflictCheck: Equatable {
    /// Not asked yet, or asked and git could not answer — an unrelated
    /// history, a missing target, a git too old for the plumbing this uses.
    /// Not a claim of safety, which is why it is not `.clean`.
    case unknown

    /// Merges cleanly.
    case clean

    /// Would conflict, in these paths.
    case conflicting([String])

    var isConflicting: Bool {
        if case .conflicting = self { return true }
        return false
    }

    /// What the header says.
    var summary: String {
        switch self {
        case .unknown: return "Merge check unavailable"
        case .clean: return "No conflicts with the target"
        case .conflicting(let paths):
            return paths.count == 1
                ? "1 file would conflict"
                : "\(paths.count) files would conflict"
        }
    }
}

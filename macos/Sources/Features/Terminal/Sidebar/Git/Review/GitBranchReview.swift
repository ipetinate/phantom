import Foundation

/// How the branch's base was arrived at.
///
/// Carried because a guessed base and a configured one deserve different
/// amounts of trust. `origin/main`, picked off a list of usual names, is
/// worth questioning in a repository that merges into `develop`; the
/// branch's own upstream is not. A reader who can see which one happened
/// can tell "there is nothing on this branch" apart from "we compared it
/// against the wrong thing".
enum GitReviewBaseSource: Equatable {
    /// The branch's configured upstream, `@{u}`.
    case upstream

    /// Whatever `origin/HEAD` points at — the remote's default branch, as
    /// recorded when the repository was cloned.
    case remoteHead

    /// One of the usual names, found by trying them in order.
    case wellKnown

    /// Named by the caller instead of worked out here.
    case explicit

    /// How the base was arrived at, in three words or fewer.
    ///
    /// Shown because the base is a guess in every case but one, and a reader
    /// looking at a surprising list of commits needs to know whether the
    /// answer came from their own upstream or from this app picking a
    /// well-known name.
    var summary: String {
        switch self {
        case .upstream: "from upstream"
        case .remoteHead: "remote default"
        case .wellKnown: "guessed"
        case .explicit: "chosen"
        }
    }
}

/// The branch's base, and the commit the two of them last shared.
struct GitReviewBase: Equatable {
    /// The ref as git names it: `origin/main`, `main`.
    let ref: String

    /// The merge base — where this branch left ``ref``.
    ///
    /// Kept because it, not ``ref``, is what the file list was compared
    /// against: `git diff base...HEAD` is defined as a diff against this
    /// commit, and a reader chasing a surprising file wants the sha that
    /// actually produced it. When several merge bases exist, this is the
    /// one git reported first — the same one its own three-dot diff used.
    let mergeBase: String

    let source: GitReviewBaseSource
}

/// One commit the branch adds on top of its base.
struct GitReviewCommit: Equatable, Identifiable {
    /// The full 40-character object name. Abbreviating in the model would
    /// throw away the only form that can be handed back to git.
    let sha: String

    /// The first line of the message, as git's `%s` gives it.
    let subject: String

    /// The author's name, not the committer's: a rebased or cherry-picked
    /// commit keeps its author and acquires a new committer, and the person
    /// a reviewer means is the one who wrote it.
    let author: String

    /// Git's own phrasing — "3 days ago" — as of the moment this was read.
    /// It ages in place, so it belongs to the read rather than to the
    /// commit; reload to refresh it.
    let relativeDate: String

    var id: String { sha }

    /// The abbreviation git itself prints in `--oneline`.
    var shortSha: String { String(sha.prefix(7)) }
}

/// One file the branch changes, relative to the merge base.
struct GitReviewFile: Equatable, Identifiable {
    /// The path after the change, or the path it had when it was deleted.
    let path: String

    /// Where a rename or copy came from, so a row can show `old → new`.
    let previousPath: String?

    /// The same vocabulary the diff viewer uses, so one badge serves both.
    let status: GitFileDiff.Status

    /// Lines added, or nil for a file git counts no lines in.
    ///
    /// `--numstat` writes `-` for a binary file rather than a number, and
    /// substituting 0 would quietly claim a change of zero lines — which
    /// reads as "nothing changed" in a total. Absence says the honest
    /// thing, and ``isBinary`` names why.
    let addedLines: Int?

    /// Lines removed, or nil for a binary file. See ``addedLines``.
    let removedLines: Int?

    var id: String { path }

    /// Git had no line counts for this file.
    var isBinary: Bool { addedLines == nil }

    var name: String { (path as NSString).lastPathComponent }

    /// The containing directory, for the dimmed second half of a row.
    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }
}

/// What a branch adds to its base: the commits, and the files.
///
/// The answer to "what will the pull request contain", read before there is
/// a pull request to look at. Deliberately *not* the working tree — an
/// uncommitted edit is the Git panel's subject, and this one's subject is
/// the branch.
///
/// Every awkward state a repository can be in is a value here rather than
/// an error: no base found, a detached `HEAD`, a repository whose first
/// commit hasn't happened, a branch that has nothing its base doesn't. Each
/// of those is somebody's Tuesday, and none of them is a failure to report.
struct GitBranchReview: Equatable {
    /// The branch under review; nil when `HEAD` is detached.
    let branch: String?

    /// The commit `HEAD` names; nil in a repository with no commits at all.
    let head: String?

    /// What the branch is compared against; nil when none could be found.
    ///
    /// A repository with one branch and no remote has no base, and that is
    /// an ordinary thing to open rather than a mistake. Without one there
    /// is nothing to subtract, so ``commits`` and ``files`` are empty and
    /// the reader is owed the sentence "there is nothing to compare this
    /// against" instead of an empty list that looks like a clean branch.
    let base: GitReviewBase?

    /// Newest first, the way git prints them and the way a list is read.
    let commits: [GitReviewCommit]

    /// Every file the branch changes, in git's own path order.
    let files: [GitReviewFile]

    /// More commits exist than were read.
    ///
    /// A branch pointed at a base years behind it has thousands, and a list
    /// that silently stops at a round number tells the reader a lie about
    /// their own branch.
    let hasMoreCommits: Bool

    init(
        branch: String?,
        head: String?,
        base: GitReviewBase?,
        commits: [GitReviewCommit] = [],
        files: [GitReviewFile] = [],
        hasMoreCommits: Bool = false
    ) {
        self.branch = branch
        self.head = head
        self.base = base
        self.commits = commits
        self.files = files
        self.hasMoreCommits = hasMoreCommits
    }

    /// `HEAD` points at a commit rather than a branch.
    ///
    /// A branch name is absent for exactly one reason: git could not
    /// resolve `HEAD` to one. A repository whose first commit hasn't
    /// happened yet still has a branch — an unborn one — so this stays
    /// false there, which is what ``isUnborn`` is for.
    var isDetached: Bool { branch == nil }

    /// The repository has no commits at all.
    var isUnborn: Bool { head == nil }

    /// The branch has nothing its base doesn't.
    ///
    /// True as well when there is no base, where it means "nothing to
    /// show" rather than "nothing to review" — ``base`` separates the two.
    var isEmpty: Bool { commits.isEmpty && files.isEmpty }

    /// Lines added across every file git counted lines for.
    var addedLines: Int { files.compactMap(\.addedLines).reduce(0, +) }

    /// Lines removed across every file git counted lines for.
    var removedLines: Int { files.compactMap(\.removedLines).reduce(0, +) }

    /// Files whose change is real but uncounted, so a total that says
    /// "+0 −0" can still say how many files it left out.
    var binaryFileCount: Int { files.filter(\.isBinary).count }
}

extension GitFileDiff.Status {
    /// Git's own letter for a status, so a row reads the same way wherever it
    /// is drawn — the branch review's list, the review panel's file cards, and
    /// the working-tree sections in the panel above them.
    ///
    /// On the model rather than private to a view, because it was private to
    /// one and the second view that needed it could not see it. Two copies of
    /// a mapping this small is how `R` comes to mean two things.
    var badge: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        }
    }
}

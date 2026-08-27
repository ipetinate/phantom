import Foundation

/// What a review screen is showing.
///
/// Two shapes with one screen, because they answer the same question at two
/// sizes: what does this change, and where. A commit is a range of one, and
/// the only thing that differs is how the range is spelled to git and which
/// commit a file's row credits.
enum GitReviewScope: Equatable, Identifiable {
    /// Everything the branch takes to its target.
    case branch(root: String)

    /// One commit out of it.
    case commit(root: String, sha: String, subject: String)

    var root: String {
        switch self {
        case .branch(let root), .commit(let root, _, _): return root
        }
    }

    /// What makes two review tabs the same tab: the repository and the work,
    /// and nothing about how either is drawn.
    ///
    /// The subject is left out on purpose. It is a *reading* of the commit —
    /// git prints it fresh on every load, an amend or a reword replaces it,
    /// and the panel's header and the tab's own label are the only things
    /// that want it. Were it part of the identity, the same commit would open
    /// a second tab the moment its subject was re-read differently, which is
    /// the one thing this rule exists to prevent: opening a commit that is
    /// already open brings its tab forward instead of making another.
    ///
    /// The sha is the full 40 characters, not the abbreviation. Two
    /// abbreviations that collide are two different commits sharing a tab,
    /// and git itself lengthens the prefix in exactly that case.
    var id: String {
        switch self {
        case .branch(let root): return "branch:\(root)"
        case .commit(let root, let sha, _): return "commit:\(root):\(sha)"
        }
    }

    /// What the panel is called at the top of itself.
    var title: String {
        switch self {
        case .branch: return "Branch Review"
        case .commit(_, let sha, let subject):
            return subject.isEmpty ? String(sha.prefix(7)) : subject
        }
    }

    /// What the tab is called in the strip, which is a narrower question than
    /// ``title``.
    ///
    /// The sha comes first because it is the part that always differs. A
    /// strip has room for a few characters before it truncates, and a branch
    /// whose commits read "Fix the tests", "Fix the tests again" gives a
    /// reader nothing in those characters — while `a1b2c3d` tells two tabs
    /// apart at a glance and is what they would type at git anyway.
    var tabTitle: String {
        switch self {
        case .branch: return "Branch Review"
        case .commit(_, let sha, let subject):
            let short = String(sha.prefix(7))
            return subject.isEmpty ? short : "\(short) \(subject)"
        }
    }

    /// The whole of it, for a tooltip: a strip truncates, and a subject is
    /// usually the part that goes.
    var tabHelp: String {
        switch self {
        case .branch: return "The branch review"
        case .commit(_, let sha, let subject):
            let short = String(sha.prefix(7))
            return subject.isEmpty ? "Review \(short)" : "Review \(short) \u{2014} \(subject)"
        }
    }

    var isCommit: Bool {
        if case .commit = self { return true }
        return false
    }
}

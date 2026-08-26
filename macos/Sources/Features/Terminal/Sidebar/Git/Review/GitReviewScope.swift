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

    var isCommit: Bool {
        if case .commit = self { return true }
        return false
    }
}

import Foundation

/// What a row in the git panel offers to do with its file.
///
/// A value rather than a menu building itself, because which items a row gets
/// is a set of rules about git's own vocabulary — a deletion has no file to
/// reveal, a conflict has no single change to discard, an ignore rule does
/// nothing to a path git already tracks — and rules are worth being able to
/// state and check without a menu on screen.
///
/// It exists because the menu had exactly one item, Copy Path, plus an ignore
/// entry that only untracked files ever saw. Everything a row could already
/// do was reachable only by hovering it or clicking it, which is to say
/// discoverable only by accident: right-clicking a modified file looked like
/// a feature that had been forgotten.
enum GitRowAction: Hashable, CaseIterable {
    /// What the change *is* — the reason the row is in this list at all.
    case openDiff

    /// The file as it stands, wherever the reader has said files should open.
    case openFile

    case stage
    case unstage

    /// Throws away the working-tree change, keeping the file.
    case discardChanges

    /// The same gesture on a file git never knew about, which does not
    /// restore anything — it removes the file. Named apart from
    /// `discardChanges` so the menu can say so before the confirmation does.
    case deleteUntrackedFile

    case addToGitignore
    case revealInFinder

    /// Absolute, which is what a path is called everywhere else in this app.
    case copyPath

    /// Git's own, relative to the repository root — the form that goes in a
    /// commit message, a code review or a `git` command.
    case copyRelativePath

    var title: String {
        switch self {
        case .openDiff: "Open Diff"
        case .openFile: "Open File"
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .discardChanges: "Discard Changes…"
        case .deleteUntrackedFile: "Delete File…"
        case .addToGitignore: "Add to .gitignore"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .copyRelativePath: "Copy Relative Path"
        }
    }

    /// The two that cannot be taken back, which is why both titles end in an
    /// ellipsis: each one asks first.
    var isDestructive: Bool {
        self == .discardChanges || self == .deleteUntrackedFile
    }

    /// The items a row offers, already split into the groups a separator goes
    /// between: look at it, change it, ignore it, find it.
    ///
    /// Grouped here rather than in the view so the separators are part of the
    /// same rule as the items — a group that empties out takes its separator
    /// with it, instead of leaving the menu with a rule floating against
    /// nothing.
    ///
    /// - Parameters:
    ///   - canDiscard: Whether the host wired discarding. It does not for a
    ///     conflicted file, where "discard the change" has no single meaning:
    ///     there are two sides and picking one is a different gesture.
    ///   - canIgnore: Whether the host wired writing to `.gitignore`.
    static func groups(
        for change: GitFileChange,
        staged: Bool,
        canDiscard: Bool,
        canIgnore: Bool
    ) -> [[GitRowAction]] {
        var open: [GitRowAction] = [.openDiff]

        /// A deleted path keeps its row and its diff — that is where you go to
        /// see what left — but there is nothing on disk behind the items that
        /// need a file.
        if change.isPresentOnDisk { open.append(.openFile) }

        var modify: [GitRowAction] = [staged ? .unstage : .stage]
        if canDiscard {
            modify.append(change.isUntracked ? .deleteUntrackedFile : .discardChanges)
        }

        /// Only for a file git is not already tracking. Adding a tracked path
        /// to `.gitignore` does nothing — ignore rules apply to untracked
        /// paths, so git carries on reporting it — and an item that quietly
        /// achieves nothing is worse than an absent one.
        let ignore: [GitRowAction] = canIgnore && change.isUntracked ? [.addToGitignore] : []

        var locate: [GitRowAction] = []
        if change.isPresentOnDisk { locate.append(.revealInFinder) }
        locate.append(.copyPath)
        locate.append(.copyRelativePath)

        return [open, modify, ignore, locate].filter { !$0.isEmpty }
    }
}

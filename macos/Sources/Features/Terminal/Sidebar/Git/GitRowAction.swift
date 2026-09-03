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

    /// The glyph beside the title, in the vocabulary
    /// `FileExplorerRowCommand.icon` set — the file explorer, the terminal
    /// rows and this list are three menus in one sidebar, and a command that
    /// appears in more than one looks the same in each.
    ///
    /// Three of them are the row's own hover buttons: `plus`, `minus` and
    /// `arrow.uturn.backward` are what a reader has already been clicking on
    /// the row to stage, unstage and discard. The diff is `text.append` for
    /// the reason `EditorPresentationControl` gives — lines of text with a
    /// change marked against them.
    ///
    /// Both copies take one glyph. They are the same action on two spellings
    /// of one path, and two glyphs would be a difference in the icon that
    /// says nothing the titles do not.
    ///
    /// Asserted to resolve in `GitRowActionTests`: an SF Symbol this build
    /// cannot draw is a menu item with a hole where its icon should be.
    var icon: String {
        switch self {
        case .openDiff: "text.append"
        case .openFile: "doc.text"
        case .stage: "plus"
        case .unstage: "minus"
        case .discardChanges: "arrow.uturn.backward"
        case .deleteUntrackedFile: "trash"
        case .addToGitignore: "nosign"
        case .revealInFinder: "folder"
        case .copyPath, .copyRelativePath: "doc.on.doc"
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

        /// Offered whether or not git already tracks the path, which is what
        /// VS Code does: its git extension exposes `git.ignore` for both the
        /// `workingTree` and `untracked` resource groups.
        ///
        /// A rule against a tracked path has no visible effect — ignore rules
        /// apply to untracked ones, so git carries on reporting the file, and
        /// nothing here quietly untracks it to force the issue. It was gated
        /// on that reasoning and the gate was the wrong call: writing the rule
        /// down is still what the reader asked for, it takes effect the day the
        /// path stops being tracked, and an item that vanishes on some rows
        /// reads as a broken menu long before anyone suspects a deliberate
        /// rule.
        ///
        /// Not on a staged row, and not on a conflicted one, matching the same
        /// two `when` clauses: neither the `index` nor the `merge` group gets
        /// this item, and a host signals the second by wiring no callback.
        let ignore: [GitRowAction] = canIgnore && !staged ? [.addToGitignore] : []

        var locate: [GitRowAction] = []
        if change.isPresentOnDisk { locate.append(.revealInFinder) }
        locate.append(.copyPath)
        locate.append(.copyRelativePath)

        return [open, modify, ignore, locate].filter { !$0.isEmpty }
    }
}

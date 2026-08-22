import Foundation

/// What ↑, ↓, ←, → and Space mean in the file tree.
///
/// The decision, with no view in it. Every one of these keys is a question
/// about the rows *on screen* — which row follows this one, which folder holds
/// it, what its first child is — and those answers are the part worth being
/// sure about. Given the same rows, the same expansion set and the same
/// selection this answers the same thing whether a key press or a test is
/// asking.
///
/// It decides and nothing else: no row is selected here, no folder opened and
/// no file read. The view spends the answer on the model, which is what keeps
/// a key press one call away from an assertion.
struct FileTreeNavigation {
    /// The rows as they are drawn, in order — the tree while it is a tree, the
    /// search matches while a search is on.
    ///
    /// Expansion is read off *this* list as much as off `expanded`: a folder's
    /// children are rows because the folder is open, so "the row below" and
    /// "its first child" are the same question asked twice. Which is also why
    /// a collapsed folder needs no special case anywhere below — its children
    /// aren't here to step onto.
    let rows: [FileRow]

    /// Which folders are open, so → can tell "open this one" from "go into
    /// it" and ← can tell "close it" from "leave it".
    let expanded: Set<String>

    /// The path the tree is acting on, or nil before anything has been
    /// clicked.
    ///
    /// It may name a row that is not on screen at all — see
    /// `FileExplorerModel.selection`, which deliberately survives a folder
    /// being collapsed and a search replacing the tree. A press then starts at
    /// the top instead of answering nothing, because a keyboard that does
    /// nothing reads as a keyboard that isn't wired up.
    let selection: String?

    /// A key the tree walks by.
    ///
    /// Not `PhantomShortcutAction` cases: those are commands a reader can
    /// rebind, and ↑ is not one of them. A tree whose arrows could be given
    /// away to something else is a tree that can be left with no way to walk
    /// it at all.
    enum Key: Equatable {
        case up
        case down
        case left
        case right

        /// Space: do the obvious thing to the selection — open a file, open
        /// or close a folder.
        case activate
    }

    /// What the press amounts to.
    ///
    /// `expand` and `collapse` both land on `FileExplorerModel.toggle(_:)` and
    /// are still two cases: the decision already knows which way the folder is
    /// going, and a test that reads `.expand` is a test about → rather than a
    /// test about a toggle.
    enum Command: Equatable {
        case nothing
        case select(String)
        case expand(FileNode)
        case collapse(FileNode)
        case open(FileNode)
    }

    func command(for key: Key) -> Command {
        let rows = self.rows.filter(Self.isNavigable)
        guard !rows.isEmpty else { return .nothing }

        guard let index = rows.firstIndex(where: { $0.node.path == selection }) else {
            /// Nothing selected, or a selection pointing somewhere this list
            /// doesn't go. An arrow starts at the top; Space has nothing to
            /// act on and says so.
            switch key {
            case .up, .down, .left, .right: return .select(rows[0].node.path)
            case .activate: return .nothing
            }
        }

        let row = rows[index]
        let isOpen = row.node.isDirectory && expanded.contains(row.node.path)

        switch key {
        case .up:
            /// Clamped rather than wrapped, both ways. A list that jumps from
            /// its first row to its last is a list that has lost the reader:
            /// the useful answer at an end is that there is nothing past it.
            guard index > 0 else { return .nothing }
            return .select(rows[index - 1].node.path)

        case .down:
            guard index + 1 < rows.count else { return .nothing }
            return .select(rows[index + 1].node.path)

        case .right:
            guard row.node.isDirectory else { return .nothing }
            guard isOpen else { return .expand(row.node) }
            return Self.firstChild(after: index, in: rows)
                .map { .select($0.node.path) } ?? .nothing

        case .left:
            if isOpen { return .collapse(row.node) }
            return Self.parent(of: index, in: rows)
                .map { .select($0.node.path) } ?? .nothing

        case .activate:
            guard row.node.isDirectory else { return .open(row.node) }
            return isOpen ? .collapse(row.node) : .expand(row.node)
        }
    }

    /// The row one level in from the row at `index`, if the list holds one.
    ///
    /// Nil covers two folders that look different and answer the same: one
    /// that is open and empty, and one that is open but whose listing hasn't
    /// landed yet — both have a sibling or nothing after them, and → into a
    /// folder should never step *past* it.
    private static func firstChild(after index: Int, in rows: [FileRow]) -> FileRow? {
        guard index + 1 < rows.count else { return nil }
        let next = rows[index + 1]
        return next.depth == rows[index].depth + 1 ? next : nil
    }

    /// The folder holding the row at `index`: the nearest row above it sitting
    /// one level out.
    ///
    /// By depth rather than by trimming the path, because depth is the
    /// structure the reader is looking at. A top-level row answers nil — the
    /// root has no row of its own to land on — and so does every row of a
    /// search, which is a flat list whose parents are exactly the folders it
    /// isn't showing.
    private static func parent(of index: Int, in rows: [FileRow]) -> FileRow? {
        let depth = rows[index].depth
        return rows[..<index].last { $0.depth == depth - 1 }
    }

    /// Whether a selection can land on the row.
    ///
    /// The two synthetic rows are not places: "12 more…" carries the *folder's*
    /// own path, so selecting it would quietly move the selection back up a
    /// level, and the create placeholder is a name being typed rather than a
    /// file that exists.
    private static func isNavigable(_ row: FileRow) -> Bool {
        !row.isTruncationNotice && !row.isCreatePlaceholder
    }
}

extension FileTreeNavigation.Key {
    /// The key a press reports, or nil for a key the tree doesn't walk by.
    ///
    /// An arrow reports a character in the private use area rather than
    /// anything printable, and `PhantomShortcut` already spells all four —
    /// comparing against those constants keeps one spelling of them in the
    /// app instead of two that can drift apart.
    init?(character: Character) {
        switch String(character) {
        case PhantomShortcut.upArrow: self = .up
        case PhantomShortcut.downArrow: self = .down
        case PhantomShortcut.leftArrow: self = .left
        case PhantomShortcut.rightArrow: self = .right
        case " ": self = .activate
        default: return nil
        }
    }
}

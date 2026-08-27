import Foundation

/// One cell of the editor grid: a tab bar's worth of open files, and whether
/// the terminal lives in this cell.
///
/// The files are an `EditorTabSet`, unchanged and unwrapped. Every rule
/// worth getting right is already in it and already tested — closing a tab
/// picks the neighbour to the left, reopening a file selects instead of
/// duplicating, a set with nothing left falls back to the terminal. A group
/// is that set plus the one fact a set of tabs cannot know on its own:
/// whether the terminal is here.
struct EditorGroup: Identifiable, Equatable {
    let id: UUID
    var tabs: EditorTabSet

    /// Whether the terminal's tab belongs to this cell.
    ///
    /// The terminal is a movable tab rather than a fixed cell — dragging it
    /// beside a file is the gesture this feature was asked for — so which
    /// cell holds it is state, and exactly one cell holds it at any moment.
    /// `EditorGroupTree` is what keeps that true; nothing at this level can
    /// see the other cells to check.
    ///
    /// A cell that does not host it must never *show* it either: with the
    /// terminal in another cell, a `selection` of `.terminal` would draw an
    /// empty pane. The tree resolves that by removing a cell that runs out
    /// of files, rather than letting it fall back to a terminal it does not
    /// have.
    var hostsTerminal: Bool

    init(
        id: UUID = UUID(),
        tabs: EditorTabSet = EditorTabSet(),
        hostsTerminal: Bool = false
    ) {
        self.id = id
        self.tabs = tabs
        self.hostsTerminal = hostsTerminal
    }

    /// Whether this cell has nothing left to draw.
    ///
    /// A cell with no files that does not host the terminal is a hole in the
    /// grid — there is no surface to show and no tab to click. The tree
    /// removes these and gives the space to the sibling, which is what makes
    /// closing the last file in a split feel like closing the split.
    ///
    /// A cell holding only review tabs is **not** vacant. The reviews are its
    /// content, and pruning it would take the commits the reader is comparing
    /// with it — the feature failing at the moment it is being used.
    var isVacant: Bool { tabs.isEmpty && tabs.reviews.isEmpty && !hostsTerminal }

    /// Whether this cell has the given file open.
    func holds(_ path: String) -> Bool {
        tabs.tabs.contains { $0.path == path }
    }
}

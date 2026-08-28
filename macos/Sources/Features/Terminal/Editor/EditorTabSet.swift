import Foundation

/// One file open in the editor.
struct EditorTab: Identifiable, Equatable {
    /// The file's path, which is also its identity: opening a file that is
    /// already open selects the existing tab instead of making a second one.
    let path: String

    /// Unsaved edits.
    var isDirty: Bool = false

    /// Whether this tab is held at the head of the bar.
    ///
    /// A property of the *tab*, not of the bar it happens to be in, and that
    /// settles the grid's question on its own: a pinned tab dragged into
    /// another cell arrives pinned, because what the reader pinned is the
    /// file. A bar that owned the pin would have to hand it over on every
    /// move, and `EditorGroupTree.move` is the one place that would have to
    /// remember to.
    ///
    /// It does not change what closing means. A pinned tab keeps its close
    /// button and closes on the ordinary gesture, in the bar and in "Close
    /// All" alike. Two things argued for that over the protection some
    /// editors give a pinned tab: the close button here shares its slot with
    /// the dirty dot — see `EditorTabItem.closeControl` — so taking it away
    /// leaves a pinned dirty tab with no way to close and makes the tab
    /// change width the moment it is pinned; and the guard that matters
    /// already exists, because `EditorCenter.requestClose` asks about unsaved
    /// edits whether the tab is pinned or not. Pin says where a tab sits, and
    /// nothing else.
    var isPinned: Bool = false

    var id: String { path }

    var name: String { (path as NSString).lastPathComponent }

    /// The containing directory, shown only to tell apart two tabs that
    /// share a name — `index.ts` twice is the ordinary case, not the edge.
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// What the pane is showing.
///
/// The terminal is one of the choices rather than the absence of a choice.
/// It used to be the latter — the pane showed the editor whenever any file
/// was open — and that made the ordinary thing impossible: glance at the
/// terminal and come back. There was no way to express "a file is open and
/// I am looking at the shell".
enum EditorSelection: Equatable {
    case terminal
    case file(String)

    /// One review, named by its ``GitReviewScope/id``.
    ///
    /// It used to carry nothing, because the window showed one review and
    /// `EditorCenter` held which one. That is what made a commit reuse the
    /// screen the last commit was on: with one review per window there was
    /// nowhere to put a second, and no way to say which of two a cell means.
    /// The id is what a tab per commit needs — and it is the id rather than
    /// the scope so that the reviews this cell holds stay the one place a
    /// scope is written down, with the selection pointing at one of them.
    case review(String)

    var path: String? {
        guard case .file(let path) = self else { return nil }
        return path
    }

    /// The review this points at, if it points at one.
    var reviewID: String? {
        guard case .review(let id) = self else { return nil }
        return id
    }
}

/// The open files, in tab order, and what the pane is showing.
///
/// A value type with no view or file access in it, because every rule worth
/// getting right lives here: what happens to the selection when you close
/// the tab you were looking at, whether reopening a file duplicates it, and
/// what the pane falls back to when the last file closes.
/// The pinned run always comes first, so the bar reads terminal, pinned
/// tabs, then the rest — the order asked for, held by the array itself
/// rather than by whoever draws it.
struct EditorTabSet: Equatable {
    private(set) var tabs: [EditorTab] = []

    /// The reviews open in this cell, in the order they were opened.
    ///
    /// A second list beside the files rather than a row among them: every
    /// rule in `tabs` is about a path — the dirty dot, the rename, the
    /// directory shown when two names collide — and a review has none. What
    /// the two lists share is the cell, and that is the point. A review that
    /// belongs to a cell is a review two cells can disagree about, which is
    /// what lets one half of a split hold `a1b2c3d` while the other holds
    /// `9f8e7d6`.
    private(set) var reviews: [GitReviewScope] = []

    /// Starts on the terminal, which is what an empty pane means.
    private(set) var selection: EditorSelection = .terminal

    var isEmpty: Bool { tabs.isEmpty }

    /// Whether the pane is showing the terminal rather than a file.
    var showsTerminal: Bool { selection == .terminal }

    var showsReview: Bool { selection.reviewID != nil }

    /// The review this cell is showing, if it is showing one.
    ///
    /// Resolved through the selection rather than stored beside it, so a tab
    /// that is gone cannot be the one on screen.
    var selectedReview: GitReviewScope? {
        selection.reviewID.flatMap { id in reviews.first { $0.id == id } }
    }

    func holdsReview(_ id: String) -> Bool { reviews.contains { $0.id == id } }

    /// The bar appears only once there is something to switch *to*.
    ///
    /// With the terminal alone there is one surface and no choice to make,
    /// so the bar would be a control that does nothing — and it would cost
    /// the terminal a row of its own height to say so.
    var showsTabBar: Bool { !tabs.isEmpty }

    var selectedPath: String? { selection.path }

    var selected: EditorTab? {
        selectedPath.flatMap { id in tabs.first { $0.id == id } }
    }

    var hasUnsavedChanges: Bool { tabs.contains(where: \.isDirty) }

    /// Where the pinned run ends and the rest begins.
    ///
    /// One array with a boundary in it rather than two arrays: the bar draws
    /// a single `ForEach`, `selectFile(at:)` numbers the tabs in the order
    /// they appear, and both of those stay true for free. Every mutation
    /// below keeps the invariant the count depends on — no unpinned tab ever
    /// sits before a pinned one — so the boundary can be read off the array
    /// instead of stored beside it and kept in step.
    var pinnedCount: Int { tabs.firstIndex(where: { !$0.isPinned }) ?? tabs.count }

    func tab(for path: String) -> EditorTab? { tabs.first { $0.path == path } }

    /// Opens a file, or selects it if it is already open.
    ///
    /// Reopening must not duplicate: the file explorer's whole interaction
    /// is clicking names, and clicking one twice is something people do
    /// without thinking.
    ///
    /// A new tab lands at the very end, which is behind the pinned run and
    /// leaves it alone — opening a file is not a request to disturb the tabs
    /// the reader chose to keep at hand.
    mutating func open(_ path: String) {
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(EditorTab(path: path))
        }
        selection = .file(path)
    }

    /// Closes a tab and picks what to show next.
    ///
    /// The neighbour to the *left*, or the new last tab when the first one
    /// closes — which is what every editor does, and what keeps closing
    /// several in a row from jumping around the bar. With nothing left, the
    /// terminal: it is the pane's home, not a fallback.
    mutating func close(_ path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        tabs.remove(at: index)

        guard selectedPath == path else { return }
        guard !tabs.isEmpty else {
            /// A review open in this cell is nearer than the terminal, which
            /// with a grid may live in another cell entirely — and it is a
            /// tab in this very strip, so falling back to it keeps the cell
            /// showing something the reader can see they are on.
            selection = reviews.last.map { .review($0.id) } ?? .terminal
            return
        }
        selection = .file(tabs[max(0, index - 1)].id)
    }

    mutating func closeAll() {
        tabs.removeAll()
        selection = .terminal
    }

    mutating func select(_ path: String) {
        guard tabs.contains(where: { $0.path == path }) else { return }
        selection = .file(path)
    }

    /// Opens a review, or brings it forward when this cell already has it.
    ///
    /// The rule files follow, keyed on ``GitReviewScope/id``: a commit that
    /// is already a tab here does not become a second one. The scope is
    /// written over the one that was there, because the two are the same tab
    /// by definition and the arriving one carries the subject as git last
    /// printed it — a reworded commit relabels its tab rather than opening a
    /// twin.
    ///
    /// Like `selectTerminal`, opening closes nothing: the file that was in
    /// front stays open and comes back when this review is closed.
    mutating func openReview(_ scope: GitReviewScope) {
        if let index = reviews.firstIndex(where: { $0.id == scope.id }) {
            reviews[index] = scope
        } else {
            reviews.append(scope)
        }
        selection = .review(scope.id)
    }

    /// Brings one of this cell's reviews forward, ignoring an id it does not
    /// hold — the same guard `select(_:)` gives a path from another cell.
    mutating func selectReview(_ id: String) {
        guard holdsReview(id) else { return }
        selection = .review(id)
    }

    /// Closes one review tab and picks what to show next.
    ///
    /// The neighbour to the left among the reviews, which is what closing a
    /// file tab does and what keeps closing several commits in a row from
    /// jumping around the bar. With no review left it falls back the way it
    /// always did, to a file or to the terminal.
    mutating func closeReview(_ id: String) {
        guard let index = reviews.firstIndex(where: { $0.id == id }) else { return }
        reviews.remove(at: index)

        guard selection.reviewID == id else { return }
        guard reviews.isEmpty else {
            selection = .review(reviews[max(0, index - 1)].id)
            return
        }
        selectAfterReview()
    }

    /// What to show once the review's tab is gone.
    ///
    /// The last file if there is one, the terminal otherwise. Not "nothing":
    /// a cell showing nothing is a cell the reader has to click to recover,
    /// and the review was laid over something.
    mutating func selectAfterReview() {
        guard showsReview else { return }
        if let last = tabs.last {
            selection = .file(last.path)
        } else {
            selection = .terminal
        }
    }

    mutating func selectTerminal() {
        selection = .terminal
    }

    /// Alternates between the terminal and the file you were last on.
    ///
    /// The whole point of the feature: peek at the shell and come back
    /// without losing your place. With no file open there is nothing to
    /// alternate with, so it stays put rather than doing something arbitrary.
    mutating func toggleTerminal(lastFile: String?) {
        if showsTerminal {
            guard let target = lastFile ?? tabs.last?.id else { return }
            select(target)
        } else {
            selection = .terminal
        }
    }

    /// Selects the nth file tab, one-based, ignoring a number with no tab.
    mutating func selectFile(at number: Int) {
        guard number >= 1, number <= tabs.count else { return }
        selection = .file(tabs[number - 1].id)
    }

    /// Pins a tab, or lets a pinned one go.
    ///
    /// Both directions are the same two steps — lift the tab out, put it back
    /// at the boundary — because after the lift the boundary is exactly the
    /// place both want. Pinning inserts at the end of the pinned run, so the
    /// run grows in the order the reader pinned things and no pin displaces
    /// an earlier one. Unpinning inserts at the head of the unpinned run,
    /// which is the nearest slot on the other side: the tab keeps the place
    /// it was looked at in rather than being thrown to the far end of a bar
    /// the reader may have to scroll to find it in.
    mutating func setPinned(_ isPinned: Bool, for path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        guard tabs[index].isPinned != isPinned else { return }

        var tab = tabs.remove(at: index)
        tab.isPinned = isPinned
        tabs.insert(tab, at: pinnedCount)
    }

    /// Whether a tab has a neighbour to trade places with on that side,
    /// inside its own run.
    ///
    /// The boundary between the runs is not a place a move may cross: an
    /// unpinned tab that slid into the pinned run would be pinned by its
    /// position and not by its own flag, which is the one way this array can
    /// come to disagree with itself. A move that would cross it is refused
    /// here rather than clamped, so the menu can leave the item out instead
    /// of offering a command that does nothing.
    func canMove(_ path: String, by offset: Int) -> Bool {
        guard offset != 0 else { return false }
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return false }

        let destination = index + offset
        guard tabs.indices.contains(destination) else { return false }
        return tabs[destination].isPinned == tabs[index].isPinned
    }

    /// Moves a tab along the bar, within its own run.
    ///
    /// - Returns: whether anything moved, so a caller can tell a refused move
    ///   from a completed one.
    @discardableResult
    mutating func move(_ path: String, by offset: Int) -> Bool {
        guard canMove(path, by: offset) else { return false }
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return false }

        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: index + offset)
        return true
    }

    /// Takes in a tab that arrives whole from another cell.
    ///
    /// Not `open(tab.path)`, which is what the grid used to do and what cost
    /// a dragged tab its dirty dot: opening builds a *fresh* tab, and a fresh
    /// tab has neither the dot nor the pin the reader gave the one they
    /// dragged. What crosses a cell boundary is the tab, so what is inserted
    /// here is the tab — into the run its own pin puts it in.
    mutating func adopt(_ tab: EditorTab) {
        guard !tabs.contains(where: { $0.path == tab.path }) else {
            select(tab.path)
            return
        }
        tabs.insert(tab, at: tab.isPinned ? pinnedCount : tabs.count)
        selection = .file(tab.path)
    }

    mutating func setDirty(_ isDirty: Bool, for path: String) {
        guard let index = tabs.firstIndex(where: { $0.path == path }) else { return }
        tabs[index].isDirty = isDirty
    }

    /// A file deleted or renamed outside the app stops being a tab.
    mutating func remove(missing paths: [String]) {
        paths.forEach { close($0) }
    }

    /// A file renamed or moved inside the app: the tab follows it, staying
    /// in place and keeping its dirty dot and its pin, rather than closing
    /// and reappearing at the end of the bar.
    mutating func repath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        guard let index = tabs.firstIndex(where: { $0.path == oldPath }) else { return }
        tabs[index] = EditorTab(
            path: newPath,
            isDirty: tabs[index].isDirty,
            isPinned: tabs[index].isPinned)
        if selection == .file(oldPath) { selection = .file(newPath) }
    }

    /// Whether two open tabs share a name, which is when the directory has
    /// to be shown to tell them apart.
    func needsDirectory(for tab: EditorTab) -> Bool {
        tabs.contains { $0.id != tab.id && $0.name == tab.name }
    }
}

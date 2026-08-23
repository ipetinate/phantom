import AppKit
import Combine
import SwiftUI

/// The open files for one window.
///
/// Per window, not app-wide: the editor takes over *that* terminal's pane,
/// so what is open belongs to it. Two windows on the same project keep
/// their own tabs, which is what makes "close everything and get my
/// terminal back" mean something local.
@MainActor
final class EditorCenter: ObservableObject {
    /// How the pane is divided, and what is open in each cell.
    ///
    /// The one source of truth for the editor's layout. `tabs` below is a
    /// view onto the cell in focus rather than state of its own, so the two
    /// can never disagree — the shape this replaces held a single tab set and
    /// could not express a second cell at all.
    @Published private(set) var tree: EditorGroupTree

    /// The cell a file opens in, and the one `tabs` describes.
    ///
    /// Kept pointing at a cell that exists: the tree removes a cell that runs
    /// out of files, and focus then falls to the sibling that took its space.
    @Published private(set) var activeGroupID: EditorGroup.ID

    /// The two facts the pane's AppKit host needs, as one value.
    ///
    /// Published in its own right rather than derived by the host from
    /// `tree`, because `@Published` sends in `willSet`: a host reading
    /// `tree` — or anything computed from it, `tabs` included — from inside
    /// that callback sees the *previous* value. One value, computed here
    /// after each change, is a seam with no ordering to get wrong.
    @Published private(set) var paneVisibility = PaneVisibility(
        showsTerminal: true, showsTabBar: false)

    struct PaneVisibility: Equatable {
        var showsTerminal: Bool
        var showsTabBar: Bool
    }

    /// The open files of the cell in focus.
    ///
    /// Computed rather than stored: every reader that predates the grid is
    /// asking about the cell being worked in, and answering from the tree
    /// leaves nothing to keep in step.
    var tabs: EditorTabSet {
        tree.group(activeGroupID)?.tabs ?? EditorTabSet()
    }

    /// Documents by path. Kept alongside the tab set rather than inside it
    /// because the tab set stays a value type — every rule about ordering
    /// and selection is testable without a file existing.
    @Published private(set) var documents: [String: EditorDocument] = [:]

    /// Open media files, by path.
    ///
    /// A second map rather than one map of something that could be either.
    /// Two homogeneous maps mean `saveAll` iterating `documents.values` can
    /// never reach a PDF, and the type system never offers `save()` on one —
    /// where an enum over both kinds would put an arm to fill in at every
    /// existing lookup, each one an invitation to write into a file that
    /// cannot take it.
    @Published private(set) var media: [String: MediaDocument] = [:]

    /// What the terminal's own tab is labelled with.
    ///
    /// Kept here rather than read from the window at render time because the
    /// bar is SwiftUI and the title is AppKit state that changes whenever the
    /// shell says so — this is the seam where the two meet.
    @Published var terminalTitle: String = "Terminal"

    /// How far down the terminal's content starts, so the pane's tab bar has
    /// space of its own instead of covering it.
    @Published var paneTabBarInset: CGFloat = 0

    /// The coat the pane paints behind its own content: the terminal's
    /// background colour at the opacity it is configured with, which
    /// `AppearanceCoordinator` resolves for the sidebar too. Pushed in by the
    /// controller on every appearance sync.
    ///
    /// Per window rather than on `ThemePalette`, because it follows the
    /// *focused surface* — two windows on different themes carry different
    /// coats — and the grid already observes this object.
    ///
    /// Nil while no surface has answered yet, which draws nothing: the window
    /// under it is translucent by design, and a guessed colour there is the
    /// opaque slab the pane used to show for a frame on open.
    @Published var paneBackground: NSColor?

    /// Raised when a file can't be opened, for the host to explain and
    /// offer the external editor instead.
    @Published var openFailure: OpenFailure?

    struct OpenFailure: Identifiable {
        let id = UUID()
        let url: URL
        let verdict: FileOpenGuard.Verdict
    }

    /// Whether the editor owns the pane right now.
    ///
    /// Derived from the *selection*, not from the tab count. Deriving it
    /// from the count is what made the terminal unreachable while a file was
    /// open — there was no way to say "a file is open and I am looking at
    /// the shell".
    var showsEditor: Bool { !tabs.showsTerminal }

    var selectedDocument: EditorDocument? {
        tabs.selectedPath.flatMap { documents[$0] }
    }

    /// Which kind of thing the selected tab is, as a value the view merely
    /// renders — so the routing can be asserted without a window.
    enum OpenPane {
        case text(EditorDocument)
        case media(MediaDocument)

        var text: EditorDocument? {
            if case .text(let document) = self { return document } else { return nil }
        }

        var media: MediaDocument? {
            if case .media(let document) = self { return document } else { return nil }
        }
    }

    var selected: OpenPane? {
        guard let path = tabs.selectedPath else { return nil }
        if let document = documents[path] { return .text(document) }
        if let document = media[path] { return .media(document) }
        return nil
    }

    /// The file to come back to when alternating away from the terminal.
    private var lastSelectedFile: String?

    private var documentObservers: [String: AnyCancellable] = [:]

    init() {
        let group = EditorGroup(hostsTerminal: true)
        tree = .leaf(group)
        activeGroupID = group.id
    }

    // MARK: Routing a change to a cell

    /// Changes the cell in focus, and leaves focus on a cell that exists.
    ///
    /// The sibling is read *before* the change: a cell that empties is
    /// removed by the tree, and afterwards there is no split left to ask.
    private func mutateActive(_ body: (inout EditorTabSet) -> Void) {
        let fallback = tree.neighbour(of: activeGroupID)
        tree.update(activeGroupID) { body(&$0.tabs) }
        if tree.group(activeGroupID) == nil {
            activeGroupID = fallback ?? tree.groupIDs[0]
        }
        refreshPaneVisibility()
    }

    /// Changes the cell that has this file open, wherever it is.
    ///
    /// The dirty dot, a rename and a close are each about one file, and that
    /// file is not necessarily in the cell being worked in. Routing them to
    /// the active cell instead would drop a dot on a tab in another cell, and
    /// leave a renamed tab pointing at a path that no longer exists.
    private func mutateHolder(of path: String, _ body: (inout EditorTabSet) -> Void) {
        guard let holder = tree.groupHolding(path) else { return }
        let fallback = tree.neighbour(of: holder)
        tree.update(holder) { body(&$0.tabs) }
        if tree.group(activeGroupID) == nil {
            activeGroupID = fallback ?? tree.groupIDs[0]
        }
        refreshPaneVisibility()
    }

    /// Puts a file in the cell in focus, or moves focus to the cell that
    /// already has it — the grid's form of "reopening never duplicates".
    private func place(_ path: String) {
        activeGroupID = tree.open(path, in: activeGroupID)
        refreshPaneVisibility()
    }

    /// The dirty dot, on whichever cell holds the file.
    private func setDirty(_ isDirty: Bool, for path: String) {
        mutateHolder(of: path) { $0.setDirty(isDirty, for: path) }
    }

    /// A renamed tab, on whichever cell holds it.
    private func repathTab(from oldPath: String, to newPath: String) {
        mutateHolder(of: oldPath) { $0.repath(from: oldPath, to: newPath) }
    }

    // MARK: Reading one cell

    /// The open files of a particular cell.
    ///
    /// The grid draws a bar and a surface per cell, so each of those asks
    /// about *its* cell rather than about the one in focus — which is what
    /// `tabs` answers, and what every reader that predates the grid wants.
    func tabs(in id: EditorGroup.ID) -> EditorTabSet {
        tree.group(id)?.tabs ?? EditorTabSet()
    }

    /// Whether a cell is the one the terminal lives in, and so the one whose
    /// bar offers the terminal's tab.
    func hostsTerminal(_ id: EditorGroup.ID) -> Bool {
        tree.group(id)?.hostsTerminal ?? false
    }

    /// Whether a cell draws a bar of tabs.
    ///
    /// Files in the cell are the first reason, and the only one that used to
    /// exist: a lone terminal offered no choice, so a bar over it would have
    /// been a control that does nothing while costing the terminal a row of
    /// its height.
    ///
    /// A grid adds the second. The terminal's tab is the handle for moving
    /// the terminal, so a terminal alone in its cell still needs it as soon
    /// as there is another cell to move it to. Alone in the whole grid it
    /// stays bare, which is both the old look and the honest one — there is
    /// nowhere to drag it, and a drop on its own cell is already a no-op.
    ///
    /// Answered here rather than in the bar because the *drop* needs it too:
    /// a tab dropped on a bar joins that cell, and a cell with no bar has no
    /// such strip to aim at. Two copies of this rule would eventually
    /// disagree, and the disagreement would read as a split appearing where
    /// the reader aimed to merge.
    func showsTabBar(in id: EditorGroup.ID) -> Bool {
        let cell = tabs(in: id)
        if !cell.isEmpty { return true }
        return hostsTerminal(id) && tree.groups.count > 1
    }

    /// What a particular cell is showing, if it is showing a file.
    func selected(in id: EditorGroup.ID) -> OpenPane? {
        guard let path = tabs(in: id).selectedPath else { return nil }
        if let document = documents[path] { return .text(document) }
        if let document = media[path] { return .media(document) }
        return nil
    }

    func selectedDocument(in id: EditorGroup.ID) -> EditorDocument? {
        selected(in: id)?.text
    }

    // MARK: The grid's gestures

    /// Moves focus to a cell, which is what working in one does.
    func focus(_ id: EditorGroup.ID) {
        guard tree.group(id) != nil, id != activeGroupID else { return }
        activeGroupID = id
        refreshPaneVisibility()
    }

    /// What a drag carries: an open file, or the terminal itself.
    ///
    /// The terminal is draggable for the same reason a file is — it is a tab
    /// in a bar — and it is a case rather than a path because there is only
    /// ever one of it.
    enum DragItem: Equatable {
        case file(String)
        case terminal
    }

    /// Drops a dragged tab on a cell.
    ///
    /// The centre of a cell means "move it here"; an edge means "split this
    /// cell and put it on that side". Both are the same two steps — split,
    /// then move — because splitting with an *empty* cell and moving into it
    /// lets the tree's own healing settle every awkward case: dragging a
    /// cell's only tab onto its own edge empties the cell it left, which
    /// collapses, so the layout ends where it began instead of leaving a
    /// half-made split behind.
    func drop(_ item: DragItem, on target: EditorGroup.ID, zone: EditorDropZone) {
        guard tree.group(target) != nil else { return }

        var destination = target
        if let split = zone.split {
            let cell = EditorGroup()
            guard tree.split(
                target,
                direction: split.direction,
                inserting: cell,
                onFirstSide: split.onFirstSide)
            else { return }
            destination = cell.id
        }

        switch item {
        case .file(let path):
            tree.move(path, to: destination)
        case .terminal:
            tree.moveTerminal(to: destination)
        }

        activeGroupID = tree.group(destination) != nil ? destination : tree.groupIDs[0]
        refreshPaneVisibility()
    }

    /// Divides the cell in focus, carrying what it is showing into the new
    /// half — the keyboard's form of a drag to that edge, routed through the
    /// same `drop` so the two cannot disagree.
    ///
    /// Whatever the cell is showing travels: a file if it is showing one, the
    /// terminal if it is showing that. A cell showing the terminal and holding
    /// nothing else has nothing to divide, and `drop` already answers that
    /// with the layout it started in.
    func divideFocusedCell(_ zone: EditorDropZone) {
        let cell = tabs
        if let path = cell.selectedPath {
            drop(.file(path), on: activeGroupID, zone: zone)
        } else if cell.showsTerminal {
            drop(.terminal, on: activeGroupID, zone: zone)
        }
    }

    /// Closes a cell, its files with it, and lets the sibling take the space.
    ///
    /// The files are closed through `close` rather than dropped with the
    /// cell, so a dirty one is still guarded and a language server still
    /// hears about it.
    func closeCell(_ id: EditorGroup.ID) {
        guard let cell = tree.group(id) else { return }
        for tab in cell.tabs.tabs { close(tab.path) }
        guard tree.group(id) != nil else { return }
        let fallback = tree.neighbour(of: id)
        tree.remove(id)
        if tree.group(activeGroupID) == nil {
            activeGroupID = fallback ?? tree.groupIDs[0]
        }
        refreshPaneVisibility()
    }

    /// Moves a divider, addressed by the split's own id so a drag survives
    /// the grid changing shape around it.
    func setRatio(_ ratio: CGFloat, forSplit id: UUID) {
        tree.setRatio(ratio, forSplit: id)
    }

    private func refreshPaneVisibility() {
        let cell = tabs
        let next = PaneVisibility(
            showsTerminal: cell.showsTerminal, showsTabBar: cell.showsTabBar)
        if paneVisibility != next { paneVisibility = next }
    }

    // MARK: Opening and closing

    /// Opens a file, optionally landing on a particular range.
    ///
    /// The range travels with the document rather than being applied here:
    /// a file opened for the first time has no text view yet, so the jump
    /// has to be something the view picks up when it appears.
    ///
    /// - Parameter showing: how to draw it on arrival. Nil means the
    ///   document decides, which is its source. Opening from the Git panel
    ///   passes `.diff`, because a file reached by clicking it in a list of
    ///   changes was chosen *for* its changes — landing on the source there
    ///   answers a question nobody asked and costs a second click.
    ///
    ///   Applied to a document that is already open too: clicking the same
    ///   file in the Git panel again is a request to see the changes, not a
    ///   request to focus a tab that happens to exist.
    @discardableResult
    func open(
        _ url: URL,
        reveal: LSPRange? = nil,
        showing: EditorPresentation? = nil,
        reviewBase: String? = nil
    ) -> Bool {
        let path = url.path

        /// Before anything is read, and before the already-open check below,
        /// which keys on the wrong map for a media file.
        ///
        /// `reveal`, `showing` and `reviewBase` are ignored rather than
        /// stored: there is no caret to move and nothing to diff. Clicking a
        /// PNG in the Git panel passes `.diff`, and it has to land on the
        /// viewer anyway.
        if let kind = EditorMediaKind.resolve(fileName: url.lastPathComponent) {
            return openMedia(url, path: path, kind: kind)
        }

        if let existing = documents[path] {
            if let reveal { existing.reveal = (id: UUID().uuidString, range: reveal) }
            if let showing { existing.presentation = showing }

            /// Written on every open, including with nil, so a file opened
            /// from the review and then reopened from the Changes list stops
            /// being compared against the base. Only setting it when non-nil
            /// would leave the second reading showing the first one's diff.
            existing.reviewBase = reviewBase
            place(path)
            lastSelectedFile = path
            return true
        }

        switch EditorDocument.load(url: url) {
        case .failure(let verdict):
            openFailure = OpenFailure(url: url, verdict: verdict)
            return false

        case .success(let document):
            /// Before it is stored, so the first body evaluation already
            /// draws the right thing. Setting it afterwards would show the
            /// source for one frame and then swap.
            ///
            /// This is the common path, not the exception: a file clicked in
            /// the Git panel is usually not open yet. Applying `showing`
            /// only to the already-open case above left the feature working
            /// exactly when it was not needed.
            if let showing { document.presentation = showing }
            document.reviewBase = reviewBase

            documents[path] = document
            document.startWatching()
            // The tab's dirty dot follows the document, and the document is
            // its own observable object — a change inside it doesn't reach
            // this one on its own.
            documentObservers[path] = document.objectWillChange
                .sink { [weak self, weak document] (_: Void) in
                    // `objectWillChange` fires *before* the value is
                    // written, so reading `isDirty` here would see the old
                    // one. The hop is what makes the dot correct.
                    DispatchQueue.main.async {
                        guard let self, let document else { return }
                        self.setDirty(document.isDirty, for: path)
                    }
                }
            if let reveal { document.reveal = (id: UUID().uuidString, range: reveal) }
            place(path)
            lastSelectedFile = path
            return true
        }
    }

    /// Opens a media file: a tab, a viewer, and none of the machinery a text
    /// document needs.
    ///
    /// No watcher, no dirty-dot observer and no `didOpen` — the absences are
    /// the point. A language server has nothing to say about a PNG, and
    /// `EditorTabSet` is keyed by path and knows nothing of documents, so the
    /// tab, its label and its icon come out right with no work at all.
    private func openMedia(_ url: URL, path: String, kind: EditorMediaKind) -> Bool {
        if media[path] != nil {
            place(path)
            lastSelectedFile = path
            return true
        }

        let verdict = FileOpenGuard.mediaVerdict(for: url)
        guard verdict.canOpen else {
            openFailure = OpenFailure(url: url, verdict: verdict)
            return false
        }

        media[path] = MediaDocument(url: url, kind: kind)
        place(path)
        lastSelectedFile = path
        return true
    }

    /// A tab the reader tried to close while it still had edits.
    ///
    /// Raised instead of acting, so the *view* asks and this stays testable
    /// without a window. Nothing was being asked before: closing a dirty tab
    /// threw the edits away without a word, which is the one thing an editor
    /// must never do quietly.
    @Published var closeConfirmation: CloseConfirmation?

    struct CloseConfirmation: Identifiable {
        let id = UUID()
        let path: String

        var name: String { (path as NSString).lastPathComponent }
    }

    /// Closes a tab, asking first when it has unsaved edits.
    func requestClose(_ path: String) {
        guard documents[path]?.isDirty == true else {
            close(path)
            return
        }
        closeConfirmation = CloseConfirmation(path: path)
    }

    func requestCloseSelected() {
        guard let path = tabs.selectedPath else { return }
        requestClose(path)
    }

    /// Saves and then closes, for the "Save" answer.
    func saveAndClose(_ path: String) {
        if documents[path]?.save() == true { close(path) }
    }

    func close(_ path: String) {
        documents[path]?.stopWatching()
        documents.removeValue(forKey: path)
        documentObservers.removeValue(forKey: path)
        media.removeValue(forKey: path)
        mutateHolder(of: path) { $0.close(path) }
    }

    /// Shows the terminal without closing anything, and moves focus to the
    /// cell it lives in — which is not necessarily the cell being worked in.
    func selectTerminal() {
        guard let host = tree.terminalHost else { return }
        tree.update(host) { $0.tabs.selectTerminal() }
        activeGroupID = host
        refreshPaneVisibility()
    }

    /// Alternates terminal ⇄ the file last looked at.
    ///
    /// Asked of the terminal's own cell rather than of the cell in focus: the
    /// question is whether the shell is on screen, and with a grid those are
    /// different cells.
    func toggleTerminal() {
        guard let host = tree.terminalHost else { return }
        guard tree.group(host)?.tabs.showsTerminal == true else {
            selectTerminal()
            return
        }
        let fallback = tree.groups.flatMap(\.tabs.tabs).last?.path
        guard let target = lastSelectedFile ?? fallback else { return }
        select(target)
    }

    func selectFile(at number: Int) {
        mutateActive { $0.selectFile(at: number) }
    }

    func closeAll() {
        documents.values.forEach { $0.stopWatching() }
        documents.removeAll()
        documentObservers.removeAll()
        media.removeAll()
        tree.closeAllFiles()
        activeGroupID = tree.terminalHost ?? tree.groupIDs[0]
        refreshPaneVisibility()
    }

    /// Selects an open file, in whichever cell has it — clicking a tab in
    /// another cell is also a request to work in that cell.
    func select(_ path: String) {
        guard let holder = tree.groupHolding(path) else { return }
        tree.update(holder) { $0.tabs.select(path) }
        activeGroupID = holder
        lastSelectedFile = path
        refreshPaneVisibility()
    }

    /// The open documents a change to `path` reaches: the file itself, and
    /// everything inside it when `path` is a folder.
    ///
    /// Matching the exact key alone is what made renaming a folder a silent
    /// no-op — the tabs for the files under it kept paths that no longer
    /// existed, watched a stale inode, and failed on save. A folder is not
    /// a document here, so it never matches by itself; the files under it
    /// are the ones that have to move.
    /// Over both maps. Reading only `documents` here is how a media tab would
    /// be left pointing at a path that no longer exists after its folder was
    /// renamed — the exact bug the folder-repath tests were written for,
    /// reopened for a new type.
    private func openPaths(under path: String) -> [String] {
        let prefix = path + "/"
        let paths = Array(documents.keys) + Array(media.keys)
        return paths.filter { $0 == path || $0.hasPrefix(prefix) }
    }

    /// A file or folder renamed or moved in the file explorer while open
    /// here.
    ///
    /// The buffer travels with it — renaming a file you are editing should
    /// not throw the edits away — and the tab keeps its place in the bar.
    func repath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }

        for path in openPaths(under: oldPath) {
            let moved = path == oldPath
                ? newPath
                : newPath + String(path.dropFirst(oldPath.count))
            if documents[path] != nil {
                repathDocument(from: path, to: moved)
            } else {
                repathMedia(from: path, to: moved)
            }
        }
    }

    /// Moves one open document, with all of its bookkeeping: the watcher
    /// follows the file, the dirty-dot observer is rebound to the new key,
    /// the tab keeps its position, and the language server is told that one
    /// URI closed and another opened.
    ///
    /// The server has to be told *here*. The comment this replaces claimed
    /// the pane's own appear/disappear calls covered it, and they do not:
    /// the pane announces the document it is showing, and a rename does not
    /// necessarily tear that view down — so the server was left holding a URI
    /// for a file that no longer exists, answering questions about it, and
    /// keeping its `announced`, `versions` and `diagnostics` entries for the
    /// rest of the session.
    ///
    /// Guarded on the document having been announced at all: introducing one
    /// nobody opened would start a language server for a file that is not on
    /// screen, and a rename is no reason to do that.
    private func repathDocument(from oldPath: String, to newPath: String) {
        guard let document = documents.removeValue(forKey: oldPath) else { return }

        let wasAnnounced = LSPCenter.shared.isOpen(path: oldPath)
        document.stopWatching()
        documentObservers.removeValue(forKey: oldPath)
        if wasAnnounced { LSPCenter.shared.didClose(path: oldPath) }

        let moved = document.transferred(to: URL(fileURLWithPath: newPath))
        documents[newPath] = moved
        moved.startWatching()
        documentObservers[newPath] = moved.objectWillChange
            .sink { [weak self, weak moved] (_: Void) in
                DispatchQueue.main.async {
                    guard let self, let moved else { return }
                    self.setDirty(moved.isDirty, for: newPath)
                }
            }
        if moved.isDirty { setDirty(true, for: newPath) }

        repathTab(from: oldPath, to: newPath)
        if lastSelectedFile == oldPath { lastSelectedFile = newPath }

        /// After the buffer has moved, so the text the server is handed is
        /// the one the new URI now has — including edits that were never
        /// saved.
        if wasAnnounced {
            LSPCenter.shared.didOpen(path: newPath, text: moved.currentText)
        }
    }

    /// Moves an open media tab, which is the whole of its bookkeeping: no
    /// watcher to re-arm, no observer to rebind, and nothing to tell a
    /// language server.
    ///
    /// The kind is resolved again from the new name, so renaming a `.png` to
    /// `.pdf` shows a PDF. A rename *out* of media keeps the old kind rather
    /// than converting the tab — the reader can close it and open it again,
    /// and turning a viewer into an editor under them would be a stranger
    /// answer than leaving it alone.
    private func repathMedia(from oldPath: String, to newPath: String) {
        guard let document = media.removeValue(forKey: oldPath) else { return }

        let name = (newPath as NSString).lastPathComponent
        media[newPath] = MediaDocument(
            url: URL(fileURLWithPath: newPath),
            kind: EditorMediaKind.resolve(fileName: name) ?? document.kind)

        repathTab(from: oldPath, to: newPath)
        if lastSelectedFile == oldPath { lastSelectedFile = newPath }
    }

    // MARK: Following a terminal between worktrees

    /// Every open tab, with the one fact the migration rule needs of it.
    ///
    /// In tab-bar order, so the popover's list of what stays behind reads
    /// top-to-bottom the way the bar does. Media is included and is never
    /// dirty — a PDF has no buffer to lose, so it simply follows.
    /// Every cell's tabs, because a dirty file in another cell is exactly
    /// the one a migration must not leave behind quietly.
    var openForMigration: [(path: String, isDirty: Bool)] {
        tree.groups
            .flatMap(\.tabs.tabs)
            .map { (path: $0.path, isDirty: $0.isDirty) }
    }

    /// Saves one open document, answering with something the caller can put
    /// on the row that asked for it.
    ///
    /// A returned sentence rather than a `Bool` because the two callers that
    /// want this are lists — the migration confirm and the removal flow —
    /// and a failure there belongs beside the file that failed. A read-only
    /// file and a full disk are both ordinary at exactly this moment, and an
    /// alert on top of the list would cover the thing it is about.
    ///
    /// A path with no open document answers nil: a media tab has nothing to
    /// save, and "nothing to do" is not a failure.
    func save(_ path: String) -> String? {
        guard let document = documents[path] else { return nil }
        guard !document.save() else { return nil }
        return document.loadError ?? "Couldn't save this file."
    }

    /// What would happen to the open tabs if this window's terminal moved
    /// from one worktree to another.
    ///
    /// Asked before anything happens, because its answer is what the reader
    /// is shown and asked to confirm. Deciding as we went would mean the
    /// list on screen was a prediction rather than the plan.
    func migrationPlan(
        from sourceRoot: String, to targetRoot: String
    ) -> [WorktreeDocumentMigration.Outcome] {
        WorktreeDocumentMigration.plan(
            documents: openForMigration, from: sourceRoot, to: targetRoot)
    }

    /// Carries out the `migrate` half of a plan. Everything else in it stays
    /// exactly where it is, which is the promise the popover made.
    ///
    /// Takes a plan rather than two roots so that applying is only applying.
    /// The chooser owns the plan and keeps it current — it recomputes while
    /// open, which is what makes its Save buttons mean "bring this one with
    /// me" — and this half stays a function of the decision that was
    /// actually on screen when Continue was pressed.
    func applyMigration(_ outcomes: [WorktreeDocumentMigration.Outcome]) {
        for (from, to) in WorktreeDocumentMigration.migrations(in: outcomes) {
            if documents[from] != nil {
                migrateDocument(from: from, to: to)
            } else {
                repathMedia(from: from, to: to)
            }
        }
    }

    /// Reopens a clean document at the same relative path under another
    /// worktree.
    ///
    /// Everything `repathDocument` does about bookkeeping, and the one thing
    /// it must not do here: carry the buffer. A rename means one file
    /// changed address, so the text travels with it. A worktree switch means
    /// there are *two* files, and the one being shown is the other one — its
    /// text has to come off the disk it lives on, or the tab would show one
    /// branch's contents under the other branch's path and save it there on
    /// the next ⌘S.
    ///
    /// Loaded before anything is torn down. `EditorDocument.load` is allowed
    /// to refuse — the destination exists, which is all the plan checked, but
    /// existing is not the same as readable — and a refusal after the old
    /// document was already removed would close a tab as the way of
    /// reporting it.
    @discardableResult
    private func migrateDocument(from oldPath: String, to newPath: String) -> Bool {
        guard documents[oldPath] != nil,
              case .success(let arrived) = EditorDocument.load(url: URL(fileURLWithPath: newPath))
        else { return false }

        guard let leaving = documents.removeValue(forKey: oldPath) else { return false }

        let wasAnnounced = LSPCenter.shared.isOpen(path: oldPath)
        leaving.stopWatching()
        documentObservers.removeValue(forKey: oldPath)
        if wasAnnounced { LSPCenter.shared.didClose(path: oldPath) }

        /// The one thing that does travel: how the file was being looked at.
        /// A reader who switched an SVG to its source is asking about this
        /// file, not about this checkout of it.
        arrived.presentation = leaving.presentation

        documents[newPath] = arrived
        arrived.startWatching()
        documentObservers[newPath] = arrived.objectWillChange
            .sink { [weak self, weak arrived] (_: Void) in
                DispatchQueue.main.async {
                    guard let self, let arrived else { return }
                    self.setDirty(arrived.isDirty, for: newPath)
                }
            }

        repathTab(from: oldPath, to: newPath)
        setDirty(false, for: newPath)
        if lastSelectedFile == oldPath { lastSelectedFile = newPath }

        if wasAnnounced {
            LSPCenter.shared.didOpen(path: newPath, text: arrived.currentText)
        }

        return true
    }

    /// A file or folder deleted in the file explorer stops being a tab, and
    /// the language server stops hearing about it.
    ///
    /// Deleting a folder closes everything that was open inside it: those
    /// tabs now point into the Trash, and leaving them open means the next
    /// save recreates a file in a directory the user just threw away.
    func didDelete(path: String) {
        for open in openPaths(under: path) {
            /// Only for the ones a server was ever told about. A media file
            /// was never announced, and announcing its closure would be the
            /// first the server ever heard of it.
            if documents[open] != nil { LSPCenter.shared.didClose(path: open) }
            close(open)
        }
    }

    // MARK: Saving

    @discardableResult
    func saveSelected() -> Bool {
        guard let document = selectedDocument else { return false }
        let saved = document.save()
        if saved {
            setDirty(false, for: document.id)
            LSPCenter.shared.didSave(path: document.url.path, text: document.currentText)
            Self.noteGitChange(at: document.url.path)
        }
        return saved
    }

    func saveAll() {
        for document in documents.values where document.isDirty {
            guard document.save() else { continue }
            setDirty(false, for: document.id)
            LSPCenter.shared.didSave(path: document.url.path, text: document.currentText)
            Self.noteGitChange(at: document.url.path)
        }
    }

    /// Tells the Git panel that a file on disk just changed.
    ///
    /// Saving is the one moment this app knows for certain that a
    /// repository's working tree moved, and nothing was passing it on. The
    /// panel polls every couple of seconds behind a three-second staleness
    /// gate, which is why the two directions felt different: removing a
    /// change updated the *diff* on screen straight away — that pane re-reads
    /// the document it is showing — while introducing one left the list of
    /// changes to be noticed by a poll, seconds later and with no visible
    /// cause.
    ///
    /// Forced, because the gate is exactly what has to be skipped: a save is
    /// news, not a guess, and it is the only kind of news this app can be
    /// sure of. One `git status` per save is cheap next to the write that
    /// just happened, and the centre already refuses to run two at once for
    /// the same repository.
    ///
    /// Here rather than in a view because every path that writes a file goes
    /// through these two methods — ⌘S, Save All, and formatting on save —
    /// and a hook on one of them would be a bug the day somebody used
    /// another.
    private static func noteGitChange(at path: String) {
        guard let root = EditorChangeLookup.repositoryRoot(forPath: path) else { return }
        GitCenter.shared.requestStatus(root: root, force: true)
    }
}

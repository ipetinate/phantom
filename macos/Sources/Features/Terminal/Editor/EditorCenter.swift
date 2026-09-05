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

    @Published private(set) var extensions: [String: ExtensionDocument] = [:]

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

    /// The review the cell in focus is showing, when it is showing one.
    ///
    /// Read off that cell rather than stored here. It used to be a property
    /// of the window — one review at a time, on the argument that two side by
    /// side is a comparison nobody asked for — and that is exactly what was
    /// asked for: a commit opened over the commit before it, so there was no
    /// way to put two of them beside each other.
    ///
    /// A review is a tab now, in the cell's own `EditorTabSet`. Which one is
    /// on screen is therefore a question about a cell, and two cells may
    /// answer it differently. That is the whole of the split comparison.
    var review: GitReviewScope? { tabs.selectedReview }

    /// Every review open in this window, in cell order.
    ///
    /// For the Git panel's commit list, which marks the commits that already
    /// have a tab. It reaches them through `GitReviewCenter` — see
    /// ``publishReviewTabs()``.
    var openReviews: [GitReviewScope] { tree.groups.flatMap(\.tabs.reviews) }

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
        case extensionDocument(ExtensionDocument)

        var text: EditorDocument? {
            if case .text(let document) = self { return document } else { return nil }
        }

        var media: MediaDocument? {
            if case .media(let document) = self { return document } else { return nil }
        }

        var extensionDocument: ExtensionDocument? {
            if case .extensionDocument(let document) = self { return document } else { return nil }
        }
    }

    var selected: OpenPane? {
        guard let path = tabs.selectedPath else { return nil }
        return pane(at: path)
    }

    private func pane(at path: String) -> OpenPane? {
        if let document = documents[path] { return .text(document) }
        if let document = media[path] { return .media(document) }
        if let document = extensions[path] { return .extensionDocument(document) }
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

        /// A tab arrives clean, and the observer that keeps the dot honest
        /// only fires on changes *after* this. A document restored with an
        /// unsaved buffer is dirty from its first frame and would otherwise
        /// sit there with no dot until the reader happened to type — telling
        /// them their unsaved work is saved, which is the one thing the dot
        /// exists to deny.
        if documents[path]?.isDirty == true { setDirty(true, for: path) }

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

        /// A review with no files beside it still needs its own tab drawn, or
        /// it is a panel with no way to close it: the button is in the strip.
        if cell.showsReview { return true }

        return hostsTerminal(id) && tree.groups.count > 1
    }

    /// What a particular cell is showing, if it is showing a file.
    func selected(in id: EditorGroup.ID) -> OpenPane? {
        guard let path = tabs(in: id).selectedPath else { return nil }
        return pane(at: path)
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
        publishReviewTabs()
    }

    /// Tells `GitReviewCenter` which reviews this window has open and which
    /// one it is looking at.
    ///
    /// From here because every gesture that could change either answer ends
    /// in `refreshPaneVisibility` — opening a review, closing one, switching
    /// tabs, and moving focus to another cell. A hook on `openReview` alone
    /// would be a highlight that follows the click rather than the tab: click
    /// a commit, then click the other cell, and the marked row would still be
    /// the first one.
    ///
    /// The centre is a singleton and this object is per window, so what is
    /// pushed is keyed by *this* window — see
    /// ``GitReviewCenter/noteReviewTabs(open:front:from:)``, which ignores a
    /// report that changes nothing.
    private func publishReviewTabs() {
        GitReviewCenter.shared.noteReviewTabs(
            open: openReviews.map(\.id),
            front: tabs.selection.reviewID,
            from: self)
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
    ///
    /// - Parameter markedBy: the agent that asked, when one did. It hangs that
    ///   agent's mark in the gutter beside the revealed line — see
    ///   ``EditorDocument/agentMark``. Nil for every gesture a person makes,
    ///   which is all of them but `reveal_line`.
    @discardableResult
    func open(
        _ url: URL,
        reveal: LSPRange? = nil,
        markedBy agent: CodingAgent? = nil,
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
            if let reveal { apply(reveal, markedBy: agent, to: existing) }
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

            /// Before anything renders, so a file with unsaved work appears
            /// the way it was left rather than appearing clean and changing
            /// under the reader a frame later.
            document.restoreUnsavedBuffer()

            documents[path] = document
            document.startWatching()
            /// Before the tab exists, so the first render already has the
            /// timeline this file left behind — and so the disk check that
            /// may throw it away happens once, here, with the text that was
            /// just read rather than one the view guessed at.
            ///
            /// After the buffer is restored, and that order is the point: the
            /// history was fingerprinted against the text the reader left,
            /// which for a dirty file is the buffer and not the file. Passing
            /// the disk text here would fail that check on exactly the files
            /// whose history matters most.
            EditorUndoCenter.shared.attach(path: path, text: document.currentText)
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
            if let reveal { apply(reveal, markedBy: agent, to: document) }
            place(path)
            lastSelectedFile = path
            return true
        }
    }

    /// Sends a document to a range, and hangs an agent's mark on it when an
    /// agent is what asked.
    ///
    /// One function for both halves of `open`, so a file that was already open
    /// and one that was not cannot come to disagree about whether a mark
    /// accompanies a reveal. The line is read out of the range rather than
    /// passed beside it: a mark and a caret on two different lines is the one
    /// thing this feature must not be able to express, and taking one number
    /// from one place is what makes it unable to.
    ///
    /// A nil `agent` leaves an existing mark alone rather than clearing it. A
    /// reader jumping to a definition has not made the agent's line wrong; only
    /// an edit does that, and the document clears it there.
    /// Both halves are the reader's to refuse — see ``EditorFeatureSettings``.
    ///
    /// The scroll is checked only for a reveal an *agent* asked for. The same
    /// path carries a jump to a definition and a click on a search result, and
    /// those the reader asked for in that moment; refusing them would be
    /// refusing their own click. `agent == nil` is what tells the two apart.
    private func apply(_ reveal: LSPRange, markedBy agent: CodingAgent?, to document: EditorDocument) {
        let features = EditorFeatureSettings.shared
        if agent == nil || features.agentReveal {
            document.reveal = (id: UUID().uuidString, range: reveal)
        }
        if let agent, features.agentGutterMark {
            document.mark(agent, atLine: reveal.start.line + 1)
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

    static func restoredExtensionTitle(_ extensionID: String) -> String {
        ExtensionStore.shared.installed.first { $0.id == extensionID }?.name ?? extensionID
    }

    func openExtension(_ document: ExtensionDocument) {
        extensions[document.path] = document
        activeGroupID = tree.open(document.tab, in: activeGroupID)
        lastSelectedFile = document.path
        refreshPaneVisibility()
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

    /// Closes a tab, asking first only when closing it would actually lose
    /// something.
    ///
    /// A dirty buffer is written down by ``EditorBackupStore`` and comes back
    /// when the file is opened again, so for almost every file closing is no
    /// longer a decision and the question is not worth asking — the same
    /// trade VS Code calls hot exit.
    ///
    /// The buffer is flushed here rather than left to ``close(_:)`` because
    /// the answer decides whether to ask: a file whose backup was written has
    /// nothing at stake, and one whose backup could not be written has
    /// everything at stake. Those are the files still worth interrupting
    /// somebody for — a buffer past ``EditorBackupStore/maximumBytes``, or a
    /// write that failed.
    ///
    /// This is the check that was missed when hot exit landed. `close(_:)`
    /// on a list of paths had been taught the rule, and this one — the path
    /// every tab's close button takes — had not, so the prompt went on
    /// appearing for every unsaved file.
    func requestClose(_ path: String) {
        guard let document = documents[path], document.isDirty else {
            close(path)
            return
        }

        document.flushBackup()
        guard !EditorBackupStore.hasBackup(path: path) else {
            close(path)
            return
        }

        closeConfirmation = CloseConfirmation(path: path)
    }

    func requestCloseSelected() {
        guard let path = tabs.selectedPath else { return }
        requestClose(path)
    }

    /// The cell the terminal lives in, which is what "the main pane" means.
    ///
    /// Named for the reader rather than for the tree: a grid has cells, and
    /// the one holding the shell is the one they started from.
    var mainPaneID: EditorGroup.ID? { tree.terminalHost }

    /// Whether this file is open in any cell.
    func isOpen(_ path: String) -> Bool { tree.groupHolding(path) != nil }

    /// Whether dividing the pane can produce anything at all, for a file that
    /// is not open yet: the cell it would land in has to have something in it
    /// already, or the new half heals straight back.
    var canSplitAnything: Bool {
        guard let cell = tree.group(activeGroupID) else { return false }
        return !cell.tabs.tabs.isEmpty || cell.hostsTerminal
    }

    /// Whether this file is already in the main pane, which is what decides
    /// whether offering to send it there would do anything.
    func isInMainPane(_ path: String) -> Bool {
        guard let main = mainPaneID else { return false }
        return tree.groupHolding(path) == main
    }

    /// Whether the cell holding `path` has anything left if that tab leaves.
    ///
    /// A lone tab cannot be split out of its own cell: the tree would divide
    /// the cell, move the tab across, find the half it left empty and heal it
    /// away again — a menu item that reads as an action and is a no-op. The
    /// terminal counts as something left behind, so a cell showing the shell
    /// and one file can still divide.
    func canSplitOut(_ item: DragItem) -> Bool {
        guard let holder = holder(of: item), let cell = tree.group(holder) else { return false }

        switch item {
        case .file:
            return cell.tabs.tabs.count > 1 || cell.hostsTerminal
        case .terminal:
            /// The terminal leaving takes the shell with it, so what has to
            /// stay behind is a file.
            return !cell.tabs.tabs.isEmpty
        }
    }

    /// What a tab's menu may offer, which is a question about where it is.
    func availability(of item: DragItem) -> EditorTabCommand.Availability {
        let holder = holder(of: item)
        let cell = holder.flatMap { tree.group($0) }

        /// The terminal answers `false` to all three of the pin questions and
        /// there is nothing to decide: it has no path, it is drawn first in
        /// its cell by `EditorTabBar` whatever the files do, and its own menu
        /// keeps only the splits anyway.
        var path: String?
        if case .file(let file) = item { path = file }
        let tab = path.flatMap { cell?.tabs.tab(for: $0) }
        let canMove: (Int) -> Bool = { offset in
            guard let path, let cell else { return false }
            return cell.tabs.canMove(path, by: offset)
        }

        return EditorTabCommand.Availability(
            hasSiblings: (cell?.tabs.tabs.count ?? 0) > 1,
            canSplitOut: canSplitOut(item),
            /// The terminal *is* the main pane, so it can never be sent there.
            canReturnToMainPane: {
                guard case .file = item, let main = mainPaneID else { return false }
                return holder != main
            }(),
            isPinned: tab?.isPinned ?? false,
            canMoveLeft: canMove(-1),
            canMoveRight: canMove(1)
        )
    }

    /// Pins a tab to the head of its bar, or lets a pinned one go.
    ///
    /// Routed to the cell that *holds* the file rather than to the cell in
    /// focus, for the reason every other per-file change is — see
    /// `mutateHolder`. Nothing here can empty a cell, so the tree's heal has
    /// nothing to do and the grid keeps its shape.
    func setPinned(_ isPinned: Bool, for path: String) {
        mutateHolder(of: path) { $0.setPinned(isPinned, for: path) }
    }

    /// Moves a tab one place along its bar, within its own run.
    ///
    /// The menu's "Move Left" and "Move Right", and the only way to reorder
    /// tabs — see `EditorTabCommand` for why this is not a drag.
    func moveTab(_ path: String, by offset: Int) {
        mutateHolder(of: path) { $0.move(path, by: offset) }
    }

    /// Divides the cell a tab is in and puts the tab in the new half — the
    /// menu's form of dragging it to that edge, routed through `drop` so the
    /// two cannot disagree about what an edge means.
    func splitOut(_ item: DragItem, zone: EditorDropZone) {
        guard let holder = holder(of: item) else { return }
        drop(item, on: holder, zone: zone)
    }

    /// Sends a tab back to the main pane, which is the gesture that undoes a
    /// split: the cell it leaves heals away when nothing is left in it.
    func moveToMainPane(_ item: DragItem) {
        guard let main = mainPaneID else { return }
        drop(item, on: main, zone: .center)
    }

    /// Opens a file and divides the cell it landed in, for a reader who asked
    /// for it beside what they are looking at rather than in front of it.
    func openInSplit(_ url: URL, zone: EditorDropZone) {
        guard open(url) else { return }
        splitOut(.file(url.path), zone: zone)
    }

    private func holder(of item: DragItem) -> EditorGroup.ID? {
        switch item {
        case .terminal: return tree.terminalHost
        case .file(let path): return tree.groupHolding(path)
        }
    }

    /// Closes every other tab in one cell.
    ///
    /// A tab with unsaved edits is left open rather than closed or asked
    /// about. `CloseConfirmation` holds one path, so a bulk close cannot ask
    /// about several — it would raise a question per file and each would
    /// overwrite the last, which is how a dialog ends up answering for a file
    /// the reader never saw. Leaving them needs no dialog and loses nothing:
    /// the tabs that stay are exactly the ones still wearing the dirty dot.
    ///
    /// - Returns: the paths kept back, so the caller can say so if it wants.
    @discardableResult
    func closeOthers(of path: String, in groupID: EditorGroup.ID) -> [String] {
        close(tabs(in: groupID).tabs.map(\.path).filter { $0 != path })
    }

    /// Closes every tab in one cell, on the same terms as `closeOthers`.
    @discardableResult
    func closeAll(in groupID: EditorGroup.ID) -> [String] {
        close(tabs(in: groupID).tabs.map(\.path))
    }

    /// Closes them, and answers with the ones that still need an answer.
    ///
    /// Which is now almost none of them. A dirty buffer is written down at
    /// ``close(_:)`` and put back when the file is opened again, so closing a
    /// file with unsaved work is not a decision any more and the prompt that
    /// used to make it one is gone — the same trade VS Code calls hot exit.
    ///
    /// What still comes back is the buffer that could not be written down:
    /// past ``EditorBackupStore/maximumBytes``, or a write that failed. Those
    /// keep the old behaviour, because for them "close" really does mean
    /// "lose it", and that is the one case worth interrupting somebody for.
    private func close(_ paths: [String]) -> [String] {
        var unsafe: [String] = []
        for path in paths {
            guard let document = documents[path], document.isDirty else {
                close(path)
                continue
            }

            document.flushBackup()
            if EditorBackupStore.hasBackup(path: path) {
                close(path)
            } else {
                unsafe.append(path)
            }
        }
        return unsafe
    }

    /// Saves and then closes, for the "Save" answer.
    func saveAndClose(_ path: String) {
        if documents[path]?.save() == true { close(path) }
    }

    func close(_ path: String) {
        documents[path]?.stopWatching()
        /// The buffer goes to disk before the document does. A file closed
        /// from anywhere -- a tab's x, a group closing, a window going away --
        /// reaches here, so this is the one place that has to be sure.
        documents[path]?.flushBackup()
        /// Before the document goes, because what is being recorded is the
        /// text it holds: from here until the file is opened again, the only
        /// thing that can change it is the world outside this app, and that
        /// fingerprint is what notices.
        if let document = documents[path] {
            EditorUndoCenter.shared.detach(path: path, text: document.currentText)
        }
        documents.removeValue(forKey: path)
        documentObservers.removeValue(forKey: path)
        media.removeValue(forKey: path)
        extensions.removeValue(forKey: path)
        mutateHolder(of: path) { $0.close(path) }
    }

    /// Opens a review as a tab, or brings the tab that already shows it
    /// forward — wherever in the grid that tab is.
    ///
    /// The identity of a review tab is ``GitReviewScope/id``: the repository
    /// and the work, with nothing about how either is drawn. Two commits
    /// therefore make two tabs, and one commit clicked twice makes one — the
    /// same promise `open(_:)` gives a file, and for the same reason. The
    /// commit list is a list of names and clicking one twice is something
    /// people do without thinking.
    ///
    /// Focus follows the tab, like `select(_:)` does for a file in another
    /// cell: clicking a commit that is open in the other half of a split is
    /// also a request to work in that half.
    ///
    /// Opening closes nothing. The file underneath stays open and comes back
    /// when the review's tab is closed or another tab is picked.
    func openReview(_ scope: GitReviewScope) {
        if let holder = tree.groups.first(where: { $0.tabs.holdsReview(scope.id) })?.id {
            tree.update(holder) { $0.tabs.openReview(scope) }
            activeGroupID = holder
            refreshPaneVisibility()
            return
        }
        mutateActive { $0.openReview(scope) }
    }

    /// Brings an open review forward, ignoring one no cell holds.
    func selectReview(_ id: String) {
        guard let holder = tree.groups.first(where: { $0.tabs.holdsReview(id) })?.id else {
            return
        }
        tree.update(holder) { $0.tabs.selectReview(id) }
        activeGroupID = holder
        refreshPaneVisibility()
    }

    /// Puts a review on screen, or takes the front one down.
    ///
    /// Kept in this shape because it is what the Git panel and the review
    /// screen itself call. `nil` still means "close", and a scope still means
    /// "show me this" — what changed underneath is that showing one no longer
    /// replaces the one before it.
    func showReview(_ scope: GitReviewScope?) {
        guard let scope else {
            closeReview()
            return
        }
        openReview(scope)
    }

    /// Takes down the review the cell in focus is showing.
    func closeReview() {
        guard let id = tabs.selection.reviewID else { return }
        closeReview(id)
    }

    /// Takes one review's tab down, wherever it is.
    ///
    /// Addressed by id rather than by cell so that closing a review from a
    /// tab strip closes *that* tab, and not whichever one the focused cell
    /// happens to be showing.
    func closeReview(_ id: String) {
        guard let holder = tree.groups.first(where: { $0.tabs.holdsReview(id) })?.id else {
            return
        }
        let fallback = tree.neighbour(of: holder)
        tree.update(holder) { $0.tabs.closeReview(id) }
        if tree.group(activeGroupID) == nil {
            activeGroupID = fallback ?? tree.groupIDs[0]
        }
        refreshPaneVisibility()
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
        for (path, document) in documents {
            EditorUndoCenter.shared.detach(path: path, text: document.currentText)
        }
        documents.removeAll()
        documentObservers.removeAll()
        media.removeAll()
        extensions.removeAll()
        tree.closeAllFiles()
        activeGroupID = tree.terminalHost ?? tree.groupIDs[0]
        refreshPaneVisibility()
    }

    /// Puts a saved arrangement back: the cells, the tabs in each, and the
    /// cell that was in front.
    ///
    /// The files are opened first and the layout is stated afterwards, in one
    /// assignment. `open` places a file in the cell *in focus*, so replaying
    /// it cell by cell would mean rebuilding the shape and moving files
    /// through it at the same time, and every intermediate shape would have
    /// to be a legal one. Documents are keyed by path and know nothing of
    /// cells, so loading them in any order and then declaring the layout
    /// gives the same result with no ordering to get wrong.
    ///
    /// A file that is gone, or that is there but cannot be read, costs its
    /// own tab and nothing else: it is left out by `rebuilt`, which is told
    /// what actually opened rather than what was asked for.
    ///
    /// Unsaved text is deliberately not restored here. The tab comes back
    /// over the file as it is on disk; the buffer the reader left is the undo
    /// timeline's to return, and two writers over the same bytes would be two
    /// sources of truth for them.
    func restore(_ state: EditorGridState) {
        var opened: Set<String> = []
        for path in state.paths {
            if let extensionID = ExtensionDocument.extensionID(fromPath: path) {
                openExtension(ExtensionDocument(extensionID: extensionID, title: Self.restoredExtensionTitle(extensionID)))
                opened.insert(path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if open(URL(fileURLWithPath: path)) { opened.insert(path) }
        }

        /// `open` raises this for a file it could name but not read, and the
        /// host turns it into a dialog offering the external editor. There is
        /// no gesture behind a restore to explain such a dialog, so a reader
        /// would be greeted at launch by a question about a file they last saw
        /// working. The tab is dropped instead, which is the same answer the
        /// missing ones get.
        openFailure = nil

        guard let rebuilt = state.rebuilt(isOpen: opened.contains) else { return }
        tree = rebuilt.tree
        activeGroupID = rebuilt.activeGroupID
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

        /// The history moves with the buffer. A rename is one file changing
        /// address, so leaving the timeline at the old path would drop it on
        /// the floor — and would leave a stale entry keyed to a path nothing
        /// will ask for again.
        EditorUndoCenter.shared.repath(from: oldPath, to: newPath)
        EditorBackupStore.repath(from: oldPath, to: newPath)

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

        /// Not `repath`: a worktree switch means there are two files, and the
        /// one arriving is the other one. Its history is its own — checked
        /// against the text just read off that checkout, which is what stops
        /// a timeline recorded on one branch being offered over another's.
        EditorUndoCenter.shared.detach(path: oldPath, text: leaving.currentText)
        EditorUndoCenter.shared.attach(path: newPath, text: arrived.currentText)

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

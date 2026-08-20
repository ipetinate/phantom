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
    @Published private(set) var tabs = EditorTabSet()

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
            tabs.select(path)
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
                        self.tabs.setDirty(document.isDirty, for: path)
                    }
                }
            if let reveal { document.reveal = (id: UUID().uuidString, range: reveal) }
            tabs.open(path)
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
            tabs.select(path)
            lastSelectedFile = path
            return true
        }

        let verdict = FileOpenGuard.mediaVerdict(for: url)
        guard verdict.canOpen else {
            openFailure = OpenFailure(url: url, verdict: verdict)
            return false
        }

        media[path] = MediaDocument(url: url, kind: kind)
        tabs.open(path)
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
        tabs.close(path)
    }

    /// Shows the terminal without closing anything.
    func selectTerminal() {
        tabs.selectTerminal()
    }

    /// Alternates terminal ⇄ the file last looked at.
    func toggleTerminal() {
        tabs.toggleTerminal(lastFile: lastSelectedFile)
    }

    func selectFile(at number: Int) {
        tabs.selectFile(at: number)
    }

    func closeAll() {
        documents.values.forEach { $0.stopWatching() }
        documents.removeAll()
        documentObservers.removeAll()
        media.removeAll()
        tabs.closeAll()
    }

    func select(_ path: String) {
        tabs.select(path)
        lastSelectedFile = path
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
                    self.tabs.setDirty(moved.isDirty, for: newPath)
                }
            }
        if moved.isDirty { tabs.setDirty(true, for: newPath) }

        tabs.repath(from: oldPath, to: newPath)
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

        tabs.repath(from: oldPath, to: newPath)
        if lastSelectedFile == oldPath { lastSelectedFile = newPath }
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
            tabs.setDirty(false, for: document.id)
            LSPCenter.shared.didSave(path: document.url.path, text: document.currentText)
            Self.noteGitChange(at: document.url.path)
        }
        return saved
    }

    func saveAll() {
        for document in documents.values where document.isDirty {
            guard document.save() else { continue }
            tabs.setDirty(false, for: document.id)
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

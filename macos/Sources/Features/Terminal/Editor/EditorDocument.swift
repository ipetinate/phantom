import AppKit
import Combine
import Foundation

/// One open file: its text, whether it has been changed, and what has
/// happened to it on disk.
///
/// The disk half matters more here than in an ordinary editor. The terminal
/// this pane belongs to is *right there*, and a branch switch or a `git
/// stash` rewrites the very file being looked at. Noticing that is the
/// difference between saving your work and saving over somebody else's.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let url: URL

    /// The text as this document last set it — loaded, saved, reverted, or
    /// replaced by a formatter. **Not what you are looking at while you
    /// type:** the buffer lives in the text view, and asking it for a copy
    /// on every keystroke is the O(file) cost this editor exists to avoid.
    @Published private(set) var text: String

    /// Bumped whenever `text` is replaced, so the view knows the change came
    /// from here and not from the reader.
    @Published private(set) var revision = 0

    /// What the buffer holds right now, reported by the view as it changes.
    ///
    /// Deliberately not `@Published`: it moves on every keystroke, and
    /// publishing it would re-render the pane once per character for no
    /// gain. What the UI needs from a keystroke is the dirty dot, which is
    /// one flag that changes once.
    private var liveText: String?

    /// The text to save, to hand to a language server, or to search.
    var currentText: String { liveText ?? text }

    @Published private(set) var isDirty = false

    /// The file changed underneath an edited buffer, so neither version can
    /// be thrown away without asking.
    @Published private(set) var hasConflict = false

    @Published private(set) var loadError: String?

    /// Where to put the cursor when this document next appears, set by a
    /// jump to a definition or a click on a search result. Carries an id so
    /// asking for the same place twice still moves the view.
    @Published var reveal: (id: String, range: LSPRange)?

    /// The line an agent pointed at through `reveal_line`, and which agent.
    ///
    /// ## Why it lives here
    ///
    /// The question ``EditorUndoCenter`` answers about itself, asked again and
    /// answered differently: what must the thing outlive? An undo stack has to
    /// survive closing a file and coming back to it, so it could not live on a
    /// document and went to a store of its own. A mark has to survive a scroll
    /// and a tab switch and nothing more — closing the tab is the reader
    /// putting the reading down — and the document is the smallest thing in the
    /// editor that survives exactly that much. The text view does not: the pane
    /// is tagged with the document's id, so changing tabs destroys and rebuilds
    /// it. And because `EditorCenter.documents` is per window, a mark is per
    /// window too, which is what `reveal_line` means: the agent moved *its own*
    /// window's editor, not whatever else is open on the same file.
    ///
    /// ## One per file, and the newest wins
    ///
    /// One, because the mark answers "where has the agent just sent me" — and a
    /// file collecting them answers a different, worse question, where the mark
    /// from ten minutes ago is indistinguishable from the one placed a second
    /// ago and there is no gesture that clears either. So a second reveal
    /// replaces the first, in the same file, whichever agent asked. Two agents
    /// pointing at two *different* files still leave two marks: there is a
    /// document each, and neither is stale.
    ///
    /// ## When it goes
    ///
    /// On any change to the text, at the two functions that are the only ways
    /// the text can change — ``edited(_:)`` and ``replaceText(_:named:undoable:)``.
    /// A mark on line 39 after three lines were inserted above it points at the
    /// wrong code, which is worse than no mark at all, and the wrong-line case
    /// is made impossible rather than unlikely by not trying to follow the line:
    /// the mark is dropped, whatever was edited and wherever. That covers the
    /// keystroke, the formatter, the rename, the revert, and the `git checkout`
    /// in the terminal next door that reloads a clean buffer.
    ///
    /// Saving does not clear it, and that is not an omission: ``save()`` writes
    /// the buffer out and moves no line in it.
    @Published private(set) var agentMark: EditorAgentMark?

    /// How this document is currently being shown — source, preview, diff,
    /// or a split of two of them.
    ///
    /// Here rather than in the view because the view does not survive being
    /// looked away from: `EditorPaneView` tags the document view with
    /// `.id(document.id)`, so switching tabs destroys and rebuilds it. A
    /// reader who put a README into preview, glanced at another file and
    /// came back would find themselves in source again, having asked for
    /// nothing of the sort.
    ///
    /// Not persisted across launches, deliberately: it is a reading posture
    /// for the current sitting, not a property of the file.
    ///
    /// Where it *starts* is a property of the file, though, and is decided
    /// here rather than by whoever draws the document: a view that applied
    /// the opening posture when it appeared would re-apply it every time the
    /// tab came back, undoing the toggle the paragraph above exists to
    /// remember. `EditorCenter.open(showing:)` still overrides it, because a
    /// file clicked in the Changes list was chosen for its changes.
    @Published var presentation: EditorPresentation

    /// The ref this file is being compared against, when it was opened from a
    /// branch review rather than from the working tree.
    ///
    /// Carried on the document because it is a property of *this reading* of
    /// the file: the same path opened from the Changes list is a working-tree
    /// diff, and opened from the review it is `base...HEAD`. Nil is the
    /// ordinary case and means "ask the working tree", which is what every
    /// other entry point wants.
    @Published var reviewBase: String?

    var id: String { url.path }

    var language: CodeLanguage {
        CodeLanguage.resolve(fileName: url.lastPathComponent)
    }

    /// What was last read from or written to disk. Compared against the
    /// file to tell "somebody else changed this" from "I changed this",
    /// which a modification date alone can't do — saving moves the date too.
    private var diskText: String

    private var watcher: DirectoryWatcher?

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.diskText = text
        self.presentation = .opening(fileName: url.lastPathComponent)
    }

    /// Reads the file, refusing anything the editor can't usefully show.
    static func load(url: URL) -> Result<EditorDocument, FileOpenGuard.Verdict> {
        let verdict = FileOpenGuard.verdict(for: url)
        guard verdict.canOpen else { return .failure(verdict) }

        guard let data = try? Data(contentsOf: url) else { return .failure(.binary) }

        // Latin-1 as the fallback rather than a refusal: it maps every byte
        // to some character, so a file in an encoding nobody can identify
        // still opens and stays editable instead of being called binary.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        return .success(EditorDocument(url: url, text: text))
    }

    /// Records what the reader has typed.
    ///
    /// Compared against the copy on disk rather than assumed dirty, so
    /// undoing back to the saved version clears the dot — the comparison is
    /// on a string the view already built, so it costs nothing extra.
    func edited(_ text: String) {
        liveText = text
        let changed = text != diskText
        if isDirty != changed { isDirty = changed }

        /// One keystroke is enough. This is the typing path, so the guard is
        /// what keeps it to an optional comparison — the write, and the publish
        /// it costs, happen once for the first character after a mark and never
        /// again until another one is placed.
        if agentMark != nil { agentMark = nil }
    }

    /// Records that `agent` pointed at `line`, replacing whatever was marked
    /// before. Written only through ``EditorCenter/open(_:reveal:markedBy:showing:reviewBase:)``,
    /// which is what reads the line out of the range being revealed.
    func mark(_ agent: CodingAgent, atLine line: Int) {
        let mark = EditorAgentMark(agent: agent, line: line)
        if agentMark != mark { agentMark = mark }
    }

    /// What the last replacement was, for the Edit menu to name.
    ///
    /// On the document rather than passed down beside the text because the
    /// view reads it from here on the pass that applies the revision, and
    /// those are the same pass.
    @Published private(set) var replacementName = "Replace"

    /// Whether the last replacement may be taken back. False only for text
    /// that came off the disk — see ``CodeTextView/replacementIsUndoable``.
    @Published private(set) var replacementIsUndoable = true

    /// Replaces the text from this side — a formatter, a rename, a reload.
    /// Bumping the revision is what tells the view to take it.
    ///
    /// - Parameters:
    ///   - name: what the Edit menu calls the step this becomes.
    ///   - undoable: false for a reload, which must not be taken back and
    ///     invalidates everything recorded before it. See
    ///     ``EditorUndoCenter`` for the rule and why it exists.
    func replaceText(_ replacement: String, named name: String = "Replace", undoable: Bool = true) {
        replacementName = name
        replacementIsUndoable = undoable
        liveText = replacement
        text = replacement
        revision += 1
        let changed = replacement != diskText
        if isDirty != changed { isDirty = changed }

        /// The other half of the rule in ``agentMark``. A formatter, a rename
        /// and a reload all arrive here, and every one of them can move the line
        /// a mark names.
        if agentMark != nil { agentMark = nil }
    }

    @discardableResult
    func save() -> Bool {
        // What the buffer holds, not what was loaded — writing `text` is why
        // saving used to put the file back the way it was opened.
        let contents = currentText
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            text = contents
            diskText = contents
            isDirty = false
            hasConflict = false
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// Keeps the buffer and stops warning about the version on disk.
    ///
    /// Their change is *acknowledged*, not discarded — recording it as the
    /// version we know about is what stops the same conflict being raised
    /// again for the same content, while leaving the document dirty because
    /// what is on screen still isn't what is on disk.
    func keepLocalVersion() {
        if let data = try? Data(contentsOf: url),
           let onDisk = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) {
            diskText = onDisk
        }
        hasConflict = false
        isDirty = currentText != diskText
    }

    /// Takes the version on disk, dropping local edits.
    func revert() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return }

        replaceText(text, named: "Reload", undoable: false)
        self.diskText = text
        isDirty = false
        hasConflict = false
    }

    /// Watches for changes made outside the app.
    ///
    /// A clean buffer reloads silently — that is the behavior that makes
    /// the editor usable next to a terminal, since `git checkout` updating
    /// what you are reading should just work. A dirty buffer raises a
    /// conflict instead, because the only other options are losing your
    /// edits or hiding theirs.
    func startWatching() {
        guard watcher == nil else { return }

        // The containing directory, not the file: an atomic save — which is
        // what most editors and every `git` operation do — replaces the
        // inode, and a descriptor held on the old one stops hearing about
        // anything. Watching the directory survives that.
        let watcher = DirectoryWatcher()
        watcher.onChange = { [weak self] _ in
            Task { @MainActor in self?.diskDidChange() }
        }
        watcher.watch([url.deletingLastPathComponent().path])
        self.watcher = watcher
    }

    func stopWatching() {
        watcher = nil
    }

    /// A copy of this document living at a new path, carrying the buffer,
    /// dirty state and conflict state with it — a rename or move must not
    /// cost the reader their edits.
    func transferred(to newURL: URL) -> EditorDocument {
        let copy = EditorDocument(url: newURL, text: text)
        copy.liveText = liveText
        copy.diskText = diskText
        copy.isDirty = isDirty
        copy.hasConflict = hasConflict
        copy.loadError = loadError
        /// Carried, because a rename moves the file and not a line in it. The
        /// undo history travels the same way, for the same reason — see
        /// ``EditorUndoCenter/repath(from:to:)``.
        copy.agentMark = agentMark
        return copy
    }

    private func diskDidChange() {
        guard let data = try? Data(contentsOf: url),
              let onDisk = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return }

        guard onDisk != diskText else { return }

        if isDirty {
            hasConflict = true
        } else {
            replaceText(onDisk, named: "Reload", undoable: false)
            diskText = onDisk
        }
    }
}

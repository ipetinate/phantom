import AppKit
import os
import SwiftUI

/// The editor as it sits in the terminal's pane: tab bar on top, text
/// below.
///
/// Reads Phantom's settings and theme here and hands them to the engine as
/// plain values — `CodeTheme`, `CodeEditorConfiguration`. That direction is
/// the whole arrangement: everything under `Engine/` stays ignorant of this
/// app, and this file is where the two meet.
struct EditorPaneView: View {
    @ObservedObject var center: EditorCenter

    /// The cell this editor draws. What it shows is that cell's selection,
    /// not the grid's — several cells can be showing different files at once.
    let groupID: EditorGroup.ID

    /// Where this pane's terminal is, which is what makes an open file's own
    /// worktree worth mentioning. See ``EditorTerminalDirectory``.
    @ObservedObject var terminalDirectory: EditorTerminalDirectory

    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(EditorSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = EditorSettings.defaultTabWidth
    @AppStorage(EditorSettings.showsMinimapKey) private var showsMinimap = true
    @AppStorage(EditorSettings.colorsBracketPairsKey) private var colorsBracketPairs = true
    @AppStorage(EditorSettings.closesBracketsKey) private var closesBrackets = true
    @AppStorage(EditorSettings.closesQuotesKey) private var closesQuotes = true
    @AppStorage(EditorSettings.closesTagsKey) private var closesTags = true

    @AppStorage(CompletionSettingsStore.enabledKey) private var completionEnabled = true
    @AppStorage(CompletionSettingsStore.bufferWordsKey) private var completesFromBuffer = true
    @AppStorage(CompletionSettingsStore.delayKey)
    private var completionDelayRaw = CompletionDelay.default.rawValue

    /// Observed, not read, and load-bearing anyway — do not delete it as
    /// dead. `@AppStorage` has no dictionary, so the per-language table is
    /// one JSON blob, and observing that blob is what republishes this view
    /// when a language's switch moves in Settings. Without it the new answer
    /// would sit in `UserDefaults` until some unrelated update happened to
    /// rebuild the configuration, which is the `showsMinimap` bug wearing a
    /// different key.
    @AppStorage(CompletionSettingsStore.byLanguageKey) private var completionByLanguage = Data()

    @ObservedObject var search: WorkspaceSearchCenter
    @ObservedObject private var lsp: LSPCenter = .shared

    /// What the server answered for "find references", shown in its own
    /// sheet. Kept here rather than in the document view because following
    /// one of them opens a *different* document, which is this view's job.
    @State private var references: [LSPReference] = []

    /// The ⇧⌘K request, alive while its picker sheet is on screen.
    @State private var attachRequest: AgentAttachRequest?

    var body: some View {
        content
            // A `safeAreaInset` rather than a `VStack`, so the tab bar's
            // height is *reserved* instead of merely drawn above the text.
            // Stacked, the text view kept its full height and scrolled
            // underneath the bar — the first lines of every file sat behind
            // it, and the bar's transparency made that read as a rendering
            // fault rather than a layout one.

            .sheet(isPresented: $search.isPresented) {
                WorkspaceSearchView(center: search) { hit in
                    search.dismiss()
                    center.open(URL(fileURLWithPath: hit.path))
                }
            }
            // Three answers, and Cancel is the default so a stray Return
            // cannot be the one that discards work.
            .alert(
                "Save changes to \(center.closeConfirmation?.name ?? "this file")?",
                isPresented: Binding(
                    get: { center.closeConfirmation != nil },
                    set: { if !$0 { center.closeConfirmation = nil } }
                ),
                presenting: center.closeConfirmation
            ) { confirmation in
                Button("Save") {
                    center.saveAndClose(confirmation.path)
                    center.closeConfirmation = nil
                }
                Button("Don't Save", role: .destructive) {
                    center.close(confirmation.path)
                    center.closeConfirmation = nil
                }
                Button("Cancel", role: .cancel) { center.closeConfirmation = nil }
            } message: { _ in
                Text("Your changes will be lost if you don't save them.")
            }
            .sheet(isPresented: Binding(
                get: { !references.isEmpty },
                set: { if !$0 { references = [] } }
            )) {
                ReferencesView(references: references) { reference in
                    references = []
                    center.open(
                        URL(fileURLWithPath: reference.location.path),
                        reveal: reference.location.range
                    )
                }
            }
            .sheet(item: $attachRequest) { request in
                AgentAttachPicker(request: request) { attachRequest = nil }
            }
    }

    /// Trades a tab showing one checkout's file for the same file in the
    /// checkout the terminal is in now.
    ///
    /// Opened before the old tab is asked to close, and the order is the
    /// point. Closing first would move the selection to a neighbouring tab,
    /// and the reader would watch an unrelated file appear on their way to
    /// the one they asked for. Opening first lands them on the new file and
    /// leaves the close as bookkeeping behind it.
    ///
    /// `requestClose` rather than `close`, so a document with unsaved edits
    /// still gets its "save first?" question. That is the case this whole
    /// banner exists for: the reason a dirty document stayed behind is that
    /// its edits belong to the branch being left, and discarding them
    /// silently on the way out would be exactly the loss
    /// ``WorktreeDocumentMigration`` refused to risk.
    private func followTerminal(from path: String, to counterpart: String) {
        guard center.open(URL(fileURLWithPath: counterpart)) else { return }
        center.requestClose(path)
    }

    /// ⌘K: the reference goes to this tab's own terminal, and the pane flips
    /// to it — a reference typed into a hidden prompt looks like the key did
    /// nothing, and seeing it land is what tells the reader they can keep
    /// typing their question.
    private func attachToOwnTerminal(document: EditorDocument, range: NSRange, text: String) {
        guard let surface = AgentAttach.ownSurface() else {
            NSSound.beep()
            return
        }
        let lines = EditorLineReference.lines(in: text as NSString, selection: range)
        let reference = EditorLineReference.reference(
            filePath: document.url.path,
            lines: lines,
            cwd: AgentAttach.ownCwd())
        AgentAttach.send(reference, into: surface)
        center.selectTerminal()
    }

    @ViewBuilder
    private var content: some View {
        if let document = center.selectedDocument(in: groupID) {
            DocumentView(
                document: document,
                theme: theme,
                configuration: configuration,
                lsp: lsp,
                terminalDirectory: terminalDirectory.path,
                onSave: { center.saveSelected() },
                onSaveAll: { center.saveAll() },
                onCloseTab: { center.requestCloseSelected() },
                onFollowTerminal: { counterpart in
                    followTerminal(from: document.url.path, to: counterpart)
                },
                onSearchWorkspace: {
                    search.present(root: (document.url.deletingLastPathComponent()).path)
                },
                onOpenLocation: { location in
                    center.open(URL(fileURLWithPath: location.path), reveal: location.range)
                },
                onShowReferences: { found in
                    references = found.map(LSPReference.init)
                },
                onAttachLine: { range, text in
                    attachToOwnTerminal(document: document, range: range, text: text)
                },
                onAttachLinePicker: { range, text in
                    attachRequest = AgentAttachRequest(
                        filePath: document.url.path,
                        lines: EditorLineReference.lines(in: text as NSString, selection: range))
                }
            )
            .id(document.id)
        } else if let media = center.selected(in: groupID)?.media {
            /// A media tab has no `DocumentView`, and that is what keeps a
            /// PDF out of reach of `didOpen`, of the dirty flag and of
            /// `save()` — none of that machinery is built for it in the first
            /// place.
            MediaPaneView(document: media, theme: theme)
                .id(media.id)
        } else {
            Color.clear
        }
    }

    /// The identifier the cursor is inside, used to prefill the rename
    /// field — retyping a name in full to change one character of it is the
    /// kind of friction that stops a feature from being used.
    static func identifier(at offset: Int, in text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }

        let isPart: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }

        // Back one when the cursor sits just past the end of a word, which
        // is exactly where it lands after double-clicking or typing it.
        var start = min(offset, characters.count - 1)
        if start > 0, !isPart(characters[start]) { start -= 1 }
        guard isPart(characters[start]) else { return "" }

        var end = start
        while start > 0, isPart(characters[start - 1]) { start -= 1 }
        while end + 1 < characters.count, isPart(characters[end + 1]) { end += 1 }
        return String(characters[start...end])
    }

    /// The terminal's palette, translated for the editor.
    private var theme: CodeTheme {
        EditorTheme.make(from: palette)
    }

    private var configuration: CodeEditorConfiguration {
        /// The LSP language id, never `document.language`. `CodeLanguage` is
        /// a lexer grouping — `.javascript` is ts, tsx, js, jsx, mts and cts
        /// at once — so keying completion on it would make "no completion in
        /// `.tsx`" mean "no completion in every `.js` file in the project",
        /// which is the collapse `CompletionSettingsStore`'s keying decision
        /// exists to prevent. Resolved through `LanguageResolver` rather than
        /// the registry, because a language an extension contributed has a
        /// switch in Settings too.
        ///
        /// The store folds the master switch and the per-language answer
        /// together. Doing it here instead would put that rule in two places.
        let completion = CompletionSettingsStore.settings(
            forLanguage: center.selectedDocument(in: groupID).flatMap {
                LanguageResolver.shared.languageID(forPath: $0.url.path)
            },
            isEnabled: completionEnabled,
            delay: .named(completionDelayRaw),
            usesBufferWords: completesFromBuffer
        )

        return CodeEditorConfiguration(
            font: EditorSettings.font(size: fontSize, family: palette.interfaceFontFamily),
            showsLineNumbers: showsLineNumbers,
            wrapsLines: wrapsLines,
            tabWidth: tabWidth,
            insertsSpacesForTab: true,
            highlightsCurrentLine: true,
            colorsBracketPairs: colorsBracketPairs,
            showsMinimap: showsMinimap,
            closesBrackets: closesBrackets,
            closesQuotes: closesQuotes,
            closesTags: closesTags,
            completionEnabled: completion.isEnabled,
            completesFromBuffer: completion.usesBufferWords,
            completionFetchDelay: completion.delay.duration
        )
    }
}

/// One document's text surface, plus the banner for a file that changed
/// underneath it.
/// What one attempt at Prettier came back with.
///
/// Three answers rather than an optional and a thrown error, because the
/// caller has to tell "Prettier does not own this file" from "Prettier looked
/// and there was nothing to change" — the first falls through to the language
/// server, the second must not. Collapsing them is how a `.kt` file ends up
/// formatted by nobody.
///
/// The failure travels as a string: it crosses an actor boundary, and what the
/// reader needs from it is a sentence, not an error to re-inspect.
enum FormatAttempt: Sendable {
    case notOurs
    case answered(PrettierEdit?)
    case failed(String)
}

/// What set formatting off: the reader's own keystroke, or the save that
/// offered to tidy on its way past.
///
/// The two differ in one thing only — what the reader is owed when formatting
/// does not happen. ⇧⌘F is a question, and a question answered by nothing at
/// all reads as a dead key. ⌘S is not a question about formatting: the reader
/// asked for the file to be on disk and the tidying was the editor's own idea,
/// so a project with no Prettier in it would otherwise raise the same dialog on
/// every single write until the reader learned to dismiss alerts unread.
enum EditorFormatTrigger: Sendable {
    case command
    case save
}

extension FormatAttempt {
    /// The sentence this outcome is worth interrupting the reader with, or nil
    /// to say nothing at all.
    ///
    /// The line: **an alert is for a failure somebody is waiting on.** Success
    /// and no-op are both silent, because both are the outcome that was asked
    /// for, and neither needs a receipt to be clicked away.
    ///
    /// - `.answered(edit)` — the buffer changed in front of the reader. That
    ///   is the receipt; a modal on top of it is a second one.
    /// - `.answered(nil)` — already formatted, or covered by an ignore rule.
    ///   This is the state ⇧⌘F is pressed to *reach*, so announcing it makes
    ///   the good case the loud one — and it is the common case, since most
    ///   files in a Prettier project are already formatted.
    /// - `.notOurs` — nothing has happened yet. The language server still gets
    ///   its turn below, and reports for itself.
    /// - `.failed` — the reader asked for something and did not get it, and the
    ///   reason carries a parse error's line and column, an unreadable config,
    ///   or a formatter that is not installed. Worth a modal, but only on
    ///   `.command`. The write goes ahead regardless.
    ///
    /// The reason is passed through whole rather than wrapped in a sentence
    /// here. Which tool is speaking is known where the run happened and not
    /// here — several can now — and "Prettier couldn't format this file: Ruff:
    /// …" is what wrapping it produced.
    func notice(for trigger: EditorFormatTrigger) -> String? {
        guard trigger == .command, case .failed(let reason) = self else { return nil }
        return reason
    }
}

private struct DocumentView: View {
    /// Whether the completion list keeps its documentation card open.
    ///
    /// Here rather than in the engine because the engine reads no
    /// `UserDefaults` — `EditorEngineBoundaryTests` forbids it, so the value
    /// crosses in and the change comes back out.
    @AppStorage(EditorSettings.showsCompletionDocumentationKey)
    private var showsCompletionDocumentation = false

    /// The switches for what the editor does unasked, observed so a change in
    /// the settings window reaches an open file without reopening it.
    ///
    /// An `@ObservedObject` rather than six `@AppStorage` lines, because
    /// `EditorFeatureSettings` already owns the reading of them — and because
    /// what crosses into the engine is one value, not six preferences.
    @ObservedObject private var editorFeatures = EditorFeatureSettings.shared
    @ObservedObject var document: EditorDocument
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration
    @ObservedObject var lsp: LSPCenter

    /// The committed text the margin's `+` and `-` are measured against.
    ///
    /// Observed rather than fetched here: the answer arrives from a
    /// subprocess, so the first pass over a freshly opened file has no
    /// baseline and the marks appear a moment later.
    @ObservedObject private var baseline: EditorGitBaseline = .shared

    /// Who last changed the line the caret is on. Observed so the sentence
    /// appears when `git blame` answers, which is after the caret moved.
    @ObservedObject private var blame: EditorBlameCenter = .shared

    /// Whether the diff pane is showing the unchanged parts of the file too.
    ///
    /// Here rather than in `GitDiffView` so its control can sit in the row of
    /// actions this view already draws, beside the presentation and split
    /// toggles. Per tab, and not remembered: it answers a question about the
    /// diff being looked at now.
    @State private var diffShowsWholeFile = false

    /// The working directory of the terminal this pane belongs to, or nil
    /// while it has not reported one. A plain value rather than the
    /// observable it came from: what this view does with it is compare it
    /// against a path, and taking it as a value is what lets the comparison
    /// be re-run on exactly the changes that matter.
    let terminalDirectory: String?

    let onSave: () -> Void
    let onSaveAll: () -> Void
    let onCloseTab: () -> Void

    /// Asked to swap this tab for the same file in the terminal's checkout,
    /// with the path to open. Offered only when that file exists.
    let onFollowTerminal: (String) -> Void

    let onSearchWorkspace: () -> Void
    let onOpenLocation: (LSPLocation) -> Void
    let onShowReferences: ([LSPLocation]) -> Void
    let onAttachLine: (NSRange, String) -> Void
    let onAttachLinePicker: (NSRange, String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    @State private var renamingAt: Int?
    @State private var newName = ""

    /// Where a rename or a jump reports it found nothing, since silence
    /// reads as the feature being broken.
    /// Observed so a remap reaches an editor that is already open, rather
    /// than only the next file to be opened.
    @ObservedObject private var shortcutStore: PhantomShortcutStore = .shared

    @AppStorage(EditorSettings.usesPrettierKey) private var usesPrettier = true
    @AppStorage(EditorSettings.markdownSnippetsKey) private var markdownSnippets = true
    @AppStorage(EditorSettings.expandsTagsKey) private var expandsTags = true
    @AppStorage(EditorSettings.formatOnSaveKey) private var formatOnSave = false

    /// Read here as well as inside `MarkdownWidthToggle`, which is what keeps
    /// the two in step: the toggle writes the preference, `@AppStorage`
    /// republishes this view, and the preview is handed the new column.
    @AppStorage(EditorSettings.markdownPreviewWidthKey)
    private var markdownPreviewWidth = EditorSettings.defaultMarkdownPreviewWidth.rawValue

    @State private var notice: String?

    /// The server log to offer alongside `notice`, captured at the moment
    /// the notice was set rather than read fresh when the button is
    /// tapped — by then a retry may have already replaced it.
    @State private var noticeLog: [String]?

    @State private var showingServerLog = false
    @State private var serverLogTitle = ""
    @State private var serverLogLines: [String] = []

    /// The diagnostics as ranges the engine can draw.
    ///
    /// Held rather than computed in `body`: converting them walks the
    /// document, and `body` runs on every keystroke — so the version that
    /// looked innocent was scanning the whole file once per diagnostic per
    /// character typed. They are recomputed when the server speaks, which
    /// is the only time they actually change.
    /// The diagnostics handed to the engine to draw — each carrying the
    /// message, because both the wave and the card are read from the one text
    /// attribute they become. See ``CodeDiagnosticMark``.
    @State private var underlines: [(range: NSRange, mark: CodeDiagnosticMark)] = []

    /// A diagnostic with its range already resolved against the document.
    private struct LocatedProblem {
        let range: NSRange
        let problem: CodeHoverInfo.Problem

        /// The server's own diagnostic, kept beside the located one.
        ///
        /// A quick fix is matched on the diagnostic's `code`, and a request
        /// that omits it comes back with the refactors and **none** of the
        /// fixes — measured on `typescript-language-server`: eighteen actions
        /// with the code, seventeen without, and the one that disappeared was
        /// the only quick fix. Nothing errors. So the caret's diagnostics have
        /// to travel with a ⌃. request, and this is where they are kept.
        let diagnostic: LSPDiagnostic
    }

    /// Every diagnostic, located once. The underlines are a subset of these
    /// and the hover card reads them directly — see `refreshUnderlines`.
    @State private var located: [LocatedProblem] = []

    /// Translates between the server's vocabulary and the list's.
    ///
    /// `@State` because it has to *survive* body evaluation: it remembers the
    /// server's own item behind each row so that row can later be resolved,
    /// and a fresh one per keystroke would hand out tokens that resolve to
    /// nothing. One per document, which is also the scope of the list it
    /// describes.
    @State private var completionBridge = CompletionBridge()

    /// Read to decide whether this file can be shown as a diff. Observed, so
    /// committing while a diff is open takes the diff away rather than
    /// leaving a stale one on screen.
    @ObservedObject private var git: GitCenter = .shared

    /// How a split is cut. A preference rather than a property of the file,
    /// so it is shared by every split and outlives the launch — someone who
    /// reads diffs stacked wants the next one stacked too.
    @AppStorage("EditorSplitDirection") private var splitDirectionRaw = SplitViewDirection.horizontal.storageKey

    /// Whether this document is from a worktree its terminal has left, and
    /// what there is to be done about it.
    ///
    /// Held in state and recomputed on the two things that can change it,
    /// rather than asked while rendering. The answer costs a walk up to
    /// `.git` and a couple of small reads, and this view redraws on every
    /// git poll and every diagnostic a language server sends.
    @State private var divergence: WorktreeDivergence.Verdict?

    /// The arrangement of whatever split this document is showing.
    ///
    /// Owned here rather than by the document because it is where the
    /// divider sits, which is a property of the window this file is being
    /// read in. Its direction is kept in step with the stored preference in
    /// both directions — see `body`.
    @StateObject private var splitModel = SplitPaneModel()

    /// What this document can be shown as, from the file's name and whether
    /// git has anything to compare it against.
    private var presentationOptions: EditorPresentationOptions {
        .resolve(fileName: document.url.lastPathComponent, hasChanges: documentHasChanges)
    }

    /// Whether there is a diff worth offering.
    ///
    /// A conflicted file has none: git answers `* Unmerged path` and nothing
    /// else, so the diff pane could only say so — which is what it did, and it
    /// was a dead end. The file it will not diff is exactly the file whose
    /// conflicts the source view can resolve, so the presentation falls back
    /// to the source rather than to a sentence.
    /// The branch this document's repository is on, for the conflict markers
    /// that only say `HEAD`.
    private var currentBranch: String? {
        guard let root = EditorChangeLookup.owningRoot(
            forPath: document.url.path, amongRoots: Array(git.statuses.keys))
        else { return nil }
        return git.status(forRoot: root)?.branch
    }

    private var documentHasChanges: Bool {
        guard let context = gitContext else { return false }
        return !context.change.isUnmerged
    }

    /// Everything a diff of this document needs, or nil when git has
    /// nothing to compare it against.
    private var gitContext: (root: String, change: GitFileChange, side: GitDiffSide)? {
        let path = document.url.path

        /// A file opened from the branch review is compared against that
        /// review's base, whatever the working tree says — including when the
        /// working tree says nothing, which is the ordinary case: most files a
        /// branch changes were committed and are clean now.
        ///
        /// The change is synthesised rather than looked up for that reason.
        /// Only two of its fields matter down this path — the path itself, and
        /// `isUntracked`, which short-circuits to the working tree — because a
        /// branch range is expressed in the arguments and not in the status
        /// letters. Giving it a letter it did not earn would be inventing
        /// history; `M` here means "ask git", and git answers.
        if let base = document.reviewBase,
           let root = EditorChangeLookup.owningRoot(forPath: path, amongRoots: Array(git.statuses.keys)),
           let relative = EditorChangeLookup.relativePath(forPath: path, root: root) {
            let change = GitFileChange(
                path: relative,
                originalPath: nil,
                index: ".",
                worktree: "M",
                isUntracked: false,
                isUnmerged: false
            )
            return (root, change, .branch(base: base))
        }

        guard let root = EditorChangeLookup.owningRoot(forPath: path, amongRoots: Array(git.statuses.keys)),
              let status = git.status(forRoot: root),
              let relative = EditorChangeLookup.relativePath(forPath: path, root: root),
              let found = EditorChangeLookup.change(relativePath: relative, in: status)
        else { return nil }

        return (root, found.change, found.side)
    }

    /// The document, drawn the way it is currently being read.
    ///
    /// Routed through `nearest`, so a presentation that stopped being
    /// available — the diff of a file whose changes were just committed —
    /// draws the source rather than an empty pane.
    @ViewBuilder
    private var presentedContent: some View {
        switch presentationOptions.nearest(to: document.presentation) {
        case .source:
            sourcePane

        case .diff:
            diffPane

        case .preview:
            previewPane

        case .image:
            svgPane

        case .table:
            tablePane

        case .split:
            /// The direction toggle rides *inside* the presentation control's
            /// box rather than being the container's own copy beside it: two
            /// backings inches apart in one corner read as two controls to
            /// learn, and the loose one was photographed sitting on the
            /// minimap. The gap inside the box is what marks it as a
            /// different kind of action.
            SplitPaneContainer(
                model: splitModel,
                showsDirectionToggle: false,
                accessoryTrailingInset: splitAccessoryTrailingInset
            ) {
                sourcePane
            } second: {
                /// Whichever alternative this file offers. A document never
                /// offers both, so there is no third case to choose in.
                if presentationOptions.splitPartner == .diff {
                    diffPane
                } else {
                    previewPane
                }
            } accessory: {
                presentationControlWithSplitToggle
            }
            /// Only the preview split configures the link here. The diff
            /// configures its own, and both switch it off on the way out —
            /// the model is shared, and an absolute mapping left switched on
            /// beside a rendered document would drag it to an offset that
            /// means nothing in it.
            .onAppear { if presentationOptions.splitPartner == .preview { linkPreviewSplit() } }
            .onDisappear { splitModel.scrollSync.isEnabled = false }
        }
    }

    /// Whether the control is this view's to draw, rather than something
    /// else's to place.
    private var drawsControlOverContent: Bool {
        switch presentationOptions.nearest(to: document.presentation) {
        case .split, .diff: false
        case .source, .preview, .image, .table: true
        }
    }

    /// How far in from the right edge the control has to sit to clear the
    /// minimap.
    ///
    /// Only the source pane has a minimap, and only when it is the whole
    /// pane. In a split the source is on the left, so its minimap runs down
    /// the middle of the window and the corner belongs to the other pane;
    /// the preview and the diff have no minimap at all. Insetting
    /// unconditionally would leave the control floating in from the edge on
    /// every one of those.
    private var controlTrailingInset: CGFloat {
        let showsSource = presentationOptions.nearest(to: document.presentation) == .source
        let minimap = showsSource && configuration.showsMinimap ? CodeTextView.minimapColumnWidth : 0

        /// Plus the scroller, always. Every pane this control floats over has
        /// a vertical one, and the control used to sit directly on top of it —
        /// which was invisible while the bar was faded out and then covered the
        /// knob the moment somebody scrolled.
        return minimap + ThinScroller.trackWidth
    }

    private var presentationControl: some View {
        EditorPresentationControl(
            options: presentationOptions,
            presentation: presentationBinding,
            /// The preview already owns this corner, so the column control
            /// joins the cluster there instead of a Settings row nobody would
            /// look for while reading a README — and instead of a second
            /// floating box, which is the mistake the split toggle was moved
            /// in here to undo.
            extra: {
                if showsRenderedMarkdown { MarkdownWidthToggle() }
            }
        )
    }

    /// The same control with the split-direction toggle in its box, for the
    /// two places a split is on screen and the toggle must exist somewhere.
    private var presentationControlWithSplitToggle: some View {
        EditorPresentationControl(
            options: presentationOptions,
            presentation: presentationBinding,
            /// An explicit stack rather than two views in the builder: `extra`
            /// is padded as one element, and a bare pair would be padded as a
            /// pair rather than laid out as two buttons.
            extra: {
                HStack(spacing: 1) {
                    if showsRenderedMarkdown { MarkdownWidthToggle() }
                    if showsDiff { wholeFileToggle }
                    SplitDirectionToggle(model: splitModel)
                }
            }
        )
    }

    /// The way back from an expanded diff.
    ///
    /// It has to exist rather than leaving the gap rows to do both jobs:
    /// clicking a gap is how the whole file is asked for, and once the gaps
    /// are gone there is no gap row left to click again.
    private var wholeFileToggle: some View {
        Button {
            diffShowsWholeFile.toggle()
        } label: {
            Image(systemName: diffShowsWholeFile
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.plain)
        .help(diffShowsWholeFile ? "Show changes only" : "Show the whole file")
    }

    /// Whether a diff is on screen for that toggle to act on — on its own or
    /// as the second pane of a split.
    private var showsDiff: Bool {
        switch presentationOptions.nearest(to: document.presentation) {
        case .diff: true
        case .split: presentationOptions.splitPartner == .diff
        case .source, .preview, .image, .table: false
        }
    }

    /// Whether prose is on screen for the column control to act on. False for
    /// the source, for a diff, and for a split whose second pane is a diff.
    private var showsRenderedMarkdown: Bool {
        switch presentationOptions.nearest(to: document.presentation) {
        case .preview: true
        case .split: presentationOptions.splitPartner == .preview
        case .source, .image, .table, .diff: false
        }
    }

    private var presentationBinding: Binding<EditorPresentation> {
        Binding(
            /// Through `nearest` on the way out, so a diff that stops
            /// existing — the change was just committed — reads as
            /// source instead of pointing at a presentation this file
            /// no longer has.
            get: { presentationOptions.nearest(to: document.presentation) },
            set: { document.presentation = $0 }
        )
    }

    /// What the split's corner controls have to clear, which depends on the
    /// arrangement: stacked, the first pane spans the top-right corner, and
    /// when the source is drawn with a minimap that is exactly where it
    /// lives. Side by side, the corner belongs to the second pane — a
    /// preview or a diff, neither of which has one. The scroller is under
    /// the corner either way.
    private var splitAccessoryTrailingInset: CGFloat {
        let stacked = splitModel.direction == .vertical
        let minimap = stacked && configuration.showsMinimap
            ? CodeTextView.minimapColumnWidth
            : 0
        return minimap + ThinScroller.trackWidth
    }

    @ViewBuilder
    private var diffPane: some View {
        if let context = gitContext {
            GitDiffView(
                path: document.url.path,
                root: context.root,
                change: context.change,
                side: context.side,
                theme: theme,
                font: configuration.font,
                model: splitModel,
                reloadKey: "\(context.change.index)\(context.change.worktree)\(document.isDirty)",
                showsWholeFile: $diffShowsWholeFile,
                accessory: { presentationControlWithSplitToggle }
            )
        } else {
            /// Reachable for an instant: the control was drawn from a status
            /// that has since been replaced by one with no entry for this
            /// file. The next body evaluation moves off `.diff` entirely.
            /// Clear, like the diff it stands in for, so the host's layer is
            /// what shows for that instant.
            Color.clear
        }
    }

    private var previewPane: some View {
        MarkdownPreviewView(
            text: document.currentText,
            fileURL: document.url,
            theme: theme,
            configuration: configuration,
            width: MarkdownPreviewWidth(rawValue: markdownPreviewWidth)
                ?? EditorSettings.defaultMarkdownPreviewWidth,
            scrollSync: splitModel.scrollSync,
            scrollSyncSide: .second,
            anchors: previewAnchors
        )
    }

    /// The SVG as a picture rather than as markup.
    ///
    /// `currentText` rather than the URL, for the same reason the preview
    /// takes it: an unsaved edit is part of the document, and rendering the
    /// file instead would show the reader a version they have already moved
    /// on from.
    private var svgPane: some View {
        EditorSVGPane(text: document.currentText, background: theme.background)
    }

    /// The CSV as the grid it stands for.
    private var tablePane: some View {
        CSVTableView(text: document.currentText, theme: theme, configuration: configuration)
    }

    /// Where the preview drew each block, so a scroll on one side can be
    /// answered in the other's coordinates.
    ///
    /// Held here rather than inside the preview because the strategy needs
    /// it too, and the strategy is configured by whoever owns the split.
    @StateObject private var previewAnchors = MarkdownPreviewAnchors()

    /// Puts the source pane on the link.
    ///
    /// The source is a `CodeTextView`, which builds its own `NSScrollView`,
    /// so it registers directly instead of going through the SwiftUI probe.
    /// That is what the link's own documentation asks for, and it avoids the
    /// failure the diff already taught us: a probe applied outside the
    /// scroll view it was meant to find looks straight past it and links
    /// nothing, silently.
    private func linkSourcePane(_ scrollView: NSScrollView) {
        splitModel.scrollSync.attach(scrollView, as: .first)
    }

    /// Raw markdown beside its rendered form.
    ///
    /// Vertical only: the two panes hold unrelated line lengths, so keeping
    /// their horizontal offsets together would drag the preview sideways
    /// for a long line of source that renders wrapped.
    private func linkPreviewSplit() {
        splitModel.scrollSync.strategy = .markdownPreview(previewAnchors, previewSide: .second)
        splitModel.scrollSync.axes = .vertical
        splitModel.scrollSync.isEnabled = true
    }

    /// The editable text, which every document has and every presentation
    /// either is or sits beside.
    private var sourcePane: some View {
        CodeTextView(
            text: document.currentText,
            textRevision: document.revision,
            replacementName: document.replacementName,
            replacementIsUndoable: document.replacementIsUndoable,
            /// Fetched by path rather than held in `@State`: the state would
            /// die with this view, which is the whole failure the timeline
            /// exists to remove. The lookup is a dictionary hit.
            undoTimeline: EditorUndoCenter.shared.timeline(forPath: document.url.path),
            /// Through the resolver, not `CodeLanguage.resolve` — a
            /// language an extension contributed carries its own
            /// keywords and comment markers, and asking the filename
            /// directly is what made such a file get a language server
            /// and no syntax colouring.
            syntax: LanguageResolver.shared.syntax(forFileName: document.url.lastPathComponent),
            /// From the file's name, not its language: `.ts` and `.tsx`
            /// are the same `CodeLanguage`, and a tag closed in `.ts` is
            /// always wrong because a `<` there can only be a generic.
            tagDialect: CodeTagDialect.resolve(fileName: document.url.lastPathComponent),
            /// Beside the dialect rather than inside the configuration,
            /// because it is read on the keystroke that types a `>` and not
            /// on the pass that decides how the text is drawn.
            expandsTags: expandsTags,
            /// Asked of the running servers rather than of the file name: it
            /// is true only while something is attached that can answer inside
            /// a `class` attribute, and it turns back off by itself when that
            /// server stops.
            completesInsideClassAttribute: lsp.completesClassAttributes(forPath: document.url.path),
            /// Read-only for the one case that cannot be saved anywhere
            /// useful — see ``WorktreeDivergence/Verdict/isReadOnly``. Not a
            /// flag of its own: the same fact that puts the banner up decides
            /// this, so the two can never drift into a banner that says
            /// read-only over a buffer that accepts typing.
            isEditable: divergence?.isReadOnly != true,
            theme: theme,
            configuration: configuration,
            onEdit: { edited in
                document.edited(edited)
                lsp.didChange(path: document.url.path, text: edited)
            },
            underlines: underlines,
            hoverProvider: { offset in await hoverInfo(at: offset) },
            completionProvider: { request in await completions(for: request) },
            completionDocProvider: { item in await documentation(for: item) },
            completionResolver: { item in await resolvedCompletion(for: item) },
            /// Remembered across lists and across launches, because it is a
            /// preference the reader expressed with a click and not a decision
            /// about one completion.
            showsCompletionDocumentation: showsCompletionDocumentation,
            onCompletionDocumentationChanged: { showsCompletionDocumentation = $0 },
            onDiagnosticNote: { WindowBreadcrumbs.note($0) },
            codeActionProvider: { range in await codeActions(in: range) },
            codeActionResolver: { item in await resolveCodeAction(item) },
            onRunCodeAction: { item in runCodeAction(item) },
            completionOffersDocumentation: { item in offersDocumentation(item) },
            completionIconFont: CompletionIconFont.font(ofSize: configuration.font.pointSize),
            reveal: revealRange,
            gutterMark: gutterMark,
            diffBaseline: baseline.baseline(for: document.url.path),
            documentPath: document.url.path,
            blameGhost: blame.current?.ghostText,
            currentBranch: currentBranch,
            onResolveConflict: { resolved, name in
                document.replaceText(resolved, named: name)
            },
            onJumpToDefinition: { offset in jump(from: offset) },
            onRename: { offset in
                newName = EditorPaneView.identifier(at: offset, in: document.currentText)
                renamingAt = offset
            },
            onFindReferences: { offset in findReferences(from: offset) },
            onFormat: { format() },
            onScrollViewReady: { linkSourcePane($0) },
            completionTriggers: completionTriggers,
            commandShortcuts: editorShortcuts,
            onSave: { saveWithFormatting() },
            onSaveAll: onSaveAll,
            onCloseTab: onCloseTab,
            onSearchWorkspace: onSearchWorkspace,
            onAttachLine: onAttachLine,
            onAttachLinePicker: onAttachLinePicker,
            /// The reader's preferences collapsed into the one value the
            /// engine takes. It may not read them itself — see
            /// `EditorAssistance` — so this is where the two vocabularies
            /// meet.
            assistance: EditorAssistance(
                autoImport: editorFeatures.autoImport,
                gitLens: editorFeatures.gitLens,
                hoverCards: editorFeatures.hoverCards,
                diffMarks: editorFeatures.diffMarks,
                completionWhileTyping: editorFeatures.completionWhileTyping,
                inlineDiagnostics: editorFeatures.inlineDiagnostics),
            assistanceRevision: editorFeatures.revision
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                conflictBanner
            }

            if let divergence {
                divergenceBanner(divergence)
            }

            if let status = serverStatus, status.isFailure, let server = lsp.definition(forPath: document.url.path) {
                serverStatusBanner(server: server, status: status)
            }

            ZStack(alignment: .topTrailing) {
                presentedContent

                /// Only where nothing else is already drawing it. A split
                /// takes this control as its accessory, and so does the
                /// diff — which is a split of its own. Drawing it here too
                /// would put a second copy in the same corner, on top of
                /// the first.
                if drawsControlOverContent {
                    presentationControl
                        .padding(.trailing, controlTrailingInset)
                }
            }
        }
        /// The document is open for as long as the tab exists, which is not
        /// the same as for as long as the text view is on screen. These used
        /// to hang off `CodeTextView`, and once a document can be shown as a
        /// preview instead, that would announce `didClose` to the language
        /// server every time somebody looked at their README.
        .onAppear {
            lsp.didOpen(path: document.url.path, text: document.currentText)
            refreshUnderlines()

            /// A server may ask to edit the buffer rather than answering with
            /// the edit — `workspace/applyEdit`, which is how a command-driven
            /// code action reaches the text. Set here because this is the pane
            /// that owns a document; without it the server runs the command,
            /// asks, is told "not applied", and nothing reaches the file.
            lsp.applyEdit = { byFile, label in
                applyWorkspaceEdits(byFile, named: label ?? "Code Action") > 0
            }

            /// The model is fresh per tab; the preference is not. Read it
            /// back so a reader who chose stacked splits gets stacked
            /// splits in the next file too.
            splitModel.direction = SplitViewDirection.fromStorage(splitDirectionRaw)

            /// Ask about this file's repository, rather than waiting to be
            /// told. `owningRoot` can only choose among roots git has
            /// already been asked about, so without this whether a file
            /// offers a diff would depend on whether the reader had
            /// happened to open the sidebar first. `requestStatus` is
            /// already debounced per root and a no-op when it is loaded.
            if let root = EditorChangeLookup.repositoryRoot(forPath: document.url.path) {
                git.requestStatus(root: root)
            }

            /// What the margin compares against. Asked for here rather than
            /// on every update: the store answers once per path and ignores
            /// the rest, but a call per keystroke is a call per keystroke.
            baseline.request(path: document.url.path)

            resolveDivergence()
        }
        /// The only thing that can make an open document diverge, and the
        /// only thing that can heal it: the terminal moving. A `cd` between
        /// two worktrees of one repository changes nothing else about this
        /// view — same file, same text, same tab — so without this the
        /// banner would be decided once, when the tab was opened, and be
        /// wrong from then on.
        ///
        /// `task(id:)` rather than `onChange`, and the document's own path in
        /// the key as well. It runs on appear *and* on every change of the
        /// key, which is what makes the answer impossible to leave stale:
        /// with `onChange` alone the tab bar — which computes the same
        /// verdict from the same directory — drew its divergence mark while
        /// this banner stayed absent, one view refreshed and the other not.
        .task(id: DivergenceKey(document: document.url.path, terminal: terminalDirectory)) {
            resolveDivergence()
        }
        .onChange(of: splitModel.direction) { splitDirectionRaw = $0.storageKey }
        .onDisappear { lsp.didClose(path: document.url.path) }
        .onChange(of: lsp.diagnostics[document.url.path] ?? []) { _ in
            refreshUnderlines()
        }
        // A server that started after this file was opened has never
        // heard of it, so the introduction has to be made again. The
        // document owns its text; the centre only says when.
        .onChange(of: lsp.availabilityGeneration) { _ in
            lsp.didOpen(path: document.url.path, text: document.currentText)
        }
        .sheet(isPresented: Binding(
            get: { renamingAt != nil },
            set: { if !$0 { renamingAt = nil } }
        )) {
            renameSheet
        }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil; noticeLog = nil } })
        ) {
            if let noticeLog, !noticeLog.isEmpty {
                Button("View Log") { showLog(noticeLog, title: "Language Server") }
            }
            Button("OK") { notice = nil; noticeLog = nil }
        }
        .sheet(isPresented: $showingServerLog) {
            ServerLogView(title: serverLogTitle, lines: serverLogLines)
        }
    }

    private func showLog(_ lines: [String], title: String) {
        serverLogLines = lines
        serverLogTitle = title
        showingServerLog = true
    }

    /// The range the engine should jump to, translated out of the
    /// protocol's coordinates.
    private var revealRange: (id: String, range: NSRange)? {
        guard let reveal = document.reveal,
              let range = LSPTextCoordinates.range(of: reveal.range, in: document.currentText as NSString)
        else { return nil }
        return (id: reveal.id, range: range)
    }

    /// The line an agent pointed at, turned into something the gutter can draw.
    ///
    /// This is where the mark stops being an agent and becomes pixels, because
    /// this is the last place that knows both: the document holds which agent,
    /// and the configuration holds the font the mark has to be sized against.
    /// The engine gets neither.
    ///
    /// Read on every body evaluation and costing one dictionary lookup after
    /// the first, because `EditorAgentMarkImages` renders once per agent and
    /// size. Nil when there is nothing to show *or* nothing to show it with: a
    /// mark that could not be rendered is a mark not drawn, never a reveal that
    /// failed.
    private var gutterMark: CodeGutterView.Mark? {
        guard EditorFeatureSettings.shared.agentGutterMark else { return nil }
        guard let mark = document.agentMark else { return nil }
        let size = CodeGutterView.markSize(for: configuration.font)
        guard let image = EditorAgentMarkImages.shared.image(for: mark.agent, size: size)
        else { return nil }
        return CodeGutterView.Mark(line: mark.line, image: image)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Symbol")
                .font(palette.font(size: 13).weight(.semibold))

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(palette.font(size: 12))
                .frame(width: 260)
                .onSubmit { commitRename() }

            HStack {
                Spacer()
                Button("Cancel") { renamingAt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func commitRename() {
        guard let offset = renamingAt else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        renamingAt = nil
        newName = ""
        guard !name.isEmpty else { return }
        rename(at: offset, to: name)
    }

    /// Turns the server's diagnostics into ranges the engine can underline.
    ///
    /// Converted here rather than in the engine: the engine is meant to
    /// know nothing about language servers, and a range with a colour is
    /// the smallest thing that carries the meaning across. One index for
    /// the whole batch — they all refer to the same document.
    private func refreshUnderlines() {
        let reported = lsp.diagnostics[document.url.path] ?? []
        guard !reported.isEmpty else {
            if !located.isEmpty { located = [] }
            if !underlines.isEmpty { underlines = [] }
            return
        }

        /// Resolved **once**, here, and read by both the squiggle and the
        /// card. They used to share the diagnostics list and convert it
        /// separately — the underlines when the server spoke, the card when
        /// the pointer stopped — and a comment claimed they therefore could
        /// not disagree. They could: every keystroke between the two moved
        /// the text under one of them, so the squiggle sat where the problem
        /// *was* while the card asked where it *is*, and hovering the mark
        /// answered nothing. Sharing the list is not the same as sharing the
        /// answer.
        let index = LSPLineIndex(document.currentText as NSString)
        located = reported.compactMap { diagnostic in
            guard let range = index.range(of: diagnostic.range) else { return nil }
            return LocatedProblem(
                range: range,
                problem: CodeHoverInfo.Problem(
                    message: diagnostic.message,
                    source: diagnostic.source,
                    color: Self.color(for: diagnostic.severity)
                ),
                diagnostic: diagnostic
            )
        }

        /// A zero-length range is kept above and dropped here, which is the
        /// one place the two legitimately differ: a server pointing at a
        /// position rather than a span — a missing semicolon, an unexpected
        /// end of file — has something to say and nothing to underline.
        underlines = located.compactMap { found in
            guard found.range.length > 0 else { return nil }
            return (found.range, CodeDiagnosticMark(
                message: found.problem.message,
                source: found.problem.source,
                color: found.problem.color))
        }
    }

    private func position(at offset: Int) -> LSPPosition {
        LSPTextCoordinates.position(at: offset, in: document.currentText as NSString)
    }

    // MARK: Code actions

    /// The server's own action behind each row the menu is showing.
    ///
    /// The same device `CompletionBridge` uses and for the same reason: the
    /// engine may not hold an `LSPCodeAction`, so it is handed an integer and
    /// this remembers what the integer meant. Replaced wholesale on each
    /// request, because a menu that has closed can no longer be resolved from.
    @State private var codeActionsByID: [Int: LSPCodeAction] = [:]

    /// What ⌃. asks for at `range`.
    ///
    /// The diagnostics under the caret travel with the request. Without them
    /// a server answers with its refactors and none of its quick fixes, and
    /// answers *successfully* — see ``LocatedProblem/diagnostic``.
    private func codeActions(in range: NSRange) async -> [CodeActionItem] {
        let text = document.currentText as NSString
        let lspRange = LSPRange(
            start: position(at: range.location),
            end: position(at: min(NSMaxRange(range), text.length)))

        let touching = located
            .filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.location == range.location }
            .map(\.diagnostic)

        let actions = await lsp.codeActions(
            path: document.url.path, range: lspRange, diagnostics: touching)

        codeActionsByID = Dictionary(
            actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let index = LSPLineIndex(text)
        return actions.map { Self.item(for: $0, path: document.url.path, using: index) }
    }

    /// Asks the server to finish a row the reader chose.
    private func resolveCodeAction(_ item: CodeActionItem) async -> CodeActionItem? {
        guard let action = codeActionsByID[item.id],
              let resolved = await lsp.resolveCodeAction(path: document.url.path, action: action)
        else { return nil }

        codeActionsByID[item.id] = resolved
        return Self.item(
            for: resolved,
            path: document.url.path,
            using: LSPLineIndex(document.currentText as NSString))
    }

    /// Carries out a row the engine could not: one that reaches another file,
    /// or one that is a command.
    ///
    /// The protocol fixes the order and it is not a preference — an action
    /// may carry an edit **and** a command, and a real quick fix from
    /// `typescript-language-server` does. Applying one and not the other
    /// performs half of what the reader chose.
    private func runCodeAction(_ item: CodeActionItem) {
        guard let action = codeActionsByID[item.id] else { return }

        Task {
            let finished = action.needsResolve
                ? await lsp.resolveCodeAction(path: document.url.path, action: action) ?? action
                : action

            if !finished.edit.isEmpty {
                applyWorkspaceEdits(finished.edit, named: finished.title)
            }

            if let invocation = finished.command {
                _ = await lsp.executeCommand(
                    path: document.url.path,
                    command: invocation.command,
                    arguments: invocation.arguments)
            }
        }
    }

    /// Applies a set of edits keyed by path, the way `rename` does.
    ///
    /// This file goes through the document so the change is one undo step and
    /// the server is told; the others are re-read immediately before being
    /// written, which is what makes them safe without a revision guard of
    /// their own.
    @discardableResult
    private func applyWorkspaceEdits(_ byFile: [String: [LSPTextEdit]], named name: String) -> Int {
        var changed = 0
        for (path, edits) in byFile where !edits.isEmpty {
            if path == document.url.path {
                let updated = LSPTextEdit.apply(edits, to: document.currentText)
                document.replaceText(updated, named: name)
                lsp.didChange(path: path, text: updated)
            } else if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                let updated = LSPTextEdit.apply(edits, to: existing)
                try? updated.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                continue
            }
            changed += 1
        }
        return changed
    }

    /// One `LSPCodeAction` in the engine's vocabulary.
    ///
    /// Only the edits to *this* file are handed over. Anything else makes the
    /// row non-local, which is what sends it back here to be run.
    private static func item(
        for action: LSPCodeAction,
        path: String,
        using index: LSPLineIndex
    ) -> CodeActionItem {
        let mine = action.edit.first { LSPCodeAction.isSameFile($0.key, as: path) }?.value ?? []

        return CodeActionItem(
            id: action.id,
            title: action.title,
            kind: CodeActionItem.Kind(lspKind: action.kind),
            isPreferred: action.isPreferred,
            disabledReason: action.disabledReason,
            edits: CompletionBridge.edits(mine, using: index)
                .map { CodeActionEdit(range: $0.range, newText: $0.newText) },
            touchesOtherFiles: action.edit.keys.contains { !LSPCodeAction.isSameFile($0, as: path) },
            runsCommand: action.command != nil,
            mayHaveUnsentEdits: action.needsResolve)
    }

    /// What the card shows: the problems reported here, then what the symbol
    /// is.
    ///
    /// Both, in that order, and it matters. The diagnostic is the reason you
    /// looked; the declaration is what you needed to see next. Showing only
    /// the second is what made the red squiggle a dead end — the message
    /// existed the whole time and had nowhere to appear.
    private func hoverInfo(at offset: Int) async -> CodeHoverInfo {
        var info = CodeHoverInfo(problems: problems(at: offset))

        if let markdown = await lsp.hover(
            path: document.url.path,
            position: position(at: offset)
        ) {
            let split = CodeHoverInfo.split(markdown: markdown)
            info.signature = split.signature
            info.documentation = split.documentation
        }

        return info
    }

    /// What to offer at an offset.
    ///
    /// The whole of the translation lives in `CompletionBridge`; what this
    /// adds is the two facts only the document has — the text the server's
    /// line/character ranges are measured against, and whether this file's
    /// server answers a resolve at all. The second is asked here rather than
    /// cached because a server can finish starting between two keystrokes,
    /// and a `false` remembered from before it was ready would leave the
    /// documentation card permanently silent.
    private func completions(for request: CodeCompletionRequest) async -> CodeCompletionAnswer {
        if let snippets = markdownSnippets(at: request.offset) {
            return .items(snippets, isIncomplete: false)
        }

        let support = lsp.completionSupport(forPath: document.url.path)

        let outcome = await lsp.completions(
            path: document.url.path,
            position: position(at: request.offset),
            /// The client advertises `contextSupport: true`, and this is
            /// where that promise is kept. Sending no context is not a
            /// dropped field a server can detect — it answers a different
            /// question, silently: `typescript-language-server` reads the
            /// trigger character to decide whether it is completing a member
            /// access at all.
            context: LSPCompletionContext.decide(
                typedCharacter: request.typedCharacter,
                isRefiningIncompleteList: request.isRefiningIncompleteList,
                support: support
            )
        )

        completionBridge.note(
            supportsResolve: lsp.completionSupport(forPath: document.url.path)?.resolveProvider == true
        )

        return completionBridge.items(from: outcome, in: document.currentText as NSString)
    }

    /// The editor's shortcuts, translated into what the engine takes.
    ///
    /// Only the editor's own commands: the explorer's live on the explorer,
    /// and handing the text view a binding for New Folder would let a
    /// keystroke meant for a tree act on a buffer.
    ///
    /// An action the reader unbound arrives as an empty list rather than
    /// being left out, because the engine reads a missing id as "use the
    /// default" and an empty one as "no shortcut" — which is the difference
    /// between a command they never touched and one they deliberately
    /// silenced.
    private var editorShortcuts: [String: [EditorShortcut]] {
        Dictionary(
            uniqueKeysWithValues: PhantomShortcutAction.actions(in: .editor).map { action in
                (
                    action.rawValue,
                    shortcutStore.shortcuts(for: action).map {
                        EditorShortcut(key: $0.key, modifiers: $0.eventModifierFlags)
                    }
                )
            }
        )
    }

    /// The characters that open the completion list on their own.
    ///
    /// The dot, and `/` in a Markdown file so the snippet catalogue opens the
    /// moment the slash is typed rather than after a letter follows it —
    /// without that character in here nothing asks the provider at all, since
    /// a slash is not an identifier.
    ///
    /// **The language server's own advertised set is deliberately not passed
    /// through.** It never was, and turning it on changes what typing feels
    /// like in every TypeScript file at once: the server advertises `/`, `@`
    /// and `<`, so the list would open on the first slash of a `//` comment,
    /// on a decorator, and on every `a < b`. VS Code does exactly that and it
    /// is defensible — it is also a decision of its own, and it arrived here
    /// as a side effect of wiring the channel this Markdown trigger needed.
    /// Doing one thing at a time: the channel is wired, and what else travels
    /// down it is a separate change with its own evaluation.
    private var completionTriggers: Set<Character> {
        var triggers: Set<Character> = ["."]

        if markdownSnippets,
           MarkdownSnippets.flavor(forFileName: document.url.lastPathComponent) != nil {
            triggers.insert("/")
        }

        return triggers
    }

    /// The Markdown catalogue's rows, when the caret is on a `/` trigger.
    ///
    /// Answered before the server is asked, and returned instead of its
    /// reply rather than merged with it: a `/` is somebody asking for this
    /// list by name, so mixing in identifiers from elsewhere would bury what
    /// they asked for. Every other keystroke in the file goes to the server
    /// exactly as before.
    ///
    /// Local and synchronous, so a `/` opens the list in the same frame —
    /// there is nothing to wait for, and a catalogue that arrives after a
    /// round trip feels like a different feature.
    ///
    /// The fence check is the part `MarkdownSnippets` cannot do for itself:
    /// it is handed a line, and a line inside a fenced block looks like any
    /// other one. Inside a fence the request falls through to the server,
    /// which is what a shell script or a Swift sample in a README should get.
    private func markdownSnippets(at offset: Int) -> [CodeCompletionItem]? {
        guard markdownSnippets else { return nil }
        guard let flavor = MarkdownSnippets.flavor(
            forFileName: document.url.lastPathComponent
        ) else { return nil }

        let text = document.currentText as NSString
        let caret = max(0, min(offset, text.length))
        guard !MarkdownParser.isInsideFencedCode(text, offset: caret) else { return nil }

        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        guard let trigger = MarkdownSnippets.trigger(
            line: text.substring(with: line),
            caretInLine: caret - line.location
        ) else { return nil }

        return MarkdownSnippets.items(
            for: flavor,
            trigger: trigger,
            lineStart: line.location
        )
    }

    /// Asks the server to finish one row, for the documentation card.
    ///
    /// The item is looked up rather than rebuilt, because the server has to be
    /// handed back the object it sent: a reconstruction from the fields this
    /// app models drops everything it does not, and a server that cannot match
    /// the item it receives answers with that item **unchanged rather than
    /// with an error** — an empty card that is indistinguishable from a symbol
    /// nobody documented.
    private func documentation(for item: CodeCompletionItem) async -> CodeCompletionDocPanel.Outcome {
        /// A catalogue row was never sent by a server, so there is nobody to
        /// ask: its card is the snippet's own summary and the text it will
        /// insert. Checked first, because the lookup below would report it as
        /// superseded — an empty card that reads as a server being slow.
        if let local = MarkdownSnippets.documentation(for: item) {
            return .resolved(local)
        }

        guard let completion = completionBridge.completion(for: item.resolveToken) else {
            Self.completionLog.debug(
                "resolve skipped: no stored item for token \(item.resolveToken ?? -1, privacy: .public)"
            )
            return .superseded
        }

        let outcome = await lsp.resolve(completion, path: document.url.path)
        Self.completionLog.debug(
            """
            resolve \(item.label, privacy: .public) \
            itemEpoch=\(completion.epoch, privacy: .public) \
            -> \(String(describing: outcome), privacy: .public)
            """
        )
        return CompletionBridge.outcome(of: outcome)
    }

    /// Asks the server to finish the row the reader accepted.
    ///
    /// The same lookup the documentation card does, for the same reason — the
    /// server has to be handed back the object it sent — but after a different
    /// half of the reply. The card wants the prose; this wants the edits that
    /// put an `import` at the top of the file, and for
    /// `typescript-language-server` and sourcekit-lsp those edits exist
    /// nowhere else. Measured on a real project: a list of 1097 rows carries
    /// the import on none of them, and the chosen row answers with one when
    /// asked on its own.
    ///
    /// Nothing here is TypeScript's. Deferring `additionalTextEdits` to
    /// `completionItem/resolve` is what the protocol allows, so this is the
    /// auto-import for every language whose server takes that option.
    ///
    /// A tighter deadline than the card's, because the reader is waiting on a
    /// keystroke rather than on a selection settling — see
    /// ``LSPTimeout/completionResolveOnAccept``.
    private func resolvedCompletion(for item: CodeCompletionItem) async -> CodeCompletionItem? {
        guard let completion = completionBridge.completion(for: item.resolveToken) else { return nil }

        let outcome = await lsp.resolve(
            completion,
            path: document.url.path,
            timeout: LSPTimeout.completionResolveOnAccept
        )
        return completionBridge.item(
            item,
            finishedBy: outcome,
            in: document.currentText as NSString
        )
    }

    /// Temporary, for tracking down a documentation card that stuck on
    /// "Loading…". Reachable with
    /// `log stream --predicate 'subsystem == "com.ipetinate.phantom"'`.
    static let completionLog = Logger(
        subsystem: "com.ipetinate.phantom",
        category: "completion"
    )

    /// Whether this row is worth an info glyph.
    ///
    /// Two conditions, and both are needed. The server has to answer resolve
    /// at all — `kotlin-language-server` 1.3.13 does not, and ships no
    /// per-item documentation either, so for Kotlin the glyph would be a
    /// control that is permanently going to answer nothing. And the row has to
    /// still be one this bridge can name: an item from a superseded list has
    /// no token left, and asking about it would come back unchanged rather
    /// than refused.
    private func offersDocumentation(_ item: CodeCompletionItem) -> Bool {
        completionBridge.supportsResolve && completionBridge.completion(for: item.resolveToken) != nil
    }

    /// The diagnostics whose range covers this offset.
    ///
    /// Read from the ranges `refreshUnderlines` already resolved, so the
    /// squiggle and the card cannot disagree about where a problem is —
    /// they are now the same values rather than the same source recomputed
    /// twice at different moments.
    ///
    /// The bound is inclusive, and a zero-length range counts as covering
    /// where it sits. Both because the offset is an *insertion* index:
    /// resting on the last character of a word reports the index after it,
    /// so a half-open test makes the end of every word a dead spot.
    private func problems(at offset: Int) -> [CodeHoverInfo.Problem] {
        located
            .filter { offset >= $0.range.location && offset <= $0.range.upperBound }
            .map(\.problem)
    }

    /// One reading of severity for the whole feature: the squiggle under the
    /// text and the label on the card are the same fact drawn twice, and two
    /// colour tables would eventually disagree.
    static func color(for severity: LSPDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .warning: return .systemOrange
        case .information, .hint: return .systemBlue
        }
    }

    private func jump(from offset: Int) {
        Task {
            let found = await lsp.definition(path: document.url.path, position: position(at: offset))
            guard let first = found.first else {
                reportEmpty(
                    whenHealthyAndEmpty: "No definition found.",
                    whenUnsupported: "This language server doesn't offer go-to-definition.",
                    capability: "definitionProvider"
                )
                return
            }
            onOpenLocation(first)
        }
    }

    private func findReferences(from offset: Int) {
        Task {
            let found = await lsp.references(path: document.url.path, position: position(at: offset))
            guard !found.isEmpty else {
                reportEmpty(
                    whenHealthyAndEmpty: "No references found.",
                    whenUnsupported: "This language server doesn't offer find references.",
                    capability: "referencesProvider"
                )
                return
            }
            onShowReferences(found)
        }
    }

    /// Formats the file the way the project says it should be.
    ///
    /// One routing for both callers — the menu item and the save — because
    /// two would drift, and the day they drift the reader gets one style on
    /// ⌥⌘F and another on ⌘S in the same file.
    ///
    /// The trigger only decides who may speak. A file whose language server
    /// has no formatter is an ordinary state, and a modal saying so on every
    /// ⌘S would train the reader to dismiss alerts without reading them — so
    /// the save path reports nothing at all. What neither path reports is a
    /// run that went fine: see `FormatAttempt.notice(for:)`.
    private func formatDocument(_ trigger: EditorFormatTrigger) async {
        /// Read-only means read-only, and formatting is the one write that
        /// does not begin with a keystroke. A non-editable text view refuses
        /// typing, but ⌘S with format-on-save turned on would still rewrite
        /// the file from underneath the banner saying it cannot be edited.
        guard divergence?.isReadOnly != true else { return }

        let timedOut = await settleLanguageServer(trigger)
        if await formatWithPrettier(trigger) { return }
        if await formatWithPrettierFromPath(trigger, handshakeTimedOut: timedOut) { return }
        if await formatWithExternalFormatter(trigger) { return }
        if await formatWithLanguageServer(trigger) { return }

        /// The server was asked and had nothing. Shell is the case: with
        /// `bash-language-server` installed, it advertises formatting and
        /// shells out to `shfmt` — so the external formatter defers to it, and
        /// a server that cannot find `shfmt` on its own `PATH` answers with an
        /// empty edit list while the tool sits installed and working. The
        /// reader gets a sentence about a server instead of a formatted file.
        ///
        /// The same lesson Markdown taught: a server advertising a capability
        /// is not the same as a server having it.
        if await formatWithExternalFormatter(trigger, serverReturnedNothing: true) { return }

        guard trigger == .command else { return }
        reportEmpty(
            whenHealthyAndEmpty: "The language server returned no formatting.",
            whenUnsupported: "This language server doesn't offer formatting.",
            capability: "documentFormattingProvider"
        )
    }

    /// Waits out a handshake that is in flight, and answers whether it gave up.
    ///
    /// The routing below reads three facts off the language server, and all
    /// three are unanswerable while it is still starting: what it is, whether
    /// it formats, and whether the fallbacks should defer to it. Asking anyway
    /// is how the first ⇧⌘F in a freshly opened Markdown file — pressed in the
    /// second between `marksman` launching and it reporting its capabilities —
    /// answered with a sentence about `marksman` not offering formatting.
    ///
    /// Polling rather than a continuation, because the status is `@Published`
    /// state on a `@MainActor` object and every reader of it is a view. A
    /// hundred milliseconds is far below the threshold where a reader suspects
    /// their keystroke was lost, and the loop ends the moment the state moves.
    private func settleLanguageServer(_ trigger: EditorFormatTrigger) async -> Bool {
        let path = document.url.path
        guard EditorFormatRoute.waitsForServer(
            trigger: trigger, server: lsp.status(forPath: path))
        else { return false }

        let deadline = Date().addingTimeInterval(EditorFormatRoute.serverSettleTimeout)
        while Date() < deadline {
            guard lsp.status(forPath: path) == .starting else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return lsp.status(forPath: path) == .starting
    }

    private func format() {
        Task { await formatDocument(.command) }
    }

    /// Writes the file, tidying it first when the reader asked for that.
    ///
    /// **The save happens whatever the formatter does** — missing, broken,
    /// slow or refusing. A ⌘S that quietly did not write because Prettier
    /// was not installed is a data-loss bug wearing a feature's clothes, and
    /// the reader would find out at the worst possible moment.
    private func saveWithFormatting() {
        guard formatOnSave else { return onSave() }
        Task {
            await formatDocument(.save)
            onSave()
        }
    }

    /// Whether Prettier answered for this file, and so the language server
    /// must not also run.
    ///
    /// True covers both of Prettier's answers: it reformatted the file, and it
    /// looked and found nothing to change. False means Prettier does not own
    /// this file at all — a `.kt` in a repository that also has a `.prettierrc`
    /// — which is the only case where falling through is right.
    ///
    /// A failure does **not** fall through. Formatting a Prettier-owned file
    /// with the language server instead would rewrite it in a style the
    /// project rejected, and do it silently; changing nothing is the smaller
    /// harm — and on ⇧⌘F it says why.
    private func formatWithPrettier(_ trigger: EditorFormatTrigger) async -> Bool {
        guard usesPrettier else { return false }

        let revision = document.revision
        let text = document.currentText
        let path = document.url.path

        /// Off the main actor: discovery walks directories and the run is a
        /// subprocess reading a pipe, and both would otherwise hold the frame
        /// on the keystroke that asked for them.
        let outcome = await Task.detached(priority: .userInitiated) {
            let project = PrettierProject.discover(forFile: path)
            guard project.handles(fileNamed: (path as NSString).lastPathComponent)
            else { return FormatAttempt.notOurs }

            do {
                return .answered(try PrettierFormatter.edit(for: text, at: path, in: project))
            } catch {
                return .failed("Prettier couldn't format this file: \(error.localizedDescription)")
            }
        }.value

        return apply(outcome, trigger: trigger, at: path, to: text, since: revision)
    }

    /// Prettier when the project did not ask for it.
    ///
    /// Returns false when this route does not apply, leaving the language
    /// server to answer and to say what it has to say. See
    /// `EditorFormatRoute.usesPrettierFromPath` for when it does.
    private func formatWithPrettierFromPath(
        _ trigger: EditorFormatTrigger,
        handshakeTimedOut: Bool
    ) async -> Bool {
        guard usesPrettier else { return false }

        let path = document.url.path
        let name = (path as NSString).lastPathComponent
        guard EditorFormatRoute.usesPrettierFromPath(
            trigger: trigger,
            prettierKnowsTheFile: PrettierProject.parserCanBeInferred(for: name),
            server: lsp.status(forPath: path),
            serverFormats: lsp.hasCapability("documentFormattingProvider", forPath: path),
            handshakeTimedOut: handshakeTimedOut)
        else { return false }

        let revision = document.revision
        let text = document.currentText

        let outcome = await Task.detached(priority: .userInitiated) {
            /// The project is still discovered, and still not asked to declare
            /// Prettier: what it contributes here is the directory to run in
            /// and, where there is one, the Prettier installed into it. A
            /// project with neither falls through to the login shell's `PATH`,
            /// which is what `PrettierFormatter.binary` already does.
            let project = PrettierProject.discover(forFile: path)
            do {
                return FormatAttempt.answered(
                    try PrettierFormatter.edit(for: text, at: path, in: project))
            } catch {
                return FormatAttempt.failed(
                    "Prettier couldn't format this file: \(error.localizedDescription)")
            }
        }.value

        return apply(outcome, trigger: trigger, at: path, to: text, since: revision)
    }

    /// The formatter for a language nothing else here formats: Ruff for
    /// Python, shfmt for shell, StyLua for Lua, xmllint for XML.
    ///
    /// Unlike the Prettier fallback above, this runs on a save too. Prettier
    /// is held back there because a stray global Prettier would claim files in
    /// every JavaScript-adjacent repository, including ones formatted by
    /// something else; these four are the only formatter their language has on
    /// this machine, which is the same position the language server's own
    /// formatter is in — and each is a switch in Settings.
    private func formatWithExternalFormatter(
        _ trigger: EditorFormatTrigger,
        serverReturnedNothing: Bool = false
    ) async -> Bool {
        let path = document.url.path
        let name = (path as NSString).lastPathComponent

        guard let known = ExternalFormatterRegistry.formatter(forFileNamed: name),
              let formatter = ExternalFormatterStore.effective(known),
              EditorFormatRoute.usesExternalFormatter(
                server: lsp.status(forPath: path),
                serverFormats: lsp.hasCapability("documentFormattingProvider", forPath: path),
                serverReturnedNothing: serverReturnedNothing)
        else { return false }

        let revision = document.revision
        let text = document.currentText

        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let formatted = try ExternalFormatterRunner.format(
                    text,
                    filePath: path,
                    formatter: formatter,
                    searchPath: LoginEnvironment.executableSearchPath(),
                    workingDirectory: (path as NSString).deletingLastPathComponent,
                    environment: LoginEnvironment.executableEnvironment())
                return FormatAttempt.answered(
                    formatted.flatMap { PrettierEdit.minimal(from: text, to: $0) })
            } catch {
                return FormatAttempt.failed(error.localizedDescription)
            }
        }.value

        return apply(outcome, trigger: trigger, at: path, to: text, since: revision)
    }

    /// What to do with the buffer, and what to say — one copy for every
    /// formatter route, because they differ in who runs and in nothing else.
    ///
    /// - Parameters:
    ///   - text: the buffer as it was when the run started. The edit was
    ///     measured against it.
    ///   - revision: the document revision at the same moment.
    private func apply(
        _ outcome: FormatAttempt,
        trigger: EditorFormatTrigger,
        at path: String,
        to text: String,
        since revision: Int
    ) -> Bool {
        /// One place decides what is worth saying, so the branches below are
        /// left deciding only what to do with the buffer.
        if let message = outcome.notice(for: trigger) {
            notice = message
            noticeLog = nil
        }

        switch outcome {
        case .notOurs:
            return false

        case .failed(let message):
            /// Kept past the notice that is about to fade, because whoever
            /// can fix this — the reader coming back, or an agent asked to —
            /// arrives after it has.
            FormatFailureStore.shared.record(message, for: path)
            return true

        case .answered(nil):
            FormatFailureStore.shared.clear(path)
            return true

        case .answered(let edit?):
            FormatFailureStore.shared.clear(path)
            /// The same guard the server path needs, for the same reason: the
            /// edit was measured against the text as it was when the run
            /// started, and the reader kept typing while a subprocess ran.
            guard document.revision == revision else { return true }

            let formatted = edit.applied(to: text)
            document.replaceText(formatted, named: "Formatting")
            lsp.didChange(path: path, text: formatted)
            return true
        }
    }

    /// What formatting was before Prettier: ask the language server.
    /// - Returns: whether the server formatted the file. False means it was
    ///   asked and had nothing, which is a different answer from a failure and
    ///   is what lets an external formatter follow it.
    @discardableResult
    private func formatWithLanguageServer(_ trigger: EditorFormatTrigger) async -> Bool {
            /// Captured before the request, compared after it.
            ///
            /// A formatting reply is a list of ranges computed against the
            /// text as it was when the request went out. Reading
            /// `document.currentText` *after* the await and splicing those
            /// ranges into it assumes nothing moved in between — and
            /// something moving is the ordinary case: the reader keeps
            /// typing, or the file watcher reloads.
            ///
            /// It does not fail loudly when that happens. An edit whose line
            /// is now past the end is dropped silently by `LSPTextEdit.apply`,
            /// and an edit that still lands inside the buffer is applied **at
            /// the wrong offset** — so the file the reader asked to tidy comes
            /// back mangled, with no error anywhere. The window is as wide as
            /// the server is slow, which on a large file is seconds.
            let revision = document.revision

            let edits = await lsp.formatting(
                path: document.url.path,
                tabSize: configuration.tabWidth,
                insertSpaces: configuration.insertsSpacesForTab
            )
            /// Nothing back, and the reporting is deliberately *not* here any
            /// more: a server that advertised formatting and then returned
            /// nothing is exactly when a tool that formats this language
            /// should get its turn. See `formatDocument`.
            guard !edits.isEmpty else { return false }
            guard document.revision == revision else { return true }
            let formatted = LSPTextEdit.apply(edits, to: document.currentText)
            document.replaceText(formatted, named: "Formatting")

            /// Told explicitly, because a programmatic replacement does not
            /// travel the path a keystroke does. `replaceText` sets the
            /// coordinator's "this edit came from us" flag, `textDidChange`
            /// returns early on it, and `onEdit` — the only caller of
            /// `didChange` — lives inside that method. So without this line
            /// the server keeps the *pre-format* text: not merely stale, but
            /// stale in a way that moves every line break and every indent,
            /// so hovers, completions and definitions all answer about
            /// positions that no longer exist. It repairs itself on the next
            /// keystroke, by accident, which is why nobody notices.
            lsp.didChange(path: document.url.path, text: formatted)
            return true
    }

    /// Applies a rename across every file the server named.
    ///
    /// Files that are not open are edited on disk directly — a rename that
    /// only touched the tabs you happened to have open would leave the
    /// project broken in exactly the places you were not looking.
    private func rename(at offset: Int, to name: String) {
        /// The other write that does not come from typing. A rename reaches
        /// this document through the server's edit list rather than through
        /// the keyboard, so the non-editable text view does not stop it.
        guard divergence?.isReadOnly != true else { return }
        Task {
            let revision = document.revision
            let byFile = await lsp.rename(
                path: document.url.path,
                position: position(at: offset),
                to: name
            )
            guard !byFile.isEmpty else {
                reportEmpty(
                    whenHealthyAndEmpty: "This symbol can't be renamed here.",
                    whenUnsupported: "This language server doesn't offer rename.",
                    capability: "renameProvider"
                )
                return
            }

            var changed = 0
            for (path, edits) in byFile {
                if path == document.url.path {
                    /// Same guard as `format`, and needed for the same reason:
                    /// the ranges describe the text as of the request. Note
                    /// the on-disk branch below is already safe by accident —
                    /// it re-reads each file immediately before editing it.
                    guard document.revision == revision else { continue }
                    let renamed = LSPTextEdit.apply(edits, to: document.currentText)
                    document.replaceText(renamed, named: "Rename")
                    lsp.didChange(path: path, text: renamed)
                } else if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                    let updated = LSPTextEdit.apply(edits, to: existing)
                    try? updated.write(toFile: path, atomically: true, encoding: .utf8)
                }
                changed += 1
            }
            notice = "Renamed in \(changed) file\(changed == 1 ? "" : "s")."
            noticeLog = nil
        }
    }

    /// Three answers for a feature that came back with nothing, depending
    /// on what's actually known about the server behind it — the point of
    /// section 1's status tracking is that this no longer has to guess.
    ///
    /// - `whenHealthyAndEmpty`: the server is running, claims to support
    ///   this, and genuinely answered empty. This is today's message,
    ///   shown only when it is actually true.
    /// - `whenUnsupported`: the server is running but never claimed to
    ///   offer this at all.
    /// - Anything else: the server is in a failure state, named along with
    ///   its recent log.
    private func reportEmpty(whenHealthyAndEmpty: String, whenUnsupported: String, capability: String) {
        let path = document.url.path
        guard let status = lsp.status(forPath: path) else {
            notice = "No language server is configured for this file."
            noticeLog = nil
            return
        }

        if status.isFailure {
            notice = "The language server \(status.summary)."
        } else if status == .starting {
            /// Still starting, after the routing already waited it out. It has
            /// not said whether it formats, so neither sentence below is true
            /// about it — and the one about capabilities is the one that read
            /// as a verdict on a server that had not spoken yet.
            notice = "The language server is still starting."
        } else if !lsp.hasCapability(capability, forPath: path) {
            notice = whenUnsupported
        } else {
            notice = whenHealthyAndEmpty
        }
        noticeLog = lsp.log(forPath: path)
    }

    /// What the server for this file's language is doing right now. Nil
    /// when none is known for this language at all.
    private var serverStatus: LSPServerStatus? {
        lsp.status(forPath: document.url.path)
    }

    private func serverStatusBanner(server: LSPServerDefinition, status: LSPServerStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            /// Selectable because the sentence is often the only place a
            /// command the reader has to run appears — a missing plugin's
            /// `npm i -D …` arrives inside the server's own failure reason,
            /// where no Copy button can reach it.
            Text("\(server.displayName) \(status.summary) — language features may not work.")
                .font(palette.font(size: 11))
                .textSelection(.enabled)

            Spacer(minLength: 0)

            if case .notInstalled = status {
                Text(server.installHint)
                    .font(palette.font(size: 11).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                CopyButton(text: server.installHint, label: "Copy install command")

                // The install is noticed on its own — a watcher on the
                // `PATH` directories and a check when the app comes back to
                // the front. This is here for the case those miss: a
                // binary that lands somewhere unwatched, and a reader with
                // no way to say "look again" other than restarting.
                Button("Check Again") { lsp.recheckMissingServers() }
                    .font(palette.font(size: 11))
                    .buttonStyle(.link)
            }

            let log = lsp.log(forPath: document.url.path)
            if !log.isEmpty {
                Button("View Log") { showLog(log, title: server.displayName) }
                    .font(palette.font(size: 11))
                    .buttonStyle(.link)
            }

            Button("Open Settings") { openServerSettings(server) }
                .font(palette.font(size: 11))
                .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12))
    }

    /// Settings, on this server's own row — every way out of the states
    /// this banner reports is there: a different binary, different
    /// arguments, or the approval a withheld server is waiting on.
    ///
    /// The row is named before the window is asked for, because the first
    /// open is also the moment the settings views are built and they read
    /// the request as they appear. The window is reached through the menu's
    /// own action, which keeps the `Ghostty.App` it needs out of the editor.
    private func openServerSettings(_ server: LSPServerDefinition) {
        SettingsNavigation.shared.target = SettingsNavigation.Target(
            section: .languageServers,
            row: SettingsNavigation.languageRow(for: server)
        )
        _ = NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil)
    }

    /// Both halves of the question, so a change to either re-asks it.
    private struct DivergenceKey: Equatable {
        let document: String
        let terminal: String?
    }

    private func resolveDivergence() {
        divergence = WorktreeDivergence.verdict(
            documentPath: document.url.path, terminalDirectory: terminalDirectory)
    }

    /// Shown when this tab is looking at one checkout's file above another
    /// checkout's shell — the state ``WorktreeDocumentMigration`` leaves a
    /// document in when it stays behind.
    ///
    /// Worth saying out loud because nothing else on screen says it. The tab
    /// shows a file name, the text is the text, and the branch the reader
    /// believes they are on is the one their prompt names — which is now a
    /// different branch from the one they are editing. Both names are given
    /// rather than only the document's: "this is from `feat-a`" answers
    /// nothing on its own, and it is the pair that identifies the mistake
    /// somebody is about to make.
    ///
    /// Two sentences and at most two buttons, matching `conflictBanner`'s
    /// weight, because it is the same kind of news: something happened
    /// underneath you, here is what it was, here is the way out.
    private func divergenceBanner(_ divergence: WorktreeDivergence.Verdict) -> some View {
        HStack(spacing: 8) {
            WorktreeIcon(size: 12)
                .foregroundStyle(.orange)

            Text(divergenceSummary(divergence))
                .font(palette.font(size: 11))

            Spacer(minLength: 0)

            /// Offered only when there is a file to offer. On the
            /// `stayMissing` side of this there is no copy in the terminal's
            /// checkout — that is *why* the tab stayed behind — and a button
            /// that opened an empty buffer at that path would create the
            /// file on the first save.
            if let counterpart = divergence.counterpart {
                Button("Open in \(divergence.terminalName)") {
                    onFollowTerminal(counterpart)
                }
                .font(palette.font(size: 11))
            }

            Button("Close") { onCloseTab() }
                .font(palette.font(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
        .help(divergence.documentRoot)
    }

    /// The sentence, in the two shapes the situation comes in.
    ///
    /// The read-only one says *why* it is read-only rather than only that it
    /// is. "Read-only" alone reads as a permissions problem the reader could
    /// go and fix; naming the branch that has no such file is what makes it
    /// obviously not one.
    private func divergenceSummary(_ divergence: WorktreeDivergence.Verdict) -> String {
        if divergence.isReadOnly {
            return "This file is from \(divergence.documentName) and doesn't exist in "
                + "\(divergence.terminalName), where the terminal is now — read-only."
        }
        return "This file is from \(divergence.documentName). The terminal has moved to "
            + "\(divergence.terminalName)."
    }

    /// Shown only when both sides have changes, which is the one case that
    /// can't be resolved without asking. A clean buffer reloads silently.
    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("This file changed on disk while you were editing it.")
                .font(palette.font(size: 11))

            Spacer(minLength: 0)

            Button("Keep Mine") { document.keepLocalVersion() }
                .font(palette.font(size: 11))
            Button("Reload") { document.revert() }
                .font(palette.font(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}

/// The server's recent stderr, verbatim. The whole reason this exists:
/// servers report their own misconfiguration there and nowhere else, and
/// before this it went straight to `/dev/null` as far as anyone using
/// Phantom could tell.
private struct ServerLogView: View {
    let title: String
    let lines: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(title) — Log")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)

            Divider()

            ScrollView {
                Text(lines.isEmpty ? "No output." : lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 360)
    }
}

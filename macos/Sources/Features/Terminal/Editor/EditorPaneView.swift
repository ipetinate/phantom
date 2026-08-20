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
    }

    @ViewBuilder
    private var content: some View {
        if let document = center.selectedDocument {
            DocumentView(
                document: document,
                theme: theme,
                configuration: configuration,
                lsp: lsp,
                onSave: { center.saveSelected() },
                onSaveAll: { center.saveAll() },
                onCloseTab: { center.requestCloseSelected() },
                onSearchWorkspace: {
                    search.present(root: (document.url.deletingLastPathComponent()).path)
                },
                onOpenLocation: { location in
                    center.open(URL(fileURLWithPath: location.path), reveal: location.range)
                },
                onShowReferences: { found in
                    references = found.map(LSPReference.init)
                }
            )
            .id(document.id)
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
            forLanguage: center.selectedDocument.flatMap {
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
private enum PrettierAttempt: Sendable {
    case notOurs
    case answered(PrettierEdit?)
    case failed(String)
}

private struct DocumentView: View {
    @ObservedObject var document: EditorDocument
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration
    @ObservedObject var lsp: LSPCenter
    let onSave: () -> Void
    let onSaveAll: () -> Void
    let onCloseTab: () -> Void
    let onSearchWorkspace: () -> Void
    let onOpenLocation: (LSPLocation) -> Void
    let onShowReferences: ([LSPLocation]) -> Void

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
    @AppStorage(EditorSettings.formatOnSaveKey) private var formatOnSave = false

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
    @State private var underlines: [(range: NSRange, color: NSColor)] = []

    /// A diagnostic with its range already resolved against the document.
    private struct LocatedProblem {
        let range: NSRange
        let problem: CodeHoverInfo.Problem
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

    private var documentHasChanges: Bool { gitContext != nil }

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

        case .split:
            /// The control goes in as the container's **accessory** rather
            /// than over the top of it. Both want the same corner, and
            /// drawn independently the container's direction toggle lands
            /// on top of this control's split button — two split glyphs
            /// overlapping, which is exactly what the accessory parameter
            /// exists to prevent.
            SplitPaneContainer(model: splitModel) {
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
                presentationControl
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
        case .source, .preview: true
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
            presentation: Binding(
                /// Through `nearest` on the way out, so a diff that stops
                /// existing — the change was just committed — reads as
                /// source instead of pointing at a presentation this file
                /// no longer has.
                get: { presentationOptions.nearest(to: document.presentation) },
                set: { document.presentation = $0 }
            )
        )
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
                accessory: { presentationControl }
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
            scrollSync: splitModel.scrollSync,
            scrollSyncSide: .second,
            anchors: previewAnchors
        )
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
            /// Asked of the running servers rather than of the file name: it
            /// is true only while something is attached that can answer inside
            /// a `class` attribute, and it turns back off by itself when that
            /// server stops.
            completesInsideClassAttribute: lsp.completesClassAttributes(forPath: document.url.path),
            theme: theme,
            configuration: configuration,
            onEdit: { edited in
                document.edited(edited)
                lsp.didChange(path: document.url.path, text: edited)
            },
            underlines: underlines,
            hoverProvider: { offset in await hoverInfo(at: offset) },
            completionProvider: { offset in await completions(at: offset) },
            completionDocProvider: { item in await documentation(for: item) },
            completionOffersDocumentation: { item in offersDocumentation(item) },
            completionIconFont: CompletionIconFont.font(ofSize: configuration.font.pointSize),
            reveal: revealRange,
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
            onSearchWorkspace: onSearchWorkspace
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                conflictBanner
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
                )
            )
        }

        /// A zero-length range is kept above and dropped here, which is the
        /// one place the two legitimately differ: a server pointing at a
        /// position rather than a span — a missing semicolon, an unexpected
        /// end of file — has something to say and nothing to underline.
        underlines = located.compactMap { found in
            guard found.range.length > 0 else { return nil }
            return (found.range, found.problem.color)
        }
    }

    private func position(at offset: Int) -> LSPPosition {
        LSPTextCoordinates.position(at: offset, in: document.currentText as NSString)
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
    private func completions(at offset: Int) async -> CodeCompletionAnswer {
        if let snippets = markdownSnippets(at: offset) { return .items(snippets) }

        let outcome = await lsp.completions(
            path: document.url.path,
            position: position(at: offset)
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
    /// `announcing` is off for the save path. A file whose language server
    /// has no formatter is an ordinary state, and a modal saying so on every
    /// ⌘S would train the reader to dismiss alerts without reading them.
    private func formatDocument(announcing: Bool) async {
        if await formatWithPrettier(announcing: announcing) { return }
        await formatWithLanguageServer(announcing: announcing)
    }

    private func format() {
        Task { await formatDocument(announcing: true) }
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
            await formatDocument(announcing: false)
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
    /// project rejected, and do it silently; saying so and changing nothing is
    /// the smaller harm.
    private func formatWithPrettier(announcing: Bool) async -> Bool {
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
            else { return PrettierAttempt.notOurs }

            do {
                return .answered(try PrettierFormatter.edit(for: text, at: path, in: project))
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .notOurs:
            return false

        case .failed(let reason):
            if announcing {
                notice = "Prettier couldn't format this file: \(reason)"
                noticeLog = nil
            }
            return true

        case .answered(nil):
            if announcing { notice = "Prettier had nothing to change here." }
            return true

        case .answered(let edit?):
            /// The same guard the server path needs, for the same reason: the
            /// edit was measured against the text as it was when the run
            /// started, and the reader kept typing while a subprocess ran.
            guard document.revision == revision else { return true }

            let formatted = edit.applied(to: text)
            document.replaceText(formatted)
            lsp.didChange(path: path, text: formatted)
            return true
        }
    }

    /// What formatting was before Prettier: ask the language server.
    private func formatWithLanguageServer(announcing: Bool) async {
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
            guard !edits.isEmpty else {
                guard announcing else { return }
                reportEmpty(
                    whenHealthyAndEmpty: "The language server returned no formatting.",
                    whenUnsupported: "This language server doesn't offer formatting.",
                    capability: "documentFormattingProvider"
                )
                return
            }
            guard document.revision == revision else { return }
            let formatted = LSPTextEdit.apply(edits, to: document.currentText)
            document.replaceText(formatted)

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
    }

    /// Applies a rename across every file the server named.
    ///
    /// Files that are not open are edited on disk directly — a rename that
    /// only touched the tabs you happened to have open would leave the
    /// project broken in exactly the places you were not looking.
    private func rename(at offset: Int, to name: String) {
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
                    document.replaceText(renamed)
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

            Text("\(server.displayName) \(status.summary) — language features may not work.")
                .font(palette.font(size: 11))

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12))
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

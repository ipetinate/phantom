import AppKit
import SwiftUI

/// The editable text surface.
///
/// An `NSTextView` behind `NSViewRepresentable` rather than SwiftUI's
/// `TextEditor`, and the reason is not taste. `TextEditor` binds to a
/// `String`: every keystroke sends the whole document through the binding
/// for SwiftUI to diff and reapply, which is O(file) per character typed.
/// A few hundred kilobytes in, typing visibly lags. It also hands out no
/// text storage, so there is nowhere to hang incremental highlighting, a
/// gutter, or anything else this needs.
///
/// ⚠️ **TextKit 2 is conditional.** `NSTextView` starts in TextKit 2, but
/// touching the legacy `.layoutManager` property makes AppKit silently fall
/// back to TextKit 1 for the rest of that view's life — and TextKit 1 lays
/// out the *entire* document instead of the viewport, which is exactly the
/// behavior this class exists to avoid. Reach for `textLayoutManager`; a
/// test asserts the view really is in TextKit 2.
struct CodeTextView: NSViewRepresentable {
    /// The minimap's width when shown. Named for the measurement rather than
    /// the view, because the coordinator already has a `minimapWidth`
    /// constraint and two things called the same thing is how the wrong one
    /// gets used.
    static let minimapColumnWidth: CGFloat = 70

    /// The text as the *host* last set it: loaded from disk, reverted,
    /// formatted, renamed. Not a binding, and not the live buffer — while
    /// you type, the buffer is ahead of this and that is correct.
    let text: String

    /// Bumped by the host whenever it replaces the text. The view applies
    /// `text` when this changes and at no other time.
    let textRevision: Int

    /// How this file is lexed, base language included.
    ///
    /// Not a bare `CodeLanguage`: a language an extension contributed has no
    /// case of its own, and passing only the base is what left such a file
    /// with a server but no colour.
    let syntax: LanguageSyntax

    /// Which markup this file is. Beside `language` rather than inside the
    /// configuration, because it describes the file and not the editor — see
    /// `CodeNSTextView.tagDialect`.
    var tagDialect: CodeTagDialect = .none

    /// Whether a server that completes class attributes is attached to this
    /// file. See `CodeClassAttribute`.
    ///
    /// Beside `tagDialect` rather than inside `CodeEditorConfiguration` for
    /// the same reason: that value is a preference held per editor, and this
    /// is a fact about one file — it changes when the document changes and
    /// again when a server finishes starting. A field there would also be
    /// compared by the `unchanged` guard, which is about what gets *drawn*.
    var completesInsideClassAttribute = false

    /// Whether the reader may type into this buffer.
    ///
    /// Beside `tagDialect` rather than inside `CodeEditorConfiguration` for
    /// the reason given there: that value is a preference held per editor,
    /// and this is a fact about the file in front of you right now — a
    /// document can become unwritable while it is open, and go back, without
    /// any preference moving.
    ///
    /// Defaults to `true`, so the only views that are read-only are the ones
    /// that asked to be. The engine does not know *why* — a file from a
    /// checkout the terminal has left, a revision being previewed — and it
    /// stays that way: it is told, it does not ask.
    var isEditable = true

    let theme: CodeTheme
    let configuration: CodeEditorConfiguration

    /// Called after the user changes the text, with what the buffer now
    /// holds.
    ///
    /// The text comes *out* through here rather than through a binding that
    /// goes both ways. A two-way binding is what `TextEditor` does, and the
    /// half that writes back into the view is what makes it destroy the
    /// selection and the undo stack — so this reports, and only the
    /// revision above can replace.
    var onEdit: (String) -> Void = { _ in }

    /// Ranges to underline, with the colour to use. Supplied as plain
    /// values so the engine never learns what a language server is.
    var underlines: [(range: NSRange, color: NSColor)] = []

    /// Asked what to say when the pointer rests on an offset.
    var hoverProvider: ((Int) async -> CodeHoverInfo?)?

    /// Asked what to offer at an offset, for the completion list.
    var completionProvider: ((Int) async -> CodeCompletionAnswer)?

    /// Asked to describe the highlighted row, for the documentation card.
    ///
    /// Separate from `completionProvider` because it is a second question
    /// asked about one row rather than more of the first answer: servers
    /// routinely withhold documentation from the list and only supply it when
    /// asked about a specific item, which is a request per selection change
    /// rather than per keystroke.
    var completionDocProvider: ((CodeCompletionItem) async -> CodeCompletionDocPanel.Outcome)?

    /// Whether a row gets an info glyph. See `CodeNSTextView` for why this is
    /// the host's question and not the item's.
    var completionOffersDocumentation: ((CodeCompletionItem) -> Bool)?

    /// The icon column's glyph font, as a value — the engine may not reach
    /// into the bundle to find it.
    var completionIconFont: NSFont?

    /// A range to select and scroll into view once. Carries an identity so
    /// the same range asked for twice still moves the view — jumping to a
    /// definition you are already looking at has to re-centre it, not do
    /// nothing.
    var reveal: (id: String, range: NSRange)?

    /// ⌘-click, and the editor commands the host implements.
    var onJumpToDefinition: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var onFindReferences: ((Int) -> Void)?
    var onFormat: (() -> Void)?

    /// Hands out the scroll view once it exists, for a host that needs to
    /// register it somewhere — keeping two panes' scrolling in step, say.
    ///
    /// A callback rather than the engine reaching for whatever it would be
    /// registered with. The rule here is that the engine takes what it needs
    /// as values; this is that rule read the other way round — it gives up
    /// what it owns and stays ignorant of what happens next.
    ///
    /// It also beats the alternative available to the host, which is
    /// searching the view hierarchy for a scroll view it cannot name. That
    /// search finds the wrong one silently when panes are nested, which is
    /// exactly the arrangement this exists to serve.
    var onScrollViewReady: ((NSScrollView) -> Void)?

    /// Keyboard commands the host owns. Passed in rather than assumed, so
    /// the engine never decides what saving means.
    /// Characters that open the completion list on their own.
    ///
    /// A value, because which ones they are is a fact about the language
    /// server and about the file — `.` nearly everywhere, `/` in Markdown for
    /// the snippet catalogue — and the engine is not allowed to know either.
    /// The view's own default keeps the dot working when nothing supplies it.
    var completionTriggers: Set<Character> = ["."]

    /// The reader's configured shortcuts, keyed by the app's action id.
    ///
    /// Passed through as values: the engine may not name the app's store, and
    /// a map is what "one command, several shortcuts" looks like from here.
    var commandShortcuts: [String: [EditorShortcut]] = [:]

    var onSave: () -> Void = {}
    var onSaveAll: () -> Void = {}
    var onCloseTab: () -> Void = {}
    var onSearchWorkspace: () -> Void = {}

    /// The selection, for the host to turn into an `@file:line` reference and
    /// type into a terminal. The range crosses rather than the string because
    /// which lines it covers is `EditorLineReference`'s judgement, and which
    /// terminal receives it is the host's — the engine holds neither.
    var onAttachLine: ((NSRange, String) -> Void)?
    var onAttachLinePicker: ((NSRange, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            storage: CodeTextStorage(
                syntax: syntax,
                theme: theme,
                configuration: configuration
            ),
            onEdit: onEdit
        )
    }

    func makeNSView(context: Context) -> NSView {
        let textView = CodeNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        /// Selectable whichever way that went: a read-only file is still one
        /// you copy out of, search in, and ⌘-click through.
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // The standard sizing recipe, and the half that was missing. A text
        // view can only grow up to `maxSize`, which defaults to its initial
        // frame — zero here — so without this it could never become wider
        // than the viewport and there was nothing for a horizontal scroller
        // to scroll. Vertical resizing is what lets it grow with the text.
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]

        // Neither the text view nor its scroll view paints a background.
        // The host puts a layer behind this whole pane, so whatever the
        // window is doing — a solid theme colour, or blur through to the
        // desktop — reaches the code the same way it reaches the terminal.
        textView.drawsBackground = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !configuration.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.useThinScrollers()
        scrollView.documentView = textView

        onScrollViewReady?(scrollView)

        // Gutter and text sit side by side in a container, rather than the
        // gutter being a ruler inside the scroll view. Separate areas can't
        // overlap, so nothing has to police where the numbers land.
        let gutter = CodeGutterView(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            font: configuration.font
        )
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.isHidden = !configuration.showsLineNumbers

        let minimap = CodeMinimapView(theme: theme, scrollView: scrollView)
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.isHidden = !configuration.showsMinimap
        // Scrolls, and only scrolls. The selection is the reader's, not the
        // map's — and this also drops a walk over every line of the document
        // that used to run on each event of a drag.
        minimap.onScrollToFraction = { [weak scrollView] fraction in
            guard let scrollView, let document = scrollView.documentView else { return }
            scrollView.contentView.scroll(to: NSPoint(
                x: scrollView.contentView.bounds.minX,
                y: Coordinator.scrollTarget(
                    fraction: fraction,
                    documentHeight: document.frame.height,
                    visibleHeight: scrollView.contentView.bounds.height
                )
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // The current-line band, under the text inside the clip view. The
        // clip view scrolls by moving its bounds, so everything in it —
        // document and band alike — moves together for free.
        let band = CurrentLineBandView()
        band.wantsLayer = true
        band.isHidden = true
        scrollView.contentView.addSubview(band, positioned: .below, relativeTo: textView)
        context.coordinator.currentLineBand = band

        let container = NSView()
        container.addSubview(gutter)
        container.addSubview(scrollView)
        container.addSubview(minimap)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let minimapWidth = minimap.widthAnchor.constraint(
            equalToConstant: configuration.showsMinimap ? Self.minimapColumnWidth : 0
        )
        let gutterWidth = gutter.widthAnchor.constraint(
            equalToConstant: configuration.showsLineNumbers ? gutter.preferredWidth : 0
        )
        gutter.onWidthChange = { width in
            gutterWidth.constant = gutter.isHidden ? 0 : width
        }

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutterWidth,
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            minimap.topAnchor.constraint(equalTo: container.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimapWidth,
        ])

        context.coordinator.gutterWidth = gutterWidth
        context.coordinator.minimap = minimap
        context.coordinator.minimapWidth = minimapWidth

        textView.onSave = onSave
        textView.onAttachLine = onAttachLine
        textView.onAttachLinePicker = onAttachLinePicker
        textView.onSaveAll = onSaveAll
        textView.onCloseTab = onCloseTab
        textView.onSearchWorkspace = onSearchWorkspace
        textView.onRename = onRename
        textView.onFindReferences = onFindReferences
        textView.onFormat = onFormat
        textView.commandShortcuts = commandShortcuts
        textView.completionTriggers = completionTriggers
        textView.completesInsideClassAttribute = completesInsideClassAttribute
        textView.onJumpToDefinition = onJumpToDefinition
        textView.hoverProvider = hoverProvider
        textView.completionProvider = completionProvider
        textView.completionDocProvider = completionDocProvider
        textView.completionOffersDocumentation = completionOffersDocumentation
        textView.completionIconFont = completionIconFont

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter

        // The gutter and the minimap already listen to this; the coordinator
        // needs it too, to colour a large document as it is scrolled into.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.applyIfNewRevision(text: text, revision: textRevision)
        context.coordinator.applyAppearance(
            theme: theme,
            configuration: configuration,
            dialect: tagDialect
        )

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let textView = context.coordinator.textView,
              let scrollView = textView.enclosingScrollView
        else { return }

        // Refreshed every update: the closures capture the document that
        // was selected when the view was made, and the selection moves.
        if let code = textView as? CodeNSTextView {
            code.onSave = onSave
            code.onAttachLine = onAttachLine
            code.onAttachLinePicker = onAttachLinePicker
            code.onSaveAll = onSaveAll
            code.onCloseTab = onCloseTab
            code.onSearchWorkspace = onSearchWorkspace
            code.onRename = onRename
            code.onFindReferences = onFindReferences
            code.onFormat = onFormat
            code.commandShortcuts = commandShortcuts
            code.completionTriggers = completionTriggers
            code.completesInsideClassAttribute = completesInsideClassAttribute
            code.onJumpToDefinition = onJumpToDefinition
            code.hoverProvider = hoverProvider
            code.completionProvider = completionProvider
            code.completionDocProvider = completionDocProvider
            code.completionOffersDocumentation = completionOffersDocumentation
            code.completionIconFont = completionIconFont
        }
        /// Reapplied every update, like the closures above it: a document can
        /// stop being writable while it is on screen — its terminal moves to
        /// a branch that has no such file — and the view is not rebuilt for
        /// that.
        textView.isEditable = isEditable
        context.coordinator.applyUnderlines(underlines)

        context.coordinator.storage.setSyntax(syntax)
        context.coordinator.applyAppearance(
            theme: theme,
            configuration: configuration,
            dialect: tagDialect
        )
        scrollView.hasHorizontalScroller = !configuration.wrapsLines

        // Applied when the *host* replaced the text, never because the two
        // differ.
        //
        // Comparing strings was the bug: as soon as anything was typed the
        // view held more than the host did, so the next SwiftUI update —
        // which happens for reasons that have nothing to do with this view —
        // read that difference as "the host has new content" and overwrote
        // the edits, insertion point back to zero. A revision the host bumps
        // when it means it says the one thing a comparison cannot: who
        // changed it.
        context.coordinator.applyIfNewRevision(text: text, revision: textRevision)

        // After the text, so a jump into a file that is being opened in the
        // same breath lands on a document that already has its content.
        if let reveal { context.coordinator.reveal(reveal) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let storage: CodeTextStorage
        let onEdit: (String) -> Void
        weak var textView: NSTextView?
        weak var gutter: CodeGutterView?
        var gutterWidth: NSLayoutConstraint?
        weak var minimap: CodeMinimapView?
        var minimapWidth: NSLayoutConstraint?
        weak var currentLineBand: CurrentLineBandView?

        /// The band's colour, or nil while the highlight is off.
        private var currentLineColor: NSColor?

        /// Set while the host is writing text in, so the delegate can tell
        /// a programmatic load from something the user typed.
        private var isApplyingExternalText = false

        /// The last reveal honoured, so a SwiftUI update that changes
        /// something unrelated doesn't drag the view back there.
        private var lastRevealID: String?

        /// The host revision currently in the buffer. Starts at a value no
        /// host will use, so the first update always loads.
        private var appliedRevision = Int.min

        /// The pending minimap rebuild. See `scheduleMinimapRefresh`.
        private var minimapTask: Task<Void, Never>?

        /// Whether this document is too big to colour in one go.
        ///
        /// Highlighting is one regex pass over everything it is given, and
        /// on a generated module interface — tens of thousands of lines,
        /// which is precisely where go-to-definition lands — that pass is
        /// the pause between clicking and seeing the file. Past this size
        /// only what you are looking at is coloured, and the rest follows as
        /// you scroll to it.
        private var highlightsOnDemand = false
        private var highlightTask: Task<Void, Never>?

        /// Around a quarter of a megabyte: comfortably above any file a
        /// person wrote by hand, and well below the generated ones.
        private static let wholeDocumentBudget = 256 * 1024

        /// The underlines currently drawn, so an update that changed
        /// something else doesn't walk the whole document to redraw marks
        /// that haven't moved.
        private var appliedUnderlines: [NSRange] = []

        /// The bracket spans currently coloured, guarded the same way.
        private var appliedBrackets: [BracketDepth.Span] = []

        /// The pair currently washed, guarded the same way again — a caret
        /// crossing a word moves through a dozen offsets that are on no
        /// bracket at all, and none of them should rewrite an attribute.
        private var appliedBracketMatch: BracketMatch.Pair?

        /// The look currently applied, so an update that changed something
        /// else doesn't rewrite every attribute in the document.
        private var appliedTheme: CodeTheme?
        private var appliedConfiguration: CodeEditorConfiguration?

        init(storage: CodeTextStorage, onEdit: @escaping (String) -> Void) {
            self.storage = storage
            self.onEdit = onEdit
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Replaces the buffer only when the host says it has new content.
        func applyIfNewRevision(text: String, revision: Int) {
            guard revision != appliedRevision else { return }
            appliedRevision = revision
            apply(text: text)
        }

        func apply(text: String) {
            guard let textView, let textStorage = textView.textStorage else { return }
            isApplyingExternalText = true
            defer { isApplyingExternalText = false }

            textStorage.setAttributedString(NSAttributedString(string: text))

            highlightsOnDemand = textStorage.length > Self.wholeDocumentBudget
            if highlightsOnDemand {
                highlightVisibleRegion()
            } else {
                let full = NSRange(location: 0, length: textStorage.length)
                storage.highlight(textStorage, in: full)
                colorBrackets(in: full)
            }

            gutter?.reload()
            scheduleMinimapRefresh()

            // Put the view back at the start of the document.
            //
            // Replacing the storage leaves the scrollers wherever they
            // were, and with wrapping off the container is effectively
            // infinitely wide — so a file opened into a view that had been
            // scrolled arrived showing the middle of its lines, with the
            // left edge of every one of them cut off. It reads as a
            // rendering fault rather than a scroll position.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollToOrigin()

            // And again once layout has settled.
            //
            // The first call runs while the view still has no real frame —
            // a scroll view with zero bounds has nowhere to scroll *to*,
            // so the request is silently a no-op, and the position AppKit
            // arrives at after laying out is whatever it had before. Doing
            // it on the next turn is what actually moves it, and doing it
            // twice costs nothing when the first one already worked.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToOrigin()
            }
        }

        /// Where to scroll so a fraction of the document sits in the middle
        /// of the viewport.
        ///
        /// Centred, because the pointer is asking to *look* at that part of
        /// the file, and clamped so dragging to either end of the map stops
        /// at the ends of the document instead of overscrolling into blank
        /// space.
        static func scrollTarget(
            fraction: CGFloat,
            documentHeight: CGFloat,
            visibleHeight: CGFloat
        ) -> CGFloat {
            let scrollable = max(0, documentHeight - visibleHeight)
            let centred = fraction * documentHeight - visibleHeight / 2
            return min(scrollable, max(0, centred))
        }

        /// Colours what is on screen, plus a margin either side.
        ///
        /// The margin is what makes scrolling look continuous rather than
        /// like colour arriving behind the text.
        func highlightVisibleRegion() {
            guard let textView,
                  let textStorage = textView.textStorage,
                  let scrollView = textView.enclosingScrollView
            else { return }

            let visible = scrollView.contentView.bounds
            guard visible.height > 0 else { return }

            let top = textView.characterIndexForInsertion(
                at: NSPoint(x: 0, y: visible.minY)
            )
            let bottom = textView.characterIndexForInsertion(
                at: NSPoint(x: textView.bounds.width, y: visible.maxY)
            )
            let lower = max(0, min(top, bottom))
            let upper = min(textStorage.length, max(top, bottom))
            guard upper > lower else { return }

            let region = CodeTextStorage.invalidationRange(
                for: NSRange(location: lower, length: upper - lower),
                in: textStorage.string as NSString
            )
            storage.highlight(textStorage, in: region)
            colorBrackets(in: region)
        }

        /// Colours the brackets in a region by nesting depth.
        ///
        /// A pass of its own, because depth is counted and the highlighter's
        /// single regex cannot count. Runs after the syntax colours so it
        /// paints over them — a bracket is punctuation, and whatever rule
        /// happened to claim it has nothing to say about which pair it is.
        ///
        /// The `defer` repaints the caret's pair, whose wash is one of the
        /// attributes a colouring pass resets. It covers every exit below,
        /// including the one that finds the depths unchanged — the depths
        /// surviving a recolour says nothing about whether the wash did.
        func colorBrackets(in region: NSRange) {
            defer {
                clearBracketMatch()
                highlightBracketMatch()
            }

            guard let textView, let textStorage = textView.textStorage else { return }
            guard storage.configuration.colorsBracketPairs else {
                if !appliedBrackets.isEmpty {
                    appliedBrackets = []
                }
                return
            }

            let text = textStorage.string as NSString
            // The tokens the highlighter already produced, so a brace inside
            // a string or a comment doesn't open a level that never closes.
            let skipped = SyntaxHighlighter(syntax: storage.syntax)
                .tokens(in: textStorage.string, range: region)
                .filter { $0.kind == .string || $0.kind == .comment }
                .map(\.range)

            let spans = BracketDepth.spans(in: text, range: region, skipping: skipped)
            guard spans != appliedBrackets else { return }
            appliedBrackets = spans

            let colors = storage.theme.bracketColors
            guard !colors.isEmpty else { return }

            textStorage.beginEditing()
            for span in spans {
                let clipped = NSIntersectionRange(
                    span.range,
                    NSRange(location: 0, length: textStorage.length)
                )
                guard clipped.length > 0 else { continue }
                textStorage.addAttribute(
                    .foregroundColor,
                    value: colors[BracketDepth.slot(for: span.depth)],
                    range: clipped
                )
            }
            textStorage.endEditing()
            requestRedraw(of: textView)
        }

        /// Washes the bracket under the caret and the one that closes it.
        ///
        /// The depth colours say how deeply a bracket is nested; this says
        /// *which other one it is*, which is the question a block running off
        /// the bottom of the screen actually raises. The rule itself is
        /// `BracketMatch` and is pure — everything here is the part that has
        /// a text storage in it.
        ///
        /// Gated on the same switch as the depth colours: both are the
        /// editor drawing on brackets, and somebody who turned that off did
        /// not ask for half of it back.
        func highlightBracketMatch() {
            guard let textView, let textStorage = textView.textStorage else { return }

            let found = matchedPair(in: textStorage, of: textView)
            guard found != appliedBracketMatch else { return }

            clearBracketMatch()
            guard let found else {
                requestRedraw(of: textView)
                return
            }

            textStorage.beginEditing()
            for range in found.ranges {
                let clipped = NSIntersectionRange(
                    range,
                    NSRange(location: 0, length: textStorage.length)
                )
                guard clipped.length > 0 else { continue }
                textStorage.addAttribute(
                    .backgroundColor,
                    value: storage.theme.bracketMatchBackground,
                    range: clipped
                )
            }
            textStorage.endEditing()

            appliedBracketMatch = found
            requestRedraw(of: textView)
        }

        /// Lifts the wash currently painted, wherever it is.
        ///
        /// By remembered range rather than over the region being redrawn: the
        /// partner of a bracket is routinely off screen, so a pass that only
        /// cleared what it was recolouring would leave a wash behind on a
        /// bracket the caret left a scroll ago.
        private func clearBracketMatch() {
            guard let applied = appliedBracketMatch else { return }
            appliedBracketMatch = nil

            guard let textStorage = textView?.textStorage else { return }
            textStorage.beginEditing()
            for range in applied.ranges {
                let clipped = NSIntersectionRange(
                    range,
                    NSRange(location: 0, length: textStorage.length)
                )
                guard clipped.length > 0 else { continue }
                textStorage.removeAttribute(.backgroundColor, range: clipped)
            }
            textStorage.endEditing()
        }

        /// The pair to wash, or `nil` when there is nothing to say.
        ///
        /// Only a window around the caret is lexed, and the search is bounded
        /// to the same window: this runs on every caret move, and lexing a
        /// megabyte per arrow key is exactly the cost `BracketMatch`'s bound
        /// exists to avoid. The window inherits the limitation the viewport
        /// pass already documents — one that opens inside a multi-line string
        /// cannot know it, so a brace in there may still be counted — which is
        /// the same trade the depth colours have always made.
        ///
        /// A selection rather than a caret means nothing: the reader is
        /// choosing text, not standing on a bracket, and two washed characters
        /// inside a highlighted range read as a rendering fault.
        private func matchedPair(
            in textStorage: NSTextStorage,
            of textView: NSTextView
        ) -> BracketMatch.Pair? {
            guard storage.configuration.colorsBracketPairs else { return nil }

            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }

            let text = textStorage.string as NSString
            let caret = min(selection.location, text.length)
            let window = CodeTextStorage.invalidationRange(
                for: NSRange(location: caret, length: 0),
                in: text,
                padding: BracketMatch.searchLimit
            )
            let skipped = SyntaxHighlighter(syntax: storage.syntax)
                .tokens(in: textStorage.string, range: window)
                .filter { $0.kind == .string || $0.kind == .comment }
                .map(\.range)

            return BracketMatch.pair(in: text, caret: caret, skipping: skipped)
        }

        /// Asks for a redraw after attributes changed in bulk.
        ///
        /// **Display only, deliberately.** The first version of this
        /// invalidated the *layout* of the whole document, on the theory that
        /// stale fragments were what made text blink out. It was a guess, it
        /// was never shown to fix anything, and it broke the gutter outright:
        /// the gutter draws by walking laid-out fragments, so throwing the
        /// layout away on every colouring pass left it walking nothing and the
        /// line numbers vanished.
        ///
        /// Changing attributes does not change layout — `beginEditing` and
        /// `endEditing` already tell the layout manager what happened. All that
        /// is owed here is a repaint.
        private func requestRedraw(of textView: NSTextView) {
            textView.needsDisplay = true
            gutter?.needsDisplay = true
        }

        /// Re-colours after a scroll settles, for a document being coloured
        /// on demand. Debounced: a flick of the wheel is one destination,
        /// not forty.
        @objc func scrolled() {
            snapOutOfTheLeftMargin()
            guard highlightsOnDemand else { return }
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.highlightVisibleRegion()
            }
        }

        /// Puts the text back against the left edge when something has left it
        /// scrolled into its own margin.
        ///
        /// Entering native fullscreen does exactly that: the clip view comes
        /// back with `bounds.origin.x == 9` — the text container inset plus the
        /// container's line fragment padding — while the text view's frame, the
        /// container, the insets and the viewport all read identically to the
        /// windowed layout. Measured, not inferred; that one number was the
        /// whole difference. The first character of every line is then drawn
        /// left of what the clip shows, and it survives leaving fullscreen,
        /// because nothing lays the view out again until the tab is switched —
        /// which is why switching tabs appeared to "fix" it.
        ///
        /// Snapping is a correction rather than a preference: there is no text
        /// to the left of the first glyph, so any offset inside the margin
        /// hides a column and reveals nothing. Real horizontal scrolling starts
        /// past the margin and is left alone. The cost is that dragging the
        /// scroller through those few points settles at zero instead of inside
        /// them, which is the same thing the reader wanted anyway.
        private func snapOutOfTheLeftMargin() {
            guard let textView,
                  let scrollView = textView.enclosingScrollView,
                  let container = textView.textContainer
            else { return }
            let clipView = scrollView.contentView
            guard let corrected = Self.horizontalSnap(
                offset: clipView.bounds.origin.x,
                margin: textView.textContainerInset.width + container.lineFragmentPadding
            ) else { return }

            clipView.scroll(to: NSPoint(x: corrected, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Where a horizontal offset inside the left margin should go, or nil
        /// when the offset is a real scroll position and must not be touched.
        static func horizontalSnap(offset: CGFloat, margin: CGFloat) -> CGFloat? {
            guard offset > 0, offset <= margin else { return nil }
            return 0
        }

        /// Rebuilds the minimap shortly, rather than now.
        ///
        /// The rebuild tokenises the **whole** document — a second full pass
        /// on top of the one that colours the text. Doing it inline meant
        /// paying it twice to open a file and once per keystroke, which on a
        /// fifty-thousand-line generated interface is exactly the pause that
        /// made going to a definition feel broken. The map is an overview:
        /// arriving a moment after the text is not a compromise, and while
        /// you type it only needs to settle when you stop.
        func scheduleMinimapRefresh() {
            guard let minimap, !minimap.isHidden else { return }
            minimapTask?.cancel()
            minimapTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.refreshMinimap()
            }
        }

        /// Recomputes the minimap's bars from the current text.
        ///
        /// Reuses the tokens the highlighter already produces rather than
        /// scanning again — the map is a second view of the same answer.
        func refreshMinimap() {
            guard let minimap, minimap.isHidden == false, let textView else { return }
            let text = textView.string
            let tokens = SyntaxHighlighter(syntax: storage.syntax)
                .tokens(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            minimap.setRows(CodeMinimapView.rows(for: text, tokens: tokens))
        }

        /// Selects a range and brings it into view, centred.
        ///
        /// Centred rather than merely visible: `scrollRangeToVisible` does
        /// the least it can, so a definition one line below the fold lands
        /// on the very last row — technically visible, and with none of the
        /// surrounding code that makes it readable.
        func reveal(_ reveal: (id: String, range: NSRange)) {
            guard reveal.id != lastRevealID, let textView else { return }
            lastRevealID = reveal.id

            let length = (textView.string as NSString).length
            let clipped = NSRange(
                location: min(reveal.range.location, length),
                length: min(reveal.range.length, max(0, length - reveal.range.location))
            )

            textView.setSelectedRange(clipped)
            textView.scrollRangeToVisible(clipped)
            if highlightsOnDemand { highlightVisibleRegion() }

            // Once layout has settled, for the same reason opening a file
            // needs a second scroll: the first runs before the view has the
            // frame it would be scrolling within.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let scrollView = textView.enclosingScrollView else { return }
                let rect = textView.firstRect(forCharacterRange: clipped, actualRange: nil)
                guard rect.height > 0 else { return }
                let local = textView.convert(
                    textView.window?.convertFromScreen(rect) ?? .zero,
                    from: nil
                )
                let target = max(0, local.midY - scrollView.contentView.bounds.height / 2)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Puts the text back at its top-left corner.
        private func scrollToOrigin() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            gutter?.needsDisplay = true
        }

        /// Draws the diagnostic underlines on top of the syntax colours.
        ///
        /// Applied as a separate pass rather than folded into highlighting:
        /// the two change for unrelated reasons — one when you type, the
        /// other when a server answers — and a single pass would mean
        /// re-tokenising the document every time a diagnostic arrived.
        func applyUnderlines(_ underlines: [(range: NSRange, color: NSColor)]) {
            guard let textView, let storage = textView.textStorage else { return }

            // SwiftUI updates this view for reasons that have nothing to do
            // with diagnostics — a theme change, a resize, a keystroke —
            // and each pass here walks the whole document. Skipping the
            // unchanged case is what keeps that off the typing path.
            let ranges = underlines.map(\.range)
            guard ranges != appliedUnderlines else { return }
            appliedUnderlines = ranges

            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            for underline in underlines {
                let clipped = NSIntersectionRange(underline.range, full)
                guard clipped.length > 0 else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: underline.color,
                ], range: clipped)
            }
            storage.endEditing()
        }

        func applyAppearance(
            theme: CodeTheme,
            configuration: CodeEditorConfiguration,
            dialect: CodeTagDialect
        ) {
            guard let textView else { return }

            // Nothing to do unless the look actually changed.
            //
            // This used to re-colour the **whole document** on every SwiftUI
            // update, and SwiftUI updates for reasons that have nothing to do
            // with appearance — including saving, which publishes the text.
            // Rewriting every attribute made TextKit 2 discard the laid-out
            // viewport and move the insertion point, which is exactly the
            // "⌘S blanks the top of the file and the cursor jumps a line"
            // that was reported.
            let unchanged = appliedTheme == theme && appliedConfiguration == configuration
            appliedTheme = theme
            appliedConfiguration = configuration

            storage.theme = theme
            storage.configuration = configuration

            // Applied every time, guard or no guard: these are constants on
            // constraints and a hidden flag, and they cost nothing.
            //
            // They also *have* to be, and that is the subtle part. The gutter's
            // width comes from its own content, which is unknown the first time
            // through — a document with no text yet measures zero. Running only
            // once meant the width stayed at that zero and the line numbers
            // never appeared. The old code got away with it by re-running on
            // every update; the repair was accidental, so here it is on purpose.
            gutter?.isHidden = !configuration.showsLineNumbers
            gutterWidth?.constant = configuration.showsLineNumbers
                ? (gutter?.preferredWidth ?? 0)
                : 0

            minimap?.isHidden = !configuration.showsMinimap
            minimapWidth?.constant = configuration.showsMinimap
                ? CodeTextView.minimapColumnWidth
                : 0

            gutter?.theme = theme
            minimap?.theme = theme

            // The hover card paints itself with the editor's own colours and
            // the file's language, so it has to be told both. Outside the
            // guard for the same reason as the two above: a card built with a
            // stale theme is a card in the wrong colours.
            //
            // The auto-closing switches are here rather than below for a
            // different reason, and it is worth stating because inside the
            // guard they would appear to work. `unchanged` compares the whole
            // configuration, so toggling one of these *is* a change and would
            // pass — right up until someone adds a field that changes for an
            // unrelated reason and starts absorbing the comparison. Then a
            // switch silently stops taking effect until the file is reopened,
            // which is precisely the bug `showsMinimap` above documents.
            // Behaviour that decides what gets typed does not belong behind a
            // guard about what gets drawn.
            if let code = textView as? CodeNSTextView {
                code.hoverTheme = theme
                code.hoverLanguage = storage.language
                code.closesBrackets = configuration.closesBrackets
                code.closesQuotes = configuration.closesQuotes
                code.closesTags = configuration.closesTags
                code.tagDialect = dialect
                code.completionEnabled = configuration.completionEnabled
                code.completesFromBuffer = configuration.completesFromBuffer
                code.completionFetchDelay = configuration.completionFetchDelay
                code.insertsSpacesForTab = configuration.insertsSpacesForTab
                code.tabWidth = configuration.tabWidth
            }

            // Everything below rewrites attributes or re-lays out the document,
            // which is what must not happen on an unrelated update.
            guard !unchanged else { return }

            textView.font = configuration.font
            textView.insertionPointColor = theme.foreground
            textView.textColor = theme.foreground
            currentLineColor = configuration.highlightsCurrentLine
                ? theme.currentLineBackground
                : nil
            updateCurrentLineBand()

            // Horizontal scrolling, when lines are not wrapped.
            //
            // `autoresizingMask` containing `.width` ties the text view to the
            // clip view's width, so it can never be wider than what is on
            // screen — and a scroll view does not scroll to somewhere its
            // document does not reach. A long line was simply cut off at the
            // right edge with no scroller to bring the rest in.
            textView.textContainer?.widthTracksTextView = configuration.wrapsLines
            let viewportWidth = textView.enclosingScrollView?.contentSize.width
                ?? textView.frame.width
            if configuration.wrapsLines {
                // Wrapping means the view is exactly as wide as the viewport
                // and the container follows it. The frame reset is the part
                // that was missing: coming from the unwrapped state the view
                // is as wide as its longest line, autoresizing only reacts to
                // the *superview* changing, and a container tracking that
                // stale width wraps at a point far past the window's edge —
                // which reads as "wrap on, text still cut off".
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.setFrameSize(NSSize(
                    width: viewportWidth,
                    height: textView.frame.height
                ))
                textView.textContainer?.size = NSSize(
                    width: viewportWidth,
                    height: .greatestFiniteMagnitude
                )
            } else {
                // Unwrapped, the view grows to its longest line — that width
                // being wider than the viewport is what horizontal scrolling
                // *is* — and never below the viewport, so short files still
                // fill the pane.
                textView.autoresizingMask = []
                textView.isHorizontallyResizable = true
                textView.minSize = NSSize(width: viewportWidth, height: 0)
                textView.textContainer?.size = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }

            gutter?.font = configuration.font
            if configuration.showsMinimap { refreshMinimap() }

            guard let textStorage = textView.textStorage else { return }

            // The selection is the reader's and must survive a recolour. A
            // full rewrite of the attributes moves it otherwise, which is how
            // the cursor climbed a line on save.
            let selection = textView.selectedRange()

            if highlightsOnDemand {
                highlightVisibleRegion()
            } else {
                let full = NSRange(location: 0, length: textStorage.length)
                storage.highlight(textStorage, in: full)
                colorBrackets(in: full)
            }

            if selection.location <= textStorage.length {
                textView.setSelectedRange(selection)
            }

            requestRedraw(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // The band follows the cursor, and so does the highlighted number
            // in the gutter — both are the same fact drawn in two places.
            gutter?.setCurrentLine(currentLineNumber(in: textView))
            updateCurrentLineBand()
            highlightBracketMatch()
        }

        /// Moves the band to the line the insertion point is on.
        ///
        /// Geometry comes from the **caret's own rect**, not from a layout
        /// fragment. The fragment version highlighted the line *below* the
        /// cursor whenever the line had content — asking the layout manager
        /// for "the fragment at this location" and asking the view "where is
        /// the insertion point" can disagree, and the insertion point is the
        /// thing the reader sees. Where the caret is drawn is, by definition,
        /// where the band belongs.
        ///
        /// That rect is only the truth once the caret's line has been laid
        /// out — see `layOutAroundCaret`, which is why the caret is measured
        /// and not guessed at.
        func updateCurrentLineBand() {
            guard let band = currentLineBand, let textView else { return }
            let selection = textView.selectedRange()
            guard let color = currentLineColor,
                  selection.length == 0,
                  let window = textView.window,
                  let clipView = band.superview
            else {
                band.isHidden = true
                return
            }

            Self.layOutAroundCaret(in: textView, caret: selection.location)

            // Screen → window → clip view, the same trip `reveal` makes.
            let onScreen = textView.firstRect(forCharacterRange: selection, actualRange: nil)
            let inClip: NSRect
            if onScreen.height > 0 {
                inClip = clipView.convert(window.convertFromScreen(onScreen), from: nil)
            } else if let laidOut = Self.caretRectInView(of: textView, caret: selection.location) {
                inClip = clipView.convert(laidOut, from: textView)
            } else {
                band.isHidden = true
                return
            }

            band.layer?.backgroundColor = color.cgColor
            band.frame = Self.bandFrame(
                caret: inClip,
                documentWidth: textView.bounds.width,
                clipWidth: clipView.bounds.width
            )
            band.isHidden = false
        }

        /// Lays out the caret's surroundings before anyone asks where the
        /// caret is.
        ///
        /// TextKit 2 answers a geometry question inside an *invalidated* range
        /// with an estimate — a position interpolated across the range —
        /// rather than by laying the range out. The estimate barely moves
        /// while the caret does, so the band fell a line further behind on
        /// every Enter: not one stale measurement but a guess that never
        /// catches up. Editing alone does not cause this. Re-colouring does:
        /// `textDidChange` rewrites the attributes around the edit — over a
        /// range that reaches thousands of characters *above* it, see
        /// `CodeTextStorage.invalidationRange` — and the band is measured
        /// directly afterwards.
        ///
        /// **Bounded, and no wider than it has to be.** Two narrower ranges
        /// were tried on screen and rejected by what they drew. The caret's
        /// own line alone leaves the bug exactly as it was — the band moves
        /// 12px on the first Enter and then stops, which is the original
        /// symptom — because the estimate is anchored *above* the caret and
        /// laying out one line inside an invalid region does not make that
        /// anchor real. Ensuring from the start of the document instead does
        /// fix it, and costs 2.5 ms per keystroke at 5 000 lines and 10 ms at
        /// 20 000 — measured, linear in the file, on a path that runs twice
        /// per keystroke. So the range is the one that made the layout
        /// invalid in the first place: the same window `highlight` was handed,
        /// clipped to end at the caret. Its width is a constant, so the cost
        /// is flat in the size of the file, and it reaches the last fragment
        /// the re-colouring left alone — which is the anchor the caret's
        /// position is measured from. Anything wider needs a measurement
        /// before it goes in, and anything narrower needs the screenshots.
        private static func layOutAroundCaret(in textView: NSTextView, caret: Int) {
            guard let layout = textView.textLayoutManager,
                  let content = layout.textContentManager
            else { return }
            let text = textView.string as NSString
            let line = text.paragraphRange(
                for: NSRange(location: min(caret, text.length), length: 0)
            )
            let invalidated = CodeTextStorage.invalidationRange(for: line, in: text)
            let start = content.documentRange.location
            guard let from = content.location(start, offsetBy: invalidated.location),
                  let to = content.location(start, offsetBy: line.location + line.length),
                  let range = NSTextRange(location: from, end: to)
            else { return }
            layout.ensureLayout(for: range)
        }

        /// Where the caret is, asked of the layout manager instead of the view.
        ///
        /// `firstRect(forCharacterRange:)` returns nothing for an empty range
        /// at the very end of the document — and a file that ends in a newline
        /// shows one more line than it has text for, so that position is the
        /// last line of nearly every file in this repo. The band was hidden
        /// there, on the one line a reader is most likely to be sitting on
        /// while typing at the end of a file. The layout manager does answer:
        /// it reports a segment for that position, in the text container's
        /// space, which `textContainerOrigin` puts back in the view's.
        ///
        /// Consulted **only** when the view has already declined, so the rule
        /// the doc comment above records — the band follows the caret's own
        /// rect, never a fragment lookup — still decides every line that has
        /// text on it.
        private static func caretRectInView(of textView: NSTextView, caret: Int) -> NSRect? {
            guard let layout = textView.textLayoutManager,
                  let content = layout.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: caret),
                  let empty = NSTextRange(location: location, end: location)
            else { return nil }

            var caretFrame: NSRect?
            layout.enumerateTextSegments(in: empty, type: .standard) { _, frame, _, _ in
                caretFrame = frame
                return false
            }
            guard let caretFrame, caretFrame.height > 0 else { return nil }

            let origin = textView.textContainerOrigin
            return caretFrame.offsetBy(dx: origin.x, dy: origin.y)
        }

        /// The band's frame in the clip view, given where the caret is in it.
        ///
        /// Full width, and the widest of the three on purpose. The document is
        /// only as wide as its longest line, so a band that stopped there would
        /// stop mid-viewport on a file of short lines — hence the viewport.
        ///
        /// **And the caret, because the document's width lags a keystroke
        /// behind.** Measured: on the longest line of a file, typing twenty
        /// characters leaves `bounds.width` at 2233pt inside `didChangeText`
        /// — which is where the band is measured — while the caret has already
        /// moved to 2377. The document view is resized in the layout pass,
        /// which happens *after* the edit is announced, so the band ended
        /// 144pt short of the caret and fell further behind with every
        /// keystroke. Widening it to the caret is what makes the band's own
        /// correctness independent of when that pass runs, which is not
        /// something this can know from here.
        static func bandFrame(
            caret: NSRect,
            documentWidth: CGFloat,
            clipWidth: CGFloat
        ) -> NSRect {
            NSRect(
                x: 0,
                y: caret.minY,
                width: max(documentWidth, clipWidth, caret.maxX),
                height: caret.height
            )
        }

        /// The one-based line the insertion point is on.
        ///
        /// Counted as newlines *before* the caret. The `.byLines` version
        /// enumerated the partial line the caret sits in as well, so any
        /// caret past a line's first character reported the line below —
        /// while an empty line, having no partial content, came out right.
        /// That asymmetry was exactly the reported bug.
        private func currentLineNumber(in textView: NSTextView) -> Int? {
            guard textView.selectedRange().length == 0 else { return nil }
            let text = textView.string as NSString
            let caret = min(textView.selectedRange().location, text.length)

            var line = 1
            var search = NSRange(location: 0, length: caret)
            while search.length > 0 {
                let found = text.range(of: "\n", options: [], range: search)
                guard found.location != NSNotFound else { break }
                line += 1
                let next = found.location + 1
                search = NSRange(location: next, length: caret - next)
            }
            return line
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage
            else { return }

            let edited = textView.selectedRange()
            let region = CodeTextStorage.invalidationRange(
                for: edited,
                in: textStorage.string as NSString
            )
            storage.highlight(textStorage, in: region)
            // Typing a brace changes the depth of everything after it, so
            // the whole document's colours are stale — but recolouring all of
            // it per keystroke is the cost this editor exists to avoid. The
            // visible region is what a reader can see being wrong.
            colorBrackets(in: region)
            gutter?.reload()
            scheduleMinimapRefresh()
            updateCurrentLineBand()
            onEdit(textView.string)
        }
    }
}

/// The band behind the line the cursor is on.
///
/// A view *underneath* the text, not drawing inside it. The first version
/// overrode `NSTextView.draw(_:)` — and overriding `draw` is one of the
/// things that silently drops an `NSTextView` to TextKit 1 (proved by probe:
/// a plain subclass with only that override loses `textLayoutManager`). The
/// gutter walks TextKit 2 fragments, so that override made the line numbers
/// vanish while the text kept rendering. This view lives in the scroll
/// view's clip view, below the document, where it can paint anything without
/// TextKit ever knowing.
final class CurrentLineBandView: NSView {
    override var isFlipped: Bool { true }

    /// Clicks belong to the text above; this is paint, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The text view itself, kept as a named subclass so the tab and save
/// key handling in the host has something to attach to — and so a test can
/// assert it came up in TextKit 2.
final class CodeNSTextView: NSTextView {
    /// ⌘S, ⇧⌘S and ⌘W, supplied by the host.
    ///
    /// Handled here rather than by a window- or app-level monitor because
    /// this view is only in the responder chain while it has focus — which
    /// makes "the editor gets these keys only when the editor is being
    /// used" a property of where the code lives instead of a condition
    /// somebody has to remember to check. ⌘W closes a terminal tab
    /// otherwise, and getting that wrong breaks the app.
    var onSave: (() -> Void)?
    var onSaveAll: (() -> Void)?
    var onCloseTab: (() -> Void)?

    /// ⇧⌘F. Plain ⌘F is deliberately left to the find bar this view
    /// already has — replacing a working in-file search with a worse one
    /// would be a downgrade dressed as a feature.
    var onSearchWorkspace: (() -> Void)?

    /// ⌘K and ⇧⌘K, carrying the selection out for the host to reference.
    ///
    /// The live text travels with the range: while somebody types, the buffer
    /// runs ahead of the host's copy, and lines counted against the stale
    /// text would name the wrong ones.
    var onAttachLine: ((NSRange, String) -> Void)?
    var onAttachLinePicker: ((NSRange, String) -> Void)?

    /// The host's language features, reached by keyboard or ⌘-click.
    var onRename: ((Int) -> Void)?
    var onFindReferences: ((Int) -> Void)?
    var onFormat: (() -> Void)?

    /// The shortcuts the reader configured, keyed by the app's action id.
    ///
    /// Handed in as values rather than read from a store, because this view
    /// lives inside the engine and may not name the app. Empty means "nothing
    /// configured", and every command falls back to the combination it has
    /// always had — so an editor with no host wiring still works.
    var commandShortcuts: [String: [EditorShortcut]] = [:]
    var onJumpToDefinition: ((Int) -> Void)?
    var hoverProvider: ((Int) async -> CodeHoverInfo?)?
    var completionProvider: ((Int) async -> CodeCompletionAnswer)?
    var completionDocProvider: ((CodeCompletionItem) async -> CodeCompletionDocPanel.Outcome)?

    /// Whether a row is worth offering an info glyph on.
    ///
    /// Asked of the host because the honest answer is about the *server* — it
    /// is "this row can be asked about", not "this row has prose", and for
    /// most servers the prose does not exist until a second request has been
    /// made. The engine is not allowed to know that a second request is a
    /// thing, so the host collapses what it knows into a yes or a no.
    var completionOffersDocumentation: ((CodeCompletionItem) -> Bool)?

    /// The glyph font for the icon column, handed in as a value.
    ///
    /// The engine cannot go and find it: it is a resource in the app bundle,
    /// and reaching `Bundle.main` from here is the dependency this whole side
    /// of the code is arranged to avoid. Nil is a supported state — the list
    /// falls back to system symbols, so a font that failed to register costs
    /// prettier icons and nothing else.
    var completionIconFont: NSFont?

    /// The card beside the list, and the request behind it.
    private var documentationPanel: CodeCompletionDocPanel?
    private var documentationState: CodeCompletionDocPanel.State = .hidden
    private var documentationTask: Task<Void, Never>?

    /// Whether the reader has asked for the card. Separate from the panel's
    /// own visibility because the card is legitimately empty for a server
    /// that answers no documentation, and "asked for and empty" has to
    /// survive the selection moving to a row that does have some.
    private var isShowingDocumentation = false

    /// How long the caret rests before the list asks for suggestions.
    ///
    /// A `var` for the same reason `hoverFetchDelay` is one: a timing test
    /// has to be able to state its own ratio rather than bet that a fixed
    /// value stays comfortably larger than a sleep on a machine running the
    /// rest of the suite in parallel.
    ///
    /// 120ms sits under the ~150ms where a suggestion starts reading as late,
    /// and above one keystroke interval for a fast typist — so a burst
    /// coalesces into one request instead of one per character. An explicit
    /// request and a trigger character both skip it: each is already a pause.
    var completionFetchDelay: Duration = .milliseconds(120)

    /// How many identifier characters open the list on their own.
    ///
    /// One, matching VS Code, and chosen deliberately over the safer two: at
    /// a single character the list is large, so the *ordering* is the entire
    /// experience. That is why `CodeCompletionFilter` scores a word-boundary
    /// match so highly and handicaps buffer words against server answers.
    var completionMinimumPrefix = 1

    /// Trigger characters the server advertised — `.` almost everywhere,
    /// plus `"`, `'`, `/`, `@` and `<` for TypeScript.
    ///
    /// Supplied as a value rather than hardcoded, because it is a fact about
    /// the language server and the engine is not allowed to know which one is
    /// running. The default keeps the dot working when nothing supplies it.
    var completionTriggers: Set<Character> = ["."]

    /// Whether one of the attached servers completes the inside of a class
    /// attribute — Tailwind's, today.
    ///
    /// Lifts the string-and-comment suppression for that one place, and
    /// widens what counts as the run being completed while it is there: see
    /// `CodeClassAttribute` for both, and `CodeCompletionTrigger.decide` for
    /// where in the order of rules it sits.
    var completesInsideClassAttribute = false

    /// The list currently on screen, if any.
    private var completionSession: CompletionSession?

    /// Built on first use and kept, so a burst of typing reuses one window
    /// rather than making and destroying one per keystroke.
    private(set) var completionPanel: CodeCompletionPanel?

    /// The in-flight fetch. Cancelled on every new one, rather than dropped —
    /// dropping the *new* request is what the version this replaces did, and
    /// it meant the answer on screen was always the one for a prefix the
    /// reader had already moved past.
    private var completionTask: Task<Void, Never>?

    /// Bumped by every open and every close, so an answer that arrives after
    /// the world moved can be recognised and discarded. The caret alone is
    /// not enough: it can return to where it was.
    private var completionGeneration = 0

    /// The offset the pointer last rested on, so the card describes what is
    /// under it rather than what the cursor happens to be near.
    private var hoverOffset: Int?
    private var hoverTask: Task<Void, Never>?

    /// Where on screen the word the card describes is drawn.
    ///
    /// Held rather than recomputed because the question every close asks is
    /// "is the pointer still hovering?", and answering it needs the *word* as
    /// well as the card: the card sits a gap below the line, so the pointer is
    /// legitimately on one, on the other, or between the two. Recomputing it
    /// from `hoverOffset` would not do — a scroll moves the glyphs and leaves
    /// the card where it was, and the rectangle that matters is the one the
    /// card was actually placed against.
    private var hoverSymbol: NSRect?

    /// How long the pointer must rest before a look-up is asked for.
    ///
    /// A property rather than a literal so a test can state its own timing
    /// contract. The behaviour worth testing here is that a superseded
    /// look-up is abandoned, and observing that needs the first request to
    /// still be pending when the pointer moves on — which with a fixed 450ms
    /// meant a test sleeping 100ms between moves was betting that 100ms of
    /// wall clock stays under 450ms. On a machine running the rest of the
    /// suite in parallel that bet loses, the first request fires, and the
    /// test fails for a fact about the host rather than about cancellation.
    /// Widening the ratio is what makes it deterministic, and only the test
    /// knows what ratio it needs.
    var hoverFetchDelay: Duration = .milliseconds(450)

    /// How long a card lingers once the pointer is no longer on what it
    /// describes.
    ///
    /// The grace exists because the card is a **separate window**, sitting a
    /// few points clear of the line: the pointer travelling towards it is off
    /// the word and not yet on the card, and both paths that notice —
    /// crossing other characters, and leaving the view entirely — used to
    /// mean "gone". Every card anybody reached for was dismissed on the way.
    /// Each move restarts the clock, so a card survives a pointer heading for
    /// it and closes shortly after the pointer settles somewhere else.
    ///
    /// The delay alone was not enough, and this is the part worth remembering:
    /// a delay only helps a pointer that keeps moving. `hoverHoldsPointer` is
    /// what decides whether the card is still wanted when the clock runs out,
    /// and it has to name the word and the gap as well as the card — a reader
    /// pausing to read, halfway across, is the most ordinary thing there is.
    ///
    /// A `var` for the same reason `hoverFetchDelay` is one: what is worth
    /// testing here is *when* the close happens, and a test that has to sleep
    /// past a shipped 400ms to find out is betting on the host being fast
    /// rather than asserting anything about this code.
    var hoverDismissDelay: Duration = .milliseconds(400)

    /// Called when the card is asked to close, whether or not one is up.
    ///
    /// An observation seam, and it is here for the same reason
    /// `CodeHoverPanel.pointerLocationProvider` is: the fact worth pinning
    /// down is the *timing* of a close, and no test can watch a real card to
    /// learn it — putting one on screen reaches `orderFront`, which from a
    /// test host with no event loop never returns. Production leaves it nil.
    var onHoverDismiss: (() -> Void)?

    /// The pending close. Separate from `hoverTask` because the two run at
    /// once: one card is on its way out while the next one is being fetched.
    private var dismissTask: Task<Void, Never>?

    /// The card itself, made on the first hover and reused after that. Kept
    /// optional rather than lazy so that a file nobody hovers over never pays
    /// for a window.
    ///
    /// Read-only outside this type: tests observe whether a hover produced a
    /// visible card and drive its `pointerLocationProvider`, but only this
    /// type decides when the card itself is created or torn down.
    private(set) var hoverPanel: CodeHoverPanel?

    /// How the card paints itself. Set by the coordinator, the only thing here
    /// that knows the file's colours and language.
    var hoverTheme: CodeTheme = .fallback
    var hoverLanguage: CodeLanguage = .plain

    /// The three auto-closing switches, mirrored from the configuration.
    ///
    /// Held here rather than read from a shared configuration because this is
    /// the object the keystroke arrives at, and the answer has to be one
    /// property load: the alternative is asking the coordinator on every
    /// character typed.
    var closesBrackets = true
    var closesQuotes = true
    var closesTags = true

    /// Whether the list may open at all, and whether buffer words join the
    /// server's answer. Mirrored from the configuration — see
    /// `CodeEditorConfiguration` for why they are two switches and not one.
    var completionEnabled = true
    var completesFromBuffer = true

    /// What Tab types, and how far.
    ///
    /// Mirrored onto the view for the same reason as the switches above: the
    /// keystroke arrives here, and the answer has to be a property load.
    /// Both values already existed in the configuration and reached only the
    /// formatting request sent to the language server — so a file was
    /// formatted with spaces and then typed into with tabs.
    var insertsSpacesForTab = true
    var tabWidth = 4

    /// Which markup this file is, which the language cannot answer.
    ///
    /// `.ts` and `.tsx` are one `CodeLanguage`, and that is right for lexing
    /// and wrong here: JSX is legal in one and a syntax error in the other,
    /// so `<` means a tag in the first and only ever a generic in the second.
    /// Kept beside the language rather than inside `CodeEditorConfiguration`
    /// because it is a fact about the *file* and not a preference about the
    /// editor — and because the configuration is what the appearance pass
    /// compares to decide whether anything changed. A field that differs for
    /// every tab would make that comparison always fail, which is how the
    /// whole document ends up being re-coloured on each switch.
    var tagDialect: CodeTagDialect = .none

    /// Whether a click means "go to the definition" rather than "put the
    /// cursor here".
    ///
    /// Split out so it can be tested: `mouseDown` itself cannot be, because
    /// `NSTextView`'s runs an event-tracking loop waiting for the mouse to
    /// come back up — call it outside a window and it never returns.
    /// ⌘ held, and none of the modifiers that mean something else.
    ///
    /// Tested against the three that change what a click *is* — ⇧ extends a
    /// selection, ⌥ makes it rectangular, ⌃ opens a menu — rather than
    /// against the whole flag set. Demanding that the flags equal exactly
    /// `.command` is what broke this: a real event also carries caps lock,
    /// the function bit and the numeric-pad bit depending on the keyboard,
    /// so the comparison was false on hardware where it should have been
    /// true, and go-to-definition stopped responding at all.
    static func isJumpClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else { return false }
        return modifiers.isDisjoint(with: [.shift, .option, .control])
    }

    // MARK: The width of the document

    /// How wide this view has to be for its longest line to be scrolled to in
    /// full.
    ///
    /// `used` is what the layout manager measured, and it is the only honest
    /// answer available: **the frame is not.** A horizontally resizable text
    /// view is supposed to keep itself as wide as its widest laid-out line,
    /// and it does — sometimes. Measured with a headless probe of this exact
    /// recipe: one 300-character line in a 400-line file gives a 2233pt frame
    /// that scrolls to the end, and the *same* line in a 5 000-line file
    /// leaves the frame at the viewport's 800pt while
    /// `usageBoundsForTextContainer` already reports 2230 used. A scroll view
    /// does not scroll to somewhere its document does not reach, so the tail
    /// of that line could not be brought on screen at all — the "long lines
    /// are cut off" report, and the reason it read as intermittent: which
    /// answer you get depends on what the last layout pass happened to touch.
    /// `sizeToFit()` is not the repair either; it left the frame at 800 in the
    /// same probe.
    ///
    /// Never below the viewport, so a file of short lines still fills the
    /// pane, and one inset either side so the last glyph of the longest line
    /// is not flush against the edge.
    static func documentWidth(used: CGFloat, inset: CGFloat, viewport: CGFloat) -> CGFloat {
        max(viewport, used + inset * 2)
    }

    /// Widens this view to the longest line TextKit has measured.
    ///
    /// Nothing to do while lines wrap, and `widthTracksTextView` is the flag
    /// that says so — with wrapping on, this view's width is what *decides*
    /// the wrap column, so widening it would move the column rather than
    /// reveal anything. Asking the container rather than carrying a copy of
    /// the setting keeps the two from disagreeing.
    private func fitDocumentWidth() {
        guard let container = textContainer,
              !container.widthTracksTextView,
              let layout = textLayoutManager,
              let scrollView = enclosingScrollView
        else { return }

        let wanted = Self.documentWidth(
            used: layout.usageBoundsForTextContainer.maxX,
            inset: textContainerInset.width,
            viewport: scrollView.contentView.bounds.width
        )
        /// A tolerance rather than an equality: this runs *inside* the layout
        /// pass, so a frame set to a value a fraction of a point away would
        /// ask for another one, and so on.
        guard abs(frame.width - wanted) > 0.5 else { return }
        setFrameSize(NSSize(width: wanted, height: frame.height))
    }

    /// The layout pass is where the width is fixed, because it is the first
    /// moment the measurement exists.
    ///
    /// Doing it from the load, the keystroke and the scroll instead — which
    /// was the first attempt — repairs nothing: at each of those the text has
    /// changed and nothing has been laid out yet, so the used width is still
    /// the old one. Proved by driving the real coordinator over the 5 000-line
    /// document: the frame stayed at 800 through all three.
    ///
    /// ⚠️ `layout()` is an `NSView` method and touches no TextKit 1 API, so it
    /// does not drop this view to TextKit 1 the way overriding `draw(_:)`
    /// does. `TextKitDowngradeTests` holds that.
    override func layout() {
        super.layout()
        fitDocumentWidth()
    }

    /// ⌘-click goes to the definition; without the modifier this is an
    /// ordinary click and must stay one.
    override func mouseDown(with event: NSEvent) {
        hoverOffset = nil
        hideHover()

        guard Self.isJumpClick(event.modifierFlags), let onJumpToDefinition else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onJumpToDefinition(characterIndexForInsertion(at: point))
    }

    /// Hovering asks the host what to say, on a delay.
    ///
    /// Debounced because the pointer crosses a whole line on its way
    /// somewhere else, and asking a language server about every character
    /// it passes over is a request per pixel of travel.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let hoverProvider else { return }

        /// Still on the card, still on the word it describes, or still crossing
        /// the gap between them: the reader is pointing at the same thing, so
        /// there is nothing to look up and nothing to close. Leaving the word
        /// out of this is what made a pointer moving *along* a symbol kill its
        /// own card — every character is a different offset, and each one
        /// scheduled a close that only the card itself could survive.
        guard !hoverHoldsPointer() else { return }

        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        guard offset != hoverOffset else { return }
        hoverOffset = offset

        // Closed on a delay, not at once. Closing immediately is correct in
        // the abstract — the card describes the offset it was opened for — and
        // wrong in the hand: the card sits beside the word, so *reaching* for it
        // means crossing other characters, and every one of them dismissed it
        // before the pointer arrived. There was no way to scroll a long
        // description or select a line out of it. Each move restarts the clock,
        // so a card survives a pointer travelling towards it and closes shortly
        // after the pointer settles somewhere else.
        scheduleHoverDismissal()

        hoverTask?.cancel()
        hoverTask = Task { [weak self, hoverFetchDelay] in
            try? await Task.sleep(for: hoverFetchDelay)
            guard !Task.isCancelled else { return }
            let info = await hoverProvider(offset)
            guard !Task.isCancelled, let info, !info.isEmpty else { return }
            await MainActor.run {
                guard let self, self.hoverOffset == offset else { return }
                self.showHover(info, at: offset)
            }
        }
    }

    /// Puts the card beside the hovered word.
    ///
    /// Anchored to the **word** — the whole identifier under the pointer, not
    /// the one character it happens to be over. A per-character anchor moved
    /// the card sideways by a glyph on every move within the same symbol, and
    /// re-presenting a card is what pulls it out from under a pointer already
    /// resting on it.
    ///
    /// An answer that arrives while the reader is holding the card is
    /// **dropped**. It describes the last offset the pointer crossed on its
    /// way there, which is behind the card by now, and showing it would move
    /// the card to that offset's line — the exit that followed hid the card,
    /// half a second after the reader reached it. This is the dismissal the
    /// report was about.
    private func showHover(_ info: CodeHoverInfo, at offset: Int) {
        guard !hoverHoldsPointer() else { return }

        let content = string as NSString
        guard content.length > 0 else { return }
        let anchor = firstRect(
            forCharacterRange: Self.symbolRange(in: content, containing: offset),
            actualRange: nil
        )
        guard anchor.height > 0 else { return }

        // A fresh card cancels the close the last one was waiting on, or it
        // would be shut 400ms after opening.
        dismissTask?.cancel()
        hoverSymbol = anchor

        let panel = hoverPanel ?? CodeHoverPanel()
        hoverPanel = panel
        panel.onPointerExit = { [weak self] in
            guard let self else { return }
            /// Cleared as well as closed, so that coming back to the same word
            /// opens the card again instead of the offset guard swallowing it.
            self.hoverOffset = nil
            /// The same grace the text view's own exit gets, for the same
            /// reason turned around: leaving the card *upwards* lands on the
            /// word it describes, and that is not a reader who is finished.
            self.hoverTask?.cancel()
            self.scheduleHoverDismissal()
        }
        panel.present(
            info,
            theme: hoverTheme,
            font: font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            anchor: anchor,
            over: self
        )
    }

    /// Closes the card unless `hoverHoldsPointer` still answers yes when the
    /// clock runs out — the pointer arrived, never left, or is still crossing.
    ///
    /// Closes the *window* and nothing else — deliberately not `hideHover`,
    /// which also cancels the pending look-up. `hoverDismissDelay` is shorter
    /// than `hoverFetchDelay`, so a dismissal that cancelled the task killed
    /// every fetch before it ran and no card could ever appear.
    private func scheduleHoverDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self, hoverDismissDelay] in
            try? await Task.sleep(for: hoverDismissDelay)
            guard !Task.isCancelled, let self else { return }
            guard !self.hoverHoldsPointer() else { return }

            /// A button held down while the card has focus is a selection
            /// being dragged out of it, and overshooting the card's edge must
            /// not take the text away mid-drag. Re-armed rather than skipped:
            /// the button coming up outside the card produces no event this
            /// view or the card would hear, so nothing else is guaranteed to
            /// ask again, and a card that fails to close is the worse bug.
            if self.isDraggingFromCard {
                self.scheduleHoverDismissal()
                return
            }

            self.hoverSymbol = nil
            self.hoverPanel?.dismiss()
            self.onHoverDismiss?()
        }
    }

    /// Whether the pointer is somewhere that still counts as hovering: on the
    /// card, on the word it describes, or in the gap between the two.
    ///
    /// False with no card up, which is what makes it safe to ask from every
    /// close: the answer then is "nothing is being held".
    private func hoverHoldsPointer() -> Bool {
        guard let hoverPanel, let hoverSymbol else { return false }
        return hoverPanel.retainsPointer(describing: hoverSymbol)
    }

    /// Whether a mouse button is down *and* the card is the window holding
    /// focus, which together mean the drag belongs to the card.
    ///
    /// The focus half matters: a drag in the editor is a selection in the
    /// code, and that already closed the card on its first press.
    private var isDraggingFromCard: Bool {
        NSEvent.pressedMouseButtons != 0 && hoverPanel?.isKeyWindow == true
    }

    /// Stops everything: no card, and no card on its way.
    private func hideHover() {
        hoverTask?.cancel()
        dismissTask?.cancel()
        hoverSymbol = nil
        hoverPanel?.dismiss()
        onHoverDismiss?()
    }

    /// Leaving the text view puts the card away on the same delay a pointer
    /// moving *within* the text gets — the same reason, turned inside out.
    ///
    /// The card is a window of its own, `PanelPlacement.gap` clear of the line
    /// it describes, and it takes mouse events so a long description can be
    /// scrolled or a line selected out of it. Reaching for it therefore means
    /// leaving this view, and for the few points of the crossing the pointer
    /// is on neither window: `hoverHoldsPointer` counts that crossing as
    /// hovering, and closing at once dismissed every card that was still on
    /// its way to being reached. The delay is kept on top of the geometry,
    /// because a reach is a hand movement and not a straight line; a pointer
    /// that genuinely left is rid of the card a moment later either way.
    ///
    /// The look-up is abandoned immediately even though the window is not.
    /// They are separate on purpose — see `scheduleHoverDismissal` — and the
    /// pointer being off the text means an answer arriving now would describe
    /// a word nobody is pointing at.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !hoverHoldsPointer() else { return }
        hoverOffset = nil
        hoverTask?.cancel()
        scheduleHoverDismissal()
    }

    /// A card is a window, and a window outlives the view that opened it. Left
    /// alone it would stay on screen after its tab was closed, describing a
    /// symbol in a file that is no longer showing.
    ///
    /// The same window is what the focus observation is hung on, re-hung here
    /// because a text view moves between windows — a tab dragged out of one
    /// carries this view with it, and an observation left on the old window
    /// would report a resignation that says nothing about this editor.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(editorWindowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        if window == nil {
            hoverOffset = nil
            hideHover()
        }
    }

    /// The editor's window losing focus closes the card, because the card is a
    /// floating window: left up it hangs over whatever the reader moved to,
    /// describing a symbol in a file they are no longer looking at.
    ///
    /// Except when the pointer is on the card, which is the one resignation
    /// that must not close anything — clicking into the card to select a line
    /// is what makes the card key and this window resign, in that order, so a
    /// handler that closed on every resignation would undo the selection it
    /// was asked for. `hoverHoldsPointer` separates the two: the pointer is
    /// inside the card in that case and somewhere else entirely in every
    /// other.
    ///
    /// `hoverOffset` is cleared either way. Focus moving is exactly when the
    /// reader may come back to the *same* word, and the guard against a
    /// repeated offset would otherwise swallow the hover they asked for.
    @objc private func editorWindowDidResignKey() {
        hoverOffset = nil
        guard !hoverHoldsPointer() else { return }
        hideHover()
    }

    /// Anything that moves the text out from under the card closes it: the
    /// card is pinned to a screen position and the word it describes is not.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        hoverOffset = nil
        hideHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `activeInActiveApp` rather than `activeInKeyWindow`: clicking into
        // the card to select a line makes the card the key window, and with the
        // stricter option this view would stop hearing about the pointer
        // entirely — no more hovers until the editor was clicked again.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    /// The right-click menu, built here rather than taken from `NSTextView`.
    ///
    /// The stock menu is written for a word processor: spelling and grammar,
    /// substitutions, transformations, speech, layout orientation, font and
    /// writing direction. In a code editor every one of those is either
    /// useless or actively unwanted — substitutions turn quotes into curly
    /// quotes in source — and they buried the four commands worth having
    /// under submenus nobody opens.
    ///
    /// Cut, copy, paste and select-all keep the standard selectors instead of
    /// closures, so `NSTextView` goes on validating them: copy greys itself
    /// over an empty selection, which is the honest state of a caret sitting
    /// in a file, and reimplementing that judgement would be reimplementing
    /// it worse.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Anchored to where the pointer is, not to the selection: the whole
        // point of right-clicking a symbol is to ask about *that* one.
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)

        let menu = NSMenu()
        var lastGroup: Int?

        for command in Self.contextMenuCommands(
            hasDefinition: onJumpToDefinition != nil,
            hasReferences: onFindReferences != nil,
            hasRename: onRename != nil,
            hasFormat: onFormat != nil,
            hasAttach: onAttachLine != nil
        ) {
            if let lastGroup, lastGroup != command.group {
                menu.addItem(.separator())
            }
            lastGroup = command.group

            let shown = displayedShortcut(for: command)

            switch command {
            case .goToDefinition:
                menu.addItem(item(command.title, key: shown.key, shown.modifiers) {
                    self.onJumpToDefinition?(offset)
                })
            case .findReferences:
                menu.addItem(item(command.title, key: shown.key, shown.modifiers) {
                    self.onFindReferences?(offset)
                })
            case .rename:
                menu.addItem(item(command.title, key: shown.key, shown.modifiers) {
                    self.onRename?(offset)
                })
            case .format:
                menu.addItem(item(command.title, key: shown.key, shown.modifiers) {
                    self.onFormat?()
                })
            case .attachLine:
                /// The selection, not the click point: right-clicking a
                /// selection to attach it is the gesture, and the click is
                /// somewhere inside it. A bare caret attaches its own line,
                /// same as ⌘K.
                menu.addItem(item(command.title, key: shown.key, shown.modifiers) {
                    self.onAttachLine?(self.selectedRange(), self.string)
                })
            case .cut, .copy, .paste, .selectAll:
                let entry = NSMenuItem(
                    title: command.title,
                    action: command.selector,
                    keyEquivalent: shown.key
                )
                entry.keyEquivalentModifierMask = shown.modifiers
                menu.addItem(entry)
            }
        }

        return menu.numberOfItems > 0 ? menu : nil
    }

    /// The combination to draw beside a command.
    ///
    /// What the reader bound, and the shipped default only when they bound
    /// nothing at all. An id present with an **empty** list is a command they
    /// deliberately unbound, and it draws no key — showing the default there
    /// would advertise a shortcut that does nothing, which is worse than a
    /// menu item with no shortcut at all.
    private func displayedShortcut(
        for command: EditorContextCommand
    ) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard let id = command.actionID, let bound = commandShortcuts[id] else {
            return (command.key, command.modifiers)
        }
        guard let primary = bound.first else { return ("", []) }
        return (primary.key, primary.modifiers)
    }

    /// What the editor's right-click menu offers, in order, and where the
    /// separators fall.
    ///
    /// A value rather than the menu building itself, so the rule — which
    /// commands exist, and which of them the host actually wired — can be
    /// stated and checked without an `NSEvent` to hand. The language commands
    /// come first because they are the reason somebody right-clicked a word;
    /// the clipboard is what they came for when they right-clicked a
    /// selection, and it is where every other app keeps it.
    static func contextMenuCommands(
        hasDefinition: Bool,
        hasReferences: Bool,
        hasRename: Bool,
        hasFormat: Bool,
        hasAttach: Bool = false
    ) -> [EditorContextCommand] {
        var commands: [EditorContextCommand] = []
        if hasDefinition { commands.append(.goToDefinition) }
        if hasReferences { commands.append(.findReferences) }
        if hasRename { commands.append(.rename) }
        if hasFormat { commands.append(.format) }
        if hasAttach { commands.append(.attachLine) }

        commands.append(contentsOf: [.cut, .copy, .paste, .selectAll])
        return commands
    }

    private func item(
        _ title: String,
        key: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = MenuAction(run: action)
        return item
    }

    /// Boxes a closure so it can ride on `representedObject`, which only
    /// takes an object — the alternative is a selector per command and a
    /// property to remember which one was meant.
    private final class MenuAction: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    /// ⌃Space asks for completions, the way most editors bind it.
    ///
    /// In `keyDown` rather than `performKeyEquivalent` because that one only
    /// sees ⌘ combinations — a plain modifier+key never reaches it.
    override func keyDown(with event: NSEvent) {
        // Typing means the reader has moved on, and the text the card
        // describes may be the text being replaced.
        hoverOffset = nil
        hideHover()

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, event.charactersIgnoringModifiers == " ",
           completionProvider != nil {
            complete(nil)
            return
        }

        /// The reader's own bindings again, for whatever
        /// `performKeyEquivalent` did not get to see — the comment above says
        /// that method only observes ⌘ combinations, and a binding on ⇧⌥↑ has
        /// to work either way round. Running it here cannot double up: this
        /// method is only reached at all when `performKeyEquivalent` answered
        /// false.
        ///
        /// Only for presses carrying option, control or command. Shift alone
        /// is how capitals are typed, and a bare key is how everything else
        /// is — swallowing either would turn a stray binding into a text view
        /// that cannot type.
        if !modifiers.isDisjoint(with: [.option, .control, .command]),
           let id = boundCommand(for: event), runCommand(id) {
            return
        }

        super.keyDown(with: event)
    }

    /// One open completion list.
    ///
    /// It used to carry the range the list was built for, and accepting used
    /// to insert over that range. **Both are gone on purpose.** A range
    /// recorded when the answer arrived is a range the reader can type past
    /// while the refilter for their next keystroke is still in flight, and
    /// inserting over it strands the characters they typed last — the range
    /// to replace is worked out at accept time by `replacementRange`, out of
    /// the buffer as it is and the range the row itself asked for.
    struct CompletionSession {
        var items: [CodeCompletionItem]
        var selection: Int
    }

    /// Asked for on purpose — ⌃Space, and `cancelOperation:` (AppKit binds
    /// Escape to it, which is why Escape has always opened this list).
    ///
    /// Unlike a typed character this ignores both the delay and the minimum
    /// prefix: someone who asks explicitly has already paused, and asking
    /// inside a string is a request rather than an accident.
    override func complete(_ sender: Any?) {
        requestCompletions(explicitly: true)
    }

    /// Every printable character, funnelled from `insertText` so the four
    /// auto-closing early returns cannot skip it.
    func completionDidType(_ typed: Character) {
        let isTrigger = completionTriggers.contains(typed)
        let decision = completionDecision(typed: typed)

        switch decision {
        case .close:
            dismissCompletions()
        case .ignore:
            break
        case .open, .refilter:
            requestCompletions(explicitly: false, immediate: isTrigger)
        }
    }

    /// Backspace, funnelled the same way.
    ///
    /// Refilters rather than closing, which is what VS Code does and what
    /// makes the list usable while correcting a typo. The list survives only
    /// while the caret is still inside the word it opened on; `prefixRange`
    /// returning something shorter is a narrowing, and returning nothing at
    /// all is the word being gone.
    func completionDidDelete() {
        guard completionSession != nil else { return }
        guard case .refilter = completionDecision(typed: nil) else {
            dismissCompletions()
            return
        }
        requestCompletions(explicitly: false, immediate: true)
    }

    /// Which language the caret's line is actually written in.
    ///
    /// A container language answers nothing useful about a single line, and
    /// that was a real bug rather than a hypothetical one: `.vue` routes to
    /// `SFCRegions`, which needs the whole document to find `^<script>` and
    /// `^</script>`, so a lone line came back with **no tokens at all** and
    /// the caller's string-and-comment suppression silently never fired in a
    /// Vue file. Measured — the same line yields `[keyword, string]` as
    /// `.javascript` and `[]` as `.vue`.
    ///
    /// The obvious repair is to hand over the whole document and scope the
    /// range to the line, and that is correct and unaffordable: 2.7 ms per
    /// keystroke on a 5000-line component, growing linearly with the file,
    /// because `SFCRegions` compiles three expressions and scans everything
    /// three times per call with no cache. Resolving the language instead
    /// costs a bounded backwards literal search and leaves the tokenizing
    /// scoped to one line, which is ~12 µs.
    ///
    /// Only a container needs resolving. Everything else — including `.jsx`,
    /// which is JavaScript that happens to carry tags — is already the
    /// language its lines are written in.
    static func effectiveLanguage(
        _ language: CodeLanguage,
        in content: NSString,
        at caret: Int,
        dialect: CodeTagDialect
    ) -> CodeLanguage {
        guard language == .vue else { return language }
        return CodeTagClose.isInMarkup(content, caret: caret, dialect: dialect) ? .html : .javascript
    }

    /// The trigger policy, asked over the caret's line only — a per-keystroke
    /// path cannot afford to tokenize the document to find out whether it is
    /// inside a string.
    private func completionDecision(typed: Character?) -> CodeCompletionTrigger.Decision {
        let content = string as NSString
        let caret = selectedRange().location
        let lineRange = content.lineRange(for: NSRange(location: min(caret, content.length), length: 0))
        let line = content.substring(with: lineRange)
        let caretInLine = caret - lineRange.location

        let suppressed = SyntaxHighlighter(language: Self.effectiveLanguage(
            hoverLanguage,
            in: content,
            at: caret,
            dialect: tagDialect
        ))
            .tokens(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            .contains { token in
                (token.kind == .string || token.kind == .comment)
                    && NSLocationInRange(max(caretInLine - 1, 0), token.range)
            }

        let context = CodeCompletionTrigger.Context(
            line: line,
            caretInLine: caretInLine,
            typed: typed,
            isInStringOrComment: suppressed,
            triggerCharacters: completionTriggers,
            minimumPrefix: completionMinimumPrefix,
            completesInsideClassAttribute: completesInsideClassAttribute)

        return CodeCompletionTrigger.decide(
            context,
            isListOpen: completionSession != nil,
            isExplicit: false)
    }

    /// Fetches and shows, debounced and cancellable.
    ///
    /// The shape is the one `mouseMoved` established for hover — cancel the
    /// previous task, sleep, check cancellation, await, check again, hop to
    /// the main actor and re-check that the world has not moved — with one
    /// addition hover does not need: the buffer moves under a completion, so
    /// a generation counter guards it as well as the offset.
    private func requestCompletions(explicitly: Bool, immediate: Bool = false) {
        guard completionEnabled, let completionProvider else { return }

        completionGeneration += 1
        let generation = completionGeneration
        let offset = selectedRange().location
        let delay = immediate || explicitly ? Duration.zero : completionFetchDelay

        completionTask?.cancel()
        completionTask = Task { [weak self, delay] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let answer = await completionProvider(offset)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.completionGeneration == generation else { return }

                /// The one case that must not reach `showCompletions`: it is
                /// not an answer, so there is nothing to draw and — crucially
                /// — nothing to clear.
                guard case .items(let items) = answer else { return }
                self.showCompletions(items, requestedAt: offset)
            }
        }
    }

    /// Ranks an answer and puts it on screen.
    private func showCompletions(_ items: [CodeCompletionItem], requestedAt offset: Int) {
        let content = string as NSString
        let caret = selectedRange().location
        let prefix = completionPrefixRange(in: content, endingAt: caret)

        let query = content.substring(with: prefix)
        let ranked = CodeCompletionFilter.rank(
            items + bufferWords(matching: query, excluding: prefix, in: content),
            query: query
        )
        guard !ranked.isEmpty else {
            dismissCompletions()
            return
        }

        completionSession = CompletionSession(items: ranked, selection: 0)

        /// Anchored on the **start of the word**, not the caret, so the list
        /// lines up under what is being completed rather than drifting right
        /// as the reader types. A zero-height rect means TextKit has not laid
        /// the line out yet, and the panel treats that as "do not show".
        let anchor = firstRect(
            forCharacterRange: NSRange(location: prefix.location, length: max(prefix.length, 1)),
            actualRange: nil)

        let panel = completionPanel ?? makeCompletionPanel()
        panel.present(
            ranked,
            query: query,
            theme: hoverTheme,
            font: font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            anchor: anchor,
            over: self
        )
    }

    /// Identifiers scraped out of the buffer, offered alongside whatever the
    /// server said.
    ///
    /// Merged on **every** request rather than only when the server answered
    /// nothing, because the ranking was built for exactly this and has never
    /// been given it: `CodeCompletionFilter` already handicaps a non-server row
    /// against a server one, and already drops a scraped word that a server row
    /// covers. Falling back only on an empty answer would make the feature
    /// arrive precisely when the editor knows least — a server that is still
    /// starting, or one that answered for a different position — and vanish
    /// once it knows more.
    ///
    /// What this buys is the language nobody installed a server for. Before it,
    /// those files offered nothing at all.
    ///
    /// **Keywords are not here, and that is a cut rather than an oversight.**
    /// A built-in language has no keyword *list* — `LanguageSyntax.builtIn`
    /// carries an empty one and the highlighter matches keywords by pattern —
    /// so offering them would mean writing fourteen lists beside a table that
    /// already encodes the same words, and watching the two drift. In a file
    /// that has used a keyword even once it is already in the buffer and comes
    /// back through here anyway. A *contributed* language does carry a list,
    /// and this is where it would attach.
    private func bufferWords(
        matching query: String,
        excluding prefix: NSRange,
        in content: NSString
    ) -> [CodeCompletionItem] {
        guard completesFromBuffer, !query.isEmpty else { return [] }

        return CodeWordIndex.words(
            in: content,
            excluding: prefix,
            matching: query,
            limit: Self.bufferWordLimit
        )
        .map { CodeCompletionItem(kind: .text, label: $0, source: .buffer) }
    }

    /// Enough to be worth having, few enough that they cannot bury a server's
    /// answer before the ranking has had a chance to sort them.
    private static let bufferWordLimit = 50

    /// The tab stops of an insertion the reader is still filling in.
    ///
    /// Ranges are absolute buffer offsets rather than offsets into the
    /// snippet, because the buffer is what everything else here speaks and a
    /// second coordinate space would have to be converted at every use.
    private struct SnippetSession {
        var fields: [NSRange]
        var active: Int
        var finalCaret: Int
    }

    private var snippetSession: SnippetSession?

    /// Inserts a snippet body and leaves the caret on its first stop.
    ///
    /// A body with no stops is not a session: there is nothing to Tab through,
    /// and holding one open would claim Tab from a reader who has finished.
    private func beginSnippet(_ snippet: CodeSnippet, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: snippet.text) else { return }
        textStorage?.replaceCharacters(in: range, with: snippet.text)
        didChangeText()

        let origin = range.location
        let inserted = (snippet.text as NSString).length
        let final = origin + (snippet.finalCaret ?? inserted)

        guard !snippet.fields.isEmpty else {
            setSelectedRange(NSRange(location: final, length: 0))
            return
        }

        snippetSession = SnippetSession(
            fields: snippet.fields.map {
                NSRange(location: origin + $0.range.location, length: $0.range.length)
            },
            active: 0,
            finalCaret: final
        )
        selectSnippetField()
    }

    /// Tab and Shift-Tab. Walking off either end finishes rather than wraps —
    /// wrapping would make the last Tab of a snippet silently reopen it.
    private func moveSnippetField(by step: Int) {
        guard let session = snippetSession else { return }
        let next = session.active + step

        guard session.fields.indices.contains(next) else {
            let final = session.finalCaret
            endSnippet()
            setSelectedRange(NSRange(location: min(final, (string as NSString).length), length: 0))
            return
        }

        snippetSession?.active = next
        selectSnippetField()
    }

    private func selectSnippetField() {
        guard let session = snippetSession else { return }
        let field = session.fields[session.active]
        let length = (string as NSString).length
        guard field.location <= length, field.location + field.length <= length else {
            endSnippet()
            return
        }
        setSelectedRange(field)
    }

    private func endSnippet() {
        snippetSession = nil
    }

    /// The edit about to happen, remembered so the snippet stops can be moved
    /// by the amount it actually changed.
    ///
    /// Captured on the way in because `didChangeText` is told *that* the text
    /// changed and not what changed — and the delta is the one number the
    /// field arithmetic needs.
    private var pendingEdit: (range: NSRange, delta: Int)?

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        if snippetSession != nil {
            let inserted = (replacementString as NSString?)?.length ?? 0
            pendingEdit = (range, inserted - range.length)
        }
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()

        /// The card is pinned to a screen position and the text it describes has
        /// just moved out from under it. `keyDown` covers what the reader types;
        /// this covers every edit that arrives by another road — a paste, a
        /// formatting pass, an undo, an edit the language server applied.
        hoverOffset = nil
        hideHover()

        guard let session = snippetSession, let edit = pendingEdit else { return }
        pendingEdit = nil

        /// `nil` means the edit went somewhere the session does not model, and
        /// the contract there is to **end** rather than to guess. A session
        /// that survives an edit it did not understand starts moving the wrong
        /// ranges, and the way that shows up is a later Tab selecting a piece
        /// of the reader's own code.
        guard let moved = CodeSnippet.adjust(
            fields: session.fields,
            active: session.active,
            editedRange: edit.range,
            delta: edit.delta
        ) else {
            endSnippet()
            return
        }

        snippetSession?.fields = moved
        snippetSession?.finalCaret = session.finalCaret + edit.delta
    }

    /// The word the caret sits at the end of.
    ///
    /// `$` counts, because it is a legal identifier character in JavaScript
    /// and TypeScript and dropping it would make `$el` complete as `el`.
    /// What the list is being filtered against, in document coordinates.
    ///
    /// Not always an identifier, which is the whole point: a class attribute's
    /// run ends at whitespace or at the quote, so `w-1/2` is one query and not
    /// three. Getting this wrong is not a subtle defect — the identifier rule
    /// answers *empty* for `w-`, and an empty query matches all 11,000
    /// candidates equally and shows them in whatever order the server sent.
    private func completionPrefixRange(in content: NSString, endingAt caret: Int) -> NSRange {
        if completesInsideClassAttribute,
           let token = CodeClassAttribute.tokenRange(in: content, caret: caret) {
            return token
        }
        return Self.identifierRange(in: content, endingAt: caret)
    }

    static func identifierRange(in content: NSString, endingAt caret: Int) -> NSRange {
        var start = min(max(caret, 0), content.length)
        while start > 0, isIdentifier(content.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: min(max(caret, 0), content.length) - start)
    }

    /// The whole identifier an offset falls inside, or that single character
    /// when it falls on something that is not one.
    ///
    /// What the hover card is anchored to, and it reaches *both* ways where
    /// `identifierRange` only reaches back from a caret: the pointer lands in
    /// the middle of a word as often as at its end. Anchoring to the one
    /// character under the pointer instead moved the card by a glyph on every
    /// move within the same symbol, and a card that moves is a card the
    /// pointer is no longer on.
    ///
    /// A single character for punctuation and for whitespace, which is the
    /// honest anchor for a hover over an operator — servers do answer for
    /// those. Empty only for an empty document, which the caller rejects
    /// before asking.
    static func symbolRange(in content: NSString, containing offset: Int) -> NSRange {
        guard content.length > 0 else { return NSRange(location: 0, length: 0) }

        let clamped = min(max(offset, 0), content.length - 1)
        guard isIdentifier(content.character(at: clamped)) else {
            return NSRange(location: clamped, length: 1)
        }

        var start = clamped
        while start > 0, isIdentifier(content.character(at: start - 1)) { start -= 1 }

        var end = clamped + 1
        while end < content.length, isIdentifier(content.character(at: end)) { end += 1 }

        return NSRange(location: start, length: end - start)
    }

    /// Whether a UTF-16 unit can be part of an identifier.
    ///
    /// One rule in one place, because two copies of it drift: `$` counts for
    /// the reason `identifierRange` gives — it is legal in JavaScript, and
    /// dropping it completes `$el` as `el` — and it has to count for the hover
    /// anchor too, or the card opens against half a name.
    static func isIdentifier(_ unit: unichar) -> Bool {
        let character = Character(UnicodeScalar(unit) ?? " ")
        return character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private func makeCompletionPanel() -> CodeCompletionPanel {
        let panel = CodeCompletionPanel()
        panel.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        panel.iconFont = completionIconFont
        panel.offersDocumentation = { [weak self] item in
            self?.completionOffersDocumentation?(item) ?? false
        }
        panel.onInfoClicked = { [weak self] item in self?.toggleDocumentation(for: item) }

        /// Once the card is open it follows the selection, which is what makes
        /// it worth opening: a card that described the row you clicked and then
        /// went stale under the arrow keys would have to be closed and reopened
        /// to be read, and nobody does that twice.
        panel.onSelectionChange = { [weak self] item in
            guard let self, self.isShowingDocumentation else { return }
            guard let item else {
                self.hideDocumentation()
                return
            }
            self.requestDocumentation(for: item)
        }

        completionPanel = panel
        return panel
    }

    /// The info glyph is a toggle, not a one-way door: it is the same control
    /// for "show me this" and "that is enough".
    private func toggleDocumentation(for item: CodeCompletionItem) {
        if isShowingDocumentation {
            hideDocumentation()
        } else {
            isShowingDocumentation = true
            requestDocumentation(for: item)
        }
    }

    /// Draws what is already known, then asks for the rest.
    ///
    /// In that order, and the order is the feature. The row's own detail — a
    /// type, a module — needs no request at all, so something true about the
    /// highlighted row is on screen before anything is sent. Arrowing down a
    /// list therefore never leaves an empty card waiting on a server; the prose
    /// fills in underneath a signature that was already right.
    private func requestDocumentation(for item: CodeCompletionItem) {
        guard isShowingDocumentation, let completionDocProvider else { return }

        documentationState = CodeCompletionDocPanel.state(
            hasSelection: true,
            supportsResolve: completionOffersDocumentation?(item) ?? false
        )
        presentDocumentation(detail: item.detail)

        documentationTask?.cancel()
        documentationTask = Task { [weak self] in
            let outcome = await completionDocProvider(item)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isShowingDocumentation else { return }

                /// Folded through `state(after:current:)` rather than assigned,
                /// because a superseded answer has to leave the card alone —
                /// every request cancels the one before it, so that is the
                /// answer that arrives most often.
                self.documentationState = CodeCompletionDocPanel.state(
                    after: outcome,
                    current: self.documentationState
                )
                self.presentDocumentation(detail: item.detail)
            }
        }
    }

    private func presentDocumentation(detail: String?) {
        guard let list = completionPanel, list.isVisible else { return }

        let panel = documentationPanel ?? {
            let made = CodeCompletionDocPanel()
            documentationPanel = made
            return made
        }()

        panel.present(
            CodeCompletionDocPanel.Content(state: documentationState, detail: detail),
            theme: hoverTheme,
            font: font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            language: hoverLanguage,
            beside: list.frame,
            over: self
        )
    }

    private func hideDocumentation() {
        isShowingDocumentation = false
        documentationTask?.cancel()
        documentationTask = nil
        documentationState = .hidden
        documentationPanel?.dismiss()
    }

    private func acceptCompletion(_ item: CodeCompletionItem) {
        guard completionSession != nil else { return }
        dismissCompletions()
        applyCompletion(item)
    }

    /// The span an accepted row replaces.
    ///
    /// The word under the caret is recomputed here rather than taken from the
    /// session that opened the list, and that is a repair rather than
    /// tidying: the session's range is the one the *answer* was drawn for, so
    /// a reader who keeps typing while a refilter is still in flight accepts
    /// against a range a character or two short. Replacing it strands what
    /// they typed last after the insertion — `conn` accepting `connect`
    /// becomes `connectn`, caret in the middle of it.
    ///
    /// `asked` — the range the row's producer named — wins where the two
    /// disagree, but by **union** rather than by replacement, for that same
    /// reason: it was measured against the document as it was, so honouring
    /// it alone re-strands anything typed since. The union covers both what
    /// the server meant to erase and what the reader has since added.
    ///
    /// Two guards, and both are about a range that no longer describes this
    /// document. It has to lie on the caret's line, which is the restriction
    /// VS Code puts on a completion's `textEdit` and which bounds the damage
    /// of a stale one to a line rather than to a file; and it has to touch
    /// the word, so a range pointing somewhere else entirely is refused
    /// rather than unioned into a deletion of everything in between. A
    /// refused range leaves the word — which is what a row carrying no range
    /// gets anyway, so the worst case is the old behaviour rather than a new
    /// one.
    static func replacementRange(asked: NSRange?, caret: Int, in content: NSString) -> NSRange {
        let caret = min(max(caret, 0), content.length)
        let word = identifierRange(in: content, endingAt: caret)
        guard let asked, asked.length >= 0 else { return word }

        let line = content.lineRange(for: NSRange(location: caret, length: 0))
        guard asked.location >= line.location, NSMaxRange(asked) <= NSMaxRange(line)
        else { return word }

        guard asked.location <= NSMaxRange(word), word.location <= NSMaxRange(asked)
        else { return word }

        return NSUnionRange(asked, word)
    }

    /// Whether accepting this row would change the buffer at all.
    ///
    /// Asked of one key only — Return — and the reason is the keystroke it
    /// costs when the answer is no. A list stays open while you type, so
    /// finishing a word the list is still offering leaves the reader looking
    /// at a row whose text is *already* what the document says. Return there
    /// was claimed as an accept, replaced `connect` with `connect`, and the
    /// line break it was pressed for never happened: nothing moved, nothing
    /// was inserted, and the keystroke was gone. That is the whole of
    /// "accepting a completion does not add a line break" — nothing on the
    /// insertion path can drop a newline, and this is the one way the reader
    /// loses one.
    ///
    /// The same rule VS Code applies, where the Enter binding for
    /// `acceptSelectedSuggestion` carries a `suggestionMakesTextEdit`
    /// condition and Tab carries none.
    ///
    /// A snippet always counts as a change even when its literal text matches:
    /// accepting one leaves tab stops and moves the caret, so it does
    /// something a newline would not. Additional edits count for the plainer
    /// reason that an auto-import is a change somewhere else in the file.
    static func acceptChangesText(
        item: CodeCompletionItem,
        caret: Int,
        in content: NSString
    ) -> Bool {
        guard !item.isSnippet, item.additionalEdits.isEmpty else { return true }
        let range = replacementRange(asked: item.replaceRange, caret: caret, in: content)
        return content.substring(with: range) != item.insertText
    }

    /// Replaces what the row says it replaces with the row's text.
    ///
    /// Through `shouldChangeText` and `didChangeText` rather than a bare
    /// `replaceCharacters`, so undo registers it as one step and the
    /// delegate fires — which is what tells the language server the buffer
    /// moved. A raw replacement desynchronises the server silently.
    ///
    /// Split from `acceptCompletion` — which is the list's half, and needs a
    /// session to have been open — so the buffer half can be driven without a
    /// panel, a window or an event loop.
    func applyCompletion(_ item: CodeCompletionItem) {
        endSnippet()

        let range = Self.replacementRange(
            asked: item.replaceRange,
            caret: selectedRange().location,
            in: string as NSString
        )

        /// Everything lands inside one undo group, so a single ⌘Z takes back
        /// the completion *and* the import it dragged in. Two steps would
        /// leave the reader with an import for a symbol they just removed —
        /// and they would have to notice that to fix it.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        /// The additional edits go in **first, back to front**. Every range
        /// the server sent is measured against the document as it was, so
        /// applying them in ascending order invalidates every position after
        /// the first one. Descending means each edit lands before anything
        /// that could have moved it — which is also why a server is free to
        /// send them in any order at all.
        ///
        /// The main insertion comes last for the same reason: an import at the
        /// top of the file would shift the caret's own range out from under it.
        var caretRange = range
        for edit in item.additionalEdits.sorted(by: { $0.range.location > $1.range.location }) {
            guard edit.range.location <= (string as NSString).length else { continue }
            guard shouldChangeText(in: edit.range, replacementString: edit.newText) else { continue }
            textStorage?.replaceCharacters(in: edit.range, with: edit.newText)
            didChangeText()

            if edit.range.location <= caretRange.location {
                caretRange.location += (edit.newText as NSString).length - edit.range.length
            }
        }

        guard item.isSnippet else {
            guard shouldChangeText(in: caretRange, replacementString: item.insertText) else { return }
            textStorage?.replaceCharacters(in: caretRange, with: item.insertText)
            didChangeText()
            setSelectedRange(NSRange(
                location: caretRange.location + (item.insertText as NSString).length,
                length: 0
            ))
            return
        }

        beginSnippet(CodeSnippet.parse(item.insertText), replacing: caretRange)
    }

    /// Closes the list and invalidates anything still in flight for it.
    ///
    /// The card goes with it. It describes a row of this list and there is no
    /// state in which it is right for one to outlive the other — a card left
    /// floating over the text after the list closed is a window nothing can
    /// dismiss.
    func dismissCompletions() {
        completionTask?.cancel()
        completionTask = nil
        completionSession = nil
        completionGeneration += 1
        completionPanel?.dismiss()
        hideDocumentation()
    }

    /// Whether a list is open, for the key-handling table.
    var isCompletionListOpen: Bool { completionSession != nil }

    /// Which keys the open list claims, and — the part that matters — which
    /// it does not.
    ///
    /// Nothing is claimed unless a list is open, which is the whole
    /// conflict-avoidance strategy: with the list closed every selector falls
    /// through untouched, so Return still reaches the find bar and Tab still
    /// indents. Spelled as a static over a `Bool` so the entire keyboard
    /// contract is testable without a window, an event or a panel.
    /// What a key does when the list, or a snippet's tab stops, own it.
    ///
    /// An enum rather than the nested optional this used to be. Two readings
    /// of `nil` were already one too many, and the snippet stops add two more
    /// answers to the same question.
    enum Claim: Equatable {
        case move(CodeCompletionPanel.Movement)
        case accept
        case dismiss

        /// Tab and Shift-Tab, once an insertion has left placeholders behind.
        case nextField
        case previousField
    }

    /// Which keys are claimed, and — the part that matters — which are not.
    ///
    /// **Nothing is claimed unless a list is open or a snippet is in progress.**
    /// That single rule is the whole conflict-avoidance strategy: with neither
    /// in play every selector falls through untouched, so Return still reaches
    /// the find bar and Tab still indents. It is spelled as a static over two
    /// `Bool`s so the entire keyboard contract can be asserted without a
    /// window, an event or a panel.
    ///
    /// The list wins Tab when both are live, because the reader is looking at
    /// a list they just opened and the stop they were on will still be there
    /// afterwards.
    ///
    /// `acceptChangesText` is Return's condition and Return's alone — see
    /// `acceptChangesText(item:caret:in:)`. Tab means "take this row" and
    /// nothing else, so it is claimed either way; Return means "break the
    /// line" to everybody who has ever used a text editor, and a claim that
    /// spends it on an accept which changes nothing is a keystroke the reader
    /// does not get back. It defaults to true so the every-other-key contract
    /// can still be asserted with two arguments.
    static func completionCommand(
        for selector: Selector,
        isListOpen: Bool,
        hasSnippetSession: Bool,
        acceptChangesText: Bool = true
    ) -> Claim? {
        if isListOpen {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): return .move(.down)
            case #selector(NSResponder.moveUp(_:)): return .move(.up)
            case #selector(NSResponder.scrollPageDown(_:)): return .move(.pageDown)
            case #selector(NSResponder.scrollPageUp(_:)): return .move(.pageUp)
            case #selector(NSResponder.insertNewline(_:)):
                return acceptChangesText ? .accept : nil
            case #selector(NSResponder.insertTab(_:)):
                return .accept
            case #selector(NSResponder.cancelOperation(_:)):
                return .dismiss
            default: return nil
            }
        }

        guard hasSnippetSession else { return nil }
        switch selector {
        case #selector(NSResponder.insertTab(_:)): return .nextField
        case #selector(NSResponder.insertBacktab(_:)): return .previousField
        case #selector(NSResponder.cancelOperation(_:)): return .dismiss
        default: return nil
        }
    }

    /// How many spaces a Tab inserts from a given column.
    ///
    /// Aligned to the next tab stop, not a flat `width` spaces: with a width
    /// of four, a Tab at column two inserts two and lands on four. That is
    /// what makes a column of code line up, and inserting four there instead
    /// would put the next line at six.
    ///
    /// - Parameter column: characters since the start of the line, zero for
    ///   the first one.
    static func spacesForTab(atColumn column: Int, width: Int) -> Int {
        guard width > 0 else { return 1 }
        return width - (column % width)
    }

    /// Characters between the caret and the start of its line.
    ///
    /// Counted in characters rather than in rendered width, which is the
    /// same thing here: this only runs when Tab inserts spaces, so the
    /// leading run is spaces, and a file that mixes in real tabs is one the
    /// reader is already converting away from.
    private var caretColumn: Int {
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let lineStart = text.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: caret)
        )
        guard lineStart.location != NSNotFound else { return caret }
        return caret - NSMaxRange(lineStart)
    }

    /// Return, carrying the line's indentation — and a list's marker — onto
    /// the next line.
    ///
    /// Through `insertText` with a replacement range rather than several
    /// edits, for the reasons `insertTabAsSpacesIfWanted` gives: one undo step
    /// for the whole thing, and one `didChange` for the language server. An
    /// empty list item is the only case that removes anything, and it removes
    /// it as part of the same replacement.
    override func insertNewline(_ sender: Any?) {
        let content = string as NSString
        let caret = selectedRange().location
        guard selectedRange().length == 0, caret <= content.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = content.lineRange(for: NSRange(location: caret, length: 0))
        let line = content.substring(with: lineRange)
        let insertion = CodeNewlineIndent.insertion(
            forLine: line.trimmingTrailingNewline,
            caretInLine: caret - lineRange.location,
            indentUnit: insertsSpacesForTab ? String(repeating: " ", count: max(tabWidth, 1)) : "\t",
            continuesLists: hoverLanguage == .markdown
        )

        /// Nothing but the newline and nothing removed is what
        /// `super.insertNewline` already does, and it does it with the
        /// system's own undo coalescing.
        guard insertion.text != "\n" || insertion.deletingBefore > 0 else {
            super.insertNewline(sender)
            return
        }

        let start = caret - insertion.deletingBefore
        insertText(
            insertion.text,
            replacementRange: NSRange(location: start, length: insertion.deletingBefore))
        setSelectedRange(NSRange(location: start + insertion.caretOffset, length: 0))
    }

    /// Tab as spaces, when that is what the reader asked for.
    ///
    /// `tabWidth` and `insertsSpacesForTab` existed in the configuration and
    /// reached only the *formatting* request sent to the language server —
    /// so a file was formatted with spaces and then typed into with tabs.
    /// Nothing was reading either value on the typing path.
    ///
    /// Goes through `insertText` rather than writing the storage directly, so
    /// it lands in one undo group with the surrounding typing and the edit is
    /// announced to the language server like any other.
    private func insertTabAsSpacesIfWanted() -> Bool {
        guard insertsSpacesForTab else { return false }

        let spaces = Self.spacesForTab(atColumn: caretColumn, width: tabWidth)
        insertText(String(repeating: " ", count: spaces), replacementRange: selectedRange())
        return true
    }

    /// Whether the row Return would take would change anything.
    ///
    /// No selected row is the same answer as a row that changes nothing: there
    /// is nothing to accept, so the keystroke belongs to the document.
    ///
    /// The session is checked first because this is read on **every** command
    /// the view is sent, and a dismissed panel keeps the rows it was last
    /// filled with — so without it this would measure a range against a list
    /// nobody is looking at, on every arrow key.
    private var highlightedRowChangesText: Bool {
        guard isCompletionListOpen, let item = completionPanel?.selectedItem else { return false }
        return Self.acceptChangesText(
            item: item,
            caret: selectedRange().location,
            in: string as NSString
        )
    }

    override func doCommand(by selector: Selector) {
        guard let claim = Self.completionCommand(
            for: selector,
            isListOpen: isCompletionListOpen,
            hasSnippetSession: snippetSession != nil,
            acceptChangesText: highlightedRowChangesText
        ) else {
            /// After the completion claim, never before: a Tab with a list
            /// open accepts the selection, and a Tab inside a snippet moves
            /// to the next field. Only a Tab that means nothing else indents.
            if selector == #selector(NSResponder.insertTab(_:)), insertTabAsSpacesIfWanted() {
                return
            }

            super.doCommand(by: selector)
            return
        }

        switch claim {
        case .move(let movement):
            completionPanel?.moveSelection(movement)
        case .accept:
            completionPanel?.acceptSelection()
        case .dismiss:
            if isCompletionListOpen { dismissCompletions() } else { endSnippet() }
        case .nextField:
            moveSnippetField(by: 1)
        case .previousField:
            moveSnippetField(by: -1)
        }
    }

    /// What each opener closes with. Quotes map to themselves: typing one
    /// is either "open a string" or "step over the one already there"
    /// depending on what is around the caret, and both halves of that
    /// decision need to recognise the same character.
    private static let autoClosingPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}",
        "\"": "\"", "'": "'", "`": "`"
    ]

    private static let quoteCharacters: Set<Character> = ["\"", "'", "`"]

    /// Whether auto-closing is switched on for the class this character
    /// belongs to.
    ///
    /// Stepping over an existing closer is gated on the same answer as
    /// inserting one, and that is a decision rather than an oversight. With
    /// closing switched off nothing was ever inserted for the reader, so a
    /// closer sitting after the caret is one they typed on purpose — stepping
    /// over it would swallow the keystroke that was meant to produce the
    /// second one.
    private func closes(_ character: Character) -> Bool {
        Self.quoteCharacters.contains(character) ? closesQuotes : closesBrackets
    }

    private static func character(in content: NSString, at index: Int) -> Character? {
        guard index >= 0, index < content.length else { return nil }
        return Character(UnicodeScalar(content.character(at: index)) ?? " ")
    }

    /// Every printable character the reader types arrives here, so this is
    /// where both features that react to typing hang: auto-closing, and the
    /// completion list.
    ///
    /// They are split into two calls rather than one body for a reason worth
    /// keeping: the auto-closing half has **four** early returns — a
    /// non-single-character insert, stepping over an existing closer, a quote
    /// touching a word, and the pair insertion itself — and a completion hook
    /// written at the bottom of that body would be skipped by all four. Which
    /// is to say it would fail on exactly the keystrokes where a bracket or a
    /// quote was involved, and work everywhere else, which is the shape of bug
    /// that survives a whole afternoon of testing by hand.
    ///
    /// So auto-closing runs first, unconditionally, on its own paths; the
    /// completion hook runs after, on all of them.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        insertTextClosingBrackets(string, replacementRange: replacementRange)

        /// `last`, not `first`: an input method commits a whole word at once,
        /// and what the list should react to is the character the caret now
        /// sits behind.
        if let typed = (string as? String)?.last {
            insertTextClosingTags(typed)
            completionDidType(typed)
        }
    }

    /// Closes a markup element once the character that decides it is already
    /// in the document.
    ///
    /// A third call rather than two more branches inside the auto-closing
    /// body, for two reasons that both point the same way. Neither `>` nor
    /// `/` is a bracket or a quote, so nothing above ever consumes them —
    /// they always reach the plain insertion at the bottom, which means this
    /// runs on a document that already contains the typed character. And that
    /// is exactly the arrangement `CodeTagClose` wants: it reads the deciding
    /// character out of the text instead of being told what was typed, so the
    /// caller and the scanner cannot disagree about what the buffer says.
    ///
    /// Keeping them out of that body also keeps its "four early returns"
    /// warning true, which is the whole reason the completion hook lives in
    /// the wrapper.
    private func insertTextClosingTags(_ typed: Character) {
        guard closesTags else { return }

        let caret = selectedRange().location
        let content = string as NSString

        let insertion: String?
        switch typed {
        case ">":
            insertion = CodeTagClose.closingTag(in: content, caret: caret, dialect: tagDialect)
        case "/":
            insertion = CodeTagClose.closingTagCompletion(in: content, caret: caret, dialect: tagDialect)
        default:
            return
        }

        guard let insertion else { return }

        /// Through the delegate rather than by writing to the storage
        /// directly: this is what registers a single undo step and what tells
        /// the host the buffer moved. A raw `replaceCharacters` leaves the
        /// language server describing a file that no longer exists — the same
        /// desynchronisation the formatter had.
        let range = NSRange(location: caret, length: 0)
        guard shouldChangeText(in: range, replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: range, with: insertion)
        didChangeText()

        /// Typing `>` leaves the caret **between** the two tags, which is
        /// where the content goes. Completing a `</` puts it after the tag it
        /// just finished, because that element is now closed and there is
        /// nothing left to write inside it.
        setSelectedRange(NSRange(
            location: typed == ">" ? caret : caret + (insertion as NSString).length,
            length: 0
        ))
    }

    /// Closes a bracket or quote as it is typed, and steps over one that is
    /// already there instead of stacking a second — the two halves every
    /// editor with this feature needs before it feels usable rather than
    /// intrusive.
    ///
    /// Quotes skip the close when a letter or digit sits on either side of
    /// the caret: `it's` and `5'` are an apostrophe and a prime mark, not
    /// the start of a string, and auto-closing them anyway is exactly the
    /// kind of wrong guess that gets this feature turned back off.
    private func insertTextClosingBrackets(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String,
              text.count == 1,
              let typed = text.first,
              selectedRange().length == 0
        else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let caret = selectedRange().location
        let content = self.string as NSString
        let after = Self.character(in: content, at: caret)

        if let after, after == typed, Self.autoClosingPairs.values.contains(typed), closes(typed) {
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        if let closing = Self.autoClosingPairs[typed], closes(typed) {
            if Self.quoteCharacters.contains(typed) {
                let before = Self.character(in: content, at: caret - 1)
                let touchesAWord = [before, after].contains { $0?.isLetter == true || $0?.isNumber == true }
                if touchesAWord {
                    super.insertText(string, replacementRange: replacementRange)
                    return
                }
            }

            super.insertText("\(typed)\(closing)", replacementRange: replacementRange)
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    /// Deleting backwards, with the same split as `insertText` and for the
    /// same reason: the pair-removal below returns early, and the completion
    /// list has to hear about the deletion either way.
    override func deleteBackward(_ sender: Any?) {
        deleteBackwardClosingPair(sender)
        completionDidDelete()
    }

    /// Backspacing between an empty auto-closed pair removes both halves in
    /// one step. Without this, closing a bracket auto-close put there for
    /// you — and that you then changed your mind about — takes two
    /// backspaces where every other editor with this feature takes one.
    private func deleteBackwardClosingPair(_ sender: Any?) {
        let caret = selectedRange().location
        if selectedRange().length == 0, caret > 0 {
            let content = self.string as NSString
            if let before = Self.character(in: content, at: caret - 1),
               let after = Self.character(in: content, at: caret),
               Self.autoClosingPairs[before] == after,
               closes(before) {
                /// Through the delegate, for the reason the tag path above
                /// gives: a raw `replaceCharacters` registers no undo step
                /// and tells nobody the buffer moved. Deleting the pair was
                /// therefore unundoable, and left the language server
                /// describing two characters that are no longer there.
                /// `textStorage`, not `super.replaceCharacters`: the latter
                /// is `NSText`'s and does not go through the machinery
                /// `shouldChangeText` primes, so the pair came back deleted
                /// with nothing on the undo stack. Measured — the test below
                /// fails on the other spelling.
                let pair = NSRange(location: caret - 1, length: 2)
                guard shouldChangeText(in: pair, replacementString: "") else { return }
                textStorage?.replaceCharacters(in: pair, with: "")
                didChangeText()
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// The command the reader bound to this event, if any.
    ///
    /// Ids are sorted so two commands sharing a combination resolve the same
    /// way every time. The app refuses to store a collision, but a
    /// dictionary's order is not a promise, and "works until you restart" is
    /// the worst shape a shortcut bug takes.
    private func boundCommand(for event: NSEvent) -> String? {
        commandShortcuts.keys.sorted().first { id in
            commandShortcuts[id]?.contains { $0.matches(event) } == true
        }
    }

    /// Runs a command by id, answering whether it was this view's to run.
    ///
    /// The caret is read here rather than passed in because the symbol
    /// commands mean "the one I am on", and a shortcut has no pointer to
    /// speak of — unlike the context menu, which anchors to where you
    /// right-clicked.
    private func runCommand(_ id: String) -> Bool {
        let caret = selectedRange().location

        switch id {
        case "save": onSave?()
        case "saveAll": onSaveAll?()
        case "closeTab":
            guard let onCloseTab else { return false }
            onCloseTab()
        case "searchWorkspace":
            guard let onSearchWorkspace else { return false }
            onSearchWorkspace()
        case "findInFile":
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(sender)
        case "goToDefinition":
            guard let onJumpToDefinition else { return false }
            onJumpToDefinition(caret)
        case "findReferences":
            guard let onFindReferences else { return false }
            onFindReferences(caret)
        case "renameSymbol":
            guard let onRename else { return false }
            onRename(caret)
        case "formatDocument":
            guard let onFormat else { return false }
            onFormat()
        case "moveLineUp":
            moveSelectedLines(.up)
        case "moveLineDown":
            moveSelectedLines(.down)
        case "attachLineToAgent":
            guard let onAttachLine else { return false }
            onAttachLine(selectedRange(), string)
        case "attachLineToAgentPicker":
            guard let onAttachLinePicker else { return false }
            onAttachLinePicker(selectedRange(), string)
        default:
            return false
        }
        return true
    }

    /// Swaps the caret's line — or every line the selection touches — with its
    /// neighbour.
    ///
    /// Through `insertText` with a replacement range, for the reason
    /// `insertNewline` gives: one undo step for the whole move and one
    /// `didChange` for the language server, instead of a delete and an insert
    /// the reader has to undo twice.
    ///
    /// A move with nowhere to go is still this view's key to swallow. Falling
    /// through at the top or bottom of a file would hand ⇧⌥↑ back to AppKit,
    /// which reads it as "extend the selection by a paragraph" — so holding the
    /// shortcut would stop moving lines and start selecting them.
    private func moveSelectedLines(_ direction: CodeLineMove.Direction) {
        guard let move = CodeLineMove.move(
            in: string as NSString, selection: selectedRange(), direction: direction)
        else { return }

        insertText(move.text, replacementRange: move.replacement)
        setSelectedRange(move.selection)
    }

    /// The reader's own bindings, and nothing else.
    ///
    /// What used to follow this was a hardcoded `switch` answering ⌘S, ⇧⌘S,
    /// ⇧⌘F, ⌘F, ⌃⌘R, ⌥⌘F, ⌃⌘G and ⌘W whenever the lookup above missed. Its
    /// comment called that "keeping the defaults working", which it was not:
    /// `PhantomShortcutStore` already returns each action's default until the
    /// reader touches it, and an empty list once they clear it. So the
    /// fallback could only ever fire *against* an explicit choice — a cleared
    /// Save still saved, a Save moved to ⌥⌘S still answered ⌘S. `runCommand`
    /// covers all fifteen ids, ⌘F's text-finder plumbing included, so nothing
    /// is lost by deleting it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        /// Focus, not visibility, and not tree order.
        ///
        /// `performKeyEquivalent` is offered to the whole view tree of the key
        /// window, so a hidden editor is still asked — and this view had no
        /// guard of any kind. The contract stated in `PhantomShortcutAction`
        /// is "these answer while a file is open **and focused**, so the
        /// terminal keeps its own keys everywhere else", and until now that
        /// held only because of where the two views happen to sit relative to
        /// each other. It holds by construction now.
        guard holdsFocus else { return super.performKeyEquivalent(with: event) }

        if let id = boundCommand(for: event), runCommand(id) { return true }

        return super.performKeyEquivalent(with: event)
    }

    /// Whether the caret is in this view — directly, or in something it owns.
    private var holdsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: self)
    }

    /// This view's own undo stack.
    ///
    /// `NSTextView` asks the responder chain for an undo manager, and in this
    /// app the window's delegate answers with the *application's* one — the
    /// manager Ghostty uses to undo closing a split or a tab. So ⌘Z in the
    /// editor performed a window operation instead of undoing a keystroke, and
    /// typing registered nothing anybody could reach.
    ///
    /// Owning one here keeps the two apart: text undo belongs to the buffer,
    /// window undo belongs to the window, and neither can consume the other's
    /// ⌘Z because only one of them has focus at a time.
    private let textUndoManager = UndoManager()

    override var undoManager: UndoManager? { textUndoManager }

    /// ⌘Z, answered by the view that holds the text.
    ///
    /// The Undo item is wired to `undo:` on the first responder, and nothing
    /// in the editor's chain answered it. The search walked past this view
    /// and past the window — whose delegate hands back the *application's*
    /// manager, the one that takes back closing a tab — so the item was
    /// validated against a stack that typing never touches. It stayed grey,
    /// and a disabled item does not consume its key equivalent: ⌘Z fell
    /// through to `keyDown`, where nothing maps it, and the beep was macOS
    /// saying exactly that — over a perfectly good undo stack that had been
    /// sitting on this view the whole time.
    ///
    /// Answering here puts the question where the text is. Window undo is
    /// untouched, because this view is in the responder chain only while it
    /// holds focus, which is precisely when ⌘Z means "take back what I
    /// typed".
    @objc func undo(_ sender: Any?) {
        guard textUndoManager.canUndo else { return }
        textUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard textUndoManager.canRedo else { return }
        textUndoManager.redo()
    }

    /// Validated against the same manager the action uses.
    ///
    /// The two disagreeing is its own bug: enabled over an empty stack reads
    /// as a dead key, and grey over a full one reads as lost work.
    ///
    /// The title is written here rather than left alone because the item is
    /// shared with the window's undo, and whoever validated last owns what it
    /// says — so leaving it would mean editing text under a menu still
    /// offering to undo closing a tab.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = Self.undoTitle("Undo", actionName: textUndoManager.undoActionName)
            return textUndoManager.canUndo

        case #selector(redo(_:)):
            item.title = Self.undoTitle("Redo", actionName: textUndoManager.redoActionName)
            return textUndoManager.canRedo

        default:
            return super.validateMenuItem(item)
        }
    }

    /// AppKit's convention for these two items: the verb alone when the stack
    /// cannot name what it holds, and the verb plus that name when it can.
    private static func undoTitle(_ verb: String, actionName: String) -> String {
        actionName.isEmpty ? verb : "\(verb) \(actionName)"
    }

    /// True when this view is laying out through TextKit 2.
    ///
    /// Exists for the test. The failure it guards against is invisible at
    /// runtime — everything still works, just with the whole document laid
    /// out on every change — so nothing else would ever notice.
    var isUsingTextKit2: Bool { textLayoutManager != nil }
}

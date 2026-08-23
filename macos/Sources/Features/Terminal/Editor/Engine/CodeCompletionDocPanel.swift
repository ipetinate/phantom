import AppKit

/// The prose a server wrote about one symbol, and whether it is markdown.
///
/// **The flag is not decoration.** A server states the format explicitly, and
/// the two are rendered by different paths: markdown is split into a
/// declaration and its documentation and reflowed, plain text is drawn exactly
/// as it arrived. Running the markdown path over plain text eats horizontal
/// rules and reflows paragraphs whose line breaks were the author's meaning —
/// which is why this arrives as a value carrying its own format rather than as
/// a `String` this panel guesses about.
///
/// A plain value for the same reason as `CodeTheme`: the engine draws this and
/// never learns where it came from, or that fetching it involved a second
/// request that could be superseded.
struct CodeDocumentation: Equatable, Sendable {
    enum Format: Equatable, Sendable {
        case plainText
        case markdown
    }

    var format: Format
    var text: String

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The card beside the completion list, describing the highlighted row.
///
/// A second panel rather than a section of the list, because the two have
/// different shapes and different lifetimes on screen: the list is a narrow
/// column that grows with the number of matches, and this is a paragraph of
/// prose that arrives later and sometimes not at all. It dies with the list.
///
/// It shares the list's constraints exactly — non-activating, never key, a
/// child window of the editor's window — and for the same reason. See
/// `CodeCompletionPanel`'s header, which is where that reasoning is written
/// down; the short version is that a panel that takes key status stops the
/// caret blinking and takes the arrow keys away from the list it belongs to.
///
/// **What it is really for is telling four answers apart**, and every one of
/// them is a `static` over values so the discrimination can be tested without a
/// window: documentation arrived, the server answered and had none, the answer
/// was about a list that no longer exists, and the server cannot answer at all.
/// `rendering(for:)` and `state(after:current:)` are those two decisions.
final class CodeCompletionDocPanel: NSPanel {
    /// What the host learned about the highlighted row's documentation.
    ///
    /// Four cases, deliberately fewer than the host's own: the panel is not
    /// allowed to know that a request, a cancellation or a timeout exists, so
    /// the host collapses its outcomes into these on the way in. Two of those
    /// collapses are worth stating, because both are the *common* path rather
    /// than an error case:
    ///
    /// - A superseded answer and a cancelled one are the same thing here. A new
    ///   request cancels the one before it, so arrow-keying down a list produces
    ///   a cancellation per row; treating that as "there is no documentation"
    ///   would blank the card on every keypress, which is precisely the flicker
    ///   this enum exists to prevent.
    /// - No server, a timeout and an outright failure all become `unanswered`.
    ///   They differ in cause and not in consequence — the card has nothing to
    ///   draw and asking again is the host's business, not the card's.
    enum Outcome: Equatable, Sendable {
        /// The answer arrived. `nil` means the server answered and had nothing,
        /// which is a settled fact and not a missing one.
        case resolved(CodeDocumentation?)

        /// The answer was about a list that no longer exists.
        case superseded

        /// The server declares that it cannot describe individual items, ever.
        case unsupported

        /// Asked, and got nothing usable back.
        case unanswered
    }

    /// What the card is currently saying.
    ///
    /// `unsupported` and `unanswered` draw identically — both leave the body
    /// blank — and are still separate cases on purpose: one is permanent and one
    /// is not, so a retry wired onto the wrong one either spins forever against
    /// a server that will never answer or gives up on one that would have.
    enum State: Equatable, Sendable {
        case hidden
        case loading
        case documentation(CodeDocumentation)

        /// The server answered and had no documentation for this item.
        case absent

        /// The server has no per-item documentation to give.
        ///
        /// **This is a fact about the server, not a bug to chase.**
        /// `kotlin-language-server` 1.3.13 declares no resolve support and sends
        /// no documentation with its items either, so for Kotlin this card is
        /// legitimately and permanently empty no matter what this editor does.
        /// It gets no spinner, no retry and no "loading" — every one of which
        /// would be a promise the server has already said it will not keep.
        case unsupported

        /// Asked, and nothing usable came back.
        case unanswered
    }

    /// Everything the card draws, as one value.
    ///
    /// `detail` is the highlighted row's own detail column — a type, a module —
    /// which the list already has in hand and which needs no request at all. It
    /// is drawn as the signature line the instant the selection moves, so that
    /// arrow-keying down a list never leaves an empty card waiting on a server:
    /// something true about the row is on screen before the request is even
    /// sent, and the documentation fills in under it.
    struct Content: Equatable {
        var state: State
        var detail: String?

        init(state: State, detail: String? = nil) {
            self.state = state
            self.detail = detail
        }
    }

    /// What actually goes on the card, once the state has been read.
    struct Rendering: Equatable {
        var signature: String?
        var body: String?

        /// Whether `body` is prose from the server or a line this card wrote
        /// about itself. The two are drawn differently — the server's words in
        /// the reader's prose colour, the card's own dimmed and italicised —
        /// because a card that says "No documentation" in the same voice as the
        /// documentation is claiming the symbol is documented as "No
        /// documentation".
        var isBodyStatus: Bool

        var isEmpty: Bool { signature == nil && body == nil }
    }

    static let maximumWidth: CGFloat = 420
    static let maximumHeight: CGFloat = 320

    /// Shown while a request is in flight, and only ever when the server said it
    /// supports one.
    static let loadingText = "Loading…"

    /// Shown when the server answered and had nothing. Drawn once and left
    /// alone: it is an answer, so there is nothing further to wait for.
    static let absentText = "No documentation"

    private let inset: CGFloat = 10

    private let card = CardView()
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let container = NSStackView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.maximumWidth, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow

        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(container)
        scrollView.documentView = document
        card.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            container.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            container.topAnchor.constraint(equalTo: document.topAnchor),
            container.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        contentView = card
    }

    /// Unconditionally, and for the same reason as the list — see
    /// `CodeCompletionPanel`. This card is beside a list being steered by the
    /// arrow keys, and a card that can take key status takes those keys.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    // MARK: - Decisions

    /// The state a fresh selection starts in.
    ///
    /// `supportsResolve` is the whole gate on the loading state: a spinner is a
    /// promise that an answer is coming, so it is only honest against a server
    /// that said it can answer. Against one that cannot the card goes straight
    /// to `unsupported` and stays there.
    static func state(hasSelection: Bool, supportsResolve: Bool) -> State {
        guard hasSelection else { return .hidden }
        guard supportsResolve else { return .unsupported }
        return .loading
    }

    /// The state after an answer arrives.
    ///
    /// `superseded` returns `current` **unchanged**, and that single line is
    /// what this function exists for. A superseded answer says "this is about a
    /// list that no longer exists", which is not the same claim as "there is
    /// nothing here" — and since every new request cancels the one before it,
    /// it is the answer that arrives most often of all. Blanking on it makes the
    /// card strobe under the arrow keys.
    ///
    /// `unanswered` clears only a card that was still waiting. Documentation
    /// already on screen is left alone: it is about the row that is still
    /// highlighted, and replacing something true with nothing because a *later*
    /// request timed out would be a strictly worse card.
    ///
    /// Documentation that arrives empty is `absent` rather than
    /// `documentation("")`, so the "nothing to say" case has exactly one
    /// representation and cannot be drawn as a blank paragraph by mistake.
    static func state(after outcome: Outcome, current: State) -> State {
        switch outcome {
        case .resolved(let documentation):
            guard let documentation, !documentation.isEmpty else { return .absent }
            return .documentation(documentation)
        case .superseded:
            /// Keeping what is on screen is right while there is something on
            /// screen, and wrong while the card is still waiting: a superseded
            /// answer is an answer, so nothing further is coming for it, and
            /// leaving `loading` up promises a card that will never arrive.
            /// Observed exactly that — the first resolve of a fresh selection
            /// came back superseded and the card said "Loading…" indefinitely.
            return current == .loading ? .unanswered : current
        case .unsupported:
            return .unsupported
        case .unanswered:
            return current == .loading ? .unanswered : current
        }
    }

    /// The declaration and the prose, pulled apart according to the format the
    /// server declared.
    ///
    /// Markdown goes through the same split the hover card uses — the servers
    /// measured here lead with the declaration in a fenced block and follow it
    /// with prose, and keeping the two apart is what lets the declaration be
    /// drawn in the editor's font while the prose stays readable text.
    ///
    /// Plain text goes through **nothing**. That asymmetry is the point: the
    /// split drops horizontal rules and rejoins single-newline runs into
    /// paragraphs, both of which are correct for markdown and destructive for
    /// text whose line breaks were meant literally.
    static func parts(of documentation: CodeDocumentation) -> (signature: String?, body: String?) {
        switch documentation.format {
        case .markdown:
            let split = CodeHoverInfo.split(markdown: documentation.text)
            return (Self.flattened(split.signature), Self.flattened(split.documentation))
        case .plainText:
            let text = documentation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, text.isEmpty ? nil : text)
        }
    }

    /// The split's blocks as the two flat strings this card draws.
    ///
    /// The hover card keeps them apart so each fence can be coloured by the
    /// language its tag names; this one draws one signature line and one body
    /// and has a `detail` of its own to fall back on, so the structure has
    /// nowhere to go. Joining prose and code with a blank line reproduces
    /// exactly what the split used to hand back — the same separator its own
    /// assembly step put between two blocks of different kinds.
    private static func flattened(_ blocks: [CodeHoverInfo.Block]) -> String? {
        let joined = blocks.map(text(of:)).joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func flattened(_ block: CodeHoverInfo.Block?) -> String? {
        block.map(text(of:))
    }

    private static func text(of block: CodeHoverInfo.Block) -> String {
        switch block {
        case .prose(let text): return text
        case .code(let source, _): return source
        }
    }

    /// What each state puts on the card.
    ///
    /// - `hidden` draws nothing and the card is put away.
    /// - `loading` keeps the row's own detail on screen and adds the waiting
    ///   line under it, so the card is never empty while a request is out.
    /// - `documentation` prefers the declaration the server wrote over the
    ///   row's detail, because the resolved one is the fuller of the two — the
    ///   detail column is a summary sized for a list.
    /// - `absent` says so, once.
    /// - `unsupported` and `unanswered` draw the detail alone. Nothing is added
    ///   under it: with no documentation coming, a status line would be the card
    ///   explaining its own plumbing to somebody who asked about a symbol.
    static func rendering(for content: Content) -> Rendering {
        switch content.state {
        case .hidden:
            return Rendering(signature: nil, body: nil, isBodyStatus: false)
        case .loading:
            return Rendering(signature: content.detail, body: loadingText, isBodyStatus: true)
        case .documentation(let documentation):
            let parts = parts(of: documentation)
            return Rendering(
                signature: parts.signature ?? content.detail,
                body: parts.body,
                isBodyStatus: false
            )
        case .absent:
            return Rendering(signature: content.detail, body: absentText, isBodyStatus: true)
        case .unsupported, .unanswered:
            return Rendering(signature: content.detail, body: nil, isBodyStatus: false)
        }
    }

    // MARK: - Geometry

    /// The card's bottom-left corner: to the right of the list, flipping to its
    /// left when it does not fit, and top-aligned with it.
    ///
    /// A separate function from `PanelPlacement.origin` rather than a case added
    /// to it, because it is a different decision on a different axis. That one
    /// flips *vertically* around a line of text and lines the panel up with the
    /// line's left edge; this one flips *horizontally* around a panel and lines
    /// the card's top up with the list's top. Folding both into one function
    /// would mean an `Edge` with four cases of which each caller uses two, and
    /// an alignment rule that changes meaning depending on which case was
    /// passed. The clamp is shared, which is the part that was actually worth
    /// sharing.
    ///
    /// Right first because the list is anchored to the prefix being typed and
    /// the code being written continues to the right of it, so the card lands on
    /// the emptier side of the screen more often than not.
    static func origin(beside list: NSRect, size: NSSize, visible: NSRect) -> NSPoint {
        let right = list.maxX + PanelPlacement.gap
        let left = list.minX - PanelPlacement.gap - size.width

        var origin = NSPoint(x: right, y: list.maxY - size.height)
        if right + size.width > visible.maxX, left >= visible.minX {
            origin.x = left
        }

        origin.x = min(
            max(origin.x, visible.minX + PanelPlacement.margin),
            max(visible.maxX - size.width - PanelPlacement.margin, visible.minX)
        )
        origin.y = min(
            max(origin.y, visible.minY + PanelPlacement.margin),
            max(visible.maxY - size.height - PanelPlacement.margin, visible.minY)
        )
        return origin
    }

    // MARK: - Presenting

    /// Draws `content` beside `list`, both in screen coordinates.
    ///
    /// A rendering with nothing in it dismisses instead of presenting, which is
    /// what keeps an empty card off the screen for Kotlin and is also what lets
    /// a test call this: the guard returns before `orderFront`, and asking the
    /// window server to show a window from a host with no running event loop
    /// hangs that call forever rather than failing it.
    func present(
        _ content: Content,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage,
        beside list: NSRect,
        over view: NSView
    ) {
        let rendering = Self.rendering(for: content)
        guard !rendering.isEmpty, let parentWindow = view.window else {
            dismiss()
            return
        }
        let screen = parentWindow.screen ?? NSScreen.main

        fill(rendering, theme: theme, font: font, language: language, on: screen)
        setFrameOrigin(Self.origin(
            beside: list,
            size: frame.size,
            visible: screen?.visibleFrame ?? NSRect(origin: .zero, size: frame.size)
        ))

        if parent == nil { parentWindow.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    // MARK: - Content

    private func fill(
        _ rendering: Rendering,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage,
        on screen: NSScreen?
    ) {
        container.views.forEach { $0.removeFromSuperview() }

        card.layer?.backgroundColor = theme.background.withAlphaComponent(1).cgColor
        card.layer?.borderColor = theme.foreground.withAlphaComponent(0.18).cgColor

        let width = Self.maximumWidth - inset * 2

        if let signature = rendering.signature {
            container.addView(
                CodeHoverPanel.label(
                    Self.signatureText(signature, theme: theme, font: font, language: language),
                    width: width
                ),
                in: .top
            )
        }

        if let body = rendering.body {
            let text = rendering.isBodyStatus
                ? Self.statusText(body, theme: theme, font: font)
                : Self.proseText(
                    body,
                    font: .systemFont(ofSize: font.pointSize + 1),
                    color: theme.foreground.withAlphaComponent(0.75)
                )
            container.addView(CodeHoverPanel.label(text, width: width), in: .top)
        }

        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        let ceiling = min(
            Self.maximumHeight,
            max(120, (screen?.visibleFrame.height ?? Self.maximumHeight) - 80)
        )
        setContentSize(NSSize(
            width: min(fitting.width, width) + inset * 2,
            height: min(fitting.height, ceiling) + inset * 2
        ))
    }

    /// The declaration, coloured by the same highlighter the editor uses, so the
    /// card looks like it belongs to the file underneath it.
    ///
    /// This and `proseText` below are the pair the hover card also needs, and
    /// they are `static` and internal here so there is one implementation of
    /// each rather than two drifting ones.
    static func signatureText(
        _ text: String,
        theme: CodeTheme,
        font: NSFont,
        language: CodeLanguage
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: theme.foreground,
        ])
        let full = NSRange(location: 0, length: (text as NSString).length)
        for token in SyntaxHighlighter(language: language).tokens(in: text, range: full) {
            result.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        return result
    }

    /// Documentation, with markdown's inline marks honoured.
    ///
    /// Inline only: a server's documentation is a paragraph with `code spans`
    /// and emphasis in it, not a document with headings and lists. Parsing it as
    /// a full document would reflow whitespace the author meant to keep, and
    /// failing to parse it at all would leave backticks on screen.
    static func proseText(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        let result = NSMutableAttributedString(
            attributedString: parsed.map { NSAttributedString($0) }
                ?? NSAttributedString(string: markdown)
        )

        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: font, .foregroundColor: color], range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    range: range
                )
            }
            if intent.contains(.stronglyEmphasized) {
                result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: range)
            }
        }
        return result
    }

    /// The card's own voice — dimmer and italic, so "No documentation" cannot be
    /// mistaken for something the server said about the symbol.
    ///
    /// Not run through the markdown parser, deliberately: these strings are
    /// written here, so parsing them would only give a future one the chance to
    /// contain a character that changes how it draws.
    static func statusText(_ text: String, theme: CodeTheme, font: NSFont) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: font.pointSize)
        let italic = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: base.pointSize)
            ?? base
        return NSAttributedString(string: text, attributes: [
            .font: italic,
            .foregroundColor: theme.foreground.withAlphaComponent(0.45),
        ])
    }

    /// A document view that grows downwards, so "scroll to zero" means the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The card's background.
    ///
    /// No tracking area, unlike the hover card's: this card appears because of
    /// the *keyboard*, not the pointer, so it has no reason to notice the
    /// pointer leaving and every reason not to — it lives beside a list the
    /// pointer crosses on its way anywhere.
    private final class CardView: NSView {
        override var isFlipped: Bool { true }
    }
}

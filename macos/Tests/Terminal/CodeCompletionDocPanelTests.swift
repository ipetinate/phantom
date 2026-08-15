import AppKit
@testable import Ghostty
import Testing

/// The documentation card's four answers, told apart without a window.
///
/// The whole risk in this card is confusing them, and each confusion has a
/// different symptom: a superseded answer read as "nothing here" makes the card
/// strobe under the arrow keys, a server that cannot resolve read as "still
/// loading" spins forever, and prose read as markdown quietly loses the line
/// breaks its author meant. There is one test below per confusion.
///
/// Nothing here presents. `NSWindow.isVisible` only becomes true by asking the
/// window server to display something, and doing that from this test host —
/// which has no running `NSApplication` event loop — hangs the call forever
/// rather than returning.
@MainActor
struct CodeCompletionDocPanelTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private let theme = CodeTheme(
        foreground: NSColor(calibratedWhite: 0.9, alpha: 1),
        background: NSColor(calibratedWhite: 0.1, alpha: 1),
        tokens: [.keyword: NSColor(calibratedRed: 0.8, green: 0.4, blue: 1, alpha: 1)],
        lineNumber: NSColor(calibratedWhite: 0.5, alpha: 1),
        currentLineNumber: NSColor(calibratedWhite: 0.7, alpha: 1),
        currentLineBackground: nil
    )

    private func markdown(_ text: String) -> CodeDocumentation {
        CodeDocumentation(format: .markdown, text: text)
    }

    private func plainText(_ text: String) -> CodeDocumentation {
        CodeDocumentation(format: .plainText, text: text)
    }

    // MARK: - Where a selection starts

    @Test func nothingSelectedHidesTheCard() {
        #expect(CodeCompletionDocPanel.state(hasSelection: false, supportsResolve: true) == .hidden)
    }

    /// A spinner is a promise that an answer is coming, so it is only honest
    /// against a server that said it can answer. This is the gate that keeps
    /// Kotlin — which declares no resolve support and sends no per-item
    /// documentation at all — from showing a loading state it will never leave.
    @Test func aServerThatCannotResolveNeverShowsALoadingState() {
        #expect(CodeCompletionDocPanel.state(hasSelection: true, supportsResolve: false) == .unsupported)
    }

    @Test func aServerThatCanResolveStartsLoading() {
        #expect(CodeCompletionDocPanel.state(hasSelection: true, supportsResolve: true) == .loading)
    }

    // MARK: - What an answer does

    @Test func documentationThatArrivesIsDrawn() {
        let documentation = markdown("Does a thing.")
        let state = CodeCompletionDocPanel.state(after: .resolved(documentation), current: .loading)

        #expect(state == .documentation(documentation))
    }

    /// "The server answered and had nothing" is a settled fact, so it gets its
    /// own state rather than an empty `documentation` — which would be drawn as
    /// a blank paragraph and read as a card that failed to load.
    @Test func aServerThatAnsweredWithNothingSettlesOnAbsent() {
        #expect(CodeCompletionDocPanel.state(after: .resolved(nil), current: .loading) == .absent)
        #expect(
            CodeCompletionDocPanel.state(after: .resolved(markdown("  \n ")), current: .loading) == .absent
        )
    }

    /// The anti-flicker invariant, and the reason this reducer exists at all.
    ///
    /// A new request cancels the one before it, so arrow-keying down a list
    /// produces one superseded answer per row — it is the *common* case, not an
    /// error. Every one of them must leave the card exactly as it was; blanking
    /// on them makes the card strobe under the keys being used to read it.
    @Test func aSupersededAnswerLeavesAnAnsweredCardExactlyAsItWas() {
        let states: [CodeCompletionDocPanel.State] = [
            .hidden,
            .documentation(markdown("Does a thing.")),
            .absent,
            .unsupported,
            .unanswered,
        ]

        for state in states {
            #expect(CodeCompletionDocPanel.state(after: .superseded, current: state) == state)
        }
    }

    /// The one state a superseded answer does *not* preserve, and the reason
    /// the rule above says "answered" rather than "any".
    ///
    /// Preserving what is on screen is right while there is something on
    /// screen. While the card is still waiting there is nothing to preserve —
    /// and a superseded answer **is** an answer, so no further one is coming
    /// for it. Leaving `loading` up promises a card that will never arrive.
    ///
    /// Observed, not theorised: the first resolve of a fresh selection came
    /// back superseded and the card read "Loading…" indefinitely.
    ///
    /// Worth knowing why superseded turns up on a *first* request at all —
    /// `typescript-language-server`'s resolve cache is a **single slot** keyed
    /// by an integer, and any later `textDocument/completion` invalidates the
    /// previous list's ids without erroring, answering about the wrong symbol
    /// instead. Measured: resolving a `ref` from an earlier list after a newer
    /// one came back describing `AnalyserNode`. Refusing that is a correctness
    /// requirement, so an empty card here is the *right* failure — the
    /// alternative is confidently wrong prose.
    @Test func aSupersededAnswerStopsACardThatWasStillWaiting() {
        #expect(CodeCompletionDocPanel.state(after: .superseded, current: .loading) == .unanswered)
    }

    /// Permanent, and it overrides whatever was on screen: the server has said
    /// it will never describe individual items, so anything still drawn is about
    /// a question that cannot be asked again.
    @Test func unsupportedIsPermanentWhateverThePreviousStateWas() {
        #expect(CodeCompletionDocPanel.state(after: .unsupported, current: .loading) == .unsupported)
        #expect(
            CodeCompletionDocPanel.state(
                after: .unsupported,
                current: .documentation(markdown("stale"))
            ) == .unsupported
        )
    }

    /// A timeout clears a card that was still waiting and leaves one that is
    /// already saying something true. Replacing real documentation about the
    /// highlighted row with nothing, because some later request timed out, is a
    /// strictly worse card.
    @Test func aFailedAnswerClearsOnlyACardThatWasStillWaiting() {
        let documentation = markdown("Does a thing.")

        #expect(CodeCompletionDocPanel.state(after: .unanswered, current: .loading) == .unanswered)
        #expect(
            CodeCompletionDocPanel.state(after: .unanswered, current: .documentation(documentation))
                == .documentation(documentation)
        )
        #expect(CodeCompletionDocPanel.state(after: .unanswered, current: .absent) == .absent)
    }

    // MARK: - Honouring the declared format

    /// Markdown is split into the declaration the server fenced and the prose
    /// that followed it, so the declaration can be drawn in the editor's own
    /// font and colours.
    @Test func markdownIsSplitIntoDeclarationAndProse() {
        let parts = CodeCompletionDocPanel.parts(
            of: markdown("```swift\nfunc connect() -> Socket\n```\n\nOpens a socket.")
        )

        #expect(parts.signature == "func connect() -> Socket")
        #expect(parts.body == "Opens a socket.")
    }

    /// The asymmetry that the format flag exists for. The markdown split drops
    /// horizontal rules and rejoins single-newline runs into paragraphs — both
    /// correct for markdown, both destructive for text whose line breaks were
    /// meant literally. Plain text goes through nothing at all.
    @Test func plainTextIsNotRunThroughTheMarkdownSplit() {
        let text = "Usage:\n  connect(host)\n---\nReturns a socket."
        let parts = CodeCompletionDocPanel.parts(of: plainText(text))

        #expect(parts.signature == nil)
        #expect(parts.body == text, "plain text must survive verbatim, rules and line breaks included")
    }

    @Test func emptyPlainTextHasNoBody() {
        #expect(CodeCompletionDocPanel.parts(of: plainText("   \n  ")).body == nil)
    }

    // MARK: - What each state draws

    /// Nothing is left waiting on a server: the row's own detail is on the card
    /// before the request is even sent.
    @Test func loadingKeepsTheRowsDetailOnScreen() {
        let rendering = CodeCompletionDocPanel.rendering(
            for: .init(state: .loading, detail: "(method) connect(host: string): Socket")
        )

        #expect(rendering.signature == "(method) connect(host: string): Socket")
        #expect(rendering.body == CodeCompletionDocPanel.loadingText)
        #expect(rendering.isBodyStatus)
    }

    /// Said once, in the card's own voice. A card that says "No documentation"
    /// in the same voice as the documentation is claiming the symbol is
    /// documented as "No documentation".
    @Test func absentSaysSoInTheCardsOwnVoice() {
        let rendering = CodeCompletionDocPanel.rendering(for: .init(state: .absent, detail: "String"))

        #expect(rendering.body == CodeCompletionDocPanel.absentText)
        #expect(rendering.isBodyStatus)
    }

    /// Kotlin's permanent state, drawn: the detail alone, and no status line
    /// under it. With nothing coming, a status line would be the card explaining
    /// its own plumbing to somebody who asked about a symbol.
    @Test func aServerWithNoResolveDrawsTheDetailAloneAndNoStatusLine() {
        let rendering = CodeCompletionDocPanel.rendering(
            for: .init(state: .unsupported, detail: "kotlin.collections.List")
        )

        #expect(rendering.signature == "kotlin.collections.List")
        #expect(rendering.body == nil)
        #expect(!rendering.isEmpty)
    }

    @Test func anUnansweredRequestAlsoDrawsTheDetailAlone() {
        let rendering = CodeCompletionDocPanel.rendering(for: .init(state: .unanswered, detail: "Socket"))

        #expect(rendering.signature == "Socket")
        #expect(rendering.body == nil)
    }

    /// The Kotlin row with no detail either — nothing at all to draw — so the
    /// card is not shown rather than shown empty.
    @Test func aRowWithNothingKnownAboutItRendersNothing() {
        #expect(CodeCompletionDocPanel.rendering(for: .init(state: .unsupported)).isEmpty)
        #expect(CodeCompletionDocPanel.rendering(for: .init(state: .hidden, detail: "String")).isEmpty)
    }

    /// The resolved declaration is the fuller of the two — a detail column is a
    /// summary sized for a list — so it replaces the detail once it arrives.
    @Test func aResolvedDeclarationOutranksTheRowsDetail() {
        let rendering = CodeCompletionDocPanel.rendering(for: .init(
            state: .documentation(markdown("```ts\nfunction connect(host: string): Socket\n```\n\nOpens it.")),
            detail: "Socket"
        ))

        #expect(rendering.signature == "function connect(host: string): Socket")
        #expect(rendering.body == "Opens it.")
        #expect(!rendering.isBodyStatus)
    }

    /// Documentation with no fenced declaration in it keeps the row's detail as
    /// the signature line, rather than dropping the one type the reader had.
    @Test func documentationWithNoDeclarationFallsBackToTheRowsDetail() {
        let rendering = CodeCompletionDocPanel.rendering(for: .init(
            state: .documentation(plainText("Opens a socket.")),
            detail: "Socket"
        ))

        #expect(rendering.signature == "Socket")
        #expect(rendering.body == "Opens a socket.")
    }

    // MARK: - Geometry

    private let list = NSRect(x: 300, y: 400, width: 260, height: 200)
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 400, height: 300)

    @Test func theCardSitsToTheRightOfTheList() {
        let point = CodeCompletionDocPanel.origin(beside: list, size: size, visible: visible)

        #expect(point.x == list.maxX + PanelPlacement.gap)
    }

    /// Its top lines up with the list's, so the two read as one object rather
    /// than two windows that happen to overlap.
    @Test func theCardsTopLinesUpWithTheLists() {
        let point = CodeCompletionDocPanel.origin(beside: list, size: size, visible: visible)

        #expect(point.y + size.height == list.maxY)
    }

    @Test func theCardFlipsToTheLeftWhenThereIsNoRoomOnTheRight() {
        let atRightEdge = NSRect(x: 1100, y: 400, width: 260, height: 200)
        let point = CodeCompletionDocPanel.origin(beside: atRightEdge, size: size, visible: visible)

        #expect(point.x == atRightEdge.minX - PanelPlacement.gap - size.width)
    }

    /// Neither side fits, so it keeps its preference and lets the clamp decide —
    /// the same rule `PanelPlacement` applies on the other axis, and for the same
    /// reason: an arbitrary flip would move the card somewhere just as bad,
    /// unpredictably.
    @Test func theCardStaysOnItsPreferredSideWhenNeitherFits() {
        let cramped = NSRect(x: 0, y: 0, width: 500, height: 900)
        let atRightEdge = NSRect(x: 200, y: 400, width: 260, height: 200)
        let point = CodeCompletionDocPanel.origin(beside: atRightEdge, size: size, visible: cramped)

        #expect(point.x == cramped.maxX - size.width - PanelPlacement.margin)
        #expect(point.x >= cramped.minX)
    }

    /// The visible frame is not rooted at zero on a Mac with a menu bar, or on a
    /// second display placed left of the first.
    @Test func theClampFollowsADisplayThatDoesNotStartAtZero() {
        let secondary = NSRect(x: -1440, y: 100, width: 1440, height: 900)
        let atEdge = NSRect(x: -200, y: 200, width: 260, height: 200)
        let point = CodeCompletionDocPanel.origin(beside: atEdge, size: size, visible: secondary)

        #expect(point.x >= secondary.minX + PanelPlacement.margin)
        #expect(point.x + size.width <= secondary.maxX)
        #expect(point.y >= secondary.minY + PanelPlacement.margin)
    }

    // MARK: - Drawing, short of the window server

    /// The status line is dimmer than the server's prose, which is what stops
    /// "No documentation" reading as something the server said.
    @Test func theCardsOwnVoiceIsDimmerThanTheServers() {
        let status = CodeCompletionDocPanel.statusText(
            CodeCompletionDocPanel.absentText,
            theme: theme,
            font: font
        )
        let color = status.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(color != nil)
        #expect((color?.alphaComponent ?? 1) < 0.75)
    }

    /// The declaration is coloured by the same highlighter the file is, which is
    /// what makes the card look like it belongs to the code under it.
    @Test func theDeclarationIsSyntaxColoured() {
        let text = CodeCompletionDocPanel.signatureText(
            "func connect() -> Socket",
            theme: theme,
            font: font,
            language: .swift
        )

        var colors: Set<String> = []
        text.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: text.length)
        ) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color.description) }
        }

        #expect(colors.count > 1, "a flat declaration means the highlighter was never consulted")
    }

    /// Backticks are marks, not text — the card renders them rather than showing
    /// them.
    @Test func inlineMarkdownIsRenderedRatherThanShown() {
        let text = CodeCompletionDocPanel.proseText(
            "Calls `connect` first.",
            font: .systemFont(ofSize: 13),
            color: .white
        )

        #expect(!text.string.contains("`"))
    }

    // MARK: - The guard that keeps a test off the window server

    /// A card with nothing to say dismisses instead of presenting — which is
    /// both the Kotlin case and what lets this test run at all, since the guard
    /// returns before `orderFront`.
    @Test func aCardWithNothingToSayIsNotPresented() {
        let panel = CodeCompletionDocPanel()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        panel.present(
            .init(state: .unsupported),
            theme: theme,
            font: font,
            language: .kotlin,
            beside: list,
            over: view
        )

        #expect(!panel.isVisible)
    }
}

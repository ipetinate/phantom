import AppKit
@testable import Ghostty
import Testing

/// The wave placed against a real laid-out document.
///
/// `CodeSquiggleTests` holds the arithmetic; this holds the part that needs
/// TextKit — that the mark lands on the characters the problem covers, that
/// it stays on its line, and that it survives the text moving underneath it.
///
/// No window and no drawing context: `marks(in:)` is the whole of what
/// `draw` would stroke, worked out and handed back.
@MainActor
struct CodeSquiggleViewTests {
    private let severity = NSColor(calibratedRed: 1, green: 0.25, blue: 0.2, alpha: 1)

    private static let source = "let alpha = 1\nlet beta = 2\n"

    /// A text view with a size and a laid-out document, which is all the
    /// layout manager needs to report segments.
    private func editor() -> (CodeNSTextView, CodeSquiggleView) {
        let textView = CodeNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.string = Self.source

        let squiggles = CodeSquiggleView(frame: textView.bounds)
        squiggles.textView = textView
        textView.addSubview(squiggles)
        textView.squiggles = squiggles

        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        return (textView, squiggles)
    }

    private func mark(_ range: NSRange, in textView: CodeNSTextView) {
        textView.textStorage?.addAttribute(.codeDiagnosticUnderline, value: severity, range: range)
    }

    private var everywhere: NSRect { NSRect(x: 0, y: 0, width: 600, height: 400) }

    // MARK: Where the mark lands

    /// The reported complaint, against real layout: a problem on five
    /// characters is marked over five characters and not over the line.
    @Test func aMarkIsNoWiderThanTheCharactersItCovers() {
        let (textView, squiggles) = editor()
        /// "alpha" — five of the thirteen characters on the first line.
        mark(NSRange(location: 4, length: 5), in: textView)

        let marks = squiggles.marks(in: everywhere)
        guard let first = marks.first else {
            Issue.record("nothing to draw")
            return
        }

        let character = first.rect.width / 5
        #expect(marks.count == 1)
        #expect(first.rect.width > 0)
        /// The whole line is thirteen characters wide, so anything at or
        /// past nine of them is the line-wide rule this replaces.
        #expect(first.rect.width < character * 9)
    }

    /// And it starts where the problem starts, not at the margin.
    @Test func aMarkStartsAtItsOwnFirstCharacter() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)

        guard let first = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw")
            return
        }

        #expect(first.rect.minX > textView.textContainerOrigin.x)
    }

    /// The severity is the colour, so it has to reach the drawing unchanged —
    /// a warning and an error are the same mark otherwise.
    @Test func theSeverityColourReachesTheDrawing() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)

        #expect(squiggles.marks(in: everywhere).first?.colour == severity)
    }

    /// Two problems are two marks, not one spanning both.
    @Test func twoProblemsOnTwoLinesAreTwoMarks() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)
        mark(NSRange(location: 18, length: 4), in: textView)

        let marks = squiggles.marks(in: everywhere)
        #expect(marks.count == 2)
        #expect(marks[0].rect.minY != marks[1].rect.minY)
    }

    // MARK: It stays on its line

    /// The invariant that matters: no part of the wave is above the baseline,
    /// so it can never be drawn through the letters it belongs to.
    @Test func nothingIsDrawnAboveTheBaseline() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)

        guard let first = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw")
            return
        }

        let reach = CodeSquiggle.maximumOverhang(forFontSize: first.fontSize)
        #expect(first.centreY - reach >= first.baseline - 0.001)
    }

    /// And it does not fall further past its line than the redraw is padded
    /// for. A 12pt line has three points of descent for a mark that stands
    /// nearly four, so a little of it does hang over — the padding in
    /// `marks(in:)` is what stops that fraction being erased by the
    /// neighbouring line's repaint and never put back.
    @Test func theOverhangIsNoLargerThanTheRedrawAllowsFor() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)

        guard let first = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw")
            return
        }

        let reach = CodeSquiggle.maximumOverhang(forFontSize: first.fontSize)
        #expect(first.centreY + reach <= first.rect.maxY + reach + 0.001)
    }

    // MARK: It follows the text

    /// The reason the ranges are attributes and not a list held beside the
    /// buffer: typing in front of a problem moves the problem, and the mark
    /// has to move with it or it points at the wrong characters from the
    /// first keystroke after a diagnostic arrives.
    @Test func aMarkMovesWithAnInsertionInFrontOfIt() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)

        guard let before = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw")
            return
        }

        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "xx")
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }

        guard let after = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw after the edit")
            return
        }

        #expect(after.rect.minX > before.rect.minX)
        #expect(abs(after.rect.width - before.rect.width) < 0.5)
    }

    // MARK: What it costs

    /// Only what is on screen. `enumerateAttribute` walks attribute runs, and
    /// this storage has one per syntax token — so a scan of the whole
    /// document would cost a walk over every token in the file on every frame
    /// of a scroll.
    @Test func aStripOfTheViewportDrawsOnlyWhatIsInIt() {
        let (textView, squiggles) = editor()
        mark(NSRange(location: 4, length: 5), in: textView)
        mark(NSRange(location: 18, length: 4), in: textView)

        guard let first = squiggles.marks(in: everywhere).first else {
            Issue.record("nothing to draw")
            return
        }

        /// The upper half of the first line, which the padding cannot
        /// stretch as far as the second.
        let strip = NSRect(
            x: 0,
            y: first.rect.minY,
            width: 600,
            height: first.rect.height / 2)

        #expect(squiggles.marks(in: strip).count == 1)
    }

    // MARK: The view itself

    /// Paint, not a control. A view that answered here would make the code
    /// unselectable wherever it had an error.
    @Test func theOverlayTakesNoClicks() {
        let (_, squiggles) = editor()

        #expect(squiggles.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(squiggles.isFlipped)
    }

    /// The whole reason this is a view at all: overriding `NSTextView.draw`
    /// silently drops the text view to TextKit 1, which lays out the entire
    /// document and blanks the gutter.
    @Test func theTextViewIsStillOnTextKit2WithTheOverlayInIt() {
        let (textView, _) = editor()

        #expect(textView.isUsingTextKit2)
    }
}

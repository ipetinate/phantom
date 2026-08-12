import AppKit
@testable import Ghostty
import Testing

/// Auto-closing brackets and quotes as they are typed.
struct CodeTextViewAutoCloseTests {
    private func textView(_ contents: String, caretAt location: Int) -> CodeNSTextView {
        let textView = CodeNSTextView()
        textView.string = contents
        textView.setSelectedRange(NSRange(location: location, length: 0))
        return textView
    }

    @Test func typingAnOpenerInsertsItsCloser() {
        let view = textView("", caretAt: 0)
        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "()")
        #expect(view.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func everyPairedOpenerCloses() {
        for (opener, closer) in [("(", ")"), ("[", "]"), ("{", "}")] {
            let view = textView("", caretAt: 0)
            view.insertText(opener, replacementRange: view.selectedRange())
            #expect(view.string == opener + closer)
        }
    }

    @Test func typingAQuoteInEmptySpaceClosesIt() {
        let view = textView("", caretAt: 0)
        view.insertText("\"", replacementRange: view.selectedRange())
        #expect(view.string == "\"\"")
        #expect(view.selectedRange() == NSRange(location: 1, length: 0))
    }

    /// Typing the closer an auto-close already placed steps over it rather
    /// than inserting a second one — without this, `(` then `)` leaves
    /// `())` instead of `()`.
    @Test func typingTheClosingBracketOverAnAutoClosedOneStepsOverIt() {
        let view = textView("()", caretAt: 1)
        view.insertText(")", replacementRange: view.selectedRange())
        #expect(view.string == "()")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// A closer with nothing matching after the caret is an ordinary
    /// character, not a step-over.
    @Test func typingAClosingBracketWithNothingToStepOverInsertsItNormally() {
        let view = textView("(a", caretAt: 2)
        view.insertText(")", replacementRange: view.selectedRange())
        #expect(view.string == "(a)")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
    }

    /// `it's`, not `it's'` — a quote right after a letter reads as an
    /// apostrophe, not the start of a string.
    @Test func typingAQuoteAfterALetterDoesNotAutoClose() {
        let view = textView("it", caretAt: 2)
        view.insertText("'", replacementRange: view.selectedRange())
        #expect(view.string == "it'")
    }

    /// Same reasoning on the other side: a quote right before a letter
    /// isn't opening a string either.
    @Test func typingAQuoteBeforeALetterDoesNotAutoClose() {
        let view = textView("s", caretAt: 0)
        view.insertText("'", replacementRange: view.selectedRange())
        #expect(view.string == "'s")
    }

    /// Brackets get no such exemption — `(` always opens, letter or not.
    @Test func typingABracketNextToALetterStillAutoCloses() {
        let view = textView("a", caretAt: 1)
        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "a()")
    }

    /// Removes both halves in one backspace, not one.
    @Test func backspaceBetweenAnEmptyPairRemovesBothHalves() {
        let view = textView("()", caretAt: 1)
        view.deleteBackward(nil)
        #expect(view.string.isEmpty)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    }

    /// Content between the pair means there is no empty pair to collapse —
    /// an ordinary backspace removes one character, as usual.
    @Test func backspaceWithContentInsideThePairOnlyRemovesOneCharacter() {
        let view = textView("(a)", caretAt: 2)
        view.deleteBackward(nil)
        #expect(view.string == "()")
    }
}

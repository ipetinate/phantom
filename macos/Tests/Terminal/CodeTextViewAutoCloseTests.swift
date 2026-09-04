import AppKit
@testable import Ghostty
import Testing

/// Auto-closing brackets, quotes and tags as they are typed.
///
/// On the main actor and serialized, like `CodeTextViewReplaceTests`: every
/// case here drives a real `NSTextView`, and `setSelectedRange` reaches
/// AppKit's shared cursor controller, which builds an `NSWindow` and raises
/// off the main thread. Run inside the whole suite the class passed anyway —
/// something else had already built that controller on the main thread — so
/// the isolation this states is what makes the class runnable on its own.
@MainActor
@Suite(.serialized)
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

    // MARK: The switches

    /// Three switches rather than one, and this is what that buys: the
    /// reader who dislikes quote closing keeps bracket closing. A single
    /// switch would make escaping the one that misfires cost the two that
    /// work.
    @Test func eachSwitchDisablesOnlyItsOwnKind() {
        let quotesOff = textView("", caretAt: 0)
        quotesOff.closesQuotes = false
        quotesOff.insertText("\"", replacementRange: quotesOff.selectedRange())
        quotesOff.insertText("(", replacementRange: quotesOff.selectedRange())
        #expect(quotesOff.string == "\"()")

        let bracketsOff = textView("", caretAt: 0)
        bracketsOff.closesBrackets = false
        bracketsOff.insertText("(", replacementRange: bracketsOff.selectedRange())
        bracketsOff.insertText("\"", replacementRange: bracketsOff.selectedRange())
        #expect(bracketsOff.string == "(\"\"")
    }

    /// Stepping over is gated on the same switch as inserting.
    ///
    /// With closing off nothing was auto-inserted, so a closer after the
    /// caret is one the reader typed on purpose — stepping over it would eat
    /// the keystroke meant to produce the second one, leaving `()` where they
    /// asked for `())`.
    @Test func withClosingOffTypingACloserInsertsItRatherThanSteppingOver() {
        let view = textView("()", caretAt: 1)
        view.closesBrackets = false
        view.insertText(")", replacementRange: view.selectedRange())
        #expect(view.string == "())")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// And the same for the collapse on backspace: two characters the reader
    /// typed are two characters to delete.
    @Test func withClosingOffBackspaceRemovesOneHalfOfThePair() {
        let view = textView("()", caretAt: 1)
        view.closesBrackets = false
        view.deleteBackward(nil)
        #expect(view.string == ")")
    }

    /// The switches default to on, which is what every editor this one is
    /// measured against does. A default that has to be discovered is a
    /// feature nobody finds.
    @Test func everySwitchStartsOn() {
        let view = CodeNSTextView()
        #expect(view.closesBrackets)
        #expect(view.closesQuotes)
        #expect(view.closesTags)
        #expect(view.expandsTags)
    }

    // MARK: Tags, through the real typing path

    /// The scanner is tested exhaustively on its own; what these check is the
    /// wiring — that the decision is asked at the right moment, against a
    /// document that already contains the deciding character, and that the
    /// caret lands where the next thing gets typed.
    private func type(_ text: String, into view: CodeNSTextView) {
        for character in text {
            view.insertText(String(character), replacementRange: view.selectedRange())
        }
    }

    @Test func typingATagCloseOpensTheElementForTyping() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        type("<div>", into: view)

        #expect(view.string == "<div>\n    \n</div>")
        #expect(view.selectedRange() == NSRange(location: 10, length: 0))
    }

    /// The closing tag goes back to the opening tag's own column, and the
    /// caret one level in from it.
    @Test func theExpansionFollowsTheOpeningTagsIndentation() {
        let view = textView("  ", caretAt: 2)
        view.tagDialect = .html
        type("<ul>", into: view)

        #expect(view.string == "  <ul>\n      \n  </ul>")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    /// XML gets the same treatment, and gets it for the names HTML calls
    /// void — there is no void element set in XML.
    @Test func xmlExpandsTheNamesHTMLWouldRefuse() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .xml
        type("<link>", into: view)

        #expect(view.string == "<link>\n    \n</link>")
    }

    /// A single-file component's template is markup, so it expands. Its
    /// `<script>` block is not, and closes nothing at all.
    @Test func anSFCTemplateExpandsAndItsScriptBlockDoesNot() {
        let template = textView("<template>\n  ", caretAt: 13)
        template.tagDialect = .sfc
        type("<div>", into: template)
        #expect(template.string == "<template>\n  <div>\n      \n  </div>")

        let script = textView("<script setup>\nmount(", caretAt: 21)
        script.tagDialect = .sfc
        type("<div>", into: script)
        #expect(script.string == "<script setup>\nmount(<div>")
    }

    /// In JSX an element is usually one term of an expression, and pushing
    /// two newlines into the middle of a `return` line would move code the
    /// reader did not ask to move. The closing tag still arrives.
    @Test func jsxClosesFlatWithoutExpanding() {
        let view = textView("return ", caretAt: 7)
        view.tagDialect = .jsx
        type("<div>", into: view)

        #expect(view.string == "return <div></div>")
        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
    }

    /// A tag the reader closed themselves is left exactly as typed — there
    /// is no element open to write inside.
    @Test func aSelfClosedTagIsLeftAsTyped() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        type("<input />", into: view)
        #expect(view.string == "<input />")
    }

    /// Text already on the line after the caret declines the expansion: the
    /// three-line shape would push it past the closing tag.
    @Test func markupTypedInFrontOfTextClosesFlat() {
        let view = textView("already here", caretAt: 0)
        view.tagDialect = .html
        type("<p>", into: view)

        #expect(view.string == "<p></p>already here")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
    }

    /// The other half: `</` completes with the innermost element still open.
    /// This is the example from the request itself.
    @Test func typingASlashAfterAnAngleCompletesTheInnermostOpenElement() {
        let view = textView("<section>\n  <p>oi\n  ", caretAt: 20)
        view.tagDialect = .html
        type("</", into: view)

        #expect(view.string == "<section>\n  <p>oi\n  </p>")
        #expect(view.selectedRange() == NSRange(location: 24, length: 0))
    }

    /// A void element has no closing tag, so offering one writes markup the
    /// parser rejects.
    @Test func aVoidElementGetsNoClosingTag() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        type("<br>", into: view)
        #expect(view.string == "<br>")
    }

    /// The case the whole heuristic exists for. In `.tsx` both readings of
    /// `<` are legal, and closing a generic would leave `Array<string></string>`.
    @Test func aGenericIsNotATag() {
        let view = textView("const a: ", caretAt: 9)
        view.tagDialect = .jsx
        type("Array<string>", into: view)
        #expect(view.string == "const a: Array<string>")
    }

    /// `.ts` is a deliberate blanket refusal: JSX is a syntax error there, so
    /// a `<` can only ever be a generic and closing it would always be wrong.
    @Test func typescriptClosesNoTagsAtAll() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .none
        type("<div>", into: view)
        #expect(view.string == "<div>")
    }

    @Test func theTagSwitchTurnsItOffWithoutTouchingBrackets() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        view.closesTags = false
        type("<div>", into: view)
        #expect(view.string == "<div>")

        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "<div>()")
    }

    /// Two switches rather than one, and this is what the second buys: the
    /// reader who wants `<div></div>` on one line keeps closing tags.
    @Test func theExpansionSwitchLeavesTheFlatClosingTag() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        view.expandsTags = false
        type("<div>", into: view)

        #expect(view.string == "<div></div>")
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
    }

    /// And with tags not closing at all there is nothing left for the
    /// expansion to expand, whatever it says.
    @Test func theTagSwitchAlsoStopsTheExpansion() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        view.closesTags = false
        view.expandsTags = true
        type("<div>", into: view)
        #expect(view.string == "<div>")
    }

    /// Tabs where the reader asked for tabs, on the same setting Return
    /// already reads.
    @Test func theExpansionIndentsWithTheReadersOwnUnit() {
        let view = textView("", caretAt: 0)
        view.tagDialect = .html
        view.insertsSpacesForTab = false
        type("<div>", into: view)
        #expect(view.string == "<div>\n\t\n</div>")
    }

    /// One keystroke, one undo — the `>` and the `</div>` it produced go back
    /// together.
    ///
    /// Asserted over a **single** `insertText`, which is the only shape of
    /// this claim that is deterministic. `NSUndoManager` groups by run loop
    /// event, so in the running app every keystroke opens its own group and
    /// the closing tag lands in the same one as the `>` that caused it. A
    /// test has no events: several `insertText` calls in one pass all land in
    /// one group, and asserting across them measures the test harness's run
    /// loop rather than the editor. The first version of this test did
    /// exactly that — it passed alone and failed in the full suite, which is
    /// the signature of a timing assumption rather than a bug.
    @Test func oneUndoTakesBackBothTheAngleAndTheTagItProduced() {
        let view = textView("<div", caretAt: 4)
        view.tagDialect = .html

        view.insertText(">", replacementRange: view.selectedRange())
        #expect(view.string == "<div>\n    \n</div>")

        view.undoManager?.undo()
        #expect(view.string == "<div")
    }

    /// The insertion is registered with the undo manager at all — which is
    /// the same thing as saying it went through the delegate, and therefore
    /// that the host was told the buffer moved. A raw `replaceCharacters`
    /// would leave the language server describing a file that no longer
    /// exists, and would show up here as nothing to undo.
    @Test func theClosingTagIsWrittenThroughTheUndoableEditPath() {
        let view = textView("<div", caretAt: 4)
        view.tagDialect = .html
        view.insertText(">", replacementRange: view.selectedRange())

        #expect(view.undoManager?.canUndo == true)
    }
}

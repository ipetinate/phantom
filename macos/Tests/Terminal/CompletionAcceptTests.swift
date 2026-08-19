import AppKit
@testable import Ghostty
import Testing

/// What accepting a row does to the buffer.
///
/// Driven straight at `applyCompletion` on a view with no window: the bug
/// this file exists for is arithmetic, and every case here is one the
/// arithmetic used to get wrong on a real server. A completion that eats a
/// character the reader typed is the one editor bug they cannot shrug off,
/// so the assertions are on the whole string and the whole selection rather
/// than on a length.
@MainActor
struct CompletionAcceptTests {
    private func textView(_ contents: String, caretAt location: Int) -> CodeNSTextView {
        let view = CodeNSTextView()
        view.string = contents
        view.setSelectedRange(NSRange(location: location, length: 0))
        return view
    }

    private func item(
        _ insertText: String,
        replacing replaceRange: NSRange? = nil,
        isSnippet: Bool = false,
        additionalEdits: [CodeTextEdit] = []
    ) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: .function,
            label: insertText,
            insertText: insertText,
            replaceRange: replaceRange,
            isSnippet: isSnippet,
            additionalEdits: additionalEdits
        )
    }

    // MARK: A row with nothing to say about the range

    /// The floor, and what a word scraped out of the buffer or a keyword can
    /// ever ask for: replace the word the caret sits at the end of.
    @Test func aRowWithNoRangeReplacesTheWordUnderTheCaret() {
        let view = textView("let value = con", caretAt: 15)
        view.applyCompletion(item("connect"))

        #expect(view.string == "let value = connect")
        #expect(view.selectedRange() == NSRange(location: 19, length: 0))
    }

    /// The word is measured **now**, not when the list was drawn — which is
    /// the difference between a correct insertion and a mangled one whenever
    /// the reader keeps typing while a refilter is still in flight. The list
    /// on screen was built for `con`; the buffer says `conn`; accepting has
    /// to replace what is there.
    @Test func typingAheadOfTheOpenListStillReplacesEverythingTyped() {
        let view = textView("conn", caretAt: 4)
        view.applyCompletion(item("connect"))

        #expect(view.string == "connect")
        #expect(view.selectedRange() == NSRange(location: 7, length: 0))
    }

    // MARK: Ranges that start before the caret

    /// Measured: `typescript-language-server` answers a dot-accessor with a
    /// range that covers the `.` and a `newText` that includes it again.
    /// Replacing only the typed word writes the dot twice.
    @Test func aRangeCoveringTheDotDoesNotLeaveASecondOne() {
        let view = textView("foo.", caretAt: 4)
        view.applyCompletion(item(".bar", replacing: NSRange(location: 3, length: 1)))

        #expect(view.string == "foo.bar")
        #expect(view.selectedRange() == NSRange(location: 7, length: 0))
    }

    /// The other shape of the same instruction — sourcekit-lsp's "erase this
    /// much first" — over a character the editor's own word scan will not
    /// claim. `#` is not an identifier character, so the word is `inc` and
    /// only the server's range knows the `#` is part of what goes.
    @Test func aRangeReachingPastAWordBoundaryTakesItWithIt() {
        let view = textView("#inc", caretAt: 4)
        view.applyCompletion(item("#include", replacing: NSRange(location: 0, length: 4)))

        #expect(view.string == "#include")
        #expect(view.selectedRange() == NSRange(location: 8, length: 0))
    }

    /// A range measured one keystroke ago is short, and honouring it alone
    /// would strand the character typed since — `foo..connect`. Union with
    /// the live word is what keeps both halves.
    @Test func aRangeAndTheLiveWordAreUnionedRatherThanChosenBetween() {
        let view = textView("foo.con", caretAt: 7)
        view.applyCompletion(item(".connect", replacing: NSRange(location: 3, length: 3)))

        #expect(view.string == "foo.connect")
        #expect(view.selectedRange() == NSRange(location: 11, length: 0))
    }

    // MARK: Ranges that extend past the caret

    /// The caret in the middle of an identifier, and a server asking for the
    /// rest of it too. Replacing only the prefix leaves the tail behind —
    /// `fooBazbar`.
    @Test func aRangeExtendingPastTheCaretTakesTheRestOfTheWord() {
        let view = textView("let x = foobar", caretAt: 11)
        view.applyCompletion(item("fooBaz", replacing: NSRange(location: 8, length: 6)))

        #expect(view.string == "let x = fooBaz")
        #expect(view.selectedRange() == NSRange(location: 14, length: 0))
    }

    // MARK: Ranges that no longer describe this document

    /// A range on another line is refused outright rather than applied or
    /// clamped. It cannot be what this caret meant, and applying it would
    /// rewrite a line the reader is not looking at.
    @Test func aRangeOnAnotherLineIsRefusedAndTheWordIsUsed() {
        let view = textView("import a\nba", caretAt: 11)
        view.applyCompletion(item("bar", replacing: NSRange(location: 0, length: 6)))

        #expect(view.string == "import a\nbar")
        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
    }

    /// On the caret's line but nowhere near its word, so the union would
    /// swallow everything in between. Refused for that reason.
    @Test func aRangeThatDoesNotTouchTheWordIsRefused() {
        let view = textView("alpha beta", caretAt: 10)
        view.applyCompletion(item("betamax", replacing: NSRange(location: 0, length: 5)))

        #expect(view.string == "alpha betamax")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    /// A refusal is never a corruption: the worst a stale range can do is
    /// leave the behaviour a row carrying no range would have had.
    @Test func aRefusedRangeMatchesWhatNoRangeWouldHaveDone() {
        let asked = CodeNSTextView.replacementRange(
            asked: NSRange(location: 0, length: 5),
            caret: 10,
            in: "alpha beta" as NSString
        )
        let none = CodeNSTextView.replacementRange(
            asked: nil,
            caret: 10,
            in: "alpha beta" as NSString
        )
        #expect(asked == none)
    }

    // MARK: The import that comes with it

    /// The additional edit lands first and the caret's own range is moved by
    /// what it inserted — without that, the identifier is written at an
    /// offset the import has already pushed along.
    @Test func anAutoImportShiftsTheInsertionItArrivedWith() {
        let view = textView("const x = useSt", caretAt: 15)
        view.applyCompletion(item(
            "useState",
            replacing: NSRange(location: 10, length: 5),
            additionalEdits: [CodeTextEdit(
                range: NSRange(location: 0, length: 0),
                newText: "import { useState } from 'react'\n"
            )]
        ))

        #expect(view.string == "import { useState } from 'react'\nconst x = useState")
        #expect(view.selectedRange() == NSRange(location: 51, length: 0))
    }

    /// One accepted completion is **one** undo step, import included.
    ///
    /// It is also the proof that the whole insertion went through
    /// `shouldChangeText` — a raw `replaceCharacters` registers no undo at
    /// all, and would leave this assertion passing for the wrong reason only
    /// if nothing had changed in the first place, which the line above rules
    /// out.
    @Test func oneAcceptedCompletionIsOneUndoStep() {
        let view = textView("const x = useSt", caretAt: 15)
        view.applyCompletion(item(
            "useState",
            replacing: NSRange(location: 10, length: 5),
            additionalEdits: [CodeTextEdit(
                range: NSRange(location: 0, length: 0),
                newText: "import { useState } from 'react'\n"
            )]
        ))
        #expect(view.string != "const x = useSt")

        view.undoManager?.undo()
        #expect(view.string == "const x = useSt")
    }

    // MARK: Snippets

    /// A snippet body goes into the same range, resolved the same way — the
    /// dot case has to survive a `$0` too.
    @Test func aSnippetHonoursTheRangeTheRowAskedFor() {
        let view = textView("foo.", caretAt: 4)
        view.applyCompletion(item(
            ".bar($1)",
            replacing: NSRange(location: 3, length: 1),
            isSnippet: true
        ))

        #expect(view.string == "foo.bar()")
    }

    // MARK: The range arithmetic on its own

    /// Clamped rather than trapped. A caret past the end is a stale offset,
    /// and the answer is the word at the end of the document rather than an
    /// index that would throw on the way into `NSString`.
    @Test func aCaretPastTheEndOfTheDocumentIsClamped() {
        let range = CodeNSTextView.replacementRange(
            asked: nil,
            caret: 900,
            in: "abc" as NSString
        )
        #expect(range == NSRange(location: 0, length: 3))
    }

    /// A range that ends exactly where the word starts still touches it, and
    /// is the common case for a trigger character: `.` at 3, word at 4.
    @Test func aRangeAbuttingTheWordCounts() {
        let range = CodeNSTextView.replacementRange(
            asked: NSRange(location: 3, length: 1),
            caret: 7,
            in: "foo.bar" as NSString
        )
        #expect(range == NSRange(location: 3, length: 4))
    }
}

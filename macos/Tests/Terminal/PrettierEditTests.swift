import Foundation
@testable import Ghostty
import Testing

/// The smallest replacement between the buffer and Prettier's answer.
///
/// Two things are being pinned here, and only one of them is arithmetic. The
/// first is that the edit is *minimal* — a whole-buffer replacement would pass
/// every "the text comes out right" assertion while still throwing away the
/// caret and the scroll position, which is the entire reason this exists. The
/// second is that the offsets are UTF-16, because the buffer is `NSString` and
/// an offset counted any other way is a silent corruption rather than a
/// visible failure.
struct PrettierEditTests {
    // MARK: Nothing to do

    /// The common case on a formatted file, and the one that has to cost
    /// nothing: no edit at all, so no undo entry, no caret move, and no
    /// document marked dirty by a save that changed nothing.
    @Test func identicalTextProducesNoEdit() {
        #expect(PrettierEdit.minimal(from: "const a = 1;\n", to: "const a = 1;\n") == nil)
    }

    @Test func twoEmptyTextsProduceNoEdit() {
        #expect(PrettierEdit.minimal(from: "", to: "") == nil)
    }

    // MARK: Minimality

    /// One reformatted line in the middle of a file touches one line.
    @Test func onlyTheChangedSpanIsReplaced() {
        let old = "const a = 1;\nconst b   =   2;\nconst c = 3;\n"
        let new = "const a = 1;\nconst b = 2;\nconst c = 3;\n"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit != nil)
        guard let edit else { return }

        #expect(edit.applied(to: old) == new)

        /// The point of the exercise: the untouched first and last lines stay
        /// outside the range. A whole-buffer replacement would be 43 long;
        /// this one rewrites the five characters `"  =  "` as `"="`, and the
        /// shared single spaces either side of them are left alone too.
        #expect(edit.range.location == 21)
        #expect(edit.range.length == 5)
        #expect(edit.newText == "=")
    }

    @Test func anInsertionAtTheEndHasAZeroLengthRange() {
        let edit = PrettierEdit.minimal(from: "a = 1", to: "a = 1;\n")
        #expect(edit?.range == NSRange(location: 5, length: 0))
        #expect(edit?.newText == ";\n")
    }

    @Test func aDeletionHasAnEmptyReplacement() {
        let edit = PrettierEdit.minimal(from: "a = 1;;\n", to: "a = 1;\n")
        #expect(edit?.newText == "")
        #expect(edit?.range.length == 1)
        #expect(edit?.applied(to: "a = 1;;\n") == "a = 1;\n")
    }

    /// Nothing in common at all still produces a valid edit rather than a
    /// special case.
    @Test func aCompletelyDifferentTextReplacesEverything() {
        let edit = PrettierEdit.minimal(from: "xyz", to: "abc")
        #expect(edit?.range == NSRange(location: 0, length: 3))
        #expect(edit?.newText == "abc")
    }

    // MARK: UTF-16, which is what the buffer counts in

    /// The offsets are code units, not `Character`s.
    ///
    /// Swift counts `"\r\n"` as **one** `Character`. This file has two CRLF
    /// terminators before the change, so a grapheme-counted prefix reports 6
    /// where the buffer means 8 — and every line ending before the edit makes
    /// it one worse. Handed to `NSTextStorage`, that lands the replacement two
    /// characters early and eats a `\r`.
    @Test func crlfLineEndingsDoNotShiftTheOffsets() {
        let old = "a\r\nbb\r\ncc"
        let new = "a\r\nbb\r\nc"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit?.range == NSRange(location: 8, length: 1))
        #expect(edit?.applied(to: old) == new)
    }

    /// A whole file converted from CRLF to LF, which is what Prettier does on
    /// a repository configured for `endOfLine: "lf"` — the case where every
    /// single line differs.
    @Test func aCrlfToLfConversionRoundTrips() {
        let old = "let x = 1\r\nlet y = 2\r\n"
        let new = "let x = 1\nlet y = 2\n"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit?.applied(to: old) == new)
    }

    /// The boundary is pulled off a surrogate pair it would otherwise split.
    ///
    /// `"😀"` and `"😁"` share their leading code unit, so the naive common
    /// prefix is one unit long and the replacement begins with an unpaired
    /// trailing surrogate — which Swift cannot hold, and substitutes U+FFFD
    /// for. Without the nudge this assertion reads `"\u{FFFD}"` and the
    /// reader's emoji is destroyed by formatting the file.
    @Test func aSurrogatePairIsNeverSplitAtThePrefix() {
        let old = "let a = \"😀\"\n"
        let new = "let a = \"😁\"\n"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit?.newText == "😁")
        #expect(edit?.range == NSRange(location: 9, length: 2))
        #expect(edit?.applied(to: old) == new)
    }

    /// The same hazard from the other end. `"😀"` (U+1F600) and `"🨀"`
    /// (U+1FA00) share their *trailing* code unit, so the common suffix would
    /// start mid-pair and the replacement would end with an unpaired leading
    /// surrogate.
    @Test func aSurrogatePairIsNeverSplitAtTheSuffix() {
        let old = "😀"
        let new = "🨀"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit?.newText == "🨀")
        #expect(edit?.range == NSRange(location: 0, length: 2))
        #expect(edit?.applied(to: old) == new)
    }

    /// Emoji far from the change must not move the arithmetic either: the
    /// prefix here spans a four-unit family emoji, so a `Character` count
    /// would be short by three.
    @Test func emojiBeforeTheChangeAreCountedInCodeUnits() {
        let old = "// 👩‍👩‍👧 note\nconst a=1;\n"
        let new = "// 👩‍👩‍👧 note\nconst a = 1;\n"

        let edit = PrettierEdit.minimal(from: old, to: new)
        #expect(edit?.applied(to: old) == new)
        #expect(edit?.range.location == (old as NSString).range(of: "a=1").location + 1)
    }

    /// Two texts that are canonically equal but not identical byte for byte —
    /// `é` composed versus decomposed. Swift's `==` on `String` says they are
    /// the same; the buffer would keep bytes Prettier did not produce.
    @Test func aNormalisationDifferenceIsStillAnEdit() {
        let old = "const e = \"e\u{0301}\";\n"
        let new = "const e = \"\u{00E9}\";\n"

        #expect(old == new)
        #expect(PrettierEdit.minimal(from: old, to: new) != nil)
        #expect(PrettierEdit.minimal(from: old, to: new)?.applied(to: old) == new)
    }

    // MARK: The caret

    /// Everything before the edit is untouched, which is the whole reason to
    /// compute a minimal edit rather than replace the buffer.
    @Test func aCaretBeforeTheEditDoesNotMove() {
        let edit = PrettierEdit(range: NSRange(location: 10, length: 5), newText: "ab")
        #expect(edit.movedCaret(from: 3) == 3)
        #expect(edit.movedCaret(from: 10) == 10)
    }

    @Test func aCaretAfterTheEditShiftsByTheDifference() {
        let edit = PrettierEdit(range: NSRange(location: 10, length: 5), newText: "ab")
        #expect(edit.movedCaret(from: 20) == 17)
        #expect(edit.movedCaret(from: 15) == 12)
    }

    /// Inside the rewritten span there is nothing honest to point at, so the
    /// caret is held rather than flung to the end of the document.
    @Test func aCaretInsideTheEditIsClampedToTheReplacement() {
        let edit = PrettierEdit(range: NSRange(location: 10, length: 5), newText: "ab")
        #expect(edit.movedCaret(from: 11) == 11)
        #expect(edit.movedCaret(from: 14) == 12)
    }

    @Test func aGrowingEditPushesTheCaretForward() {
        let edit = PrettierEdit(range: NSRange(location: 4, length: 1), newText: "    ")
        #expect(edit.movedCaret(from: 9) == 12)
    }
}

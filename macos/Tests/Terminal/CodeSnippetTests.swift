import Foundation
@testable import Ghostty
import Testing

/// Reading a snippet body, and the arithmetic that keeps its tab stops in place
/// while the user types over them.
///
/// The parser's failures are the interesting half: this is the one part of
/// completion whose bugs write the wrong thing into somebody's file rather than
/// merely annoying them.
struct CodeSnippetTests {
    private func fields(_ body: String) -> [CodeSnippet.Field] {
        CodeSnippet.parse(body).fields
    }

    private func locations(_ body: String) -> [Int] {
        fields(body).map(\.range.location)
    }

    // MARK: - The grammar

    @Test func aBareTabStopIsAFieldWithNothingInIt() {
        let snippet = CodeSnippet.parse("console.log($1)")

        #expect(snippet.text == "console.log()")
        #expect(snippet.fields.count == 1)
        #expect(snippet.fields.first?.range == NSRange(location: 12, length: 0))
        #expect(snippet.fields.first?.placeholder == "")
    }

    @Test func bracedAndUnbracedTabStopsAgree() {
        #expect(CodeSnippet.parse("a$1b").text == CodeSnippet.parse("a${1}b").text)
        #expect(locations("a$1b") == locations("a${1}b"))
    }

    @Test func aPlaceholderInsertsItsDefaultAndSpansIt() {
        let snippet = CodeSnippet.parse("${1:message}")

        #expect(snippet.text == "message")
        #expect(snippet.fields.first?.range == NSRange(location: 0, length: 7))
        #expect(snippet.fields.first?.placeholder == "message")
    }

    /// No choice UI in v1, declared as a cut — so the first option is taken and
    /// becomes an ordinary placeholder you can type over.
    @Test func aChoiceTakesItsFirstOption() {
        let snippet = CodeSnippet.parse("${1|public,private,internal|}")

        #expect(snippet.text == "public")
        #expect(snippet.fields.first?.placeholder == "public")
    }

    /// `$0` is not a stop you edit — it is where the caret goes when you are
    /// done — so it must not appear among the navigable fields.
    @Test func theFinalCaretIsNotATabStop() {
        let snippet = CodeSnippet.parse("if ($1) {\n\t$0\n}")

        #expect(snippet.fields.map(\.index) == [1])
        #expect(snippet.finalCaret == (snippet.text as NSString).range(of: "\n}").location)
    }

    /// A body with no `$0` leaves the decision to the caller, which puts the
    /// caret at the end of the insertion.
    @Test func aBodyWithoutAFinalMarkerSaysSo() {
        #expect(CodeSnippet.parse("${1:x}").finalCaret == nil)
    }

    /// LSP allows `$0` to carry a default. The text goes in and the caret lands
    /// at the start of it.
    @Test func aFinalMarkerMayCarryText() {
        let snippet = CodeSnippet.parse("done: ${0:here}")

        #expect(snippet.text == "done: here")
        #expect(snippet.finalCaret == 6)
        #expect(snippet.fields.isEmpty)
    }

    @Test func tabOrderIsAscendingByIndex() {
        #expect(fields("${3:c} ${1:a} ${2:b}").map(\.index) == [1, 2, 3])
    }

    @Test func aTwoDigitIndexIsReadWhole() {
        #expect(fields("${12:x}").map(\.index) == [12])
    }

    // MARK: - Escapes

    @Test func escapedMarkersAreLiteralText() {
        #expect(CodeSnippet.parse("\\$notAMarker").text == "$notAMarker")
        #expect(CodeSnippet.parse("a\\}b").text == "a}b")
        #expect(CodeSnippet.parse("a\\\\b").text == "a\\b")
        #expect(CodeSnippet.parse("\\$1").fields.isEmpty)
    }

    /// The escape has to survive being inside a placeholder, or a snippet like
    /// `log(${1:a\}b})` terminates at the wrong brace and swallows the rest.
    @Test func anEscapedBraceInsideAPlaceholderDoesNotEndIt() {
        let snippet = CodeSnippet.parse("log(${1:a\\}b})")

        #expect(snippet.text == "log(a}b)")
        #expect(snippet.fields.first?.placeholder == "a}b")
    }

    // MARK: - Nesting

    /// Parsed recursively and flattened: both stops become ordinary fields, and
    /// their ranges overlap — because that is what the text actually looks like.
    @Test func nestedPlaceholdersFlattenIntoTwoFields() {
        let snippet = CodeSnippet.parse("${1:${2:inner}}")

        #expect(snippet.text == "inner")
        #expect(snippet.fields.map(\.index) == [1, 2])
        #expect(snippet.fields.allSatisfy { $0.range == NSRange(location: 0, length: 5) })
    }

    // MARK: - Repeated indices

    /// The static stand-in for mirroring, which v1 does not do. The loop reads
    /// correctly the moment it is inserted; what it will not do is follow the
    /// first `i` if you rename it.
    @Test func aRepeatedIndexInsertsItsDefaultAndStaysOneField() {
        let snippet = CodeSnippet.parse("for (let ${1:i} = 0; $1 < ${2:n}; $1++) {}")

        #expect(snippet.text == "for (let i = 0; i < n; i++) {}")
        #expect(snippet.fields.map(\.index) == [1, 2])
        #expect(snippet.fields.first?.range == NSRange(location: 9, length: 1))
    }

    /// The first occurrence is the navigable one even when a later one declares
    /// a default of its own — the later default is inserted as text and nothing
    /// more.
    @Test func theFirstOccurrenceIsTheNavigableOne() {
        let snippet = CodeSnippet.parse("${1:a}${1:b}")

        #expect(snippet.text == "ab")
        #expect(snippet.fields.count == 1)
        #expect(snippet.fields.first?.range == NSRange(location: 0, length: 1))
    }

    // MARK: - Malformed bodies

    /// **The deliberate choice, and the one worth arguing about.** A dropped
    /// marker leaves a snippet that looks like it worked and quietly inserted
    /// the wrong thing; a `${1:` left on screen is a wrong insertion the user
    /// can see and fix in one keystroke. When something cannot be understood,
    /// the failure should be visible.
    @Test func aMalformedMarkerPassesThroughAsLiteralText() {
        for body in ["${1:unterminated", "$", "${}", "${1|a,b}", "${x}", "${1", "a$", "a${1:b${2"] {
            let snippet = CodeSnippet.parse(body)

            #expect(snippet.text == body, "\(body.debugDescription) should pass through unchanged")
            #expect(snippet.fields.isEmpty, "\(body.debugDescription) should declare no fields")
            #expect(snippet.finalCaret == nil)
        }
    }

    /// The scope of the pass-through: it is the **marker** that goes literal,
    /// not the body. An unterminated outer placeholder wrapping a well-formed
    /// inner one loses only itself — `${1:` shows up on screen, which is the
    /// visible failure the design asks for, and the inner stop still works.
    /// Discarding it as well would be throwing away something correct to
    /// punish something next to it.
    @Test func anUnterminatedOuterMarkerDoesNotTakeAValidInnerOneWithIt() {
        let snippet = CodeSnippet.parse("${1:a${2:b}")

        #expect(snippet.text == "${1:ab")
        #expect(snippet.fields.map(\.index) == [2])
        #expect(snippet.fields.first?.range == NSRange(location: 5, length: 1))
    }

    /// And the malformed marker must not take the well-formed one down with it:
    /// the rollback that makes the literal pass-through work has to put back the
    /// text *and* the fields the failed attempt had already recorded.
    @Test func aMalformedMarkerLeavesEarlierFieldsIntact() {
        let snippet = CodeSnippet.parse("${1:ok} ${2")

        #expect(snippet.text == "ok ${2")
        #expect(snippet.fields.map(\.index) == [1])
        #expect(snippet.fields.first?.range == NSRange(location: 0, length: 2))
    }

    @Test func anEmptyBodyParsesToNothing() {
        let snippet = CodeSnippet.parse("")

        #expect(snippet.text.isEmpty)
        #expect(snippet.fields.isEmpty)
        #expect(snippet.finalCaret == nil)
    }

    /// Field ranges are UTF-16 offsets, because they are handed straight to
    /// `NSTextView` — so text before a stop that contains an astral-plane
    /// character has to count as two.
    @Test func fieldRangesAreCountedInUTF16Units() {
        #expect(locations("a🎉${1:b}") == [3])
    }

    // MARK: - adjust

    private func adjust(
        _ fields: [(Int, Int)],
        active: Int,
        edited: (Int, Int),
        delta: Int
    ) -> [NSRange]? {
        CodeSnippet.adjust(
            fields: fields.map { NSRange(location: $0.0, length: $0.1) },
            active: active,
            editedRange: NSRange(location: edited.0, length: edited.1),
            delta: delta
        )
    }

    @Test func typingInsideTheActiveFieldGrowsItAndShiftsWhatFollows() {
        #expect(
            adjust([(4, 3), (10, 1)], active: 0, edited: (7, 0), delta: 5)
                == [NSRange(location: 4, length: 8), NSRange(location: 15, length: 1)]
        )
    }

    @Test func deletingInsideTheActiveFieldShrinksIt() {
        #expect(
            adjust([(4, 3), (10, 1)], active: 0, edited: (5, 2), delta: -2)
                == [NSRange(location: 4, length: 1), NSRange(location: 8, length: 1)]
        )
    }

    /// A bare `$1` is a field of length zero, and typing into it is the most
    /// common thing that happens to a snippet. If a zero-length field could not
    /// grow, half of them would end the session on the first keystroke.
    @Test func anEmptyFieldCanBeTypedInto() {
        #expect(
            adjust([(4, 0), (10, 1)], active: 0, edited: (4, 0), delta: 1)
                == [NSRange(location: 4, length: 1), NSRange(location: 11, length: 1)]
        )
    }

    /// Typing at the very end of a placeholder extends it rather than leaving
    /// it: appending to `${1:name}` is editing the name.
    @Test func typingAtTheTrailingEdgeExtendsTheField() {
        #expect(
            adjust([(4, 3)], active: 0, edited: (7, 0), delta: 1)
                == [NSRange(location: 4, length: 4)]
        )
    }

    @Test func fieldsBeforeTheActiveOneDoNotMove() {
        #expect(
            adjust([(4, 3), (10, 1)], active: 1, edited: (10, 1), delta: 4)
                == [NSRange(location: 4, length: 3), NSRange(location: 10, length: 5)]
        )
    }

    /// Nil means **end the session**, and that is the important half of the
    /// contract: a session that survives an edit it did not understand starts
    /// moving the wrong ranges, and the symptom is a Tab press selecting a piece
    /// of the user's own code. Ending it costs a Tab and corrupts nothing.
    @Test func anEditOutsideTheActiveFieldEndsTheSession() {
        #expect(adjust([(4, 3), (10, 1)], active: 0, edited: (2, 1), delta: 1) == nil)
        #expect(adjust([(4, 3), (10, 1)], active: 0, edited: (9, 1), delta: 1) == nil)
    }

    /// Pasting over a placeholder *and* its closing paren, most often.
    @Test func anEditSpanningPastTheFieldEndsTheSession() {
        #expect(adjust([(4, 3), (10, 1)], active: 0, edited: (6, 3), delta: -3) == nil)
    }

    @Test func anActiveIndexThatIsNotAFieldEndsTheSession() {
        #expect(adjust([(4, 3)], active: 2, edited: (4, 0), delta: 1) == nil)
        #expect(adjust([(4, 3)], active: -1, edited: (4, 0), delta: 1) == nil)
        #expect(adjust([], active: 0, edited: (0, 0), delta: 1) == nil)
    }

    /// The nested case, left alone deliberately: v1 does not navigate nested
    /// stops, and guessing which side of the edit an inner field belongs on
    /// would be inventing an answer.
    @Test func aFieldNestedInsideTheActiveOneIsNotShifted() {
        #expect(
            adjust([(0, 5), (0, 5)], active: 0, edited: (2, 0), delta: 3)
                == [NSRange(location: 0, length: 8), NSRange(location: 0, length: 5)]
        )
    }
}

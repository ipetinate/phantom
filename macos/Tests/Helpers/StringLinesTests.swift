import Foundation
@testable import Ghostty
import Testing

/// `String.splitIntoLines()` and the CRLF trap it exists to close.
///
/// Swift counts `"\r\n"` as a single `Character`, so the obvious
/// `split(separator: "\n")` finds no separator at all in text with Windows
/// line endings and returns the whole input as one line. It fails silently
/// — no throw, no truncation, just a count nobody checked — and it had
/// already reached three separate places in this app before anyone noticed.
struct StringLinesTests {
    /// The premise the whole thing rests on. If this ever stops being true,
    /// the helper is unnecessary and the tests below are noise.
    @Test func swiftCountsCRLFAsOneCharacter() {
        #expect("\r\n".count == 1)
        #expect("\r\n".unicodeScalars.count == 2)
        #expect(Character("\r\n") != Character("\n"))
    }

    /// The bug, stated directly: what the ordinary split does versus what
    /// this one does, on the same string.
    @Test func theOrdinarySplitFindsNoLinesInCRLFTextAndThisOneDoes() {
        let text = "alpha\r\nbeta\r\ngamma\r\n"

        #expect(
            text.split(separator: "\n", omittingEmptySubsequences: false).count == 1,
            "the trap: a Character-based split sees one line here"
        )
        #expect(text.splitIntoLines() == ["alpha\r", "beta\r", "gamma\r", ""])
    }

    @Test func plainNewlinesAreUnaffected() {
        #expect("alpha\nbeta\ngamma\n".splitIntoLines() == ["alpha", "beta", "gamma", ""])
        #expect("".splitIntoLines() == [""])
        #expect("one".splitIntoLines() == ["one"])
    }

    /// Mixed endings in one document — a file half-converted, or two tools
    /// having appended to it.
    @Test func mixedLineEndingsSplitAtEveryNewline() {
        #expect("a\r\nb\nc\r\n".splitIntoLines() == ["a\r", "b", "c\r", ""])
    }

    /// A bare `\r` with no `\n` after it is a progress-bar overwrite, not a
    /// terminator, and is not a place to break a line.
    @Test func aBareCarriageReturnIsNotALineBreak() {
        #expect("50%\r100%\n".splitIntoLines() == ["50%\r100%", ""])
    }

    // MARK: Dropping the terminator's other half

    @Test func onlyTheTrailingCarriageReturnIsDropped() {
        #expect("value\r".droppingTrailingCarriageReturn == "value")
        #expect("value".droppingTrailingCarriageReturn == "value")
        #expect("".droppingTrailingCarriageReturn == "")
    }

    /// One, not all of them: `50%\r100%` is one line whose middle `\r` is
    /// content, and a line that genuinely ends in two keeps the first.
    @Test func aCarriageReturnInsideTheLineSurvives() {
        #expect("50%\r100%\r".droppingTrailingCarriageReturn == "50%\r100%")
        #expect("done\r\r".droppingTrailingCarriageReturn == "done\r")
    }
}

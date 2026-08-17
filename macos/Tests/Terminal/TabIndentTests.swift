import AppKit
@testable import Ghostty
import Testing

/// Tab inserting spaces, and landing on the right column when it does.
///
/// The property worth protecting is alignment, not count: a Tab that always
/// inserts `width` spaces looks right on an empty line and puts every
/// subsequent line one stop further out.
struct TabIndentTests {
    @Test func aTabAtTheStartOfALineFillsTheWholeStop() {
        #expect(CodeNSTextView.spacesForTab(atColumn: 0, width: 4) == 4)
    }

    /// The case a flat "insert width spaces" gets wrong. From column two
    /// with a width of four, the next stop is two away, not four.
    @Test func aTabPartwayThroughAStopFillsOnlyTheRemainder() {
        #expect(CodeNSTextView.spacesForTab(atColumn: 2, width: 4) == 2)
        #expect(CodeNSTextView.spacesForTab(atColumn: 3, width: 4) == 1)
    }

    /// Sitting exactly on a stop moves to the next one rather than inserting
    /// nothing — a Tab always has to move the caret.
    @Test func aTabOnAStopMovesToTheNextOne() {
        #expect(CodeNSTextView.spacesForTab(atColumn: 4, width: 4) == 4)
        #expect(CodeNSTextView.spacesForTab(atColumn: 8, width: 4) == 4)
    }

    @Test func anotherWidthIsRespected() {
        #expect(CodeNSTextView.spacesForTab(atColumn: 0, width: 2) == 2)
        #expect(CodeNSTextView.spacesForTab(atColumn: 1, width: 2) == 1)
        #expect(CodeNSTextView.spacesForTab(atColumn: 5, width: 8) == 3)
    }

    /// A width of zero would divide by zero. It cannot arrive from Settings,
    /// but it can arrive from a config file someone edited by hand, and a
    /// Tab that crashes the editor is worse than one that inserts a space.
    @Test func aZeroWidthStillInsertsSomething() {
        #expect(CodeNSTextView.spacesForTab(atColumn: 0, width: 0) == 1)
        #expect(CodeNSTextView.spacesForTab(atColumn: 3, width: -2) == 1)
    }
}

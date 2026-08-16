import Foundation
@testable import Ghostty
import Testing

/// `GitDiffInlineEdits.between` — the word-level pass on top of the
/// line-level diff.
///
/// The contract worth remembering is what nil means: *no useful
/// character-level detail*, so treat the whole line as changed. It covers
/// three different situations — identical, replaced outright, and too long
/// to compare — and in all three the honest thing to draw is the same.
struct GitDiffInlineEditsTests {
    private func text(_ source: String, _ ranges: [NSRange]) -> [String] {
        let value = source as NSString
        return ranges.map { value.substring(with: $0) }
    }

    // MARK: Pointing at the change

    @Test func pointsAtTheOneWordThatChanged() throws {
        let edits = try #require(
            GitDiffInlineEdits.between(
                removed: "let total = compute(alpha)",
                added: "let total = compute(beta)"
            )
        )

        #expect(text("let total = compute(alpha)", edits.removed) == ["alpha"])
        #expect(text("let total = compute(beta)", edits.added) == ["beta"])
    }

    /// Word granularity, not character. `alpha` → `alpho` lights up the
    /// word, because a single highlighted letter in the middle of an
    /// identifier is harder to see than the identifier.
    @Test func highlightsWholeWordsRatherThanTheLettersInsideThem() throws {
        let edits = try #require(GitDiffInlineEdits.between(removed: "value alpha end", added: "value alpho end"))
        #expect(text("value alpha end", edits.removed) == ["alpha"])
        #expect(text("value alpho end", edits.added) == ["alpho"])
    }

    @Test func aPureInsertionMarksNothingOnTheRemovedSide() throws {
        let edits = try #require(GitDiffInlineEdits.between(removed: "call(a)", added: "call(a, b)"))
        #expect(edits.removed.isEmpty)
        #expect(text("call(a, b)", edits.added) == [", b"])
    }

    @Test func aPureDeletionMarksNothingOnTheAddedSide() throws {
        let edits = try #require(GitDiffInlineEdits.between(removed: "call(a, b)", added: "call(a)"))
        #expect(edits.added.isEmpty)
        #expect(text("call(a, b)", edits.removed) == [", b"])
    }

    @Test func severalSeparateChangesGetSeveralSpans() throws {
        let removed = "func run(alpha: Int, beta: Int) -> Int"
        let added = "func run(first: Int, second: Int) -> Int"
        let edits = try #require(GitDiffInlineEdits.between(removed: removed, added: added))

        #expect(text(removed, edits.removed) == ["alpha", "beta"])
        #expect(text(added, edits.added) == ["first", "second"])
    }

    /// Trimming the matching ends first is what keeps the highlight off the
    /// eighty characters nobody is asking about.
    @Test func aChangeAtTheEndLeavesTheStartAlone() throws {
        let removed = "import Foundation.NSString"
        let added = "import Foundation.NSNumber"
        let edits = try #require(GitDiffInlineEdits.between(removed: removed, added: added))

        #expect(text(removed, edits.removed) == ["NSString"])
        #expect(text(added, edits.added) == ["NSNumber"])
    }

    @Test func leadingIndentationChangeIsFound() throws {
        let edits = try #require(GitDiffInlineEdits.between(removed: "  value", added: "      value"))
        #expect(text("      value", edits.added) == ["      "])
    }

    // MARK: When there is nothing useful to point at

    @Test func identicalLinesHaveNoInlineDetail() {
        #expect(GitDiffInlineEdits.between(removed: "same", added: "same") == nil)
    }

    /// Two lines that share nothing but punctuation are a replacement, not
    /// an edit. Highlighting the brackets they have in common speckles the
    /// row and hides the change instead of showing it.
    @Test func aLineReplacedOutrightGetsNoSpeckledHighlight() {
        #expect(
            GitDiffInlineEdits.between(
                removed: "throw ConfigurationError.missingKey(name)",
                added: "return .success"
            ) == nil
        )
    }

    /// A minified bundle on one line. Comparing two of them word by word is
    /// quadratic in a place where nobody is reading the result.
    @Test func aLineTooLongToCompareIsLeftAlone() {
        let long = String(repeating: "abcdefghij ", count: 400)
        #expect(long.count > GitDiffInlineEdits.maximumLineLength)
        #expect(GitDiffInlineEdits.between(removed: long, added: long + "x") == nil)
    }

    // MARK: Text that is not ASCII

    /// Ranges are UTF-16 offsets and must land on grapheme boundaries: an
    /// emoji is two UTF-16 units and a family emoji is many more, and a
    /// range that cuts one in half draws a replacement character.
    @Test func rangesLandOnClusterBoundariesInEmojiAndAccents() throws {
        let removed = "label 🇧🇷 café done"
        let added = "label 🇧🇷 cafés done"
        let edits = try #require(GitDiffInlineEdits.between(removed: removed, added: added))

        #expect(text(removed, edits.removed) == ["café"])
        #expect(text(added, edits.added) == ["cafés"])

        /// Every span converts back into a Swift range, which it only can
        /// when both ends sit on a character boundary.
        for range in edits.added {
            #expect(Range(range, in: added) != nil)
        }
    }

    @Test func anEmojiThatChangedIsHighlightedWhole() throws {
        let removed = "status ✅ ok"
        let added = "status ❌ ok"
        let edits = try #require(GitDiffInlineEdits.between(removed: removed, added: added))

        #expect(text(removed, edits.removed) == ["✅"])
        #expect(text(added, edits.added) == ["❌"])
    }

    // MARK: Line endings

    /// The line-level diff carries the carriage return, so the word-level
    /// one sees it too — and on a file converted to CRLF that is the only
    /// difference there is.
    @Test func aCarriageReturnIsTheChangeWhenNothingElseIs() throws {
        let edits = try #require(GitDiffInlineEdits.between(removed: "value", added: "value\r"))
        #expect(edits.removed.isEmpty)
        #expect(edits.added.count == 1)
    }
}

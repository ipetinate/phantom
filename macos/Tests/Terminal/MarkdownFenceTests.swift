import Foundation
@testable import Ghostty
import Testing

/// Whether an offset is inside a fenced code block.
///
/// This is the one thing the snippet catalogue cannot answer for itself: it is
/// handed a single line, and a line inside a fence looks like any other. Get
/// this wrong and typing `/table` in the middle of a shell sample in a README
/// offers to insert a Markdown table — the one place the `/` trigger, which is
/// otherwise unambiguous, would still be wrong.
struct MarkdownFenceTests {
    private func inside(_ text: String, at offset: Int) -> Bool {
        MarkdownParser.isInsideFencedCode(text as NSString, offset: offset)
    }

    /// The offset of the character after `marker` in `text`, so a case can
    /// point at a caret position without counting characters by hand.
    private func caret(after marker: String, in text: String) -> Int {
        let range = (text as NSString).range(of: marker)
        return NSMaxRange(range)
    }

    @Test func plainProseIsNeverInsideAFence() {
        let text = "# Title\n\nSome prose about tables.\n"
        #expect(!inside(text, at: caret(after: "about ", in: text)))
        #expect(!inside(text, at: 0))
        #expect(!inside(text, at: (text as NSString).length))
    }

    @Test func aLineBetweenFencesIsInside() {
        let text = "intro\n\n```sh\necho hi\n```\n\nafter\n"
        #expect(inside(text, at: caret(after: "echo ", in: text)))
        #expect(!inside(text, at: caret(after: "after", in: text)))
    }

    /// The caret on the opening fence's own line is not yet inside it —
    /// otherwise typing the fence would suppress the catalogue on the very
    /// line you are still writing.
    @Test func theOpeningFenceLineIsNotItselfInside() {
        let text = "```ts\ncode\n```\n"
        #expect(!inside(text, at: 3))
        #expect(inside(text, at: caret(after: "code", in: text)))
    }

    /// An unclosed fence swallows the rest of the file, which is what the
    /// renderer does too — and the alternative would offer snippets inside
    /// code for every file somebody is halfway through writing.
    @Test func anUnclosedFenceRunsToTheEnd() {
        let text = "intro\n\n```\nstill code\nand more\n"
        #expect(inside(text, at: caret(after: "and more", in: text)))
    }

    /// Tildes are fences too, and a tilde does not close a backtick.
    @Test func tildeFencesCountAndDoNotCloseBacktickOnes() {
        let tilde = "~~~\ncode\n~~~\nafter\n"
        #expect(inside(tilde, at: caret(after: "code", in: tilde)))
        #expect(!inside(tilde, at: caret(after: "after", in: tilde)))

        let mixed = "```\ncode\n~~~\nstill code\n"
        #expect(inside(mixed, at: caret(after: "still code", in: mixed)))
    }

    /// A closer has to be at least as long as its opener, so a three-backtick
    /// line inside a four-backtick block is content — which is exactly how a
    /// README shows somebody how to write a fence.
    @Test func aShorterFenceDoesNotClose() {
        let text = "````md\n```\nnot a closer\n````\nafter\n"
        #expect(inside(text, at: caret(after: "not a closer", in: text)))
        #expect(!inside(text, at: caret(after: "after", in: text)))
    }

    /// A fence with an info string is an opener, never a closer. Without this
    /// a document alternating ```` ```ts ```` blocks would read as one long
    /// block and then as none.
    @Test func aFenceWithAnInfoStringNeverCloses() {
        let text = "```ts\none\n```js\ntwo\n"
        #expect(inside(text, at: caret(after: "two", in: text)))
    }

    /// CRLF is the trap this repo has paid for before: the line's own ending
    /// must not be read as the fence's info string.
    @Test func windowsLineEndingsBehaveTheSame() {
        let text = "intro\r\n```\r\ncode\r\n```\r\nafter\r\n"
        #expect(inside(text, at: caret(after: "code", in: text)))
        #expect(!inside(text, at: caret(after: "after", in: text)))
    }

    /// An offset outside the text answers rather than trapping — the caller
    /// is a view reading a caret that may already have moved.
    @Test func anOffsetOutsideTheTextIsClamped() {
        #expect(!inside("", at: 0))
        #expect(!inside("hi", at: 999))
        #expect(!inside("hi", at: -5))
    }
}

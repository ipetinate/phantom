import Foundation
@testable import Ghostty
import Testing

/// The three shapes `textDocument/hover` answers in, and the one of them that
/// was being read as if it were another.
struct LSPHoverContentsTests {
    /// `MarkedString` in its object form is code in a named language, not
    /// markdown. Taking its `value` and calling that markdown is what put
    /// Tailwind's CSS on the card as body text.
    ///
    /// The payload is verbatim from `tailwindcss-language-server` 0.16.0
    /// hovering `flex` in a `className`.
    @Test func aMarkedStringGetsTheFenceItsLanguageImplies() {
        let contents: LSPValue = [
            "language": .string("css"),
            "value": .string(".flex {\n  display: flex;\n}"),
        ]

        #expect(
            LSPHoverContents.markdown(from: contents)
                == "```css\n.flex {\n  display: flex;\n}\n```"
        )
    }

    /// The point of the fence, and both halves of it: `CodeHoverInfo` reads a
    /// leading fenced block as the declaration — drawn in the editor's own
    /// font — *and* takes the highlighter language from the fence's tag, so
    /// the CSS is coloured as CSS rather than as the `.tsx` around it.
    /// Without a fence, every line is prose — and prose is reflowed, so three
    /// lines of CSS became one.
    @Test func theFenceIsWhatMakesTheCardDrawItAsHighlightedCode() throws {
        let contents: LSPValue = [
            "language": .string("css"),
            "value": .string(".flex {\n  display: flex;\n}"),
        ]
        let markdown = try #require(LSPHoverContents.markdown(from: contents))

        let (signature, documentation) = CodeHoverInfo.split(markdown: markdown)

        #expect(
            signature == .code(".flex {\n  display: flex;\n}", language: .css),
            "\(String(describing: signature))"
        )
        #expect(documentation.isEmpty, "\(documentation)")
    }

    /// What it looked like before, kept as a test because the failure was not
    /// an error anywhere — it was a card that read like a sentence.
    @Test func theSameCSSWithoutAFenceIsReflowedIntoProse() {
        let (signature, documentation) = CodeHoverInfo.split(
            markdown: ".flex {\n  display: flex;\n}"
        )

        #expect(signature == nil)
        #expect(documentation == [.prose(".flex { display: flex; }")], "\(documentation)")
    }

    /// A `MarkupContent` carries `kind`, not `language`, and is markdown
    /// already. Fencing it would put a server's prose in the code font.
    @Test func aMarkupContentPassesThroughUntouched() {
        let contents: LSPValue = [
            "kind": .string("markdown"),
            "value": .string("```swift\nfunc f()\n```\n\nDoes a thing."),
        ]

        #expect(
            LSPHoverContents.markdown(from: contents)
                == "```swift\nfunc f()\n```\n\nDoes a thing."
        )
    }

    /// An object with a `value` and nothing to say about its language is the
    /// shape most servers send, and it is left alone.
    @Test func anObjectWithNoLanguageIsNotFenced() {
        #expect(LSPHoverContents.markdown(from: ["value": .string("marked")]) == "marked")
    }

    @Test func aPlainStringIsAlreadyTheAnswer() {
        #expect(LSPHoverContents.markdown(from: .string("plain")) == "plain")
    }

    /// An array mixes the shapes, and each element is resolved on its own —
    /// so a fenced element stays fenced next to a plain one.
    @Test func anArrayResolvesEachElementByItsOwnShape() {
        let contents: LSPValue = [
            .string("a"),
            ["value": .string("b")],
            ["language": .string("css"), "value": .string(".c {}")],
        ]

        #expect(
            LSPHoverContents.markdown(from: contents) == "a\n\nb\n\n```css\n.c {}\n```"
        )
    }

    /// Nothing to say is nil at every level: the card checks `isEmpty` before
    /// it opens a window, so an empty string here is a blank panel floating
    /// over the code.
    @Test func emptinessIsNothingRatherThanAnEmptyCard() {
        #expect(LSPHoverContents.markdown(from: nil) == nil)
        #expect(LSPHoverContents.markdown(from: .null) == nil)
        #expect(LSPHoverContents.markdown(from: .string("")) == nil)
        #expect(LSPHoverContents.markdown(from: ["value": .string("")]) == nil)
        #expect(LSPHoverContents.markdown(from: ["language": .string("css"), "value": .string("")]) == nil)
        #expect(LSPHoverContents.markdown(from: [.string(""), .string("")]) == nil)
    }

    /// A language of `""` is no language, and an empty info string on a fence
    /// is worse than none: it claims a block whose language nobody named.
    @Test func anEmptyLanguageIsNoLanguage() {
        let contents: LSPValue = ["language": .string(""), "value": .string("text")]
        #expect(LSPHoverContents.markdown(from: contents) == "text")
    }

    /// The seam itself: `LSPCenter` still answers hover, and answers it with
    /// this.
    @Test func theCenterAnswersThroughTheSameRules() {
        let contents: LSPValue = ["language": .string("css"), "value": .string(".a {}")]
        #expect(LSPCenter.hoverText(from: contents) == "```css\n.a {}\n```")
    }
}

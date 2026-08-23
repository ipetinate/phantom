import AppKit
@testable import Ghostty
import Testing

/// The markdown a language server actually sends, and what the card makes of
/// it.
///
/// `CodeHoverInfoTests` covers the declaration/prose split. This file covers
/// the half that showed: the card parses its documentation as **inline**
/// markdown — deliberately, because that is what keeps a doc comment's own
/// line breaks — and inline parsing leaves block syntax where it found it. So
/// every block marker a server sends has to be resolved by the splitter or it
/// is drawn as text. Each payload below was taken from what the real server
/// answers, and each one drew wrong before.
struct CodeHoverMarkdownTests {
    /// `sourcekit-lsp` sends `### Complexity` and `### Discussion`. Inline
    /// parsing draws the hashes.
    @Test func aHeadingLosesItsHashesAndBecomesEmphasis() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Returns the elements.

        ### Complexity

        O(n), where n is the length.
        """)

        #expect(documentation == [.prose("Returns the elements.\n\n**Complexity**\n\nO(n), where n is the length.")], "\(documentation)")
    }

    /// `# Examples` is the same rule at another depth — `rust-analyzer`'s
    /// heading level, and the one that made `# Examples` read as a comment.
    @Test func aTopLevelHeadingIsAHeadingToo() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "# Examples\n\nBasic usage:")
        #expect(documentation == [.prose("**Examples**\n\nBasic usage:")], "\(documentation)")
    }

    /// The space is what separates a heading from a line of C that opens with
    /// a directive.
    @Test func aHashWithNoSpaceAfterItIsNotAHeading() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "#include <stdio.h>")
        #expect(documentation == [.prose("#include <stdio.h>")], "\(documentation)")
    }

    /// Closing hashes are decoration and go with the opening ones.
    @Test func aClosedHeadingKeepsOnlyItsText() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "## Parameters ##")
        #expect(documentation == [.prose("**Parameters**")], "\(documentation)")
    }

    /// A heading somebody already bolded reads correctly on its own, and
    /// wrapping it again would nest `**` inside `**`, which the parser gives
    /// back as literal asterisks.
    @Test func anAlreadyEmphasisedHeadingIsLeftAlone() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "### **Note**")
        #expect(documentation == [.prose("**Note**")], "\(documentation)")
    }

    /// The one that shredded every Swift doc comment. `sourcekit-lsp` wraps
    /// its prose, so the rest of a bullet's own sentence arrives on the next
    /// line — and starting a new paragraph there turned each bullet into a
    /// bullet plus an orphan.
    @Test func aWrappedListItemIsStillOneItem() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        - transform: A mapping closure. It accepts an
        element of this sequence as its parameter.
        - Returns: An array.
        """)

        #expect(documentation == [.prose("""
        - transform: A mapping closure. It accepts an element of this sequence as its parameter.
        - Returns: An array.
        """)], "\(documentation)")
    }

    /// A blank line still ends an item, so the paragraph after a list is a
    /// paragraph and not the tail of the last bullet.
    @Test func aBlankLineEndsAnItem() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        - sep: the separator

        Everything else is positional.
        """)

        #expect(documentation == [.prose("- sep: the separator\n\nEverything else is positional.")], "\(documentation)")
    }

    /// Depth is carried by the indentation alone — a bullet is a bullet at any
    /// column — so throwing it away made a parameter and the list it belongs
    /// to two unrelated bullets.
    @Test func aNestedItemKeepsItsIndentation() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        - Parameters:
          - transform: A mapping closure.
        """)

        #expect(documentation == [.prose("- Parameters:\n  - transform: A mapping closure.")], "\(documentation)")
    }

    /// A note in a docstring. The marker is structure, and once the line is on
    /// its own it says nothing.
    @Test func aQuotedNoteLosesItsMarker() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Prints the values.

        > Note: flush is keyword-only.
        """)

        #expect(documentation == [.prose("Prints the values.\n\nNote: flush is keyword-only.")], "\(documentation)")
    }

    /// A quote wrapped over two lines is one note, reflowed like any other
    /// paragraph.
    @Test func aQuoteSpanningLinesIsOneParagraph() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        > Deprecated since 3.9: use
        > the walrus operator instead.
        """)

        #expect(documentation == [.prose("Deprecated since 3.9: use the walrus operator instead.")], "\(documentation)")
    }

    /// `rust-analyzer` answers with the module path in one fenced block and
    /// the signature in the next, with nothing between them. Latching on the
    /// first one put the path in the code font and drew the real signature as
    /// prose in the body face.
    @Test func aRunOfLeadingFencedBlocksIsAllDeclaration() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```rust
        core::iter::traits::iterator
        ```

        ```rust
        fn map<B, F>(self, f: F) -> Map<Self, F>
        ```

        ---

        Takes a closure.
        """)

        #expect(signature == .code(
            "core::iter::traits::iterator\n\nfn map<B, F>(self, f: F) -> Map<Self, F>",
            language: .rust
        ))
        #expect(documentation == [.prose("Takes a closure.")], "\(documentation)")
    }

    /// The other side of that rule: prose first means the fence is an example,
    /// so nothing is drawn as a declaration. A card with a signature it made
    /// up out of an example is worse than a card with none.
    ///
    /// The example is still *code*, though, and keeps the language its fence
    /// named — it is drawn in the editor's font beside the prose rather than
    /// folded into it.
    @Test func aFenceAfterProseIsAnExampleAndNotADeclaration() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        The current value.

        ```swift
        let a = 1
        ```
        """)

        #expect(signature == nil)
        #expect(
            documentation == [.prose("The current value."), .code("let a = 1", language: .swift)],
            "\(documentation)"
        )
    }
}

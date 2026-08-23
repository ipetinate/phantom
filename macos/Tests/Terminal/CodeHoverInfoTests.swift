import AppKit
@testable import Ghostty
import Testing

/// Splitting a language server's hover payload into declaration and prose.
///
/// The payloads here are the real shapes: `sourcekit-lsp`,
/// `typescript-language-server` and `pylsp` each answer in markdown, and each
/// does it slightly differently. Getting the split wrong shows the reader
/// either backtick-fenced noise or a declaration set in body text.
struct CodeHoverInfoTests {
    @Test func theFirstFencedBlockIsTheDeclaration() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func save() throws
        ```

        Writes the buffer to disk.
        """)

        #expect(signature == .code("func save() throws", language: .swift))
        #expect(documentation == [.prose("Writes the buffer to disk.")], "\(documentation)")
    }

    /// The rule between the two carries nothing once they are apart, and left
    /// in it reads as a stray row of dashes at the top of the prose.
    @Test func theHorizontalRuleBetweenThemIsDropped() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        ```typescript
        (property) SetupWorker.start: (options?: StartOptions) => StartReturnType
        ```

        ---

        Registers and activates the mock Service Worker.
        """)

        #expect(
            documentation == [.prose("Registers and activates the mock Service Worker.")],
            "\(documentation)"
        )
    }

    /// A dashed line is only a rule when that is all it is — a sentence that
    /// happens to open with a dash is prose.
    @Test func aDashedListItemIsNotMistakenForARule() {
        let (_, documentation) = CodeHoverInfo.split(markdown: "- sep: the separator")
        #expect(documentation == [.prose("- sep: the separator")], "\(documentation)")
    }

    /// A `@see` example, or a second overload: a block of its own, in the code
    /// font, with the language its fence named. Flattened into the prose
    /// around it — which is what used to happen — an example reads as a
    /// sentence somebody forgot to finish.
    @Test func aLaterFencedBlockIsCodeRatherThanProse() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func start()
        ```

        See also:

        ```swift
        worker.start()
        ```
        """)

        #expect(signature == .code("func start()", language: .swift))
        #expect(
            documentation == [.prose("See also:"), .code("worker.start()", language: .swift)],
            "\(documentation)"
        )
    }

    /// Plenty of servers answer in plain text. It is documentation, not a
    /// declaration, and calling it one would set a paragraph in the code font.
    @Test func aPayloadWithNoFenceIsAllProse() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: "The current value.")

        #expect(signature == nil)
        #expect(documentation == [.prose("The current value.")], "\(documentation)")
    }

    /// A multi-line declaration is one block, not the first line of one.
    @Test func aDeclarationSpanningLinesIsKeptWhole() {
        let (signature, _) = CodeHoverInfo.split(markdown: """
        ```swift
        func apply(
            theme: CodeTheme
        )
        ```
        """)

        #expect(signature == .code("func apply(\n    theme: CodeTheme\n)", language: .swift))
    }

    /// Nothing to say is different from an empty card: the engine checks
    /// `isEmpty` before opening a window, and a blank card floating over the
    /// code is what happens when it lies.
    @Test func emptinessCountsProblemsAsWellAsText() {
        #expect(CodeHoverInfo().isEmpty)
        #expect(CodeHoverInfo(signature: .code("func f()", language: .swift)).isEmpty == false)
        #expect(CodeHoverInfo(documentation: [.prose("A note.")]).isEmpty == false)
        #expect(CodeHoverInfo(
            problems: [.init(message: "unresolved", source: nil, color: .systemRed)]
        ).isEmpty == false)
    }

    /// A doc comment arrives wrapped to the column its author's editor used.
    /// Wrapping it again at the card's width is what produced the ragged
    /// "short line, long line" prose — markdown says a single newline is a
    /// space, and reading it that way is what makes the card read as text.
    @Test func hardWrappedProseIsRejoined() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        A plan file is plain markdown: no front matter,
        no working directory, no session id.
        """)

        #expect(
            documentation == [
                .prose("A plan file is plain markdown: no front matter, no working directory, no session id."),
            ],
            "\(documentation)"
        )
    }

    /// A blank line is the one break markdown does keep, and paragraphs are
    /// worth keeping apart.
    @Test func blankLinesStayParagraphBreaks() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        First paragraph
        continues here.

        Second paragraph.
        """)

        #expect(
            documentation == [.prose("First paragraph continues here.\n\nSecond paragraph.")],
            "\(documentation)"
        )
    }

    /// A run of prose is still assembled as one block: only a fence breaks it
    /// in two, because only a fence is drawn differently.
    @Test func proseAroundAnExampleIsTwoBlocksAndNotFour() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Uses the value.

        ```ts
        const a = 1
        ```

        And then some more.
        """)

        #expect(
            documentation == [
                .prose("Uses the value."),
                .code("const a = 1", language: .javascript),
                .prose("And then some more."),
            ],
            "\(documentation)"
        )
    }

    /// In a list the break *is* the meaning, so rejoining would run the items
    /// together into one sentence.
    @Test func listItemsKeepTheirOwnLines() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Options:

        - sep: the separator
        - end: the terminator
        """)

        #expect(
            documentation == [.prose("Options:\n\n- sep: the separator\n- end: the terminator")],
            "\(documentation)"
        )
    }

    /// Same for a fenced example: its line breaks are code, not wrapping.
    @Test func fencedExamplesAreNotReflowed() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        ```swift
        func f()
        ```

        Example:

        ```swift
        let a = 1
        let b = 2
        ```
        """)

        #expect(
            documentation == [
                .prose("Example:"),
                .code("let a = 1\nlet b = 2", language: .swift),
            ],
            "\(documentation)"
        )
    }

    /// The normal state of a doc comment somebody is halfway through writing.
    /// Its content is still code and still worth drawing as code.
    @Test func anUnclosedFenceIsStillAnExample() {
        let (_, documentation) = CodeHoverInfo.split(markdown: """
        Docs here.

        ```css
        .a { color: red; }
        """)

        #expect(
            documentation == [
                .prose("Docs here."),
                .code(".a { color: red; }", language: .css),
            ],
            "\(documentation)"
        )
    }

    /// Whitespace-only payloads are the empty case, not a card with a blank
    /// line in it.
    @Test func blankPayloadsProduceNothing() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: "\n  \n")

        #expect(signature == nil)
        #expect(documentation.isEmpty, "\(documentation)")
    }
}

/// Which highlighter a fence's tag picks, which is the whole difference
/// between a hover that reads as CSS and one that reads as a sentence.
struct CodeHoverFenceLanguageTests {
    /// The whole block rather than its language alone, so "this was not a code
    /// block at all" and "this was a code block naming no language" stay two
    /// different failures instead of collapsing into one nil.
    private func declaration(_ markdown: String) -> CodeHoverInfo.Block? {
        CodeHoverInfo.split(markdown: markdown).signature
    }

    /// The payload `tailwindcss-language-server` answers with, once
    /// `LSPHoverContents` has given it back the fence its `MarkedString`
    /// implied.
    @Test func aCSSFenceIsColouredAsCSS() {
        let block = declaration("```css\n.flex {\n  display: flex;\n}\n```")
        #expect(block == .code(".flex {\n  display: flex;\n}", language: .css), "\(String(describing: block))")
    }

    /// The tag decides, never the file the pointer is in — the CSS above is
    /// hovered inside a `.tsx`, and colouring it with TypeScript's rules is
    /// the bug this replaced.
    @Test func everyTagThisBuildKnowsResolves() {
        #expect(declaration("```swift\nlet a = 1\n```") == .code("let a = 1", language: .swift))
        #expect(declaration("```typescript\nconst a = 1\n```") == .code("const a = 1", language: .javascript))
        #expect(declaration("```rust\nlet a = 1;\n```") == .code("let a = 1;", language: .rust))
        #expect(declaration("```scss\n.a {}\n```") == .code(".a {}", language: .css))
    }

    /// The info string can carry more than a language — `ts title="app.ts"`
    /// is a real fence in a docs site — and only its first word is the tag.
    @Test func onlyTheFirstWordOfTheInfoStringIsTheLanguage() {
        let block = declaration("```ts title=\"app.ts\"\nconst a = 1\n```")
        #expect(block == .code("const a = 1", language: .javascript), "\(String(describing: block))")
    }

    /// Nil rather than a guess, which is what draws the block monospaced and
    /// uncoloured. A tag naming something that is not source — `diff`,
    /// `mermaid`, shell output — must not be run through a highlighter that
    /// would find keywords in it anyway.
    @Test func aFenceThatNamesNothingKnownIsNotHighlighted() {
        #expect(declaration("```\nsome text\n```") == .code("some text", language: nil))
        #expect(declaration("```mermaid\ngraph TD\n```") == .code("graph TD", language: nil))
    }

    /// `rust-analyzer` answers with the module path in one block and the
    /// signature in the next; they are one declaration and take one language.
    @Test func theDeclarationTakesTheLanguageOfItsFirstFence() {
        let (signature, documentation) = CodeHoverInfo.split(markdown: """
        ```rust
        core::iter::traits::iterator
        ```

        ```rust
        fn map<B, F>(self, f: F) -> Map<Self, F>
        ```

        Takes a closure.
        """)

        #expect(
            signature == .code(
                "core::iter::traits::iterator\n\nfn map<B, F>(self, f: F) -> Map<Self, F>",
                language: .rust
            ),
            "\(String(describing: signature))"
        )
        #expect(documentation == [.prose("Takes a closure.")], "\(documentation)")
    }
}

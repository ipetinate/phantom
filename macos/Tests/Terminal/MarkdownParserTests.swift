import Foundation
@testable import Ghostty
import Testing

/// The block splitter, which is where every markdown bug lives.
///
/// Written as strings and expectations because that is the only form these
/// rules hold still in: half of them are "this construct beats that one *in
/// this context*", and prose describing the precedence is exactly as
/// convincing as prose describing a regex.
struct MarkdownParserTests {
    private func parse(_ text: String, flavor: MarkdownParser.Flavor = .markdown) -> MarkdownDocument {
        MarkdownParser.parse(text, flavor: flavor)
    }

    private func kinds(_ text: String) -> [MarkdownBlock.Kind] {
        parse(text).blocks.map(\.kind)
    }

    /// Unwrapping helpers rather than `guard case`, so a wrong shape fails
    /// the expectation it was written for instead of falling out of the
    /// test early and reporting nothing.
    private func code(_ kind: MarkdownBlock.Kind?) -> MarkdownCodeBlock? {
        if case let .code(code) = kind { return code }
        return nil
    }

    private func list(_ kind: MarkdownBlock.Kind?) -> MarkdownList? {
        if case let .list(list) = kind { return list }
        return nil
    }

    private func table(_ kind: MarkdownBlock.Kind?) -> MarkdownTable? {
        if case let .table(table) = kind { return table }
        return nil
    }

    private func quoted(_ kind: MarkdownBlock.Kind?) -> [MarkdownBlock]? {
        if case let .quote(blocks) = kind { return blocks }
        return nil
    }

    // MARK: - Nothing at all

    @Test func anEmptyDocumentHasNoBlocks() {
        #expect(parse("").blocks.isEmpty)
        #expect(parse("\n\n\n").blocks.isEmpty)
        #expect(parse("   \n\t\n").blocks.isEmpty)
    }

    // MARK: - Headings

    @Test func atxHeadingsCarryTheirLevel() {
        #expect(kinds("# One") == [.heading(level: 1, text: "One")])
        #expect(kinds("###### Six") == [.heading(level: 6, text: "Six")])
    }

    @Test func sevenHashesIsNotAHeading() {
        #expect(kinds("####### Seven") == [.paragraph(text: "####### Seven")])
    }

    @Test func aHashWithoutASpaceIsNotAHeading() {
        #expect(kinds("#NoSpace") == [.paragraph(text: "#NoSpace")])
    }

    @Test func closingHashesAreDropped() {
        #expect(kinds("## Title ##") == [.heading(level: 2, text: "Title")])
    }

    /// The hash that belongs to the text rather than to the syntax.
    @Test func aTrailingHashWithoutASpaceIsPartOfTheText() {
        #expect(kinds("## C#") == [.heading(level: 2, text: "C#")])
    }

    @Test func aHeadingIndentedFourSpacesIsCode() {
        let blocks = parse("    # not a heading").blocks
        #expect(blocks.count == 1)
        #expect(code(blocks.first?.kind)?.code == "# not a heading")
        #expect(code(blocks.first?.kind)?.info == nil)
    }

    // MARK: - Setext, and the four meanings of `---`

    @Test func anEqualsUnderlineIsALevelOneHeading() {
        #expect(kinds("Title\n=====") == [.heading(level: 1, text: "Title")])
    }

    @Test func aDashUnderlineIsALevelTwoHeading() {
        #expect(kinds("Title\n---") == [.heading(level: 2, text: "Title")])
    }

    /// A single dash still underlines: CommonMark puts setext above both the
    /// thematic break and the empty list item when a paragraph is open.
    @Test func oneDashUnderAParagraphIsStillAHeading() {
        #expect(kinds("Title\n-") == [.heading(level: 2, text: "Title")])
    }

    @Test func dashesAfterABlankLineAreAThematicBreak() {
        #expect(kinds("Title\n\n---") == [.paragraph(text: "Title"), .thematicBreak])
    }

    @Test func starsUnderAParagraphAreAThematicBreakNotAHeading() {
        #expect(kinds("Title\n***\nmore") == [
            .paragraph(text: "Title"),
            .thematicBreak,
            .paragraph(text: "more"),
        ])
    }

    @Test func aThematicBreakTakesSeveralForms() {
        #expect(kinds("***") == [.thematicBreak])
        #expect(kinds("___") == [.thematicBreak])
        #expect(kinds("- - -") == [.thematicBreak])
        #expect(kinds("*****") == [.thematicBreak])
    }

    /// Too short for a rule, and a rule is what the block level asks about
    /// first.
    @Test func twoDashesAloneAreAParagraph() {
        #expect(kinds("--") == [.paragraph(text: "--")])
    }

    @Test func aMultiLineParagraphUnderlinedKeepsAllOfItsText() {
        #expect(kinds("one\ntwo\n===") == [.heading(level: 1, text: "one\ntwo")])
    }

    // MARK: - Front matter

    @Test func frontMatterIsItsOwnBlock() {
        let blocks = parse("---\ntitle: x\ntags: [a]\n---\n\n# H").blocks
        #expect(blocks.map(\.kind) == [
            .frontMatter("title: x\ntags: [a]"),
            .heading(level: 1, text: "H"),
        ])
    }

    /// Without a closer it was never front matter, and swallowing the file
    /// on the strength of one line would be the worst possible reading.
    @Test func anUnclosedFrontMatterOpenerIsJustARule() {
        #expect(kinds("---\ntitle: x") == [.thematicBreak, .paragraph(text: "title: x")])
    }

    @Test func frontMatterOnlyCountsAtTheTop() {
        #expect(kinds("intro\n\n---\nkey: v\n---") == [
            .paragraph(text: "intro"),
            .thematicBreak,
            .heading(level: 2, text: "key: v"),
        ])
    }

    // MARK: - Fenced code

    @Test func aFenceKeepsItsLanguage() {
        let block = parse("```swift\nlet x = 1\n```").blocks.first
        #expect(code(block?.kind)?.info == "swift")
        #expect(code(block?.kind)?.languageHint == "swift")
        #expect(code(block?.kind)?.code == "let x = 1")
        #expect(code(block?.kind)?.isClosed == true)
    }

    @Test func aFenceInfoStringKeepsOnlyItsFirstWordAsTheLanguage() {
        let block = parse("```ts title=\"app.ts\"\nx\n```").blocks.first
        #expect(code(block?.kind)?.info == "ts title=\"app.ts\"")
        #expect(code(block?.kind)?.languageHint == "ts")
    }

    @Test func tildeFencesWork() {
        #expect(code(parse("~~~js\nx\n~~~").blocks.first?.kind)?.languageHint == "js")
    }

    /// The normal state of a file somebody is halfway through typing.
    @Test func anUnclosedFenceRunsToTheEndAndSaysSo() {
        let blocks = parse("# T\n\n```swift\nlet x = 1\nstill code").blocks
        #expect(blocks.count == 2)
        #expect(code(blocks.last?.kind)?.code == "let x = 1\nstill code")
        #expect(code(blocks.last?.kind)?.isClosed == false)
    }

    /// Everything inside a fence is text, however much it looks like
    /// markdown.
    @Test func aFenceSwallowsHeadingsAndListsAndRules() {
        let blocks = parse("```\n# not a heading\n- not a list\n---\n```").blocks
        #expect(blocks.count == 1)
        #expect(code(blocks.first?.kind)?.code == "# not a heading\n- not a list\n---")
    }

    /// A shorter run inside a longer fence is content, not the closer.
    @Test func onlyAnEqualOrLongerRunClosesAFence() {
        let blocks = parse("````\n```\ninner\n```\n````").blocks
        #expect(blocks.count == 1)
        #expect(code(blocks.first?.kind)?.code == "```\ninner\n```")
    }

    @Test func aTildeFenceIsNotClosedByBackticks() {
        let block = parse("~~~\n```\n~~~").blocks.first
        #expect(code(block?.kind)?.code == "```")
        #expect(code(block?.kind)?.isClosed == true)
    }

    /// A backtick in the info string means the line was a paragraph with
    /// code spans in it all along.
    @Test func aBacktickInTheInfoStringMeansItWasNeverAFence() {
        #expect(kinds("```a`b") == [.paragraph(text: "```a`b")])
    }

    @Test func anIndentedFenceLosesItsOwnIndentFromEveryLine() {
        #expect(code(parse("  ```\n  one\n    two\n  ```").blocks.first?.kind)?.code == "one\n  two")
    }

    // MARK: - Lists

    @Test func aBulletListCollectsItsItems() {
        let found = list(parse("- one\n- two").blocks.first?.kind)
        #expect(found?.items.count == 2)
        #expect(found?.isOrdered == false)
        #expect(found?.isTight == true)
        #expect(found?.items.first?.blocks == [
            MarkdownBlock(kind: .paragraph(text: "one"), sourceLines: 0...0),
        ])
    }

    /// A list that starts at three still starts at three — how a README
    /// numbers steps that continued after a code block.
    @Test func anOrderedListKeepsTheNumbersAsWritten() {
        let found = list(parse("3. three\n4. four").blocks.first?.kind)
        #expect(found?.isOrdered == true)
        #expect(found?.items.map(\.ordinal) == [3, 4])
    }

    @Test func nestingIsRecursiveNotFlattened() {
        let outer = list(parse("- a\n  - b\n    - c\n- d").blocks.first?.kind)
        #expect(outer?.items.count == 2)

        let second = list(outer?.items.first?.blocks.last?.kind)
        #expect(outer?.items.first?.blocks.count == 2)
        #expect(second?.items.count == 1)

        let third = list(second?.items.first?.blocks.last?.kind)
        #expect(third?.items.count == 1)
        #expect(third?.items.first?.blocks.map(\.kind) == [.paragraph(text: "c")])
    }

    /// A numbered list nested inside a bulleted one — the case a flat depth
    /// model gets wrong, because one `isOrdered` cannot describe both.
    @Test func aNestedListKeepsItsOwnKind() {
        let outer = list(parse("- a\n  1. one\n  2. two").blocks.first?.kind)
        #expect(outer?.isOrdered == false)

        let inner = list(outer?.items.first?.blocks.last?.kind)
        #expect(inner?.isOrdered == true)
        #expect(inner?.items.map(\.ordinal) == [1, 2])
    }

    /// One space of indent is not enough to nest: the marker has to reach
    /// the parent item's content column.
    @Test func aMarkerLeftOfTheContentColumnIsASibling() {
        #expect(list(parse("- a\n - b").blocks.first?.kind)?.items.count == 2)
    }

    @Test func aBlankLineBetweenItemsMakesTheListLoose() {
        let found = list(parse("- a\n\n- b").blocks.first?.kind)
        #expect(found?.items.count == 2)
        #expect(found?.isTight == false)
    }

    @Test func twoBlankLinesEndTheList() {
        let blocks = parse("- a\n\n\n- b").blocks
        #expect(blocks.count == 2)
        #expect(list(blocks.first?.kind)?.items.count == 1)
        #expect(list(blocks.last?.kind)?.items.count == 1)
    }

    /// Changing the bullet character starts a new list, which is
    /// CommonMark's way of letting two lists touch with no blank line.
    @Test func changingTheBulletStartsANewList() {
        #expect(parse("- a\n* b").blocks.count == 2)
    }

    @Test func aBulletListAndAnOrderedListDoNotMerge() {
        #expect(parse("- a\n1. b").blocks.count == 2)
    }

    @Test func aLazyContinuationStaysInsideItsItem() {
        let blocks = parse("- a\nstill a\n\nafter").blocks
        #expect(blocks.count == 2)
        #expect(list(blocks.first?.kind)?.items.count == 1)
        #expect(list(blocks.first?.kind)?.items.first?.blocks == [
            MarkdownBlock(kind: .paragraph(text: "a\nstill a"), sourceLines: 0...1),
        ])
        #expect(blocks.last?.kind == .paragraph(text: "after"))
    }

    @Test func aFenceInsideAnItemBelongsToTheItem() {
        let found = list(parse("- run this:\n\n  ```sh\n  make\n  ```\n\n- then this").blocks.first?.kind)
        #expect(found?.items.count == 2)
        #expect(found?.isTight == false)
        #expect(found?.items.first?.blocks.count == 2)
        #expect(code(found?.items.first?.blocks.last?.kind)?.code == "make")
        #expect(code(found?.items.first?.blocks.last?.kind)?.languageHint == "sh")
    }

    @Test func taskBoxesAreRead() {
        let found = list(parse("- [ ] todo\n- [x] done\n- plain").blocks.first?.kind)
        #expect(found?.items.map(\.isChecked) == [false, true, nil])
        #expect(found?.items.first?.blocks == [
            MarkdownBlock(kind: .paragraph(text: "todo"), sourceLines: 0...0),
        ])
    }

    @Test func anEmptyItemIsStillAnItem() {
        let found = list(parse("- a\n-\n- c").blocks.first?.kind)
        #expect(found?.items.count == 3)
        #expect(found?.items[1].blocks.isEmpty == true)
    }

    // MARK: - Lists interrupting a paragraph

    @Test func aBulletInterruptsAParagraph() {
        #expect(kinds("text\n- item").count == 2)
    }

    /// The rule that stops a sentence ending in a year from becoming a list:
    /// only `1.` may interrupt.
    @Test func anOrderedItemNotStartingAtOneDoesNotInterrupt() {
        #expect(kinds("Released 2024\n2. not a list") == [
            .paragraph(text: "Released 2024\n2. not a list"),
        ])
    }

    @Test func anOrderedItemStartingAtOneDoesInterrupt() {
        #expect(kinds("text\n1. item").count == 2)
    }

    @Test func anEmptyItemCannotInterruptAParagraph() {
        #expect(kinds("text\n-") == [.heading(level: 2, text: "text")])
    }

    // MARK: - Block quotes

    @Test func aQuoteHoldsBlocksNotText() {
        let inner = quoted(parse("> ## Note\n>\n> Be careful.").blocks.first?.kind)
        #expect(inner?.map(\.kind) == [
            .heading(level: 2, text: "Note"),
            .paragraph(text: "Be careful."),
        ])
    }

    @Test func aQuoteCanHoldAFence() {
        let inner = quoted(parse("> ```swift\n> let x = 1\n> ```").blocks.first?.kind)
        #expect(code(inner?.first?.kind)?.code == "let x = 1")
        #expect(code(inner?.first?.kind)?.languageHint == "swift")
    }

    @Test func aQuoteTakesLazyContinuations() {
        let blocks = parse("> a\nb\n\nc").blocks
        #expect(blocks.count == 2)
        #expect(quoted(blocks.first?.kind)?.map(\.kind) == [.paragraph(text: "a\nb")])
    }

    @Test func nestedQuotesNest() {
        let outer = quoted(parse("> > deep").blocks.first?.kind)
        #expect(quoted(outer?.first?.kind)?.map(\.kind) == [.paragraph(text: "deep")])
    }

    // MARK: - Tables

    @Test func aTableNeedsItsSeparatorRow() {
        #expect(kinds("| a | b |\n| 1 | 2 |") == [.paragraph(text: "| a | b |\n| 1 | 2 |")])
    }

    @Test func aTableReadsHeadersAndRows() {
        let found = table(parse("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |").blocks.first?.kind)
        #expect(found?.headers == ["a", "b"])
        #expect(found?.rows == [["1", "2"], ["3", "4"]])
    }

    @Test func colonsInTheSeparatorSetAlignment() {
        let found = table(parse("| a | b | c | d |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |").blocks.first?.kind)
        #expect(found?.alignments == [.leading, .center, .trailing, nil])
    }

    /// Squared off in the parser, so no renderer has to re-decide it.
    @Test func raggedRowsArePaddedAndTruncated() {
        let found = table(parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |").blocks.first?.kind)
        #expect(found?.rows == [["1", ""], ["1", "2"]])
    }

    /// A separator whose column count disagrees with the header is not a
    /// separator, and the whole thing falls back to prose.
    @Test func aMismatchedSeparatorIsNotATable() {
        #expect(kinds("| a | b |\n|---|\n| 1 |") == [.paragraph(text: "| a | b |\n|---|\n| 1 |")])
    }

    @Test func aTableAfterAParagraphStillParses() {
        let blocks = parse("intro\n| a |\n|---|\n| 1 |").blocks
        #expect(blocks.count == 2)
        #expect(blocks.first?.kind == .paragraph(text: "intro"))
        #expect(table(blocks.last?.kind)?.headers == ["a"])
        #expect(table(blocks.last?.kind)?.rows == [["1"]])
    }

    @Test func anEscapedPipeStaysInsideItsCell() {
        let found = table(parse("| a | b |\n|---|---|\n| x \\| y | z |").blocks.first?.kind)
        #expect(found?.rows == [["x \\| y", "z"]])
    }

    // MARK: - Link definitions

    @Test func linkDefinitionsAreLiftedOutOfTheText() {
        let document = parse("See [docs][d].\n\n[d]: https://example.com \"Docs\"")
        #expect(document.blocks.map(\.kind) == [.paragraph(text: "See [docs][d].")])
        #expect(document.linkDefinitions == [
            MarkdownLinkDefinition(label: "d", destination: "https://example.com", title: "Docs"),
        ])
    }

    @Test func aDefinitionLabelIsCaseInsensitive() {
        #expect(parse("[Docs]: https://x.com").linkDefinitions.map(\.label) == ["docs"])
    }

    /// `[note]: see the docs` is a sentence, not a definition.
    @Test func aBracketedLineWithProseAfterItIsAParagraph() {
        let document = parse("[note]: see the docs")
        #expect(document.linkDefinitions.isEmpty)
        #expect(document.blocks.map(\.kind) == [.paragraph(text: "[note]: see the docs")])
    }

    // MARK: - Line endings and whitespace

    @Test func crlfIsNormalisedBeforeAnythingLooksAtALine() {
        #expect(kinds("# A\r\n\r\npara\r\n") == [
            .heading(level: 1, text: "A"),
            .paragraph(text: "para"),
        ])
    }

    /// The two trailing spaces are a hard line break and belong to the
    /// inline pass, so the block level has to hand them over untouched.
    @Test func aParagraphKeepsItsOwnNewlinesAndTrailingSpaces() {
        #expect(kinds("one  \ntwo") == [.paragraph(text: "one  \ntwo")])
    }

    // MARK: - HTML

    @Test func anHtmlBlockIsKeptVerbatim() {
        #expect(kinds("<div align=\"center\">\n  <img src=\"a.png\">\n</div>") == [
            .html("<div align=\"center\">\n  <img src=\"a.png\">\n</div>"),
        ])
    }

    @Test func anHtmlCommentIsAnHtmlBlock() {
        #expect(kinds("<!-- hidden -->") == [.html("<!-- hidden -->")])
    }

    /// A comment ends at `-->`, not at the first blank line inside it.
    ///
    /// Found in a real file: a `<!-- USAGE: … -->` header with a blank line
    /// in the middle was cut in half, and the second half was drawn as
    /// prose — a comment leaking onto the page, which is the exact opposite
    /// of what a comment is for.
    @Test func aCommentWithABlankLineInsideItStaysOneBlock() {
        let text = "<!-- one\n\ntwo\n-->\n\n# H"
        #expect(kinds(text) == [.html("<!-- one\n\ntwo\n-->"), .heading(level: 1, text: "H")])
    }

    @Test func aScriptBlockEndsAtItsClosingTag() {
        let text = "<script>\nlet a = 1\n\nlet b = 2\n</script>\n\nafter"
        #expect(kinds(text) == [
            .html("<script>\nlet a = 1\n\nlet b = 2\n</script>"),
            .paragraph(text: "after"),
        ])
    }

    /// An ordinary tag has no terminator of its own, so the blank line is
    /// still what ends it.
    @Test func aPlainTagBlockStillEndsAtABlankLine() {
        #expect(kinds("<div>\nhi\n</div>\n\nafter") == [
            .html("<div>\nhi\n</div>"),
            .paragraph(text: "after"),
        ])
    }

    @Test func anUnterminatedCommentTakesTheRestOfTheFile() {
        #expect(kinds("<!-- open\n\nstill inside") == [.html("<!-- open\n\nstill inside")])
    }

    @Test func aLessThanFollowedByProseIsNotHtml() {
        #expect(kinds("< not html") == [.paragraph(text: "< not html")])
    }

    /// An inline element with content after it is prose with markup in it,
    /// not a block.
    ///
    /// Found in a real README: the logo line
    /// `<a href="…"><img src="…"></a>` was being drawn as a panel of raw
    /// source. `a` and `img` are inline elements, and only CommonMark's
    /// block-level tag list opens a block on sight.
    @Test func anInlineElementLineIsAParagraph() {
        let logo = "<a href=\"https://x.com\"><img src=\"logo.png\"></a>"
        #expect(kinds(logo) == [.paragraph(text: logo)])
    }

    @Test func aBlockLevelTagStillOpensABlock() {
        #expect(kinds("<div>\nhi\n</div>") == [.html("<div>\nhi\n</div>")])
        #expect(kinds("<table>\n<tr><td>1</td></tr>\n</table>") == [
            .html("<table>\n<tr><td>1</td></tr>\n</table>"),
        ])
    }

    /// A tag alone on its line is a block even when nothing knows the name —
    /// which is the door an MDX component comes through.
    @Test func anUnknownTagAloneOnItsLineIsABlock() {
        #expect(kinds("<Callout type=\"warn\">\nhi\n</Callout>") == [
            .html("<Callout type=\"warn\">\nhi\n</Callout>"),
        ])
    }

    /// That kind, and only that kind, may not cut an open paragraph in half.
    @Test func aBareTagDoesNotInterruptAParagraph() {
        #expect(kinds("some prose\n<Callout>") == [.paragraph(text: "some prose\n<Callout>")])
        #expect(kinds("some prose\n<div>") == [
            .paragraph(text: "some prose"),
            .html("<div>"),
        ])
    }

    // MARK: - MDX

    @Test func mdxImportsAreScriptOnlyInMdx() {
        let text = "import Callout from '../components/Callout'\nexport const meta = { a: 1 }\n\n# Title"
        #expect(kinds(text) == [
            .paragraph(text: "import Callout from '../components/Callout'\nexport const meta = { a: 1 }"),
            .heading(level: 1, text: "Title"),
        ])
        #expect(MarkdownParser.parse(text, flavor: .mdx).blocks.map(\.kind) == [
            .script("import Callout from '../components/Callout'\nexport const meta = { a: 1 }"),
            .heading(level: 1, text: "Title"),
        ])
    }

    @Test func jsxComesThroughAsHtmlWithItsSourceIntact() {
        let text = "Text\n\n<Callout type=\"warn\">\n  Careful.\n</Callout>\n\nAfter"
        #expect(MarkdownParser.parse(text, flavor: .mdx).blocks.map(\.kind) == [
            .paragraph(text: "Text"),
            .html("<Callout type=\"warn\">\n  Careful.\n</Callout>"),
            .paragraph(text: "After"),
        ])
    }

    /// An indented `import` is prose: it is an ordinary English word.
    @Test func anIndentedImportIsNotAScriptBlock() {
        #expect(MarkdownParser.parse("  import matters here", flavor: .mdx).blocks.map(\.kind) == [
            .paragraph(text: "  import matters here"),
        ])
    }

    @Test func theFlavorComesFromTheExtension() {
        #expect(MarkdownParser.flavor(forFileName: "README.md") == .markdown)
        #expect(MarkdownParser.flavor(forFileName: "page.mdx") == .mdx)
        #expect(MarkdownParser.flavor(forFileName: "Page.MDX") == .mdx)
    }

    // MARK: - Source lines

    /// Recorded so the preview can be scrolled in step with the raw text
    /// beside it, which is the whole reason the parse is line-based.
    @Test func everyBlockKnowsWhichLinesItCameFrom() {
        let document = parse("# One\n\npara\n\n```\ncode\n```\n\n- a\n- b")
        #expect(document.blocks.map(\.sourceLines) == [0...0, 2...2, 4...6, 8...9])
    }

    @Test func aBlockInsideAQuoteKeepsTheDocumentsLineNumbers() {
        let document = parse("intro\n\n> quoted\n> more")
        #expect(document.blocks.count == 2)
        #expect(document.blocks.last?.sourceLines == 2...3)
        #expect(quoted(document.blocks.last?.kind)?.map(\.sourceLines) == [2...3])
    }

    @Test func aBlockInsideAListItemKeepsTheDocumentsLineNumbers() {
        let found = list(parse("- one\n- two\n- three").blocks.first?.kind)
        #expect(found?.items.map { $0.blocks.map(\.sourceLines) } == [[0...0], [1...1], [2...2]])
    }

    @Test func sourceLinesStayInBoundsForAnUnclosedFence() {
        #expect(parse("```\ncode").blocks.map(\.sourceLines) == [0...1])
    }

    // MARK: - A whole file

    /// One realistic document, because a parser can pass every rule in
    /// isolation and still lose its place halfway down a README.
    @Test func aRealisticReadmeComesOutInOrder() {
        let readme = """
        # Phantom

        A terminal that edits.

        ## Install

        ```sh
        brew install phantom
        ```

        ## Features

        - Splits
        - Editor
          - Syntax highlighting
          - Completion
        - Git

        > **Note**
        > Requires macOS 14.

        | Setting | Default |
        |---------|---------|
        | Theme   | system  |

        ---

        See [the docs][docs].

        [docs]: https://example.com
        """

        let document = parse(readme)
        let shapes: [String] = document.blocks.map { block in
            switch block.kind {
            case .heading(let level, _): return "h\(level)"
            case .paragraph: return "p"
            case .code: return "code"
            case .list: return "list"
            case .quote: return "quote"
            case .table: return "table"
            case .thematicBreak: return "rule"
            case .html: return "html"
            case .frontMatter: return "front"
            case .script: return "script"
            }
        }
        #expect(shapes == ["h1", "p", "h2", "code", "h2", "list", "quote", "table", "rule", "p"])
        #expect(document.linkDefinitions.map(\.label) == ["docs"])
    }
}

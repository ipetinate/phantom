import AppKit
import Foundation
@testable import Ghostty
import Testing

/// What the parse turns into.
///
/// Kept apart from `MarkdownParserTests` on purpose: these assert on
/// attributes of the rendered string, so the drawing can be argued about
/// without a single parser test moving.
struct MarkdownRendererTests {
    private var style: MarkdownStyle { .fallback }

    private func render(_ markdown: String, flavor: MarkdownParser.Flavor = .markdown, baseURL: URL? = nil)
        -> MarkdownRenderer.Output {
        MarkdownRenderer(style: style, baseURL: baseURL)
            .render(MarkdownParser.parse(markdown, flavor: flavor))
    }

    private func attributes(
        _ key: NSAttributedString.Key,
        in text: NSAttributedString
    ) -> [Any] {
        var found: [Any] = []
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value { found.append(value) }
        }
        return found
    }

    private func fonts(in text: NSAttributedString) -> [NSFont] {
        attributes(.font, in: text).compactMap { $0 as? NSFont }
    }

    private func foregroundColors(in text: NSAttributedString) -> [NSColor] {
        attributes(.foregroundColor, in: text).compactMap { $0 as? NSColor }
    }

    private func textBlocks(in text: NSAttributedString) -> [NSTextBlock] {
        attributes(.paragraphStyle, in: text)
            .compactMap { $0 as? NSParagraphStyle }
            .flatMap(\.textBlocks)
    }

    // MARK: - Nothing at all

    @Test func anEmptyDocumentRendersNothing() {
        let output = render("")
        #expect(output.text.length == 0)
        #expect(output.anchors.isEmpty)
    }

    // MARK: - Prose

    @Test func aHeadingIsBiggerThanTheBodyText() {
        let heading = render("# Title").text
        let paragraph = render("Title").text
        let headingSize = fonts(in: heading).first?.pointSize ?? 0
        let bodySize = fonts(in: paragraph).first?.pointSize ?? 0
        #expect(headingSize > bodySize)
    }

    /// The traits the inline pass found survive the heading's own font, so
    /// a code span in a heading is still monospaced.
    @Test func aCodeSpanInsideAHeadingStaysMonospaced() {
        let text = render("# The `init` method").text
        let monospaced = fonts(in: text).filter { $0.fontDescriptor.symbolicTraits.contains(.monoSpace) }
        #expect(!monospaced.isEmpty)
    }

    @Test func emphasisBecomesFontTraits() {
        let text = render("plain *italic* **bold**").text
        let traits = fonts(in: text).map(\.fontDescriptor.symbolicTraits)
        #expect(traits.contains { $0.contains(.italic) })
        #expect(traits.contains { $0.contains(.bold) })
    }

    @Test func aLinkCarriesItsDestination() {
        let text = render("See [the docs](https://example.com).").text
        let links = attributes(.link, in: text).compactMap { $0 as? URL }
        #expect(links.map(\.absoluteString) == ["https://example.com"])
    }

    /// The definitions are collected document-wide and fed back into the
    /// inline parse, which is the only way a reference link one block away
    /// from its target can resolve.
    @Test func aReferenceLinkResolvesAgainstADefinitionElsewhereInTheFile() {
        let text = render("See [the docs][d].\n\n[d]: https://example.com").text
        let links = attributes(.link, in: text).compactMap { $0 as? URL }
        #expect(links.map(\.absoluteString) == ["https://example.com"])
    }

    @Test func strikethroughIsDrawnAsStrikethrough() {
        let text = render("~~gone~~").text
        #expect(!attributes(.strikethroughStyle, in: text).isEmpty)
    }

    // MARK: - Code

    /// The whole reason a fence keeps its info string: the app already owns
    /// a highlighter, and an uncoloured Swift block looks unfinished.
    @Test func aFencedSwiftBlockIsSyntaxHighlighted() {
        let text = render("```swift\nlet x = \"hi\"\n```").text
        let distinct = Set(foregroundColors(in: text).map(\.description))
        #expect(distinct.count > 1, "expected more than one colour in a highlighted fence")
    }

    @Test func aFenceWithNoLanguageIsLeftAlone() {
        let text = render("```\nlet x = \"hi\"\n```").text
        let distinct = Set(foregroundColors(in: text).map(\.description))
        #expect(distinct.count == 1)
    }

    @Test func aFenceInAnUnknownLanguageStillRendersItsText() {
        let text = render("```mermaid\ngraph TD;\n```").text
        #expect(text.string.contains("graph TD;"))
    }

    @Test func fenceInfoStringsMapToLanguages() {
        #expect(CodeLanguage.resolve(fenceInfo: "swift") == .swift)
        #expect(CodeLanguage.resolve(fenceInfo: "bash") == .shell)
        #expect(CodeLanguage.resolve(fenceInfo: "console") == .shell)
        #expect(CodeLanguage.resolve(fenceInfo: "typescript") == .javascript)
        #expect(CodeLanguage.resolve(fenceInfo: "yml") == .yaml)
        #expect(CodeLanguage.resolve(fenceInfo: nil) == nil)
        #expect(CodeLanguage.resolve(fenceInfo: "mermaid") == nil)
        #expect(CodeLanguage.resolve(fenceInfo: "text") == nil)
    }

    /// Said out loud, because an unclosed fence is why the rest of the
    /// document stopped being prose.
    @Test func anUnclosedFenceIsLabelled() {
        #expect(render("```swift\nlet x = 1").text.string.contains("unclosed fence"))
        #expect(!render("```swift\nlet x = 1\n```").text.string.contains("unclosed fence"))
    }

    @Test func aCodeBlockSitsOnAFilledPanel() {
        let blocks = textBlocks(in: render("```\ncode\n```").text)
        #expect(blocks.contains { $0.backgroundColor != nil })
    }

    // MARK: - Structure

    @Test func aQuoteGetsALeftBar() {
        let blocks = textBlocks(in: render("> quoted").text)
        #expect(blocks.contains { $0.borderColor(for: .minX) != nil })
    }

    @Test func aTableBecomesARealTable() {
        let blocks = textBlocks(in: render("| a | b |\n|---|---|\n| 1 | 2 |").text)
        let cells = blocks.compactMap { $0 as? NSTextTableBlock }
        #expect(cells.count == 4)
        #expect(cells.first?.table.numberOfColumns == 2)
    }

    @Test func columnAlignmentReachesTheParagraphStyle() {
        let text = render("| a | b |\n|:-:|--:|\n| 1 | 2 |").text
        let alignments = attributes(.paragraphStyle, in: text)
            .compactMap { $0 as? NSParagraphStyle }
            .map(\.alignment)
        #expect(alignments.contains(.center))
        #expect(alignments.contains(.right))
    }

    @Test func aThematicBreakDrawsARule() {
        let blocks = textBlocks(in: render("a\n\n---\n\nb").text)
        #expect(blocks.contains { $0.borderColor(for: .minY) != nil })
    }

    @Test func listMarkersAreDrawn() {
        #expect(render("- one\n- two").text.string.contains("•"))
        #expect(render("3. three").text.string.contains("3."))
    }

    @Test func taskBoxesAreDrawnAsBoxes() {
        let rendered = render("- [ ] todo\n- [x] done").text.string
        #expect(rendered.contains("☐"))
        #expect(rendered.contains("☑"))
    }

    /// A reader cannot tell two nesting levels apart when both use the same
    /// bullet.
    @Test func nestedBulletsChangeShape() {
        let rendered = render("- one\n  - two").text.string
        #expect(rendered.contains("•"))
        #expect(rendered.contains("◦"))
    }

    @Test func aNestedItemIsIndentedFurtherThanItsParent() {
        let text = render("- one\n  - two").text
        let indents = attributes(.paragraphStyle, in: text)
            .compactMap { $0 as? NSParagraphStyle }
            .map(\.firstLineHeadIndent)
        #expect((indents.max() ?? 0) > 0)
    }

    // MARK: - HTML and MDX

    /// Markup whose entire purpose is to be invisible.
    @Test func anHtmlCommentIsNotDrawn() {
        #expect(render("before\n\n<!-- hidden -->\n\nafter").text.string.contains("hidden") == false)
    }

    @Test func rawHtmlIsShownAsSource() {
        #expect(render("<div align=\"center\">\n  hi\n</div>").text.string.contains("<div align=\"center\">"))
    }

    /// The honest version of "we do not evaluate JSX".
    @Test func anMdxComponentIsLabelledAsUnrendered() {
        let rendered = render("<Callout type=\"warn\">\n  Careful.\n</Callout>", flavor: .mdx).text.string
        #expect(rendered.contains("<Callout type=\"warn\">"))
        #expect(rendered.contains("shown as source"))
    }

    /// An ordinary HTML element in an `.mdx` file is still markup, not a
    /// component, and does not earn the label.
    @Test func aPlainElementInMdxIsNotLabelled() {
        let rendered = render("<div>\n  hi\n</div>", flavor: .mdx).text.string
        #expect(rendered.contains("<div>"))
        #expect(!rendered.contains("shown as source"))
    }

    @Test func mdxImportsAreLabelledAsNotEvaluated() {
        let rendered = render("import Callout from './c'\n\n# Title", flavor: .mdx).text.string
        #expect(rendered.contains("import Callout from './c'"))
        #expect(rendered.contains("not evaluated"))
    }

    @Test func frontMatterIsShownAsSource() {
        let rendered = render("---\ntitle: x\n---\n\n# H").text.string
        #expect(rendered.contains("front matter"))
        #expect(rendered.contains("title: x"))
    }

    // MARK: - Images

    /// Neither loaded nor silently dropped: the reader is told the path did
    /// not resolve, which is the difference between a broken document and a
    /// broken preview.
    @Test func aMissingLocalImageBecomesAnHonestPlaceholder() {
        let base = URL(fileURLWithPath: "/tmp/definitely-not-here")
        let rendered = render("![a logo](./logo.png)", baseURL: base).text.string
        #expect(rendered.contains("image:"))
        #expect(rendered.contains("a logo"))
    }

    /// Every badge in a README is a remote image, and a preview that
    /// re-renders as you type would announce the open file to a handful of
    /// third parties on every keystroke.
    @Test func aRemoteImageIsNotFetchedAndSaysSo() {
        let text = render("![build](https://img.shields.io/badge.svg)").text
        #expect(text.string.contains("image:"))
        #expect(attributes(.link, in: text).compactMap { $0 as? URL }.first?.host == "img.shields.io")
    }

    @Test func aLocalImageThatExistsIsDrawn() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markdown-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: CGSize(width: 8, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: CGRect(x: 0, y: 0, width: 8, height: 4))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return }
        try tiff.write(to: directory.appendingPathComponent("logo.tiff"))

        let text = render("![logo](./logo.tiff)", baseURL: directory).text
        #expect(!attributes(.attachment, in: text).isEmpty)
        #expect(!text.string.contains("image:"))
    }

    // MARK: - The map back to the source

    /// The whole reason the parse is line-based, and what a synchronised
    /// split needs from this side.
    @Test func aSourceLineFindsItsPlaceInTheRenderedText() {
        let output = render("# One\n\npara\n\n```\ncode\n```")
        let heading = output.renderedOffset(forSourceLine: 0)
        let paragraph = output.renderedOffset(forSourceLine: 2)
        let fence = output.renderedOffset(forSourceLine: 5)

        #expect(heading == 0)
        #expect((paragraph ?? 0) > (heading ?? 0))
        #expect((fence ?? 0) > (paragraph ?? 0))
    }

    @Test func aRenderedOffsetFindsItsSourceLine() {
        let output = render("# One\n\npara\n\n```\ncode\n```")
        #expect(output.sourceLine(forRenderedOffset: 0) == 0)

        let fence = output.renderedOffset(forSourceLine: 5) ?? 0
        #expect(output.sourceLine(forRenderedOffset: fence) == 4)
    }

    /// A cursor resting on the blank line between two blocks still has to
    /// answer, or the preview stops following partway through a scroll.
    @Test func aBlankLineBetweenBlocksAnswersWithTheBlockAboveIt() {
        let output = render("# One\n\npara")
        #expect(output.renderedOffset(forSourceLine: 1) == 0)
    }

    @Test func anOffsetPastTheEndDoesNotWalkOffTheEnd() {
        let output = render("# One")
        #expect(output.sourceLine(forRenderedOffset: 9_999) == 0)
        #expect(output.renderedOffset(forSourceLine: 9_999) == 0)
    }

    @Test func anEmptyDocumentAnswersNothingRatherThanCrashing() {
        let output = render("")
        #expect(output.renderedOffset(forSourceLine: 3) == nil)
        #expect(output.sourceLine(forRenderedOffset: 3) == nil)
    }

    // MARK: - A whole file

    @Test func aRealisticReadmeRendersEveryBlock() {
        let readme = """
        # Phantom

        A terminal that **edits**.

        ```swift
        let phantom = Terminal()
        ```

        - Splits
          - Nested
        - [Docs][d]

        > Requires macOS 14.

        | Setting | Default |
        |---------|--------:|
        | Theme   | system  |

        ---

        [d]: https://example.com
        """

        let output = render(readme)
        /// Heading, paragraph, fence, list, quote, table, rule — the link
        /// definition contributes no block, which is the point of lifting
        /// it out.
        #expect(output.anchors.count == 7)
        #expect(output.text.string.contains("Phantom"))
        #expect(output.text.string.contains("let phantom = Terminal()"))
        #expect(output.text.string.contains("Nested"))
        #expect(!attributes(.link, in: output.text).isEmpty)

        /// Anchors are in order and none of them overlaps the next, which
        /// is what makes the scroll lookups a scan rather than a search.
        let ranges = output.anchors.map(\.range)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
    }
}

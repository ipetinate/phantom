import Foundation
@testable import Ghostty
import Testing

/// The HTML a README actually contains, reduced to markdown.
///
/// A pure function over a string, so every case here is a document somebody
/// wrote and the answer it should get. The two halves are deliberately
/// different: `prose` has no fallback and must always draw something, while
/// `block` may refuse — and a refusal is what keeps the raw-source panel for
/// markup that flattening would misrepresent.
struct MarkdownHTMLTests {
    // MARK: - Inline

    @Test func aBreakBecomesAHardBreak() {
        #expect(MarkdownHTML.prose("Line<br>break") == "Line  \nbreak")
        #expect(MarkdownHTML.prose("Line<br />break") == "Line  \nbreak")
    }

    @Test func emphasisTagsBecomeEmphasis() {
        #expect(MarkdownHTML.prose("<b>bold</b> and <i>it</i>") == "**bold** and *it*")
        #expect(MarkdownHTML.prose("<strong>b</strong><em>i</em>") == "**b***i*")
        #expect(MarkdownHTML.prose("<del>gone</del>") == "~~gone~~")
    }

    /// A key cap is not code, and a preview has nothing closer: both are
    /// "this is typed, not read".
    @Test func aKeyCapBecomesACodeSpan() {
        #expect(MarkdownHTML.prose("<kbd>Cmd</kbd>+<kbd>K</kbd>") == "`Cmd`+`K`")
        #expect(MarkdownHTML.prose("<code>init()</code>") == "`init()`")
    }

    @Test func anImageTagBecomesAMarkdownImage() {
        #expect(MarkdownHTML.prose("<img src=\"a.png\" alt=\"logo\">") == "![logo](a.png)")
        #expect(MarkdownHTML.prose("<img src=\"a.png\">") == "![](a.png)")
    }

    /// CommonMark's own escape, and the only way a destination holding a
    /// space survives becoming a markdown link.
    @Test func aSourceWithASpaceIsWrappedInAngleBrackets() {
        #expect(MarkdownHTML.prose("<img src=\"my logo.png\">") == "![](<my logo.png>)")
    }

    @Test func anAnchorBecomesAMarkdownLink() {
        #expect(MarkdownHTML.prose("<a href=\"https://x\">text</a>") == "[text](https://x)")
    }

    /// `<a name="usage">` is how a hand-written README plants a scroll
    /// target, and empty brackets in the prose would be worse than nothing.
    @Test func anAnchorWithNowhereToGoIsJustItsText() {
        #expect(MarkdownHTML.prose("<a name=\"usage\">Usage</a>") == "Usage")
    }

    /// The logo line at the top of half the repositories on GitHub.
    @Test func aLinkWrappingAnImageSurvivesAsBoth() {
        let reduced = MarkdownHTML.prose("<a href=\"https://x\"><img src=\"logo.png\" alt=\"L\"></a>")
        #expect(reduced == "[![L](logo.png)](https://x)")
    }

    @Test func subscriptsAndSuperscriptsBecomeUnicode() {
        #expect(MarkdownHTML.prose("H<sub>2</sub>O") == "H₂O")
        #expect(MarkdownHTML.prose("x<sup>2</sup>") == "x²")
    }

    /// Every character has to map or none does: two shifted glyphs out of
    /// four reads as corruption, and the plain text was fine.
    @Test func aShiftWithNoUnicodeFormFallsBackToItsText() {
        #expect(MarkdownHTML.prose("<sup>quux</sup>") == "quux")
    }

    @Test func aWrapperIsDroppedAndItsTextKept() {
        #expect(MarkdownHTML.prose("<span class=\"x\">plain</span>") == "plain")
    }

    /// ⚠️ The regression this file exists to prevent. A reducer that deleted
    /// every angle-bracketed word it did not recognise would silently eat the
    /// generics out of a paragraph of prose.
    @Test func somethingThatIsNotHtmlIsLeftExactlyAsWritten() {
        #expect(MarkdownHTML.prose("Vec<String> and Map<K, V>") == "Vec<String> and Map<K, V>")
        #expect(MarkdownHTML.prose("a < b") == "a < b")
        #expect(MarkdownHTML.prose("<Callout type=\"warn\">hi</Callout>") == "<Callout type=\"warn\">hi</Callout>")
    }

    /// Out of scope inside prose means visible, not deleted: the reader can
    /// see there is markup there that this preview is not drawing.
    @Test func markupOutOfScopeStaysVisibleInProse() {
        let table = "<table><tr><td>1</td></tr></table>"
        #expect(MarkdownHTML.prose(table) == table)
    }

    /// An unclosed tag still has to balance its delimiter, or two asterisks
    /// leak into the page.
    @Test func anUnclosedTagIsStillBalanced() {
        #expect(MarkdownHTML.prose("<b>unclosed") == "**unclosed**")
    }

    @Test func aCommentInsideProseIsDropped() {
        #expect(MarkdownHTML.prose("before<!-- hi -->after") == "beforeafter")
    }

    /// The fast path: prose with no markup in it comes back untouched, which
    /// is every paragraph of every document.
    @Test func proseWithNoMarkupIsUntouched() {
        #expect(MarkdownHTML.prose("just words, and 2 < 3 arithmetic") == "just words, and 2 < 3 arithmetic")
    }

    /// ⚠️ A document explaining markup is not a document using it. Without the
    /// code-span skip, "`<br>` breaks a line" had the `<br>` inside its own
    /// backticks rewritten into an actual line break.
    @Test func markupInsideACodeSpanIsLeftAlone() {
        #expect(MarkdownHTML.prose("Use `<br>` to break a line") == "Use `<br>` to break a line")
        #expect(MarkdownHTML.prose("``a <b> c``") == "``a <b> c``")
        /// The span closes, so the tag after it is still reduced.
        #expect(MarkdownHTML.prose("`<br>` and <b>bold</b>") == "`<br>` and **bold**")
    }

    @Test func anEscapedTagStaysEscaped() {
        #expect(MarkdownHTML.prose("\\<b\\>literal") == "\\<b\\>literal")
    }

    // MARK: - Blocks

    /// ⚠️ The bug the author reported, in the shape it arrives in. Four spaces
    /// of ordinary HTML indentation is an indented code block to a markdown
    /// parser, so a reduction that kept them came back out of the re-parse as
    /// the panel of source it was supposed to replace.
    @Test func theCentredLogoHeaderBecomesAnImage() throws {
        let header = """
        <p align="center">
            <img src="docs/logo.png" width="180">
        </p>
        """

        let reduction = try #require(MarkdownHTML.block(header))
        #expect(reduction.text.contains("![](docs/logo.png)"))
        #expect(reduction.alignment == .center)
        #expect(!reduction.text.contains("    "))
    }

    @Test func aHeadingInsideAWrapperStaysAHeading() throws {
        let reduction = try #require(MarkdownHTML.block("<h1 align=\"center\">Phantom</h1>"))
        #expect(reduction.text.contains("# Phantom"))
        #expect(reduction.alignment == .center)
    }

    @Test func alignmentIsReadFromAStyleAttributeToo() throws {
        let reduction = try #require(MarkdownHTML.block("<div style=\"text-align: center\">\nmiddle\n</div>"))
        #expect(reduction.alignment == .center)
    }

    @Test func aWrapperWithNoAlignmentAsksForNone() throws {
        let reduction = try #require(MarkdownHTML.block("<p>hi</p>"))
        #expect(reduction.text == "hi")
        #expect(reduction.alignment == nil)
    }

    /// Markup with nothing to say draws nothing, rather than a panel showing
    /// the reader a scroll target they cannot use.
    @Test func markupWithNoTextInItReducesToNothing() throws {
        #expect(MarkdownHTML.block("<div></div>")?.text.isEmpty == true)
        #expect(MarkdownHTML.block("<a name=\"usage\"></a>")?.text.isEmpty == true)
    }

    @Test func layoutAndBehaviourKeepTheSourcePanel() {
        #expect(MarkdownHTML.block("<table>\n<tr><td>1</td></tr>\n</table>") == nil)
        #expect(MarkdownHTML.block("<ul>\n<li>one</li>\n</ul>") == nil)
        #expect(MarkdownHTML.block("<details>\n<summary>More</summary>\nhidden\n</details>") == nil)
        #expect(MarkdownHTML.block("<script>\nlet a = 1\n</script>") == nil)
        #expect(MarkdownHTML.block("<iframe src=\"https://x\"></iframe>") == nil)
    }

    /// Which is what keeps an MDX component labelled as unrendered: a name
    /// this file has never heard of is not something to guess at.
    @Test func aComponentKeepsTheSourcePanel() {
        #expect(MarkdownHTML.block("<Callout type=\"warn\">\nhi\n</Callout>") == nil)
    }

    /// The recursion guard. The renderer parses this text as markdown and
    /// renders what comes out, so a reduction still holding a tag could arrive
    /// back as an HTML block and go round again.
    @Test func aReductionThatStillHoldsATagIsRefused() {
        #expect(MarkdownHTML.block("<div>a < b</div>") == nil)
        #expect(MarkdownHTML.block("<div>unterminated <") == nil)
    }

    @Test func aRuleBecomesAThematicBreak() throws {
        let reduction = try #require(MarkdownHTML.block("<hr>"))
        #expect(reduction.text.contains("---"))
    }

    /// A quoted attribute is the one place a `>` appears without ending the
    /// tag, so the scan cannot simply run to the next one.
    @Test func aGreaterThanInsideAnAttributeDoesNotEndTheTag() throws {
        let reduction = try #require(MarkdownHTML.block("<p title=\"a > b\">text</p>"))
        #expect(reduction.text == "text")
    }

    @Test func spacesAroundAnAttributesEqualsAreTolerated() throws {
        let reduction = try #require(MarkdownHTML.block("<div align = \"center\">hi</div>"))
        #expect(reduction.alignment == .center)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// Splitting a single-file component into its blocks.
struct SFCRegionTests {
    private let component = """
    <script setup lang="ts">
    import { ref } from 'vue';
    const searchTerm = ref('');
    </script>

    <template>
      <div class="filters">
        <WButton @click="emit('create')">Novo</WButton>
      </div>
    </template>

    <style scoped lang="scss">
    .filters {
      display: flex;
    }
    </style>
    """

    private func language(at needle: String, in text: String) -> CodeLanguage? {
        guard let range = text.range(of: needle) else { return nil }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        return SFCRegions.language(at: offset, in: text)
    }

    @Test func eachBlockIsItsOwnLanguage() {
        #expect(language(at: "import { ref }", in: component) == .javascript)
        #expect(language(at: "<div class", in: component) == .html)
        #expect(language(at: "display: flex", in: component) == .css)
    }

    /// The blocks come back in the order they appear, whatever order they
    /// are searched for — a later pass over the document walks them.
    @Test func regionsAreOrderedByPosition() {
        let regions = SFCRegions.regions(in: component)
        #expect(regions.map(\.language) == [.javascript, .html, .css])
        #expect(regions.map(\.range.location) == regions.map(\.range.location).sorted())
    }

    /// The tags themselves are not part of the block: `<script>` is markup,
    /// and lexing it as JavaScript would make `script` an identifier.
    @Test func theOpeningTagIsNotInsideTheBlock() {
        guard let range = component.range(of: "<script setup") else {
            Issue.record("the fixture no longer contains the tag this asserts on")
            return
        }
        let offset = component.distance(from: component.startIndex, to: range.lowerBound)
        #expect(SFCRegions.language(at: offset, in: component) == nil)
    }

    /// The attributes on a block tag change what the compiler does, not how
    /// the body is lexed — `<script setup lang="ts">` is still JavaScript to
    /// a highlighter, and `<style scoped lang="scss">` still CSS.
    @Test func blockAttributesDoNotChangeTheLanguage() {
        let plain = "<script>\nconst a = 1;\n</script>"
        #expect(SFCRegions.regions(in: plain).first?.language == .javascript)

        let module = "<style module>\n.a { color: red; }\n</style>"
        #expect(SFCRegions.regions(in: module).first?.language == .css)
    }

    /// A `<template #slot>` inside the template is indented, which is how
    /// the outer block's end is told from an inner one's. This is the
    /// splitter's documented assumption, so it is worth an assertion.
    @Test func anIndentedNestedTemplateDoesNotEndTheOuterOne() {
        let nested = """
        <template>
          <WTable>
            <template #footer>
              <span>total</span>
            </template>
          </WTable>
        </template>
        """
        let regions = SFCRegions.regions(in: nested)
        #expect(regions.count == 1)
        // The whole body, nested block included.
        #expect(regions.first.map { NSMaxRange($0.range) > 60 } == true)
    }

    @Test func aFileWithNoBlocksHasNoRegions() {
        #expect(SFCRegions.regions(in: "just some text").isEmpty)
        #expect(SFCRegions.regions(in: "").isEmpty)
    }

    /// An unclosed block is not claimed. Half a file coloured as CSS while
    /// it is being typed reads worse than none of it.
    @Test func anUnclosedBlockIsIgnored() {
        #expect(SFCRegions.regions(in: "<style>\n.a { color: red;").isEmpty)
    }
}

/// What the highlighter makes of an SFC.
struct SFCTokenTests {
    private func kinds(of needle: String, in text: String, language: CodeLanguage) -> [TokenKind] {
        let ns = text as NSString
        let tokens = SyntaxHighlighter(language: language)
            .tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let target = ns.range(of: needle)
        return tokens
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.kind)
    }

    /// `.vue` used to resolve straight to JavaScript, which is why the
    /// template's tags came out plain and `class` came out as a JavaScript
    /// keyword. A tag is a tag.
    @Test func templateTagsAreTags() {
        let text = "<template>\n<div class=\"a\"></div>\n</template>"
        #expect(kinds(of: "<div", in: text, language: .vue).contains(.keyword))
        #expect(kinds(of: "class", in: text, language: .vue).contains(.attribute))
    }

    /// Component tags too — they are the majority of the markup in this
    /// codebase, and capitalisation must not turn them into a type.
    @Test func componentTagsAreTagsAndNotTypes() {
        let text = "<template>\n<WButton variant=\"primary\" />\n</template>"
        let found = kinds(of: "<WButton", in: text, language: .vue)
        #expect(found.contains(.keyword))
        #expect(!found.contains(.type))
    }

    /// Vue's own attribute shapes: a bound prop, an event, a directive.
    @Test func boundPropsEventsAndDirectivesAreAttributes() {
        let text = """
        <template>
        <WPagination :total-pages="totalPages" @w-next="next" v-model="page" />
        </template>
        """
        #expect(kinds(of: ":total-pages", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "@w-next", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "v-model", in: text, language: .vue).contains(.attribute))
    }

    @Test func theScriptBlockIsStillJavaScript() {
        let text = "<script setup lang=\"ts\">\nconst a = 1;\n</script>"
        #expect(kinds(of: "const", in: text, language: .vue).contains(.keyword))
    }

    /// The stylesheet was not interpreted at all before.
    @Test func theStyleBlockIsInterpreted() {
        let text = """
        <style scoped lang="scss">
        .filters {
          display: flex;
          gap: var(--gl-spacing-06);
          width: 100%;
        }
        </style>
        """
        #expect(kinds(of: ".filters", in: text, language: .vue).contains(.type))
        #expect(kinds(of: "display", in: text, language: .vue).contains(.attribute))
        #expect(kinds(of: "flex", in: text, language: .vue).contains(.keyword))
        #expect(kinds(of: "100%", in: text, language: .vue).contains(.number))
        #expect(kinds(of: "var", in: text, language: .vue).contains(.function))
    }

    /// BEM nesting is most of the lines in these stylesheets, and `&__x` is
    /// not a class selector — the old pattern matched neither.
    @Test func scssNestingIsASelector() {
        let text = "<style lang=\"scss\">\n.a {\n  &__toolbar { display: flex; }\n}\n</style>"
        #expect(kinds(of: "&__toolbar", in: text, language: .vue).contains(.type))
    }

    @Test func scssLineCommentsAreComments() {
        let text = "<style lang=\"scss\">\n// a note\n.a { color: red; }\n</style>"
        #expect(kinds(of: "// a note", in: text, language: .vue).contains(.comment))
    }

    /// A property and a value spelled the same must not collide: `flex` is
    /// a value here and `display` a property, and the property rule takes
    /// precedence because it looks for the colon.
    @Test func aPropertyIsNotMistakenForAValue() {
        let text = "<style>\n.a { display: flex; }\n</style>"
        #expect(kinds(of: "display", in: text, language: .vue) == [.attribute])
    }

    /// Nothing outside a block is coloured — the container is markup the
    /// splitter deliberately declines to claim.
    @Test func textBetweenBlocksIsLeftAlone() {
        let text = "<script>\nlet a = 1;\n</script>\n\nfree text\n\n<style>\n.a { }\n</style>"
        #expect(kinds(of: "free text", in: text, language: .vue).isEmpty)
    }
}

/// An HTML document's own blocks.
///
/// The same problem an SFC has, in the other direction: lexed as markup from
/// end to end, a `<script>` block's `const` is not a keyword, its `//` is not
/// a comment, and — measured, this is the one that reads as a bug rather than
/// as something missing — every `name =` in it is painted as an *attribute*,
/// because "a name before an equals sign" is what an attribute is in markup
/// and what an assignment is in code.
struct MarkupContainerTests {
    private func kinds(of needle: String, in text: String) -> [TokenKind] {
        let ns = text as NSString
        let tokens = SyntaxHighlighter(language: .html)
            .tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let target = ns.range(of: needle)
        return tokens
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.kind)
    }

    private let page = """
    <!doctype html>
    <html>
      <head>
        <script type="text/babel">
          const Card = ({ title }) => {
            // a note
            return <div className="card">{title}</div>;
          };
        </script>
        <style>
          .card { display: flex; }
        </style>
      </head>
      <body><div class="root">text</div></body>
    </html>
    """

    @Test func theScriptBlockIsJavaScript() {
        #expect(kinds(of: "const Card", in: page).contains(.keyword))
        #expect(kinds(of: "// a note", in: page) == [.comment])
    }

    @Test func theStyleBlockIsCSS() {
        #expect(kinds(of: ".card {", in: page).contains(.type))
        #expect(kinds(of: "display", in: page).contains(.attribute))
    }

    /// The frame is still the document: an HTML container lexes what is
    /// *around* its blocks with its own rules, which is the difference from an
    /// SFC, where the frame is three tags and nothing else.
    @Test func theMarkupAroundTheBlocksIsStillMarkup() {
        #expect(kinds(of: "<html", in: page).contains(.keyword))
        #expect(kinds(of: "<div class", in: page).contains(.keyword))
        #expect(kinds(of: "class=\"root\"", in: page).contains(.attribute))
    }

    /// The block's own tag belongs to the markup around it, not to the
    /// language inside — `<script` lexed as JavaScript makes `script` an
    /// identifier.
    @Test func theBlockTagsThemselvesAreMarkup() {
        #expect(kinds(of: "<script type", in: page).contains(.keyword))
    }

    /// **The rule an SFC cannot share.** In an HTML file `<script>` is inside
    /// `<head>`, so it is indented, so the column-zero convention that tells
    /// an SFC's own `<template>` from a nested one would find nothing here.
    @Test func anIndentedBlockIsFoundInMarkupAndNotInAnSFC() {
        let indented = "<html>\n  <script>\n    const a = 1;\n  </script>\n</html>"
        #expect(SFCRegions.regions(in: indented, of: .markup).map(\.language) == [.javascript])
        #expect(SFCRegions.regions(in: indented, of: .singleFileComponent).isEmpty)
    }

    /// `<SCRIPT>` is ordinary in hand-written HTML, and case is not something
    /// a Vue toolchain ever produces — which is why only one of the two
    /// containers ignores it.
    @Test func markupIsCaseInsensitive() {
        let shouting = "<HTML>\n  <SCRIPT>\n  const a = 1;\n  </SCRIPT>\n</HTML>"
        #expect(SFCRegions.regions(in: shouting, of: .markup).map(\.language) == [.javascript])
    }

    /// `<template>` in HTML holds markup, which is what the document is
    /// already being lexed as. Claiming it would mean lexing HTML as HTML
    /// through a second, slower path.
    @Test func markupDoesNotClaimATemplateElement() {
        let text = "<template>\n<b>x</b>\n</template>"
        #expect(SFCRegions.regions(in: text, of: .markup).isEmpty)
        #expect(SFCRegions.regions(in: text, of: .singleFileComponent).map(\.language) == [.html])
    }

    /// An unclosed block is not claimed, so a file being typed is markup
    /// until the closing tag exists rather than half a document in the wrong
    /// language.
    @Test func anUnclosedBlockLeavesTheDocumentAsMarkup() {
        let unclosed = "<html>\n  <script>\n    const a = 1;\n"
        #expect(SFCRegions.regions(in: unclosed, of: .markup).isEmpty)
        #expect(kinds(of: "const", in: unclosed).isEmpty)
    }

    /// Which file types are made of blocks, in the one place that decides it.
    @Test func onlyTheTwoContainersAreContainers() {
        #expect(SFCRegions.container(of: .vue) == .singleFileComponent)
        #expect(SFCRegions.container(of: .html) == .markup)
        #expect(SFCRegions.container(of: .javascript) == nil)
        #expect(SFCRegions.container(of: .css) == nil)
    }
}

/// JSX, which is markup written in a language whose `<` is an operator.
///
/// The reason this is a rule and not a container: JSX is not a *block* inside
/// JavaScript with tags around it that a splitter could find — it is an
/// expression, anywhere an expression can go. So the tags are painted by a
/// pattern, and the pattern's whole difficulty is telling `<div` from
/// `Array<string>`.
struct JSXTagTests {
    private func kinds(of needle: String, in text: String) -> [TokenKind] {
        let ns = text as NSString
        let tokens = SyntaxHighlighter(language: .javascript)
            .tokens(in: text, range: NSRange(location: 0, length: ns.length))
        let target = ns.range(of: needle)
        return tokens
            .filter { NSIntersectionRange($0.range, target).length > 0 }
            .map(\.kind)
    }

    private let element = """
    const Card = ({ title }: Props) => (
      <>
        <div className="card">{title}</div>
        <p>hello</p>
      </>
    );
    """

    @Test func anElementsTagsAreTags() {
        #expect(kinds(of: "<div", in: element).contains(.keyword))
        #expect(kinds(of: "</div", in: element).contains(.keyword))
    }

    /// A closing tag with text in front of it — `<p>hello</p>` — is the
    /// commonest shape in JSX, and it is why the closing branch of the rule
    /// carries no guard at all: `</` cannot begin a comparison.
    @Test func aClosingTagAfterTextIsStillATag() {
        #expect(kinds(of: "</p>", in: element).contains(.keyword))
    }

    @Test func fragmentsAreTags() {
        #expect(kinds(of: "<>", in: element).contains(.keyword))
        #expect(kinds(of: "</>", in: element).contains(.keyword))
    }

    /// **The regression this rule is one character away from.** Every one of
    /// these appears hundreds of times in the TypeScript this editor is used
    /// on, and an unguarded `<[A-Za-z]` paints all of them as tags — measured,
    /// 1390 wrongly coloured tokens across the 723 `.ts` and `.vue` files of
    /// one real project. With the guard: zero changed tokens in the same 723.
    @Test func typeArgumentsAreNotTags() {
        let typescript = """
        const list: Array<string> = [];
        const map = new Map<string, number>();
        const [state, setState] = useState<Foo>(null);
        """
        #expect(!kinds(of: "<string>", in: typescript).contains(.keyword))
        #expect(!kinds(of: "<string, number>", in: typescript).contains(.keyword))
        #expect(!kinds(of: "<Foo>", in: typescript).contains(.keyword))
    }

    @Test func comparisonsAreNotTags() {
        let comparisons = """
        const ok = a < b && c > d;
        for (let i = 0; i < list.length; i += 1) {}
        const gt = width>height;
        """
        #expect(kinds(of: "< b", in: comparisons).isEmpty)
        #expect(kinds(of: "< list", in: comparisons).isEmpty)
        #expect(kinds(of: ">height", in: comparisons).isEmpty)
    }

    /// The two halves together, which is the case the item was reported for:
    /// JSX in a `<script type="text/babel">` block of an HTML page. The
    /// container gets the block lexed as JavaScript; the rule gets its tags
    /// coloured. Before, the block was markup — so the tags were right by
    /// accident and everything else was wrong.
    @Test func jsxInsideAnHTMLScriptBlockGetsBoth() {
        let page = """
        <html>
          <script type="text/babel">
            const App = () => <div className="root">hi</div>;
          </script>
        </html>
        """
        let ns = page as NSString
        let tokens = SyntaxHighlighter(language: .html)
            .tokens(in: page, range: NSRange(location: 0, length: ns.length))

        func kinds(of needle: String) -> [TokenKind] {
            let target = ns.range(of: needle)
            return tokens
                .filter { NSIntersectionRange($0.range, target).length > 0 }
                .map(\.kind)
        }

        #expect(kinds(of: "const App").contains(.keyword))
        #expect(kinds(of: "<div className").contains(.keyword))
        #expect(kinds(of: "</div>").contains(.keyword))
    }
}

/// The split's answer, kept between calls.
///
/// It has to be kept, because the colouring pass is not one pass: measured,
/// `CodeTextStorage` colours the edited range, `colorBrackets` tokenizes the
/// same region again to find the strings a brace must not be counted inside,
/// `matchedPair` tokenizes a window around the caret, and the minimap
/// tokenizes the whole document. Three scans of the document per keystroke on
/// a `.vue`, and each was a full one: 1977 µs per keystroke on the largest
/// `.vue` of a real project (38 KB), against 671 µs with this cache — best of
/// three, `-O`, 50 keystrokes each changing the text.
///
/// And it has to be *correct*, which is the only thing a test can check here:
/// a cache that answers about the wrong document colours the wrong
/// characters, silently.
struct SFCRegionCacheTests {
    private let script = "<script>\nlet a = 1;\n</script>"
    private let style = "<style>\n.a { }\n</style>"

    /// The document is the key. Asking about another one in between must not
    /// leave the first answer standing.
    @Test func anotherDocumentDoesNotAnswerForThisOne() {
        #expect(SFCRegions.regions(in: script).map(\.language) == [.javascript])
        #expect(SFCRegions.regions(in: style).map(\.language) == [.css])
        #expect(SFCRegions.regions(in: script).map(\.language) == [.javascript])
    }

    /// The container is part of the key: the same bytes are two different
    /// splits depending on which convention is being applied to them.
    @Test func theContainerIsPartOfTheKey() {
        let indented = "<html>\n  <script>\n  const a = 1;\n  </script>\n</html>"
        #expect(SFCRegions.regions(in: indented, of: .markup).count == 1)
        #expect(SFCRegions.regions(in: indented, of: .singleFileComponent).isEmpty)
        #expect(SFCRegions.regions(in: indented, of: .markup).count == 1)
    }

    /// More documents than the cache holds, so the eviction path is the one
    /// under test rather than the hit.
    @Test func evictionAnswersFromTheDocumentRatherThanFromTheCache() {
        for index in 0..<8 {
            let text = "<script>\nlet v\(index) = \(index);\n</script>"
            let regions = SFCRegions.regions(in: text)
            #expect(regions.map(\.language) == [.javascript])
            let body = (text as NSString).substring(with: regions[0].range)
            #expect(body.contains("v\(index)"), "the cache answered for another document")
        }
    }
}

/// Telling a local build from the installed app.
struct DevelopmentBuildTests {
    /// `zig build` writes to `zig-out`, and nothing installed runs from
    /// there — which is what makes this a property of how the copy was
    /// produced rather than of remembering to set a flag.
    @Test func aBuildOutputPathIsADevelopmentBuild() {
        #expect(DevelopmentBuild.isBuildOutputPath("/Users/x/Projects/phantom/zig-out/Phantom.app"))
        #expect(DevelopmentBuild.isBuildOutputPath("/Users/x/Library/Developer/Xcode/DerivedData/A/Phantom.app"))
    }

    @Test func anInstalledAppIsNot() {
        #expect(!DevelopmentBuild.isBuildOutputPath("/Applications/Phantom.app"))
        #expect(!DevelopmentBuild.isBuildOutputPath("/Users/x/Applications/Phantom.app"))
    }

    /// A folder that merely contains the word must not count — the check is
    /// on path components, not on a substring.
    @Test func aSimilarlyNamedFolderIsNotAMatch() {
        #expect(!DevelopmentBuild.isBuildOutputPath("/Users/x/my-zig-outputs/Phantom.app"))
        #expect(!DevelopmentBuild.isBuildOutputPath("/Applications/zig-outer/Phantom.app"))
    }
}

/// The block tags themselves.
///
/// They drew as plain white text while everything inside them was coloured:
/// `SFCRegions` keeps the tags out of the block on purpose, and the container
/// they belong to had no rules at all. Four kinds per tag now — the name, its
/// attributes, their values, and the punctuation holding them together.
struct SFCBlockTagTests {
    private struct Named: Equatable {
        let text: String
        let kind: TokenKind
    }

    private func tokens(_ text: String) -> [Named] {
        let ns = text as NSString
        return SyntaxHighlighter(language: .vue)
            .tokens(in: text, range: NSRange(location: 0, length: ns.length))
            .sorted { $0.range.location < $1.range.location }
            .map { Named(text: ns.substring(with: $0.range), kind: $0.kind) }
    }

    @Test func theScriptTagIsTakenApart() {
        let found = tokens("<script setup lang=\"ts\">\nconst a = 1;\n</script>")

        #expect(Array(found.prefix(7)) == [
            Named(text: "<", kind: .punctuation),
            Named(text: "script", kind: .keyword),
            Named(text: "setup", kind: .attribute),
            Named(text: "lang", kind: .attribute),
            Named(text: "=", kind: .punctuation),
            Named(text: "\"ts\"", kind: .string),
            Named(text: ">", kind: .punctuation),
        ])
    }

    /// The closing tag as well, and its slash travels with the `<` rather
    /// than becoming a token of its own.
    @Test func theClosingTagIsTakenApartToo() {
        let found = tokens("<script>\nconst a = 1;\n</script>")

        #expect(Array(found.suffix(3)) == [
            Named(text: "</", kind: .punctuation),
            Named(text: "script", kind: .keyword),
            Named(text: ">", kind: .punctuation),
        ])
    }

    @Test func theTemplateTagIsTakenApart() {
        let found = tokens("<template lang=\"pug\">\np hello\n</template>")

        #expect(Array(found.prefix(6)) == [
            Named(text: "<", kind: .punctuation),
            Named(text: "template", kind: .keyword),
            Named(text: "lang", kind: .attribute),
            Named(text: "=", kind: .punctuation),
            Named(text: "\"pug\"", kind: .string),
            Named(text: ">", kind: .punctuation),
        ])
    }

    /// `scoped` has no value and `lang` has one, which is the pair that says
    /// a value is optional rather than assumed.
    @Test func theStyleTagIsTakenApart() {
        let found = tokens("<style scoped lang=\"scss\">\n.a { color: red; }\n</style>")

        #expect(Array(found.prefix(7)) == [
            Named(text: "<", kind: .punctuation),
            Named(text: "style", kind: .keyword),
            Named(text: "scoped", kind: .attribute),
            Named(text: "lang", kind: .attribute),
            Named(text: "=", kind: .punctuation),
            Named(text: "\"scss\"", kind: .string),
            Named(text: ">", kind: .punctuation),
        ])
    }

    /// A custom block is a block tag like any other. `SFCRegions` does not
    /// claim its body — it has no language to claim it as — and the tag is
    /// still a tag.
    @Test func aCustomBlockTagIsATagAsWell() {
        let found = tokens("<i18n lang=\"json\">\n{}\n</i18n>")
        #expect(found.first == Named(text: "<", kind: .punctuation))
        #expect(found.dropFirst().first == Named(text: "i18n", kind: .keyword))
    }

    /// The blocks inside still lex as themselves, which is the arrangement
    /// this must not disturb.
    @Test func theBlocksInsideStillLexAsThemselves() {
        let found = tokens("<script setup>\nconst a = 1;\n</script>")
        #expect(found.contains(Named(text: "const", kind: .keyword)))
        #expect(found.contains(Named(text: "1", kind: .number)))
    }

    /// **The failure a rule set would have brought with it.** An unclosed
    /// block is not a region, so the whole of it arrives as frame — and
    /// markup's rules read every `name =` in it as an attribute. Only the
    /// tag is coloured.
    @Test func anUnclosedBlockKeepsItsAssignmentsPlain() {
        let found = tokens("<script>\nconst url = \"x\"\n")
        #expect(found.map(\.kind) == [.punctuation, .keyword, .punctuation])
    }

    /// An indented tag is not a block tag, which is `SFCRegions`' own
    /// column-zero convention applied to the frame.
    @Test func anIndentedTagIsNotABlockTag() {
        #expect(tokens("  <script>\n").isEmpty)
    }

    /// Nothing outside a tag is claimed. This is the line a markup rule set
    /// would have painted and a tag pass does not.
    @Test func textBetweenBlocksIsStillLeftAlone() {
        let text = "<script>\nlet a = 1;\n</script>\n\nname = \"free text\"\n"
        let found = tokens(text)
        #expect(!found.contains { $0.text == "name" })
        #expect(!found.contains { $0.text == "\"free text\"" })
    }
}

import Foundation
@testable import Ghostty
import Testing

/// Closing tags as they are typed, and the two value types the decision
/// rests on: which pairs a language auto-closes, and which files close tags
/// at all.
struct CodeTagCloseTests {
    /// The caret sits at the end of `source`, which is where it is when the
    /// character that triggers this has just been typed.
    private func closing(_ source: String, _ dialect: CodeTagDialect) -> String? {
        let text = source as NSString
        return CodeTagClose.closingTag(in: text, caret: text.length, dialect: dialect)
    }

    private func completion(_ source: String, _ dialect: CodeTagDialect) -> String? {
        let text = source as NSString
        return CodeTagClose.closingTagCompletion(in: text, caret: text.length, dialect: dialect)
    }

    private func stackNames(_ source: String, _ dialect: CodeTagDialect) -> [String] {
        let text = source as NSString
        return CodeTagClose.scan(text, upTo: text.length, dialect: dialect).elementNames(in: text)
    }

    private func denseMarkup(bytes: Int) -> NSString {
        var text = ""
        var row = 0
        while (text as NSString).length < bytes {
            text += "  <li class=\"row\" onClick={() => pick(\(row))}>\n"
            text += "    <span title=\"a>b\">item \(row)</span>\n"
            text += "  </li>\n"
            row += 1
        }
        return text as NSString
    }

    /// The dialect table, row by row — each one a judgement someone may
    /// want to revise on its own.
    @Test func markupExtensionsResolveToHTML() {
        for name in ["page.html", "page.htm"] {
            #expect(CodeTagDialect.resolve(fileName: name) == .html, "\(name)")
        }
    }

    /// XML is its own row for one fact: it has no void elements, so `<link>`
    /// there opens an element that HTML would refuse to close. SVG is XML.
    @Test func xmlExtensionsResolveToXML() {
        for name in ["feed.xml", "logo.svg"] {
            #expect(CodeTagDialect.resolve(fileName: name) == .xml, "\(name)")
        }
    }

    @Test func jsxExtensionsResolveToJSX() {
        #expect(CodeTagDialect.resolve(fileName: "App.tsx") == .jsx)
        #expect(CodeTagDialect.resolve(fileName: "App.jsx") == .jsx)
    }

    /// JSX in a `.js` file is what half of npm ships, and generics are not
    /// legal there — so the one heuristic this feature needs errs less in a
    /// `.js` file than in the `.tsx` file it was designed for.
    @Test func plainJavaScriptResolvesToJSX() {
        for name in ["app.js", "app.mjs", "app.cjs"] {
            #expect(CodeTagDialect.resolve(fileName: name) == .jsx, "\(name)")
        }
    }

    /// The row the whole table exists for: `.ts` and `.tsx` are one
    /// `CodeLanguage` and opposites here.
    @Test func typeScriptResolvesToNothing() {
        for name in ["api.ts", "api.mts", "api.cts"] {
            #expect(CodeTagDialect.resolve(fileName: name) == CodeTagDialect.none, "\(name)")
            #expect(CodeLanguage.resolve(fileName: name) == .javascript, "\(name)")
        }
        #expect(CodeLanguage.resolve(fileName: "App.tsx") == .javascript)
    }

    @Test func singleFileComponentsResolveToSFC() {
        #expect(CodeTagDialect.resolve(fileName: "Card.vue") == .sfc)
        #expect(CodeTagDialect.resolve(fileName: "Card.svelte") == .sfc)
    }

    @Test func everythingElseResolvesToNothing() {
        for name in ["main.swift", "lib.rs", "notes.txt", "Makefile", "README"] {
            #expect(CodeTagDialect.resolve(fileName: name) == CodeTagDialect.none, "\(name)")
        }
    }

    @Test func extensionsMatchWithoutRegardToCase() {
        #expect(CodeTagDialect.resolve(fileName: "App.TSX") == .jsx)
        #expect(CodeTagDialect.resolve(fileName: "Page.HTML") == .html)
        #expect(CodeTagDialect.resolve(fileName: "Api.TS") == CodeTagDialect.none)
    }

    /// The pairs no language disagrees about.
    @Test func everyLanguageClosesBracketsAndStrings() {
        for language in CodeLanguage.allCases {
            let pairs = CodeAutoClosePairs.resolve(language)
            #expect(pairs.closer(for: "(") == ")", "\(language)")
            #expect(pairs.closer(for: "[") == "]", "\(language)")
            #expect(pairs.closer(for: "{") == "}", "\(language)")
            #expect(pairs.closer(for: "\"") == "\"", "\(language)")
            #expect(pairs.closer(for: "`") == "`", "\(language)")
        }
    }

    /// `&'a str` is a lifetime, and typing it left to right walks straight
    /// past the touches-a-word guard: at the instant the `'` lands there is
    /// no letter on either side of it yet.
    @Test func rustDoesNotCloseTheSingleQuote() {
        let rust = CodeAutoClosePairs.resolve(.rust)
        #expect(rust.closer(for: "'") == nil)
        #expect(rust.isQuote("'") == false)
        #expect(rust.isCloser("'") == false)
    }

    @Test func rustStillClosesEverythingElse() {
        let rust = CodeAutoClosePairs.resolve(.rust)
        #expect(rust.closer(for: "(") == ")")
        #expect(rust.isQuote("\"") == true)
        #expect(rust.isQuote("`") == true)
        #expect(rust.isCloser(")") == true)
    }

    @Test func otherLanguagesKeepTheSingleQuote() {
        for language in [CodeLanguage.javascript, .swift, .python, .html] {
            let pairs = CodeAutoClosePairs.resolve(language)
            #expect(pairs.closer(for: "'") == "'", "\(language)")
            #expect(pairs.isQuote("'") == true, "\(language)")
        }
    }

    /// Comparison outnumbers markup even in a `.tsx` file, so `<` opens
    /// nothing anywhere. Tags are decided at `>` and `</`, with context.
    @Test func angleBracketsAreNotAPairInAnyLanguage() {
        for language in CodeLanguage.allCases {
            let pairs = CodeAutoClosePairs.resolve(language)
            #expect(pairs.closer(for: "<") == nil, "\(language)")
            #expect(pairs.isCloser(">") == false, "\(language)")
        }
    }

    /// Closing on `>`, in its simplest shape.
    @Test func aPlainElementCloses() {
        #expect(closing("<div>", .jsx) == "</div>")
        #expect(closing("<div>", .html) == "</div>")
    }

    /// The most common markup there is, and what a naive "suppress anything
    /// near a quote" rule would break.
    @Test func attributesWithQuotedValuesClose() {
        #expect(closing("<div class=\"a\">", .html) == "</div>")
        #expect(closing("<div class='a'>", .html) == "</div>")
    }

    @Test func aGreaterThanInsideAnAttributeIsNotTheTerminator() {
        #expect(closing("<a href=\"a>b\">", .html) == "</a>")
        #expect(closing("<a href=\"a>b\"", .html) == nil)
    }

    /// Catches a backwards-walking implementation, which meets the arrow's
    /// `>` first and gives up — and Prettier formats JSX handlers exactly
    /// this way.
    @Test func aJSXExpressionAttributeClosesAcrossItsArrow() {
        #expect(closing("<div onClick={() => x}>", .jsx) == "</div>")
        #expect(closing("<Row onSelect={(a) => ({ id: a })}>", .jsx) == "</Row>")
    }

    /// Catches a single-line implementation.
    @Test func aTagSpreadOverSeveralLinesCloses() {
        let source = """
        <button
          type="submit"
          onClick={() => submit()}
        >
        """
        #expect(closing(source, .jsx) == "</button>")
    }

    /// One character of lookbehind: an identifier before the `<` means a
    /// generic, and there is no tie to break.
    @Test func genericsDoNotClose() {
        #expect(closing("const xs: Array<string>", .jsx) == nil)
        #expect(closing("useState<User>", .jsx) == nil)
    }

    @Test func nestedGenericsDoNotClose() {
        #expect(closing("let m: Map<string, Set<number>>", .jsx) == nil)
        #expect(closing("let m: Map<string, Set<number>", .jsx) == nil)
    }

    @Test func markupInsideAStringDoesNotClose() {
        #expect(closing("const s = \"<div>", .jsx) == nil)
        #expect(closing("const s = '<div>", .jsx) == nil)
        #expect(closing("const s = `<div>", .jsx) == nil)
    }

    @Test func voidElementsGetNoClosingTag() {
        #expect(closing("<br>", .html) == nil)
        #expect(closing("<img src=\"a.png\">", .html) == nil)
        #expect(closing("<input type=\"text\">", .jsx) == nil)
        #expect(closing("<hr>", .jsx) == nil)
    }

    /// XML has no void element set at all: every name on HTML's list is
    /// somebody's element there, and refusing to close it writes a document
    /// no parser accepts.
    @Test func xmlClosesTheNamesHTMLCallsVoid() {
        #expect(closing("<link>", .xml) == "</link>")
        #expect(closing("<source src=\"a.mp4\">", .xml) == "</source>")
        #expect(closing("<br>", .xml) == "</br>")

        #expect(closing("<link>", .html) == nil)
    }

    @Test func xmlPutsThoseNamesOnTheStack() {
        #expect(stackNames("<ul><br><li>", .xml) == ["ul", "br", "li"])
    }

    /// And XML names are case sensitive, which is every dialect's rule but
    /// HTML's.
    @Test func xmlMatchesNamesWithRegardToCase() {
        #expect(stackNames("<Item></item>", .xml) == ["Item"])
        #expect(stackNames("<Item></Item>", .xml).isEmpty)
    }

    /// A rule, not an accident: in JSX lowercase means DOM element and a
    /// capital means somebody's component, so `<Br>` is not the void one.
    @Test func jsxReadsACapitalisedVoidNameAsAComponent() {
        #expect(closing("<Br>", .jsx) == "</Br>")
        #expect(closing("<br>", .jsx) == nil)
        #expect(closing("<Input value={v}>", .jsx) == "</Input>")
    }

    /// HTML has no such distinction, and `<BR>` is legal there.
    @Test func htmlMatchesVoidNamesWithoutRegardToCase() {
        #expect(closing("<BR>", .html) == nil)
        #expect(closing("<Img src=\"a.png\">", .html) == nil)
    }

    @Test func aSelfClosingTagGetsNoClosingTag() {
        #expect(closing("<div />", .jsx) == nil)
        #expect(closing("<div/>", .jsx) == nil)
        #expect(closing("<Row data={rows}/>", .jsx) == nil)
    }

    @Test func aClosingTagDoesNotTriggerAnother() {
        #expect(closing("<div>x</div>", .jsx) == nil)
    }

    /// `.ts` is the one row of the table where closing would always be
    /// wrong, so nothing reaches the scanner at all.
    @Test func typeScriptFilesCloseNothing() {
        #expect(closing("<div>", CodeTagDialect.none) == nil)
        #expect(closing("<div class=\"a\">", CodeTagDialect.none) == nil)
        #expect(completion("<div>\n</", CodeTagDialect.none) == nil)
    }

    @Test func aCommentIsNotATag() {
        #expect(closing("<!-- <div> -->", .html) == nil)
        #expect(closing("<!-- <div>", .html) == nil)
        #expect(closing("<!DOCTYPE html>", .html) == nil)
    }

    @Test func customElementsAndMemberComponentsClose() {
        #expect(closing("<my-widget>", .html) == "</my-widget>")
        #expect(closing("<Foo.Bar>", .jsx) == "</Foo.Bar>")
        #expect(closing("<svg:rect>", .html) == "</svg:rect>")
    }

    /// A fragment opens no element, so it asks for no closing tag.
    @Test func fragmentsGetNothing() {
        #expect(closing("return <>", .jsx) == nil)
    }

    @Test func aGreaterThanThatEndsNoTagIsLeftAlone() {
        #expect(closing("if (a > b)", .jsx) == nil)
        #expect(closing("for (let i = 0; i < n; i++) {}\nx >", .jsx) == nil)
        #expect(closing("a <= b >", .jsx) == nil)
    }

    /// The identifier half of the lookbehind is scoped to dialects where
    /// generics exist. In HTML inline markup routinely follows text with no
    /// space, and no generic can ever appear to be confused with.
    @Test func htmlClosesAnElementThatFollowsTextDirectly() {
        #expect(closing("<p>Hello<b>", .html) == "</b>")
        #expect(closing("x<sub>", .html) == "</sub>")
        #expect(closing("x<sub>", .jsx) == nil)
    }

    /// Completing on `</`, in the example the feature was asked for.
    @Test func slashCompletesTheInnermostOpenElement() {
        #expect(completion("<section>\n  <p>oi\n  </", .html) == "p>")
    }

    @Test func anAlreadyClosedElementIsNotOffered() {
        #expect(completion("<div><span>x</span>\n</", .jsx) == "div>")
        #expect(completion("<div><span></span></div>\n</", .jsx) == nil)
    }

    @Test func slashWithNothingOpenOffersNothing() {
        #expect(completion("</", .jsx) == nil)
        #expect(completion("const a = 1\n</", .jsx) == nil)
    }

    /// A `</` inside a tag body or a comment is not the start of a closing
    /// tag, which is what the pending-tag half of the scan is for.
    @Test func slashInsideATagBodyOffersNothing() {
        #expect(completion("<section><div a=\"</", .html) == nil)
        #expect(completion("<section>\n<!-- </", .html) == nil)
    }

    @Test func completionNeedsTheSlashToFollowTheAngleBracket() {
        #expect(completion("<section>\n  <p>oi\n  <", .html) == nil)
        #expect(completion("<section>\n  <p>oi\n  /", .html) == nil)
    }

    /// The window is what fits on screen. An element opened further above
    /// than that is one the reader cannot see either, and the scan declines
    /// rather than name whichever tag happened to survive truncation.
    @Test func anElementOpenedAboveTheWindowIsRefused() {
        let filler = String(repeating: "a line of ordinary prose\n", count: 500)
        #expect((filler as NSString).length > CodeTagClose.scanWindow)

        #expect(completion("<div>\n" + filler + "</", .html) == nil)
        #expect(completion("<div>\nshort\n</", .html) == "div>")
    }

    /// What the stack does and does not carry.
    @Test func selfClosedAndVoidElementsDoNotGoOnTheStack() {
        #expect(stackNames("<div /><span>", .jsx) == ["span"])
        #expect(stackNames("<ul><br><li>", .html) == ["ul", "li"])
    }

    @Test func aClosingTagPopsEverythingLeftOpenInsideIt() {
        #expect(stackNames("<div><span><em></span>", .html) == ["div"])
        #expect(stackNames("<div><span></span>", .jsx) == ["div"])
    }

    /// A window that starts mid-document sees closing tags whose openers are
    /// out of view. Popping on those would corrupt a stack that was right.
    @Test func aClosingTagWithNoOpenerIsIgnored() {
        #expect(stackNames("</em><div>", .html) == ["div"])
    }

    @Test func htmlPopsWithoutRegardToCaseAndJSXDoesNot() {
        #expect(stackNames("<DIV><span></SPAN>", .html) == ["DIV"])
        #expect(stackNames("<div><Span></span>", .jsx) == ["div", "Span"])
    }

    /// Single-file components, where the same file holds markup that
    /// closes tags and script that must not.
    @Test func aVueTemplateClosesTags() {
        let source = """
        <template>
          <div>
        """
        #expect(closing(source, .sfc) == "</div>")
    }

    @Test func aVueScriptBlockClosesNothing() {
        let source = """
        <template>
          <span></span>
        </template>

        <script setup>
        const el = build()
        if (el) {
          mount(<div>
        """
        #expect(closing(source, .sfc) == nil)
        #expect(CodeTagClose.scan(source as NSString, upTo: (source as NSString).length, dialect: .sfc).isInRawText == false)
    }

    @Test func aTemplateBelowTheScriptBlockStillCloses() {
        let source = """
        <script setup>
        const a = 1
        </script>

        <template>
          <div>
        """
        #expect(closing(source, .sfc) == "</div>")
    }

    @Test func aVueStyleBlockClosesNothing() {
        let source = """
        <template>
          <span></span>
        </template>

        <style scoped>
        .a { content: "<div>
        """
        #expect(closing(source, .sfc) == nil)
    }

    /// Svelte has no `<template>` wrapper — its markup *is* the top level —
    /// which is why the probe asks about `<script>` and `<style>` rather
    /// than about `<template>`.
    @Test func svelteMarkupIsRawTextWithNoWrapper() {
        let source = """
        <script>
        let n = 1
        </script>

        <ul>
          <li>
        """
        #expect(closing(source, .sfc) == "</li>")
    }

    /// A nested `<template #slot>` is indented, which is the convention the
    /// probe leans on and `SFCRegions` documents.
    @Test func aNestedTemplateDoesNotEndTheOuterOne() {
        let source = """
        <template>
          <Table>
            <template #row>
              <td></td>
            </template>
            <tr>
        """
        #expect(closing(source, .sfc) == "</tr>")
    }

    /// Only a markup-first file answers yes. A `.tsx` file bears markup in
    /// its expressions and is JavaScript on every line of it, which is why
    /// this is not the same predicate as `isInRawText` — that one is true
    /// in `.tsx`, because tags can be closed there.
    @Test func onlyMarkupFirstDialectsAreMarkup() {
        let text = "<div>x" as NSString
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: .html) == true)
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: .xml) == true)
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: .jsx) == false)
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: CodeTagDialect.none) == false)

        #expect(CodeTagClose.scan(text, upTo: text.length, dialect: .jsx).isInRawText == true)
    }

    @Test func anSFCIsMarkupInItsTemplateAndNotInItsBlocks() {
        let source = """
        <template>
          <div>a</div>
        </template>

        <script setup>
        const a = 1
        """
        let text = source as NSString
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: .sfc) == false)

        let inTemplate = (source as NSString).range(of: "a</div>").location
        #expect(CodeTagClose.isInMarkup(text, caret: inTemplate, dialect: .sfc) == true)
    }

    @Test func anSFCStyleBlockIsNotMarkup() {
        let source = """
        <template>
          <div>a</div>
        </template>

        <style scoped>
        .a { color: red }
        """
        let text = source as NSString
        #expect(CodeTagClose.isInMarkup(text, caret: text.length, dialect: .sfc) == false)
    }

    /// Svelte puts its markup at the top level, so the caret can sit *above*
    /// every block marker. That reads as markup by design, not by luck: the
    /// probe only ever looks behind the caret, and a block beginning below
    /// the caret cannot contain it.
    @Test func svelteMarkupAboveTheScriptBlockIsMarkup() {
        let source = """
        <ul>
          <li>one</li>
        </ul>

        <script>
        let n = 1
        </script>
        """
        let text = source as NSString
        let inMarkup = (source as NSString).range(of: "one").location
        #expect(CodeTagClose.isInMarkup(text, caret: inMarkup, dialect: .sfc) == true)

        let inScript = (source as NSString).range(of: "let n").location
        #expect(CodeTagClose.isInMarkup(text, caret: inScript, dialect: .sfc) == false)

        /// The same file with the block still being typed, which is what
        /// isolates the lookbehind from a whole-document search: here the
        /// `<script>` below has no `</script>` to balance it, so anything
        /// scanning past the caret would report this markup as script.
        let unterminated = """
        <ul>
          <li>one</li>
        </ul>

        <script>
        let n = 1
        """ as NSString
        let aboveTheBlock = unterminated.range(of: "one").location
        #expect(CodeTagClose.isInMarkup(unterminated, caret: aboveTheBlock, dialect: .sfc) == true)
        #expect(CodeTagClose.isInMarkup(unterminated, caret: unterminated.length, dialect: .sfc) == false)
    }

    /// And markup sandwiched between two blocks, which is where an answer
    /// built on "the last marker wins" would go wrong in one direction or
    /// the other.
    @Test func markupBetweenTwoBlocksIsMarkup() {
        let source = """
        <script>
        let n = 1
        </script>

        <ul>
          <li>one</li>
        </ul>

        <style>
        li { color: red }
        </style>
        """
        let text = source as NSString
        let inMarkup = (source as NSString).range(of: "one").location
        #expect(CodeTagClose.isInMarkup(text, caret: inMarkup, dialect: .sfc) == true)

        let inStyle = (source as NSString).range(of: "color: red").location
        #expect(CodeTagClose.isInMarkup(text, caret: inStyle, dialect: .sfc) == false)
    }

    /// The regions-only promise, stated as a test so the next caller cannot
    /// mistake this for `isInRawText`.
    @Test func markupSaysNothingAboutCommentsOrStrings() {
        let commented = "<template>\n  <!-- a comment" as NSString
        #expect(CodeTagClose.isInMarkup(commented, caret: commented.length, dialect: .sfc) == true)
        #expect(CodeTagClose.scan(commented, upTo: commented.length, dialect: .sfc).isInRawText == false)

        let attribute = "<div class=\"a" as NSString
        #expect(CodeTagClose.isInMarkup(attribute, caret: attribute.length, dialect: .html) == true)
    }

    /// The scan runs on every `>` and every `/` typed into a markup file, so
    /// the number that matters is per call, not per suite: the target is
    /// roughly 200µs over a full window, and an optimised build measures
    /// about 35µs of it.
    ///
    /// The ceiling is 1ms per call, which is deliberately far above both.
    /// Tests build unoptimised — where the same scan costs around 240µs —
    /// and the regression this guards against is an implementation that
    /// walks the whole document rather than a window, which is two orders
    /// of magnitude, not two-fold. A tighter number here would only buy
    /// flakiness on a loaded machine.
    @Test func scanningAFullWindowStaysWithinBudget() {
        let text = denseMarkup(bytes: 8 * 1024)
        #expect(text.length >= 8 * 1024)

        let started = ContinuousClock.now
        for _ in 0..<200 {
            _ = CodeTagClose.scan(text, upTo: text.length, dialect: .jsx)
        }
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .milliseconds(200), "200 scans took \(elapsed)")
    }
}

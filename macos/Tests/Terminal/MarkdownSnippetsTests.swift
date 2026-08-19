import Foundation
@testable import Ghostty
import Testing

/// The Markdown snippet catalogue: what it inserts, and — the half that
/// decides whether anyone keeps the feature turned on — when it stays quiet.
///
/// Two failure modes are worth naming, because both are invisible until
/// somebody is mid-sentence. The first is a body whose markers do not parse:
/// it looks fine in this file, and it writes `${1:language}` into the reader's
/// document. The second is a trigger that fires while someone is writing
/// English, which in this editor is not merely noisy — Return accepts the
/// highlighted row, so an open list turns the end of a paragraph into a
/// fenced code block.
struct MarkdownSnippetsTests {
    private let everything = MarkdownSnippets.entries(for: .mdx)

    private func entry(_ trigger: String) throws -> MarkdownSnippets.Entry {
        try #require(
            everything.first { $0.trigger == trigger },
            "no entry triggered by \(trigger)"
        )
    }

    private func expansion(_ trigger: String) throws -> String {
        CodeSnippet.parse(try entry(trigger).body).text
    }

    // MARK: - Every body is a snippet, not a string with dollars in it

    /// The invisible failure: a marker the parser could not read passes
    /// through as literal text, deliberately — so the place to catch it is
    /// here, not in the file it would land in.
    @Test func everyBodyExpandsWithNoMarkerLeftBehind() {
        for entry in everything {
            let text = CodeSnippet.parse(entry.body).text

            #expect(!text.contains("${"), "\(entry.trigger) leaves a marker in: \(text)")

            let dollarBeforeDigit = zip(text, text.dropFirst()).contains { $0 == "$" && $1.isNumber }
            #expect(!dollarBeforeDigit, "\(entry.trigger) leaves a tab stop in: \(text)")
        }
    }

    /// Tab order is ascending by index, so a gap or a duplicate is a stop the
    /// reader tabs into out of sequence — or never reaches at all.
    @Test func tabStopsAreNumberedFromOneWithNoGaps() {
        for entry in everything {
            let indices = CodeSnippet.parse(entry.body).fields.map(\.index)
            let expected = indices.isEmpty ? [] : Array(1...indices.count)
            #expect(indices == expected, "\(entry.trigger) numbers its stops \(indices)")
        }
    }

    /// A bare `$1` is a stop with nothing in it: zero-width, invisible, and
    /// impossible to tell from the caret sitting there anyway. Every stop in
    /// this catalogue selects text you can see and type over.
    @Test func everyTabStopSelectsSomethingToTypeOver() {
        for entry in everything {
            for field in CodeSnippet.parse(entry.body).fields {
                #expect(
                    !field.placeholder.isEmpty,
                    "\(entry.trigger) has an empty stop at index \(field.index)"
                )
            }
        }
    }

    /// Without `$0` the caret lands after the last character, which for a
    /// fenced block is outside the fence and for a heading is two blank lines
    /// down. Every body here says where it wants to end.
    @Test func everyBodySaysWhereTheCaretEndsUp() throws {
        for entry in everything {
            let snippet = CodeSnippet.parse(entry.body)
            let caret = try #require(snippet.finalCaret, "\(entry.trigger) has no $0")
            #expect(caret >= 0 && caret <= (snippet.text as NSString).length)
        }
    }

    // MARK: - The constructs themselves

    /// The separator row is the one nobody remembers, and getting it wrong
    /// does not produce a wonky table — it produces three lines of literal
    /// pipes.
    @Test func theTableSeparatorIsTheRowNobodyRemembers() throws {
        let lines = try expansion("table").components(separatedBy: "\n")

        #expect(lines.count >= 3)
        #expect(lines[1] == "| --- | --- |")

        let widths = Set(lines.prefix(3).map { $0.components(separatedBy: "|").count })
        #expect(widths.count == 1, "header, separator and row disagree on column count: \(lines)")
    }

    /// The language is the first thing you type because it is the thing the
    /// highlighter needs before the body exists, and the caret ends up inside
    /// the fence rather than after it.
    @Test func theCodeFenceTakesItsLanguageFirst() throws {
        let snippet = CodeSnippet.parse(try entry("code").body)
        let text = snippet.text as NSString

        #expect(snippet.fields.first?.placeholder == "swift")
        #expect(snippet.text.hasPrefix("```swift\n"))
        #expect(snippet.text.hasSuffix("\n```"))
        #expect(snippet.finalCaret == text.range(of: "\n").location + 1)
    }

    /// A reference with no definition renders as literal brackets. The
    /// definition here is written by repeating index 2, which the parser
    /// resolves to that index's default — if that behaviour ever changes this
    /// snippet starts emitting an empty label and nobody notices until a page
    /// renders wrong.
    @Test func theReferenceLinkDefinesTheLabelItUses() throws {
        let text = try expansion("reflink")

        #expect(text.contains("[text][label]"))
        #expect(text.contains("[label]: https://"))
    }

    @Test func theFootnoteDefinesTheMarkerItUses() throws {
        let text = try expansion("footnote")

        #expect(text.hasPrefix("[^note]"))
        #expect(text.contains("[^note]: Explanation"))
    }

    /// Same repeated-index mechanism, and the one place it is most obviously
    /// right: the closing tag has to be the tag that was opened.
    @Test func theJSXElementClosesTheTagItOpened() throws {
        let text = try expansion("component")

        #expect(text == "<Component>\n  children\n</Component>")
    }

    @Test func frontMatterIsFencedOnBothSides() throws {
        let text = try expansion("frontmatter")

        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("\ntitle: Title\n"))
        #expect(text.dropFirst(4).contains("---\n"))
    }

    @Test func theTaskBoxStartsEmpty() throws {
        let text = try expansion("task")

        #expect(text == "- [ ] task")
    }

    @Test func aHeadingCarriesItsLevelInHashes() throws {
        for level in 1...6 {
            let text = try expansion("h\(level)")
            #expect(text.prefix(while: { $0 == "#" }).count == level)
            #expect(text.hasPrefix(String(repeating: "#", count: level) + " Heading"))
        }
    }

    // MARK: - The catalogue

    @Test func theCatalogueCoversTheConstructsPeopleActuallyType() {
        let triggers = Set(everything.map(\.trigger))
        let required = [
            "code", "table", "link", "image", "reflink", "task", "quote",
            "details", "frontmatter", "footnote", "hr",
            "h1", "h2", "h3", "h4", "h5", "h6",
        ]

        for trigger in required {
            #expect(triggers.contains(trigger), "nothing is triggered by \(trigger)")
        }
    }

    /// A trigger is typed after a slash, so it has to be reachable without
    /// shift and without punctuation — and two of them sharing a word would
    /// make one unreachable.
    @Test func triggersAreUniqueAndTypeable() {
        let triggers = everything.map(\.trigger)

        #expect(Set(triggers).count == triggers.count, "duplicate trigger in \(triggers)")

        for trigger in triggers {
            #expect(trigger.count >= 2, "\(trigger) is too short to aim at")
            #expect(trigger == trigger.lowercased(), "\(trigger) needs shift to type")
            #expect(
                trigger.allSatisfy { $0.isLetter || $0.isNumber },
                "\(trigger) contains a character the trigger scanner stops at"
            )
        }
    }

    /// MDX is Markdown plus JSX, so it gets everything Markdown gets. The
    /// converse must not hold: an `import` offered in a `.md` file inserts a
    /// line that renders as prose.
    @Test func mdxGetsEverythingMarkdownGetsAndMore() {
        let markdown = MarkdownSnippets.entries(for: .markdown).map(\.trigger)
        let mdx = MarkdownSnippets.entries(for: .mdx).map(\.trigger)

        #expect(Set(markdown).isSubset(of: Set(mdx)))
        #expect(mdx.count > markdown.count)

        for jsx in MarkdownSnippets.jsxEntries.map(\.trigger) {
            #expect(!markdown.contains(jsx), "\(jsx) is offered in plain Markdown")
        }
    }

    @Test func everyRowIsASnippetRowThatInsertsItsBody() {
        let items = MarkdownSnippets.items(for: .mdx)

        #expect(items.map(\.label) == everything.map(\.trigger))
        #expect(items.map(\.insertText) == everything.map(\.body))
        #expect(Set(items.map(\.id)).count == items.count)

        for item in items {
            #expect(item.isSnippet, "\(item.label) would be inserted as literal text")
            #expect(item.kind == .snippet)
            #expect(item.source == .keyword)
            #expect(item.detail?.isEmpty == false, "\(item.label) has an empty detail column")
            #expect(item.replaceRange == nil, "\(item.label) claims a span nobody gave it")
        }
    }

    @Test func aRowCarriesTheSpanItReplaces() {
        let span = NSRange(location: 12, length: 4)
        let items = MarkdownSnippets.items(for: .markdown, replacing: span)

        #expect(items.allSatisfy { $0.replaceRange == span })
    }

    /// The trigger is found in a line and applied to a document, and the
    /// offset between the two is the one piece of arithmetic in wiring this up
    /// that can be wrong without looking wrong.
    @Test func aTriggerSpanIsPlacedInTheDocument() throws {
        let trigger = try #require(MarkdownSnippets.trigger(line: "see /tab", caretInLine: 8))
        let items = MarkdownSnippets.items(for: .markdown, trigger: trigger, lineStart: 100)

        #expect(items.allSatisfy { $0.replaceRange == NSRange(location: 104, length: 4) })
    }

    // MARK: - The documentation card

    /// The preview is the parsed body rather than a second copy of it, so the
    /// card cannot promise a shape the snippet does not insert.
    @Test func theCardPreviewsExactlyWhatWillBeInserted() throws {
        let table = try entry("table")
        let card = try #require(MarkdownSnippets.documentation(for: table.item()))
        let inserted = try expansion("table")

        #expect(card.format == .plainText)
        #expect(card.text.hasPrefix(table.summary))
        #expect(card.text.hasSuffix(inserted))
    }

    @Test func everyRowHasACard() {
        for item in MarkdownSnippets.items(for: .mdx) {
            #expect(MarkdownSnippets.documentation(for: item) != nil, "\(item.label) has no card")
        }
    }

    /// The host asks this about every highlighted row, including the ones a
    /// language server sent — answering for those would put a Markdown
    /// preview under someone's TypeScript symbol.
    @Test func aRowFromSomewhereElseGetsNoCard() {
        let foreign = CodeCompletionItem(kind: .function, label: "table", source: .server)

        #expect(MarkdownSnippets.documentation(for: foreign) == nil)
    }

    // MARK: - Which files get a catalogue

    @Test func theFlavourFollowsTheExtension() {
        #expect(MarkdownSnippets.flavor(forFileName: "README.md") == .markdown)
        #expect(MarkdownSnippets.flavor(forFileName: "notes.markdown") == .markdown)
        #expect(MarkdownSnippets.flavor(forFileName: "NOTES.MD") == .markdown)
        #expect(MarkdownSnippets.flavor(forFileName: "post.mdx") == .mdx)
        #expect(MarkdownSnippets.flavor(forFileName: "main.swift") == nil)
        #expect(MarkdownSnippets.flavor(forFileName: "LICENSE") == nil)
    }

    // MARK: - Staying quiet in prose

    private func trigger(_ line: String, _ caret: Int? = nil) -> MarkdownSnippets.Trigger? {
        MarkdownSnippets.trigger(
            line: line,
            caretInLine: caret ?? (line as NSString).length
        )
    }

    @Test func aSlashOpensTheCatalogue() throws {
        let found = try #require(trigger("/tab"))

        #expect(found.query == "tab")
        #expect(found.range == NSRange(location: 0, length: 4))
    }

    /// The slash is part of the span, so accepting a row leaves no sigil
    /// behind in the file.
    @Test func theSlashIsPartOfWhatGetsReplaced() throws {
        let found = try #require(trigger("see /tab"))

        #expect(found.query == "tab")
        #expect(found.range == NSRange(location: 4, length: 4))
    }

    /// How somebody learns the triggers without being told them.
    @Test func aBareSlashAsksForEverything() throws {
        let found = try #require(trigger("/"))

        #expect(found.query.isEmpty)
        #expect(found.range == NSRange(location: 0, length: 1))
    }

    /// Refiltering: only what is behind the caret counts, so backspacing into
    /// the word narrows the query instead of ending the session.
    @Test func onlyTheTextBehindTheCaretIsTheQuery() throws {
        let found = try #require(trigger("/table", 3))

        #expect(found.query == "ta")
        #expect(found.range == NSRange(location: 0, length: 3))
    }

    /// The whole reason the rule is a slash and not a word. Every line here
    /// contains a trigger word spelled exactly, and not one of them may open
    /// a list — because Return, pressed at the end of any of them, would
    /// accept whatever was highlighted.
    @Test func noWordInProseOpensTheList() {
        let prose = [
            "table",
            "The table of contents",
            "- link",
            "code",
            "code review notes",
            "an image of a cat",
            "quote",
            "details",
            "  hr",
            "> quote of the day",
            "1. task",
            "- [ ] task",
            "# heading",
        ]

        for line in prose {
            #expect(trigger(line) == nil, "\(line) opens a list at the end of the line")
        }
    }

    /// The escape hatch must not land back in the middle of ordinary prose,
    /// and a Markdown file is full of slashes that are not requests.
    @Test func aSlashInsideAWordOrAPathIsNotARequest() {
        let notRequests = [
            "https://tab",
            "see docs/table",
            "and/or",
            "24/7",
            "//tab",
            "/tab/link",
            "src/components/image",
        ]

        for line in notRequests {
            #expect(trigger(line) == nil, "\(line) opens a list")
        }
    }

    /// After anything that is not a word character, though, a slash is a
    /// request — whitespace, punctuation, or the start of the line.
    @Test func aSlashAfterAnythingElseIsARequest() {
        let requests = ["/tab", "a /tab", "(/img", "  /table", "- /link", "> /quote"]

        for line in requests {
            #expect(trigger(line) != nil, "\(line) does not open a list")
        }
    }

    /// A caret arrives from a view that measures it against a document, so it
    /// can be past the end of the line this function was handed.
    @Test func theCaretIsClampedToTheLine() throws {
        let clamped = try #require(trigger("/tab", 99))

        #expect(clamped.range == NSRange(location: 0, length: 4))
        #expect(trigger("/tab", -5) == nil)
        #expect(trigger("", 0) == nil)
        #expect(trigger("/tab", 0) == nil)
    }
}

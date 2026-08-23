import AppKit

/// What to say when the pointer rests on a symbol.
///
/// A plain value, for the same reason as `CodeTheme`: the engine draws this
/// and knows nothing about where it came from. The host fills it from a
/// language server and from whatever diagnostics it is holding, and the
/// engine never learns that either exists.
struct CodeHoverInfo: Equatable {
    /// A problem reported at the hovered position.
    struct Problem: Equatable {
        let message: String

        /// Which tool said it — `swiftc`, `pylint`, `ts`. Worth showing
        /// because the same line can carry a compiler error and a linter's
        /// opinion, and those are not equally binding.
        let source: String?
        let color: NSColor
    }

    /// A run of hover content the card draws as one thing.
    ///
    /// Two cases because there are two ways to draw text and the payload
    /// says which: prose is proportional and reflowed, source is
    /// monospaced, kept line for line, and coloured. Collapsing them — which
    /// is what a single `String` did — means one of the two is always drawn
    /// as the other.
    enum Block: Equatable {
        /// Prose, with markdown's *inline* marks still in it. The card
        /// parses those; block syntax has already been resolved by `split`.
        case prose(String)

        /// Source, and the language its fence named.
        ///
        /// **Nil is a real answer, not a missing one.** An untagged fence,
        /// and a tag this build has no rules for — `text`, `diff`,
        /// `mermaid` — both mean "draw this monospaced and do not pretend
        /// to know what it is". Guessing the document's language instead
        /// colours a fence of shell output as if it were the file around
        /// it. See `CodeLanguage.resolve(fenceInfo:)`.
        case code(String, language: CodeLanguage?)
    }

    var problems: [Problem] = []

    /// The declaration, as the server wrote it inside its leading fenced
    /// code block.
    var signature: Block?

    /// What followed the declaration, in order.
    ///
    /// A list rather than one string, because a doc comment interleaves the
    /// two: prose, then a `@see` example, then more prose. Flattened, the
    /// example lost its fences and was drawn as a sentence.
    var documentation: [Block] = []

    var isEmpty: Bool {
        problems.isEmpty && signature == nil && documentation.isEmpty
    }

    /// Splits a language server's hover payload into declaration and prose.
    ///
    /// Servers answer in markdown and lead with the declaration inside a
    /// fenced code block — `sourcekit-lsp`, `typescript-language-server` and
    /// `pylsp` all do. Keeping the two apart is what lets the declaration be
    /// drawn in the editor's own font and colours while the prose stays
    /// ordinary readable text. Rendered as one blob it is either all code or
    /// all prose, and both are worse than the split.
    ///
    /// A later fenced block — a `@see` example, a second overload — becomes a
    /// `.code` block of its own rather than being flattened into the prose
    /// around it. It used to lose its fences and its font with them, which
    /// made an example read as a sentence. A fenced block with no prose
    /// *before* it is still the declaration, however many there are:
    /// `rust-analyzer` answers with the module path in one block and the
    /// signature in the next, and taking only the first put the module path
    /// in the code font and the real signature into the prose.
    ///
    /// **Every fence keeps the language its info string names**, resolved
    /// through `CodeLanguage.resolve(fenceInfo:)` — the same table the
    /// markdown preview uses, so a ```` ```css ```` fence is coloured by the
    /// same rules in both places. The declaration takes the language of the
    /// *first* leading fence, since the later ones are continuations of it.
    ///
    /// Documentation is also **reflowed**: a doc comment arrives wrapped to
    /// whatever column its author's editor used, and wrapping it again at the
    /// card's width leaves a ragged alternation of short and long lines.
    /// Markdown's own rule is that a single newline is a space and only a
    /// blank line starts a paragraph, so honouring it is both more correct and
    /// what makes the card read as prose. List items and fenced examples keep
    /// their line breaks, because there the break is the meaning — and a
    /// wrapped list item is *reflowed into the item*, which is the same rule
    /// read one level down. Without that, every hard-wrapped bullet
    /// `sourcekit-lsp` sends arrived as a bullet followed by an orphan
    /// paragraph holding the rest of its own sentence.
    ///
    /// **Block markers are resolved here rather than drawn.** The card parses
    /// what comes out of this as *inline* markdown, deliberately — that is
    /// what preserves the line breaks above — and inline parsing leaves block
    /// syntax exactly where it found it. So a heading arrived on screen as
    /// `### Complexity`, hashes and all, and a note as `> flush is
    /// keyword-only`. A heading becomes emphasis, which the card already
    /// draws bold; a quote loses a marker that says nothing once the line is
    /// on its own.
    static func split(markdown: String) -> (signature: Block?, documentation: [Block]) {
        var signature: [String] = []
        var signatureLanguage: CodeLanguage?
        var hasOpenedSignatureFence = false

        var documentation: [Block] = []
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        var listItem: [String]?

        var example: [String] = []
        var exampleLanguage: CodeLanguage?

        var isInFence = false
        var isQuoting = false
        var hasSeenProse = false

        func endParagraph() {
            if let listItem {
                blocks.append(ProseBlock(
                    kind: .listItem,
                    text: listItem.joined(separator: " ")
                ))
            }
            listItem = nil

            guard !paragraph.isEmpty else { return }
            blocks.append(ProseBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph = []
        }

        /// Everything said since the last code block, as one block, so the
        /// reflow above still happens across a whole run of prose and stops
        /// at the example that interrupts it.
        func endProse() {
            endParagraph()
            defer { blocks = [] }
            guard let text = Self.assemble(blocks) else { return }
            documentation.append(.prose(text))
        }

        func endExample() {
            endProse()
            guard let text = Self.trimmed(example) else { return }
            documentation.append(.code(text, language: exampleLanguage))
            example = []
            exampleLanguage = nil
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInFence {
                    isInFence = false
                    if hasSeenProse { endExample() }
                    continue
                }

                isInFence = true
                let language = Self.language(ofFence: String(trimmed.dropFirst(3)))
                if hasSeenProse {
                    exampleLanguage = language
                } else {
                    /// A second declaration block gets a blank line above it,
                    /// so the module path and the signature `rust-analyzer`
                    /// sends read as the two things they are rather than as
                    /// one declaration four lines long. The fences themselves
                    /// are gone by the time anything downstream could tell —
                    /// which is why the first one's language is kept here.
                    if !signature.isEmpty { signature.append("") }
                    if !hasOpenedSignatureFence {
                        signatureLanguage = language
                        hasOpenedSignatureFence = true
                    }
                }
                endParagraph()
                isQuoting = false
                continue
            }

            if isInFence {
                if hasSeenProse {
                    example.append(line)
                } else {
                    signature.append(line)
                }
                continue
            }

            if trimmed.isEmpty {
                endParagraph()
                isQuoting = false
                continue
            }

            /// Anything outside a fence that is not blank is documentation —
            /// which is what ends the declaration. A rule counts: it is how
            /// most servers write that boundary in the first place.
            hasSeenProse = true

            // A horizontal rule is how most servers separate the declaration
            // from its documentation. As text it is a row of dashes, which
            // carries nothing once the two are already apart.
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                endParagraph()
                isQuoting = false
                continue
            }

            if let heading = Self.heading(trimmed) {
                endParagraph()
                isQuoting = false
                blocks.append(ProseBlock(kind: .paragraph, text: Self.emphasized(heading)))
                continue
            }

            if trimmed.hasPrefix(">") {
                if !isQuoting { endParagraph() }
                isQuoting = true
                let quoted = Self.unquoted(trimmed)
                /// A bare `>` is a blank line inside the quote.
                if quoted.isEmpty { endParagraph() } else { paragraph.append(quoted) }
                continue
            }

            if isQuoting {
                endParagraph()
                isQuoting = false
            }

            if Self.isListItem(trimmed) {
                endParagraph()
                listItem = [Self.indentation(of: line) + trimmed]
                continue
            }

            /// A line under an item is the rest of that item's own sentence,
            /// not a new paragraph. Only a blank line, another item, or a block
            /// of some other kind ends one.
            if listItem != nil {
                listItem?.append(trimmed)
                continue
            }

            paragraph.append(trimmed)
        }

        /// An unclosed fence is the normal state of a doc comment somebody is
        /// halfway through writing, and its content is still worth drawing as
        /// what it is.
        if isInFence, hasSeenProse {
            endExample()
        } else {
            endProse()
        }

        let declaration = Self.trimmed(signature)
            .map { Block.code($0, language: signatureLanguage) }
        return (declaration, documentation)
    }

    /// A run of prose that has to stay together.
    private struct ProseBlock {
        enum Kind { case paragraph, listItem }
        let kind: Kind
        let text: String
    }

    /// The language a fence's info string names, or nil for a fence that
    /// names none this build knows.
    ///
    /// Both halves are borrowed rather than rewritten: `MarkdownCodeBlock`
    /// already defines what the *first word* of an info string is — `ts
    /// title="app.ts"` is a real fence and its language is `ts` — and
    /// `CodeLanguage.resolve(fenceInfo:)` already maps that word onto the
    /// highlighter. A second copy of either rule here is a second copy that
    /// drifts.
    private static func language(ofFence info: String) -> CodeLanguage? {
        CodeLanguage.resolve(fenceInfo: MarkdownCodeBlock(info: info, code: "").languageHint)
    }

    /// The text of an ATX heading, or nil when the line is not one.
    ///
    /// Six hashes is markdown's limit, and the space after them is what makes
    /// `#include <stdio.h>` in a C doc comment a line of prose rather than a
    /// heading called `include <stdio.h>`. Closing hashes — `## Examples ##` —
    /// are decoration and go with the opening ones.
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }

        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Bold, which is as much of a heading as an inline renderer can draw.
    ///
    /// Left alone when the text is already carrying strong emphasis: `**`
    /// nested inside `**` is not something the parser recovers from, and a
    /// heading somebody already bolded reads correctly without help.
    private static func emphasized(_ text: String) -> String {
        text.contains("**") ? text : "**\(text)**"
    }

    /// A blockquote line with its markers taken off, nesting included.
    private static func unquoted(_ line: String) -> String {
        var text = Substring(line)
        while text.first == ">" {
            text = text.dropFirst()
            if text.first == " " { text = text.dropFirst() }
        }
        return String(text).trimmingCharacters(in: .whitespaces)
    }

    /// The leading whitespace of a line.
    ///
    /// Kept, because it is the only thing left that says which level a nested
    /// item is on: `isListItem` is asked about the *trimmed* line — a bullet is
    /// a bullet at any depth — so without this a `- Parameters:` and the
    /// `  - transform:` under it came out at the same column, reading as two
    /// unrelated bullets.
    private static func indentation(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    /// Whether a line is a bullet or a numbered item, and so owns its line.
    private static func isListItem(_ line: String) -> Bool {
        if let first = line.first, "-*+•".contains(first) {
            return line.dropFirst().first == " "
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// Joins one run of prose back up: a blank line between paragraphs, a
    /// single newline between the items of a list.
    ///
    /// Code no longer passes through here — a fence is its own `Block` now —
    /// which is why the tight rule has only lists left to apply to.
    private static func assemble(_ blocks: [ProseBlock]) -> String? {
        var result = ""
        var previous: ProseBlock.Kind?

        for block in blocks {
            if !result.isEmpty {
                let tight = previous == block.kind && block.kind != .paragraph
                result += tight ? "\n" : "\n\n"
            }
            result += block.text
            previous = block.kind
        }

        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Drops the blank lines around a block and joins what is left.
    private static func trimmed(_ lines: [String]) -> String? {
        var lines = lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

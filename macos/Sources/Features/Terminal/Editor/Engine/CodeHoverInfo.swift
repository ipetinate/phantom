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

    var problems: [Problem] = []

    /// The declaration, as the server wrote it inside a fenced code block.
    var signature: String?

    /// The prose that followed the declaration.
    var documentation: String?

    var isEmpty: Bool {
        problems.isEmpty && signature == nil && documentation == nil
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
    /// A later fenced block — a `@see` example, a second overload — keeps its
    /// content and loses its fences: the text is still worth reading and the
    /// markers are not. A fenced block with no prose *before* it is still the
    /// declaration, however many there are: `rust-analyzer` answers with the
    /// module path in one block and the signature in the next, and taking
    /// only the first put the module path in the code font and the real
    /// signature into the prose.
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
    static func split(markdown: String) -> (signature: String?, documentation: String?) {
        var signature: [String] = []
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        var listItem: [String]?
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

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                /// A second declaration block gets a blank line above it, so
                /// the module path and the signature `rust-analyzer` sends read
                /// as the two things they are rather than as one declaration
                /// four lines long. The fences themselves are gone by the time
                /// anything downstream could tell.
                if isInFence, !hasSeenProse, !signature.isEmpty { signature.append("") }
                endParagraph()
                isQuoting = false
                continue
            }

            if isInFence {
                if hasSeenProse {
                    blocks.append(ProseBlock(kind: .verbatim, text: line))
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
        endParagraph()

        return (trimmed(signature), assemble(blocks))
    }

    /// A run of prose that has to stay together.
    private struct ProseBlock {
        enum Kind { case paragraph, listItem, verbatim }
        let kind: Kind
        let text: String
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

    /// Joins the blocks back up: a blank line between paragraphs, a single
    /// newline inside a list or a code example.
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

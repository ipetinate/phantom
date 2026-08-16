import Foundation

/// Splits markdown into blocks.
///
/// A pure function over a string: no views, no file access, no clock. That
/// is not tidiness for its own sake — a markdown parser is nothing but edge
/// cases, and the only way to hold them still is to be able to write each
/// one as a string and an expectation.
///
/// **Why hand-written when Foundation ships a markdown parser.** It is
/// worth being precise about this, because the obvious reading — that
/// `AttributedString(markdown:)` is inline-only — is wrong. With
/// `interpretedSyntax: .full` it parses block structure perfectly well and
/// reports it as `presentationIntent` runs: headings, nested lists with
/// their ordinals, fenced code *with the info string*, tables with column
/// alignments, thematic breaks. It is a real CommonMark implementation and
/// it beats this file on the exotic corners.
///
/// What it will not give back is **where any of it came from**. An
/// `AttributedString` carries no offsets into the markdown that produced
/// it, and this preview is built to sit beside the raw text in a split
/// where scrolling one side moves the other. That mapping has to be
/// recorded while the lines are still lines; it cannot be recovered
/// afterwards from the runs. Two smaller reasons point the same way: the
/// raw text of a block survives here, which is what lets a fence be handed
/// to `SyntaxHighlighter` and an MDX component be shown as the source it
/// is, and Foundation quietly mangles a document that opens with YAML front
/// matter — the `---` becomes a thematic break and the first key becomes a
/// heading.
///
/// So Foundation still does the inline half, which is the half it is good
/// at and the half that is genuinely tedious. See `MarkdownInline`.
enum MarkdownParser {
    /// Which dialect the file is written in.
    ///
    /// Only two things separate them, and both are about *not* drawing
    /// something as prose: MDX's `import`/`export` lines, and its JSX.
    enum Flavor: Equatable {
        case markdown
        case mdx
    }

    static func parse(_ text: String, flavor: Flavor = .markdown) -> MarkdownDocument {
        var parse = Parse(flavor: flavor)
        let lines = Self.lines(of: text)
        let blocks = parse.blocks(in: lines, offset: 0, isDocumentStart: true)
        return MarkdownDocument(
            blocks: blocks,
            linkDefinitions: parse.linkDefinitions,
            flavor: flavor
        )
    }

    static func flavor(forFileName fileName: String) -> Flavor {
        (fileName as NSString).pathExtension.lowercased() == "mdx" ? .mdx : .markdown
    }

    /// Line endings normalised before anything looks at a line.
    ///
    /// `components(separatedBy: .newlines)` cannot be used for this: it
    /// treats a CRLF as two separators and invents a blank line between
    /// every pair of real ones, which turns a Windows-authored README into
    /// a document with no paragraphs and no lists.
    static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

/// The parse in progress.
///
/// A struct rather than a pile of free functions because two things have to
/// be threaded through the recursion — the flavor, and the link definitions
/// found anywhere in the document — and passing them by hand through every
/// nested call is how one of them ends up dropped inside a block quote.
private struct Parse {
    let flavor: MarkdownParser.Flavor
    var linkDefinitions: [MarkdownLinkDefinition] = []

    /// `lines` is one entry per source line, and `offset` is the absolute
    /// index of `lines[0]` in the whole document.
    ///
    /// That invariant is what makes `sourceLines` right inside a quote or a
    /// list item: the recursive calls are handed a *de-indented copy* of a
    /// slice, never a compacted one, so index arithmetic still lands on the
    /// original line.
    mutating func blocks(in lines: [String], offset: Int, isDocumentStart: Bool) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if Syntax.isBlank(line) {
                index += 1
                continue
            }

            if isDocumentStart, index == 0, let end = frontMatterEnd(in: lines) {
                let body = lines[1..<end].joined(separator: "\n")
                blocks.append(block(.frontMatter(body), offset + 0, offset + end))
                index = end + 1
                continue
            }

            if let fence = Syntax.fence(line) {
                let (block, next) = codeBlock(from: fence, in: lines, at: index, offset: offset)
                blocks.append(block)
                index = next
                continue
            }

            if let heading = Syntax.atxHeading(line) {
                blocks.append(
                    block(.heading(level: heading.level, text: heading.text), offset + index, offset + index)
                )
                index += 1
                continue
            }

            if Syntax.isThematicBreak(line) {
                blocks.append(block(.thematicBreak, offset + index, offset + index))
                index += 1
                continue
            }

            if Syntax.quoteMarker(line) != nil {
                let (block, next) = quoteBlock(in: lines, at: index, offset: offset)
                blocks.append(block)
                index = next
                continue
            }

            if flavor == .mdx, Syntax.isScriptLine(line) {
                let next = Syntax.endOfParagraphRun(in: lines, from: index)
                let body = lines[index..<next].joined(separator: "\n")
                blocks.append(block(.script(body), offset + index, offset + next - 1))
                index = next
                continue
            }

            if Syntax.isHTMLBlockStart(line) {
                let next = Syntax.htmlBlockEnd(in: lines, from: index)
                let body = lines[index..<next].joined(separator: "\n")
                blocks.append(block(.html(body), offset + index, offset + next - 1))
                index = next
                continue
            }

            if let definition = Syntax.linkDefinition(line) {
                linkDefinitions.append(definition)
                index += 1
                continue
            }

            if let marker = Syntax.listMarker(line), marker.markerIndent <= 3 {
                let (block, next) = listBlock(in: lines, at: index, offset: offset)
                blocks.append(block)
                index = next
                continue
            }

            if let (table, next) = tableBlock(in: lines, at: index) {
                blocks.append(block(.table(table), offset + index, offset + next - 1))
                index = next
                continue
            }

            if Syntax.indentWidth(line) >= 4 {
                let (block, next) = indentedCode(in: lines, at: index, offset: offset)
                blocks.append(block)
                index = next
                continue
            }

            let (block, next) = paragraphOrSetext(in: lines, at: index, offset: offset)
            blocks.append(block)
            index = next
        }

        return blocks
    }

    private func block(_ kind: MarkdownBlock.Kind, _ first: Int, _ last: Int) -> MarkdownBlock {
        MarkdownBlock(kind: kind, sourceLines: first...max(first, last))
    }

    /// The line index of the closing `---`, when the document opens with
    /// front matter.
    ///
    /// Nil when there is no closer, and that is the point: a document whose
    /// very first line is a horizontal rule is a document with a horizontal
    /// rule, not one with unterminated front matter swallowing all of it.
    private func frontMatterEnd(in lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { return index }
        }
        return nil
    }

    private func codeBlock(
        from fence: Syntax.Fence,
        in lines: [String],
        at index: Int,
        offset: Int
    ) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var cursor = index + 1
        var isClosed = false

        while cursor < lines.count {
            if Syntax.closes(lines[cursor], fence) {
                isClosed = true
                cursor += 1
                break
            }
            body.append(Syntax.dropIndent(lines[cursor], fence.indent))
            cursor += 1
        }

        let code = MarkdownCodeBlock(info: fence.info, code: body.joined(separator: "\n"), isClosed: isClosed)
        return (block(.code(code), offset + index, offset + cursor - 1), cursor)
    }

    private func indentedCode(in lines: [String], at index: Int, offset: Int) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var cursor = index
        var pendingBlanks = 0

        while cursor < lines.count {
            let line = lines[cursor]
            if Syntax.isBlank(line) {
                pendingBlanks += 1
                cursor += 1
                continue
            }
            guard Syntax.indentWidth(line) >= 4 else { break }
            body.append(contentsOf: repeatElement("", count: pendingBlanks))
            pendingBlanks = 0
            body.append(Syntax.dropIndent(line, 4))
            cursor += 1
        }

        let last = cursor - pendingBlanks - 1
        let code = MarkdownCodeBlock(info: nil, code: body.joined(separator: "\n"), isClosed: true)
        return (block(.code(code), offset + index, offset + last), cursor - pendingBlanks)
    }

    /// A quote is re-parsed, not flattened.
    ///
    /// `> ## Note` is a heading that happens to be inside a quote, and a
    /// quote holding a fenced example is the shape half the READMEs in the
    /// world use for "don't do this". Stripping the markers and running the
    /// same block parser over what is left is both less code than handling
    /// those inline and the only version that gets them right.
    private mutating func quoteBlock(in lines: [String], at index: Int, offset: Int) -> (MarkdownBlock, Int) {
        var body: [String] = []
        var cursor = index

        while cursor < lines.count {
            let line = lines[cursor]
            if let stripped = Syntax.quoteMarker(line) {
                body.append(stripped)
                cursor += 1
                continue
            }
            /// A lazy continuation: a bare line under a quoted paragraph is
            /// still part of it, which is what lets a quote be typed
            /// without repeating `>` on every wrapped line.
            if !Syntax.isBlank(line), !Syntax.startsNewBlock(line, flavor: flavor),
               Syntax.listMarker(line) == nil, body.last.map({ !Syntax.isBlank($0) }) == true {
                body.append(line)
                cursor += 1
                continue
            }
            break
        }

        let inner = blocks(in: body, offset: offset + index, isDocumentStart: false)
        return (block(.quote(inner), offset + index, offset + cursor - 1), cursor)
    }

    private mutating func listBlock(in lines: [String], at index: Int, offset: Int) -> (MarkdownBlock, Int) {
        guard let first = Syntax.listMarker(lines[index]) else {
            return (block(.paragraph(text: lines[index]), offset + index, offset + index), index + 1)
        }

        var list = MarkdownList()
        var cursor = index
        var sawBlankBetweenItems = false

        /// One past the last line that carried content, so a list that
        /// stopped at a blank line does not claim the blank.
        var contentEnd = index + 1

        while cursor < lines.count {
            guard let marker = Syntax.listMarker(lines[cursor]),
                  marker.markerIndent < first.contentIndent,
                  marker.isOrdered == first.isOrdered,
                  marker.delimiter == first.delimiter
            else { break }

            if !list.items.isEmpty, sawBlankBetweenItems { list.isTight = false }
            sawBlankBetweenItems = false

            var body = [marker.content]
            var scan = cursor + 1
            var pendingBlanks = 0
            var endOfContent = cursor + 1
            var ranOut = false

            while scan < lines.count {
                let line = lines[scan]

                if Syntax.isBlank(line) {
                    pendingBlanks += 1
                    /// Two blank lines end a list outright, and one blank
                    /// followed by anything unindented ends this item —
                    /// both decided by what comes after, so the blanks are
                    /// held rather than committed.
                    if pendingBlanks >= 2 { ranOut = true; break }
                    scan += 1
                    continue
                }

                if Syntax.indentWidth(line) >= marker.contentIndent {
                    body.append(contentsOf: repeatElement("", count: pendingBlanks))
                    if pendingBlanks > 0 { list.isTight = false }
                    pendingBlanks = 0
                    body.append(Syntax.dropIndent(line, marker.contentIndent))
                    scan += 1
                    endOfContent = scan
                    continue
                }

                if pendingBlanks > 0 { break }
                if Syntax.listMarker(line) != nil { break }
                if Syntax.startsNewBlock(line, flavor: flavor) { break }
                body.append(line)
                scan += 1
                endOfContent = scan
            }

            sawBlankBetweenItems = pendingBlanks > 0
            list.items.append(
                MarkdownList.Item(
                    ordinal: marker.ordinal,
                    isChecked: marker.isChecked,
                    blocks: blocks(in: body, offset: offset + cursor, isDocumentStart: false)
                )
            )
            contentEnd = endOfContent
            cursor = ranOut ? endOfContent : scan
            if ranOut { break }
        }

        /// An item holding more than prose reads as loose whatever the
        /// blank lines said — a nested list or a fence inside an item needs
        /// the air, and packing it makes the two levels indistinguishable.
        if list.items.contains(where: { $0.blocks.count > 1 }) { list.isTight = false }

        return (block(.list(list), offset + index, offset + contentEnd - 1), cursor)
    }

    private func tableBlock(in lines: [String], at index: Int) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let headers = Syntax.tableCells(lines[index])
        guard !headers.isEmpty,
              let alignments = Syntax.tableAlignments(lines[index + 1]),
              alignments.count == headers.count
        else { return nil }

        var table = MarkdownTable(headers: headers, alignments: alignments)
        var cursor = index + 2

        while cursor < lines.count {
            let line = lines[cursor]
            guard !Syntax.isBlank(line), line.contains("|"), !Syntax.startsNewBlock(line, flavor: flavor)
            else { break }
            var cells = Syntax.tableCells(line)
            /// Squared off here so no renderer has to decide it twice: a
            /// short row gets empty cells, a long one loses its extras.
            /// GFM says the same, and a hand-edited table is ragged more
            /// often than not.
            if cells.count < headers.count {
                cells.append(contentsOf: repeatElement("", count: headers.count - cells.count))
            }
            table.rows.append(Array(cells.prefix(headers.count)))
            cursor += 1
        }

        return (table, cursor)
    }

    /// A paragraph, unless an underline turns it into a heading.
    ///
    /// `---` is the single easiest thing in markdown to get wrong: under a
    /// paragraph it is a level-2 heading, after a blank line it is a
    /// horizontal rule, on line one it opens front matter, and inside a
    /// table it is the separator. This is where the first of those is
    /// decided, and it has to be checked *before* the same line is offered
    /// to the thematic-break test — which is why the loop below asks about
    /// the underline first and why the block loop can safely ask about the
    /// rule first.
    private func paragraphOrSetext(in lines: [String], at index: Int, offset: Int) -> (MarkdownBlock, Int) {
        var body: [String] = [lines[index]]
        var cursor = index + 1

        while cursor < lines.count {
            let line = lines[cursor]
            if Syntax.isBlank(line) { break }

            if let level = Syntax.setextLevel(line) {
                let text = body.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                return (
                    block(.heading(level: level, text: text), offset + index, offset + cursor),
                    cursor + 1
                )
            }

            if Syntax.startsNewBlock(line, flavor: flavor) { break }
            if Syntax.interruptsParagraph(line) { break }

            /// A table's header row is indistinguishable from a paragraph
            /// line until the separator under it is read, so the paragraph
            /// stops one line *early* and gives the header back.
            ///
            /// `tableBlock` is what decides, rather than "the next line
            /// looks like dashes and pipes": a separator whose column count
            /// disagrees with the header is not a separator at all, and
            /// breaking on the look of it would split one paragraph into
            /// three.
            if tableBlock(in: lines, at: cursor - 1) != nil {
                cursor -= 1
                body.removeLast()
                break
            }

            body.append(line)
            cursor += 1
        }

        let text = body.joined(separator: "\n")
        return (block(.paragraph(text: text), offset + index, offset + cursor - 1), cursor)
    }
}

/// Line-level tests, each answering one question about one line.
///
/// Kept apart from the parse because they are the part worth reading twice:
/// every one of them is a rule from CommonMark that a plausible-looking
/// simplification gets wrong.
private enum Syntax {
    struct Fence {
        let character: Character
        let length: Int
        let info: String?
        let indent: Int
    }

    struct Marker {
        let ordinal: Int?
        let markerIndent: Int

        /// The column the item's content starts at — what decides whether
        /// the next line continues this item or belongs to its parent.
        let contentIndent: Int
        let content: String
        let isChecked: Bool?

        /// `-`, `*`, `+`, `.` or `)`. Changing it starts a new list, which
        /// is CommonMark's way of letting two lists touch.
        let delimiter: Character

        var isOrdered: Bool { ordinal != nil }
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Leading whitespace in columns, counting a tab as four.
    static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 - (width % 4) } else { break }
        }
        return width
    }

    /// Removes `width` columns of indent, expanding a tab that straddles
    /// the boundary into the spaces it stood for.
    static func dropIndent(_ line: String, _ width: Int) -> String {
        var consumed = 0
        var index = line.startIndex

        while index < line.endIndex, consumed < width {
            let character = line[index]
            if character == " " {
                consumed += 1
            } else if character == "\t" {
                let step = 4 - (consumed % 4)
                if consumed + step > width {
                    let overshoot = consumed + step - width
                    return String(repeating: " ", count: overshoot) + line[line.index(after: index)...]
                }
                consumed += step
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }

        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        /// `## Title ##` is one heading with a closing run, but `## C#` is a
        /// heading whose text ends in a `#` — the space before the run is
        /// what tells them apart.
        if text.hasSuffix("#") {
            let kept = text.count - text.reversed().prefix { $0 == "#" }.count
            let remainder = String(text.prefix(kept))
            if remainder.isEmpty || remainder.hasSuffix(" ") {
                text = remainder.trimmingCharacters(in: .whitespaces)
            }
        }
        return (hashes.count, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        let body = line.trimmingCharacters(in: .whitespaces)
        guard let first = body.first, first == "-" || first == "*" || first == "_" else { return false }
        let marks = body.filter { !$0.isWhitespace }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    /// The `===` or `---` under a paragraph.
    ///
    /// A single `-` counts, which looks wrong and is not: CommonMark makes
    /// setext beat both the thematic break and the empty list item when a
    /// paragraph is open above it.
    static func setextLevel(_ line: String) -> Int? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.allSatisfy({ $0 == "=" }) { return 1 }
        if body.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func fence(_ line: String) -> Fence? {
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }

        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        /// A backtick in a backtick fence's info string means this was
        /// never a fence — it is a paragraph containing code spans.
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, length: run.count, info: info.isEmpty ? nil : info, indent: indent)
    }

    static func closes(_ line: String, _ open: Fence) -> Bool {
        guard let fence = fence(line) else { return false }
        return fence.character == open.character && fence.length >= open.length && fence.info == nil
    }

    /// The line with its `>` and one following space removed, or nil.
    static func quoteMarker(_ line: String) -> String? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard body.first == ">" else { return nil }
        let rest = body.dropFirst()
        return rest.first == " " ? String(rest.dropFirst()) : String(rest)
    }

    static func listMarker(_ line: String) -> Marker? {
        let markerIndent = indentWidth(line)
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }

        var ordinal: Int?
        var delimiter: Character
        var length: Int

        if first == "-" || first == "*" || first == "+" {
            let next = body.dropFirst().first
            guard next == nil || next == " " || next == "\t" else { return nil }
            delimiter = first
            length = 1
        } else {
            let digits = body.prefix(while: \.isNumber)
            /// Nine digits is CommonMark's ceiling, and it is the rule that
            /// stops a line like `2024. A year to remember` from becoming a
            /// list — as does the delimiter check below for `2024 was`.
            guard (1...9).contains(digits.count), let value = Int(digits) else { return nil }
            let rest = body.dropFirst(digits.count)
            guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
            let after = rest.dropFirst().first
            guard after == nil || after == " " || after == "\t" else { return nil }
            ordinal = value
            delimiter = mark
            length = digits.count + 1
        }

        let afterMarker = body.dropFirst(length)
        let spaces = afterMarker.prefix { $0 == " " }.count
        /// One to four spaces set the content column; none or five or more
        /// mean the content starts one space in and the rest is the
        /// content's own indent — which is what makes an indented code
        /// block inside a list item possible.
        let gap = (spaces == 0 || spaces > 4) ? 1 : spaces
        let content = String(afterMarker.dropFirst(min(spaces, gap)))

        var isChecked: Bool?
        var text = content
        if content.count >= 3, content.hasPrefix("[") {
            let box = content.dropFirst().first
            if content.dropFirst(2).first == "]", box == " " || box == "x" || box == "X" {
                let rest = content.dropFirst(3)
                if rest.isEmpty || rest.first == " " {
                    isChecked = box != " "
                    text = String(rest.dropFirst(rest.isEmpty ? 0 : 1))
                }
            }
        }

        return Marker(
            ordinal: ordinal,
            markerIndent: markerIndent,
            contentIndent: markerIndent + length + gap,
            content: text,
            isChecked: isChecked,
            delimiter: delimiter
        )
    }

    /// Cells of one table row, outer pipes dropped and `\|` left escaped
    /// for the inline pass to resolve.
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var isEscaped = false

        for character in line.trimmingCharacters(in: .whitespaces) {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                isEscaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)

        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true, cells.count > 1 {
            cells.removeFirst()
        }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, cells.count > 1 {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The `|---|:-:|` row, or nil when the line is not one.
    ///
    /// The whole existence of a table hangs on this: without a separator
    /// row a pipe-filled line is a paragraph, and GFM says so.
    static func tableAlignments(_ line: String) -> [MarkdownTable.Alignment?]? {
        guard line.contains("-"), line.contains("|") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [MarkdownTable.Alignment?] = []
        for cell in cells {
            guard !cell.isEmpty else { return nil }
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }

            switch (leading, trailing) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.leading)
            case (false, true): alignments.append(.trailing)
            case (false, false): alignments.append(nil)
            }
        }
        return alignments
    }

    static func linkDefinition(_ line: String) -> MarkdownLinkDefinition? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("[") else { return nil }

        var label = ""
        var index = body.index(after: body.startIndex)
        var isEscaped = false
        var closed = false

        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)
            if isEscaped {
                label.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" { isEscaped = true; continue }
            if character == "]" { closed = true; break }
            label.append(character)
        }

        guard closed, !label.isEmpty, index < body.endIndex, body[index] == ":" else { return nil }

        let tail = body[body.index(after: index)...].trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }

        var destination = String(tail.prefix { !$0.isWhitespace })
        let remainder = tail.dropFirst(destination.count).trimmingCharacters(in: .whitespaces)
        if destination.hasPrefix("<"), destination.hasSuffix(">"), destination.count > 1 {
            destination = String(destination.dropFirst().dropLast())
        }

        var title: String?
        if remainder.count >= 2 {
            let first = remainder.first
            let last = remainder.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'")
                || (first == "(" && last == ")") {
                title = String(remainder.dropFirst().dropLast())
            } else {
                /// Anything else after the destination means this was never
                /// a definition — `[note]: see the docs` is prose.
                return nil
            }
        } else if !remainder.isEmpty {
            return nil
        }

        return MarkdownLinkDefinition(label: label.lowercased(), destination: destination, title: title)
    }

    /// The tags that make a line an HTML *block* just by appearing at the
    /// start of it — CommonMark's type 6 list, which is block-level HTML and
    /// nothing else.
    ///
    /// The list matters more than it looks. Without it every line opening
    /// with any tag became a block, so a README's logo line —
    /// `<a href="…"><img src="…"></a>` — was drawn as a panel of raw source
    /// instead of as the paragraph it is. `a` and `img` are inline elements;
    /// a line built out of them is prose with markup in it.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
        "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "title", "tr", "track", "ul",
    ]

    /// How a line opens an HTML block, when it does.
    struct HTMLBlock {
        /// False for CommonMark's type 7 — a bare tag alone on its line —
        /// which is the one kind that may not cut an open paragraph in half.
        let canInterruptParagraph: Bool
    }

    static func htmlBlock(_ line: String) -> HTMLBlock? {
        guard indentWidth(line) <= 3 else { return nil }
        let body = line.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("<") else { return nil }

        let after = body.dropFirst()
        let lowered = after.lowercased()

        /// Types 1 to 5: comments, processing instructions, declarations,
        /// CDATA, and the four tags whose content is not markup.
        if lowered.hasPrefix("!") || lowered.hasPrefix("?") { return HTMLBlock(canInterruptParagraph: true) }
        for tag in ["script", "pre", "style", "textarea"] where lowered.hasPrefix(tag) {
            return HTMLBlock(canInterruptParagraph: true)
        }

        let named = after.hasPrefix("/") ? after.dropFirst() : after
        guard let first = named.first, first.isLetter else { return nil }

        let name = String(named.prefix { $0.isLetter || $0.isNumber }).lowercased()
        if blockTags.contains(name) { return HTMLBlock(canInterruptParagraph: true) }

        /// Type 7: one complete tag and nothing else on the line. This is
        /// the door an MDX component comes through — `<Callout type="warn">`
        /// names no known element, so only being alone on its line makes it
        /// a block.
        guard let close = body.firstIndex(of: ">"),
              body[body.index(after: close)...].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return HTMLBlock(canInterruptParagraph: false)
    }

    static func isHTMLBlockStart(_ line: String) -> Bool {
        htmlBlock(line) != nil
    }

    /// MDX's `import` and `export` lines.
    ///
    /// Anchored at column zero on purpose: `import` is an ordinary English
    /// word and an indented one is far more likely to be prose than a
    /// module graph.
    static func isScriptLine(_ line: String) -> Bool {
        guard indentWidth(line) == 0 else { return false }
        for keyword in ["import", "export"] where line.hasPrefix(keyword) {
            let next = line.dropFirst(keyword.count).first
            if next == nil || next == " " || next == "{" || next == "*" { return true }
        }
        return false
    }

    /// The end of a run of non-blank lines — how an MDX script block knows
    /// where it stops.
    static func endOfParagraphRun(in lines: [String], from index: Int) -> Int {
        var cursor = index
        while cursor < lines.count, !isBlank(lines[cursor]) { cursor += 1 }
        return cursor
    }

    /// Where an HTML block stops, which is not simply the next blank line.
    ///
    /// CommonMark ends a comment at `-->`, a processing instruction at `?>`,
    /// and a `<script>`, `<pre>`, `<style>` or `<textarea>` at its closing
    /// tag; only the generic case — an ordinary tag opening a line — ends at
    /// a blank line.
    ///
    /// Found by a real file rather than by reading the spec: a document
    /// opening with a multi-paragraph `<!-- USAGE: … -->` header had the
    /// comment cut at its internal blank line, and the second half was drawn
    /// as prose. A comment leaking into the page is the exact opposite of
    /// what a comment is for.
    static func htmlBlockEnd(in lines: [String], from index: Int) -> Int {
        let opener = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
        var terminator: String?

        if opener.hasPrefix("<!--") {
            terminator = "-->"
        } else if opener.hasPrefix("<?") {
            terminator = "?>"
        } else if opener.hasPrefix("<![cdata[") {
            terminator = "]]>"
        } else if opener.hasPrefix("<!") {
            terminator = ">"
        } else {
            for tag in ["script", "pre", "style", "textarea"] where opener.hasPrefix("<" + tag) {
                terminator = "</" + tag + ">"
            }
        }

        guard let terminator else { return endOfParagraphRun(in: lines, from: index) }

        var cursor = index
        while cursor < lines.count {
            if lines[cursor].lowercased().contains(terminator) { return cursor + 1 }
            cursor += 1
        }
        /// Unterminated, like an unclosed fence: the rest of the file is the
        /// block, rather than the opener alone and prose after it.
        return lines.count
    }

    /// Whether a line begins a block that a paragraph, a quote or a list
    /// item cannot swallow as a continuation.
    static func startsNewBlock(_ line: String, flavor: MarkdownParser.Flavor) -> Bool {
        if fence(line) != nil { return true }
        if atxHeading(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if quoteMarker(line) != nil { return true }
        if htmlBlock(line)?.canInterruptParagraph == true { return true }
        if flavor == .mdx, isScriptLine(line) { return true }
        return false
    }

    /// Whether a list marker on this line breaks an open paragraph.
    ///
    /// The rule that stops a sentence ending in a year from becoming a
    /// list: an ordered item may only interrupt when it is numbered `1`,
    /// and an empty item may not interrupt at all.
    static func interruptsParagraph(_ line: String) -> Bool {
        guard let marker = listMarker(line), marker.markerIndent <= 3 else { return false }
        guard !marker.content.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let ordinal = marker.ordinal { return ordinal == 1 }
        return true
    }
}

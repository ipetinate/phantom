import AppKit

/// Lays a parsed document out as one attributed string.
///
/// **One string, not a stack of views.** A README in a single `NSTextView`
/// gets text selection across block boundaries, find, copy-as-text and
/// smooth scrolling for free, and all four are things a reader expects from
/// a document and nobody would build by hand. The cost is that block
/// decoration has to be expressed as text attributes — which `NSTextBlock`
/// and `NSTextTable` already do, and which is why the preview asks for
/// TextKit 1 while the editor insists on TextKit 2.
///
/// The renderer is deliberately separate from the parse: nothing here
/// decides what a block *is*, so the drawing can be argued about without
/// touching a single parser test.
struct MarkdownRenderer {
    /// Where a block's source lines ended up in the rendered text.
    struct Anchor: Equatable {
        let sourceLines: ClosedRange<Int>
        let range: NSRange
    }

    /// The rendered document, and the map back to the markdown.
    struct Output {
        let text: NSAttributedString

        /// One entry per top-level block, in order.
        let anchors: [Anchor]

        /// Where to scroll the preview so it shows what raw line `line`
        /// shows — the preview half of a synchronised split.
        ///
        /// Falls back to the last block that starts before the line, so a
        /// cursor sitting in a blank line between two blocks still answers.
        func renderedOffset(forSourceLine line: Int) -> Int? {
            var fallback: Int?
            for anchor in anchors {
                if anchor.sourceLines.contains(line) { return anchor.range.location }
                if anchor.sourceLines.lowerBound > line { break }
                fallback = anchor.range.location
            }
            return fallback ?? anchors.first?.range.location
        }

        /// The other direction: which raw line the reader is looking at.
        func sourceLine(forRenderedOffset offset: Int) -> Int? {
            var fallback: Int?
            for anchor in anchors {
                if NSLocationInRange(offset, anchor.range) { return anchor.sourceLines.lowerBound }
                if anchor.range.location > offset { break }
                fallback = anchor.sourceLines.lowerBound
            }
            return fallback ?? anchors.first?.sourceLines.lowerBound
        }
    }

    let style: MarkdownStyle

    /// The directory the document lives in, for resolving `./docs/a.png`.
    var baseURL: URL?

    /// One level of list or quote indentation.
    private static let indentStep: CGFloat = 22

    func render(_ document: MarkdownDocument) -> Output {
        let text = NSMutableAttributedString()
        var anchors: [Anchor] = []

        for block in document.blocks {
            let start = text.length
            append(block, to: text, document: document, indent: 0, containers: [])
            guard text.length > start else { continue }
            anchors.append(
                Anchor(
                    sourceLines: block.sourceLines,
                    range: NSRange(location: start, length: text.length - start)
                )
            )
        }

        return Output(text: text, anchors: anchors)
    }

    // MARK: - Blocks

    private func append(
        _ block: MarkdownBlock,
        to out: NSMutableAttributedString,
        document: MarkdownDocument,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        switch block.kind {
        case let .heading(level, text):
            appendHeading(level: level, text: text, to: out, document: document, indent: indent, containers: containers)

        case let .paragraph(text):
            let content = NSMutableAttributedString(
                attributedString: MarkdownInline.render(
                    text,
                    style: style,
                    definitions: document.linkDefinitions,
                    baseURL: baseURL
                )
            )
            content.append(NSAttributedString(string: "\n"))
            apply(
                paragraph(indent: indent, spacingBefore: 0, spacing: style.bodyFont.pointSize * 0.75, containers: containers),
                to: content
            )
            out.append(content)

        case let .code(code):
            appendCode(code, to: out, indent: indent, containers: containers)

        case let .list(list):
            appendList(list, to: out, document: document, indent: indent, containers: containers)

        case let .quote(inner):
            appendQuote(inner, to: out, document: document, indent: indent, containers: containers)

        case let .table(table):
            appendTable(table, to: out, document: document, indent: indent, containers: containers)

        case .thematicBreak:
            appendThematicBreak(to: out, indent: indent, containers: containers)

        case let .html(source):
            /// A comment is markup whose whole purpose is to be invisible,
            /// and showing it as code would be the one case where being
            /// literal is less honest than being quiet.
            guard !isComment(source) else { return }
            appendSource(
                source,
                caption: document.flavor == .mdx && isComponent(source)
                    ? "component — shown as source, not rendered"
                    : nil,
                language: .html,
                to: out,
                indent: indent,
                containers: containers
            )

        case let .script(source):
            appendSource(
                source,
                caption: "module — not evaluated",
                language: .javascript,
                to: out,
                indent: indent,
                containers: containers
            )

        case let .frontMatter(source):
            appendSource(
                source,
                caption: "front matter",
                language: .yaml,
                to: out,
                indent: indent,
                containers: containers
            )
        }
    }

    private func appendHeading(
        level: Int,
        text: String,
        to out: NSMutableAttributedString,
        document: MarkdownDocument,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        let size = style.headingSize(level)
        let content = rescaled(
            MarkdownInline.render(text, style: style, definitions: document.linkDefinitions, baseURL: baseURL),
            to: .systemFont(ofSize: size, weight: .semibold)
        )
        content.append(NSAttributedString(string: "\n"))

        var blocks = containers
        /// The rule under the top two levels, which is what makes a long
        /// README scannable rather than a wall of bold text.
        if level <= 2 {
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(style.ruleColor, for: .maxY)
            rule.setWidth(size * 0.28, type: .absoluteValueType, for: .padding, edge: .maxY)
            blocks.append(rule)
        }

        let paragraphStyle = paragraph(
            indent: indent,
            spacingBefore: size * (level == 1 ? 0.5 : 1.0),
            spacing: size * 0.5,
            containers: blocks
        )
        apply(paragraphStyle, to: content)
        out.append(content)
    }

    private func appendCode(
        _ code: MarkdownCodeBlock,
        to out: NSMutableAttributedString,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        appendSource(
            code.code,
            /// Worth saying out loud: an unclosed fence is why the rest of
            /// the document stopped being prose, and without the note the
            /// preview just looks broken.
            caption: code.isClosed ? nil : "unclosed fence",
            language: CodeLanguage.resolve(fenceInfo: code.languageHint),
            to: out,
            indent: indent,
            containers: containers
        )
    }

    /// A block of source text on a filled panel, syntax-highlighted when the
    /// language is one this build knows.
    ///
    /// The same shape serves fenced code, raw HTML, MDX modules and front
    /// matter, because all four are "text the preview is showing you rather
    /// than interpreting" and they should look alike.
    private func appendSource(
        _ source: String,
        caption: String?,
        language: CodeLanguage?,
        to out: NSMutableAttributedString,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        let panel = NSTextBlock()
        panel.backgroundColor = style.fillColor
        for edge in [NSRectEdge.minX, .maxX] {
            panel.setWidth(10, type: .absoluteValueType, for: .padding, edge: edge)
        }
        for edge in [NSRectEdge.minY, .maxY] {
            panel.setWidth(8, type: .absoluteValueType, for: .padding, edge: edge)
        }

        if let caption {
            let label = NSMutableAttributedString(
                string: caption + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: style.codeFont.pointSize * 0.85),
                    .foregroundColor: style.secondaryColor,
                ]
            )
            apply(
                paragraph(indent: indent, spacingBefore: 10, spacing: 2, containers: containers),
                to: label
            )
            out.append(label)
        }

        let body = NSMutableAttributedString(
            string: source + "\n",
            attributes: [.font: style.codeFont, .foregroundColor: style.textColor]
        )
        if let language {
            highlight(source, language: language, in: body)
        }
        apply(
            paragraph(
                indent: indent,
                spacingBefore: caption == nil ? 10 : 0,
                spacing: 10,
                containers: containers + [panel]
            ),
            to: body
        )
        out.append(body)
    }

    /// Colours a code block with the editor's own highlighter.
    ///
    /// Nearly free — the highlighter is already here, already cached per
    /// language, and already the thing colouring the file in the other
    /// pane — and it is the difference between a preview that looks like a
    /// document and one that looks unfinished.
    private func highlight(_ source: String, language: CodeLanguage, in body: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: (source as NSString).length)
        for token in SyntaxHighlighter(language: language).tokens(in: source, range: full) {
            guard NSMaxRange(token.range) <= body.length else { continue }
            body.addAttribute(.foregroundColor, value: style.theme.color(for: token.kind), range: token.range)
        }
    }

    private func appendList(
        _ list: MarkdownList,
        to out: NSMutableAttributedString,
        document: MarkdownDocument,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        let step = Self.indentStep
        let air = list.isTight ? 0 : style.bodyFont.pointSize * 0.4

        for (position, item) in list.items.enumerated() {
            var rest = item.blocks
            let leading: NSAttributedString

            /// The item's first paragraph shares the marker's line; anything
            /// else — a nested list, a fence — starts below it.
            if case let .paragraph(text)? = rest.first?.kind {
                rest.removeFirst()
                leading = MarkdownInline.render(
                    text,
                    style: style,
                    definitions: document.linkDefinitions,
                    baseURL: baseURL
                )
            } else {
                leading = NSAttributedString()
            }

            let line = NSMutableAttributedString(
                string: marker(for: item, at: position, in: list, indent: indent) + "\t",
                attributes: [.font: style.bodyFont, .foregroundColor: style.secondaryColor]
            )
            line.append(leading)
            line.append(NSAttributedString(string: "\n"))

            let paragraphStyle = paragraph(
                indent: indent,
                spacingBefore: position == 0 ? air : 0,
                spacing: air,
                containers: containers
            )
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.headIndent = indent + step
            paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + step)]
            apply(paragraphStyle, to: line)
            out.append(line)

            for block in rest {
                append(block, to: out, document: document, indent: indent + step, containers: containers)
            }
        }
    }

    private func marker(
        for item: MarkdownList.Item,
        at position: Int,
        in list: MarkdownList,
        indent: CGFloat
    ) -> String {
        if let isChecked = item.isChecked { return isChecked ? "☑" : "☐" }
        if let ordinal = item.ordinal { return "\(ordinal)." }

        /// The bullet changes with depth for the same reason a printed
        /// outline does: at two levels of indent alone, a reader cannot see
        /// which list an item belongs to.
        let bullets = ["•", "◦", "▪"]
        let level = Int(indent / Self.indentStep)
        return bullets[min(level, bullets.count - 1)]
    }

    private func appendQuote(
        _ inner: [MarkdownBlock],
        to out: NSMutableAttributedString,
        document: MarkdownDocument,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        let bar = NSTextBlock()
        bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setBorderColor(style.secondaryColor, for: .minX)
        bar.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        for edge in [NSRectEdge.minY, .maxY] {
            bar.setWidth(4, type: .absoluteValueType, for: .padding, edge: edge)
        }

        for block in inner {
            append(block, to: out, document: document, indent: indent, containers: containers + [bar])
        }
    }

    private func appendTable(
        _ table: MarkdownTable,
        to out: NSMutableAttributedString,
        document: MarkdownDocument,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        guard table.columnCount > 0 else { return }

        let grid = NSTextTable()
        grid.numberOfColumns = table.columnCount
        grid.layoutAlgorithm = .automaticLayoutAlgorithm
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false

        func appendRow(_ cells: [String], at row: Int, isHeader: Bool) {
            for (column, cell) in cells.enumerated() {
                let block = NSTextTableBlock(
                    table: grid,
                    startingRow: row,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setBorderColor(style.ruleColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                if isHeader { block.backgroundColor = style.fillColor }

                let content = NSMutableAttributedString(
                    attributedString: MarkdownInline.render(
                        cell,
                        style: style,
                        definitions: document.linkDefinitions,
                        baseURL: baseURL
                    )
                )
                if isHeader {
                    content.enumerateAttribute(
                        .font,
                        in: NSRange(location: 0, length: content.length)
                    ) { value, range, _ in
                        let font = value as? NSFont ?? style.bodyFont
                        content.addAttribute(
                            .font,
                            value: MarkdownInline.font(font, bold: true, italic: false),
                            range: range
                        )
                    }
                }
                content.append(NSAttributedString(string: "\n"))

                let paragraphStyle = paragraph(
                    indent: 0,
                    spacingBefore: 0,
                    spacing: 0,
                    containers: containers + [block]
                )
                switch table.alignments.indices.contains(column) ? table.alignments[column] : nil {
                case .center: paragraphStyle.alignment = .center
                case .trailing: paragraphStyle.alignment = .right
                case .leading, nil: paragraphStyle.alignment = .left
                }
                apply(paragraphStyle, to: content)
                out.append(content)
            }
        }

        appendRow(table.headers, at: 0, isHeader: true)
        for (offset, row) in table.rows.enumerated() {
            appendRow(row, at: offset + 1, isHeader: false)
        }

        /// A table's last cell ends the table only when a paragraph outside
        /// it follows, so an empty one is appended to close the grid.
        let closer = NSMutableAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
        ])
        apply(paragraph(indent: indent, spacingBefore: 0, spacing: 10, containers: containers), to: closer)
        out.append(closer)
    }

    private func appendThematicBreak(
        to out: NSMutableAttributedString,
        indent: CGFloat,
        containers: [NSTextBlock]
    ) {
        let rule = NSTextBlock()
        rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        rule.setBorderColor(style.ruleColor, for: .minY)

        let line = NSMutableAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: style.ruleColor,
        ])
        apply(
            paragraph(indent: indent, spacingBefore: 14, spacing: 14, containers: containers + [rule]),
            to: line
        )
        out.append(line)
    }

    // MARK: - Attributes

    private func paragraph(
        indent: CGFloat,
        spacingBefore: CGFloat,
        spacing: CGFloat,
        containers: [NSTextBlock]
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        style.lineSpacing = 2
        style.textBlocks = containers
        return style
    }

    private func apply(_ paragraphStyle: NSParagraphStyle, to text: NSMutableAttributedString) {
        text.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: text.length)
        )
    }

    /// Re-sizes inline text to a heading's font while keeping the traits the
    /// inline pass found — `## The **hard** part` stays bolder than the rest
    /// of its own heading, and a code span in a heading stays monospaced.
    private func rescaled(_ text: NSAttributedString, to font: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            let current = value as? NSFont ?? style.bodyFont
            let traits = current.fontDescriptor.symbolicTraits
            let base = traits.contains(.monoSpace)
                ? NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .semibold)
                : font
            result.addAttribute(
                .font,
                value: MarkdownInline.font(base, bold: true, italic: traits.contains(.italic)),
                range: range
            )
        }
        return result
    }

    // MARK: - HTML shapes

    /// Whether an HTML block is nothing but a comment.
    private func isComment(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")
    }

    /// Whether a JSX-looking block names a component rather than an element.
    ///
    /// The capital letter is JSX's own rule for the distinction, and it is
    /// the whole difference between markup a browser would draw and a
    /// component only a bundler can resolve — which is the thing this
    /// preview has to admit it is not doing.
    private func isComponent(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        let name = trimmed.dropFirst().drop { $0 == "/" }
        return name.first?.isUppercase == true
    }
}

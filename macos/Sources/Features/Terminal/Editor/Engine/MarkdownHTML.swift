import Foundation

/// The small dialect of HTML this preview draws, reduced to markdown.
///
/// **Why a reduction rather than a renderer.** Drawing arbitrary HTML means
/// a box model, a cascade and a layout engine — a browser — and there is one
/// of those on the machine already. What a README actually contains is a
/// short list of shapes: a centred wrapper around a logo, a badge row, a
/// `<br>` in a table cell, a `<kbd>` in a keyboard hint. Every one of those
/// has a markdown spelling, so they are rewritten into markdown and handed
/// to the parser and the inline pass that were already there. Nothing new
/// draws anything.
///
/// **What is in.** `b`, `strong`, `i`, `em`, `code`, `kbd`, `samp`, `var`,
/// `tt`, `del`, `s`, `strike`, `sub`, `sup`, `br`, `hr`, `img`, `a`,
/// `h1`–`h6`, and the wrappers that carry no meaning of their own — `p`,
/// `div`, `center`, `span`, `figure`, `figcaption`, `picture`, `small`, `u`,
/// `abbr`, `cite`, `q`, `ins`, `mark`, `big`, `font`, `nobr`, `time`, `data`,
/// `dfn`.
///
/// **What is out**, and why each: anything whose own layout or behaviour a
/// flattening would misrepresent. A `table` reduced to prose is a paragraph
/// of cells with no columns; `ul`, `ol`, `li`, `dl` would need their markers
/// and their nesting rebuilt; `details` and `summary` are a disclosure this
/// preview cannot open, and pretending the closed half is prose hides that;
/// `pre` is preformatted and the reduction normalises whitespace; `script`,
/// `style`, `iframe`, `svg`, `canvas`, `video`, `audio`, `form` and its
/// controls are not text at all. Those keep the raw-source panel they have
/// always had, which is the honest answer for markup nothing here can draw.
///
/// **An unknown tag is left verbatim, deliberately.** `Vec<String>` in a
/// paragraph is prose, and a reducer that deleted every angle-bracketed word
/// it did not recognise would silently eat it. So only names this file knows
/// to be HTML are touched, and `<Callout>` in an MDX file stays the
/// unrendered component it is.
enum MarkdownHTML {
    /// Markup rewritten as markdown, plus the alignment the markup asked for.
    struct Reduction: Equatable {
        var text: String

        /// From an `align` attribute, or a `style` naming `text-align`. Nil
        /// when the markup said nothing about it — which is not the same as
        /// `.leading`, since a centred wrapper inside a left-aligned document
        /// has to be told apart from one that never asked.
        var alignment: MarkdownTable.Alignment?
    }

    /// Inline markup inside a paragraph, a heading or a table cell.
    ///
    /// Never fails: prose is drawn whatever it holds, and a tag this does not
    /// know survives as the text it is.
    static func prose(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return reduce(text, strict: false)?.text ?? text
    }

    /// A whole block of raw HTML, or nil when the block holds something this
    /// cannot draw and the source panel is the honest answer.
    ///
    /// The `<` check is the recursion guard, and it is load-bearing: the
    /// renderer parses this text as markdown and renders the blocks that come
    /// out, so a reduction that still held a tag could arrive back here as an
    /// HTML block and go round again. In strict mode a tag can only survive
    /// as an unterminated `<`, so refusing those closes the loop and costs a
    /// document that writes `a < b` inside a `div` nothing but its panel.
    static func block(_ source: String) -> Reduction? {
        guard let reduction = reduce(source, strict: true) else { return nil }
        guard !reduction.text.contains("<") else { return nil }
        /// A reduction with no text in it is not a failure: `<a name="usage">`
        /// is a scroll target and `<br>` on its own is a spacer, and both are
        /// markup with nothing to say. In strict mode an empty result can only
        /// mean that — anything unrecognised has already returned nil — so
        /// drawing nothing is the honest answer, and better than the panel of
        /// raw source the reader used to get.
        return Reduction(text: dedented(reduction.text), alignment: reduction.alignment)
    }

    /// Leading whitespace removed from every line, because the result is
    /// parsed as markdown and markdown counts columns.
    ///
    /// ⚠️ The case that made this necessary is the commonest HTML in a README:
    ///
    /// ```html
    /// <p align="center">
    ///     <img src="docs/logo.png">
    /// </p>
    /// ```
    ///
    /// Four spaces of ordinary HTML indentation is an *indented code block* to
    /// a markdown parser, so the reduction came back out of the parse as a
    /// panel of source — the exact thing this whole path exists to stop.
    /// Trailing spaces are left alone: two of them are markdown's hard break,
    /// which is what a `<br>` was rewritten into.
    private static func dedented(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { String($0.drop { $0 == " " || $0 == "\t" }) }
            .joined(separator: "\n")
    }

    // MARK: - The walk

    /// One open element, and what closing it puts back.
    private struct Open {
        let element: Element

        /// How many characters of output existed when this opened, for the
        /// two elements that need their own content — `sub` and `sup` map
        /// theirs to Unicode rather than wrapping it in delimiters.
        let mark: Int

        let closing: String
        let shift: Shift?
    }

    /// - Parameter strict: whether an element out of scope, or a tag that is
    ///   not HTML at all, fails the whole reduction. True for a block, whose
    ///   fallback is the source panel; false for prose, which has no fallback
    ///   and must draw something.
    private static func reduce(_ text: String, strict: Bool) -> Reduction? {
        var out = ""
        var stack: [Open] = []
        var alignment: MarkdownTable.Alignment?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            /// ⚠️ A code span is copied out whole, tags and all. Without this
            /// a README explaining that "`<br>` breaks a line" had the `<br>`
            /// inside its own backticks rewritten into an actual line break —
            /// the reduction eating the documentation of the thing it reduces.
            if character == "`" {
                index = copyCodeSpan(from: text, at: index, into: &out)
                continue
            }

            guard character == "<" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }

            /// An escaped `\<b\>` is a document showing markup rather than
            /// using it, and markdown's own escape has to survive a pass that
            /// runs before markdown does.
            if out.hasSuffix("\\") {
                out.append(character)
                index = text.index(after: index)
                continue
            }

            /// A comment inside prose is markup whose whole purpose is to be
            /// invisible, and an unterminated one takes the rest with it —
            /// the same reading `MarkdownRenderer` gives a comment block.
            if text[index...].hasPrefix("<!--") {
                guard let end = text.range(of: "-->", range: index..<text.endIndex) else { break }
                index = end.upperBound
                continue
            }

            guard let scanned = Tag.scan(text, from: index) else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            index = scanned.next

            guard let element = Element.named(scanned.tag.name) else {
                if strict { return nil }
                out += scanned.tag.source
                continue
            }
            if case .unsupported = element {
                if strict { return nil }
                out += scanned.tag.source
                continue
            }

            if alignment == nil { alignment = scanned.tag.alignment }

            if scanned.tag.isClosing {
                guard let position = stack.lastIndex(where: { $0.element == element }) else { continue }
                while stack.count > position {
                    out = close(stack.removeLast(), in: out)
                }
                continue
            }

            let entry = Self.open(element, tag: scanned.tag, into: &out)
            /// A void element holds nothing, and a self-closing tag closes
            /// itself — either way there is no content to wait for.
            if let entry {
                if scanned.tag.isSelfClosing {
                    out = close(entry, in: out)
                } else {
                    stack.append(entry)
                }
            }
        }

        /// An unclosed `<b>` still has to balance its `**`, or the delimiter
        /// leaks into the page as two asterisks.
        while let entry = stack.popLast() {
            out = close(entry, in: out)
        }

        return Reduction(text: out, alignment: alignment)
    }

    /// Copies a code span verbatim, and answers where it ended.
    ///
    /// CommonMark's rule: a run of *n* backticks is closed by the next run of
    /// exactly *n*. An opener with no closer is not a code span at all, and
    /// the honest thing to do with the rest of the text is leave it as
    /// written — which is what this does, since a stray backtick is far more
    /// likely to be prose than markup worth rewriting.
    private static func copyCodeSpan(from text: String, at start: String.Index, into out: inout String) -> String.Index {
        var index = start
        var opening = 0
        while index < text.endIndex, text[index] == "`" {
            opening += 1
            out.append("`")
            index = text.index(after: index)
        }

        while index < text.endIndex {
            guard text[index] == "`" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }

            var closing = 0
            while index < text.endIndex, text[index] == "`" {
                closing += 1
                out.append("`")
                index = text.index(after: index)
            }
            if closing == opening { break }
        }
        return index
    }

    /// Emits an element's opening text, and says what has to be remembered.
    ///
    /// Nil for anything that closes immediately: a break, a rule, an image.
    private static func open(_ element: Element, tag: Tag, into out: inout String) -> Open? {
        func entry(_ closing: String, shift: Shift? = nil) -> Open {
            Open(element: element, mark: out.count, closing: closing, shift: shift)
        }

        switch element {
        case .wrapper:
            return entry("")

        case let .delimited(delimiter):
            out += delimiter
            return entry(delimiter)

        case let .standalone(text):
            out += text
            return nil

        case let .heading(level):
            out += "\n\n" + String(repeating: "#", count: level) + " "
            return entry("\n\n")

        case .image:
            out += Self.image(tag)
            return nil

        case .anchor:
            /// An anchor with nowhere to go is a wrapper: `<a name="x">` is
            /// how a hand-written README plants a scroll target, and drawing
            /// `[]()` for it would put empty brackets in the prose.
            guard let destination = tag.destination(for: "href") else { return entry("") }
            out += "["
            return entry("](\(destination))")

        case let .shifted(shift):
            return entry("", shift: shift)

        case .unsupported:
            return nil
        }
    }

    /// Puts back what an element's closing tag owes: its delimiter, or the
    /// Unicode form of everything it wrapped.
    private static func close(_ entry: Open, in out: String) -> String {
        guard let shift = entry.shift else { return out + entry.closing }

        let mark = out.index(out.startIndex, offsetBy: min(entry.mark, out.count))
        let inner = String(out[mark...])
        /// Every character has to map or none does: `x²` is worth having and
        /// `x²ⁿᵗʰ` with two of the four characters shifted is worse than the
        /// plain text it came from.
        guard let mapped = shift.map(inner) else { return out }
        return String(out[..<mark]) + mapped
    }

    /// `<img>` as a markdown image.
    ///
    /// A `width` or `height` attribute is dropped rather than honoured: the
    /// renderer scales every image to the reader's measure, and a document
    /// asking for 800 points inside a 500-point column would be obeyed into
    /// a picture wider than the page.
    private static func image(_ tag: Tag) -> String {
        guard let source = tag.destination(for: "src") else { return "" }
        let alt = (tag.attributes["alt"] ?? "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "[", with: "")
        return "![\(alt)](\(source))"
    }

    // MARK: - Elements

    /// What this file does with one tag name.
    private enum Element: Equatable {
        /// Dropped; whatever it wrapped is kept.
        case wrapper

        /// Wrapped in a pair of markdown delimiters.
        case delimited(String)

        /// Holds nothing and emits its own text.
        case standalone(String)

        case heading(Int)
        case image
        case anchor

        /// Rewritten as Unicode, when every character it wrapped has a form.
        case shifted(Shift)

        /// Known HTML this cannot draw, and would misrepresent by trying.
        case unsupported

        static func named(_ name: String) -> Element? {
            if let mapped = mapped[name] { return mapped }
            return unsupportedTags.contains(name) ? .unsupported : nil
        }

        private static let mapped: [String: Element] = [
            "b": .delimited("**"), "strong": .delimited("**"),
            "i": .delimited("*"), "em": .delimited("*"),
            /// A key cap is not code, and a preview has nothing closer: both
            /// are "this is typed, not read", and both want the monospace
            /// face the reader already has for source.
            "code": .delimited("`"), "kbd": .delimited("`"), "samp": .delimited("`"),
            "var": .delimited("`"), "tt": .delimited("`"),
            "del": .delimited("~~"), "s": .delimited("~~"), "strike": .delimited("~~"),
            /// Two spaces and a newline is markdown's hard break, which is
            /// what `<br>` means. A bare newline would be a soft one and
            /// would come out as a space.
            "br": .standalone("  \n"),
            "wbr": .standalone(""),
            "hr": .standalone("\n\n---\n\n"),
            "img": .image,
            "a": .anchor,
            "sub": .shifted(.subscripted),
            "sup": .shifted(.superscripted),
            "h1": .heading(1), "h2": .heading(2), "h3": .heading(3),
            "h4": .heading(4), "h5": .heading(5), "h6": .heading(6),
            "p": .wrapper, "div": .wrapper, "center": .wrapper, "span": .wrapper,
            "figure": .wrapper, "figcaption": .wrapper, "picture": .wrapper,
            "small": .wrapper, "big": .wrapper, "u": .wrapper, "font": .wrapper,
            "abbr": .wrapper, "cite": .wrapper, "q": .wrapper, "ins": .wrapper,
            "mark": .wrapper, "nobr": .wrapper, "time": .wrapper, "data": .wrapper,
            "dfn": .wrapper, "bdi": .wrapper, "bdo": .wrapper,
        ]

        /// HTML whose meaning is its layout or its behaviour. Listed rather
        /// than inferred, so "this is out of scope" and "this is not HTML"
        /// stay two different answers — the first keeps the source panel, the
        /// second stays visible as text.
        private static let unsupportedTags: Set<String> = [
            "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
            "col", "colgroup", "ul", "ol", "li", "dl", "dt", "dd", "menu", "dir",
            "pre", "blockquote", "details", "summary", "dialog",
            "script", "style", "noscript", "template", "slot",
            "iframe", "embed", "object", "param", "applet", "svg", "canvas",
            "video", "audio", "source", "track", "map", "area",
            "form", "input", "button", "select", "option", "optgroup",
            "textarea", "label", "fieldset", "legend", "output", "progress", "meter",
            "html", "head", "body", "title", "base", "link", "meta",
            "header", "footer", "nav", "aside", "main", "article", "section",
            "address", "hgroup", "search", "ruby", "rt", "rp",
            "frame", "frameset", "noframes", "basefont", "marquee",
        ]
    }

    /// A baseline shift, and the characters that have one.
    ///
    /// Unicode rather than a font attribute because the reduction's output is
    /// markdown text, and text is all it can carry. The tables are
    /// deliberately short: these are the characters that appear in `H₂O`,
    /// `x²`, a footnote marker and an ordinal, and nothing else is worth
    /// half-rendering.
    private enum Shift: Equatable {
        case subscripted
        case superscripted

        func map(_ text: String) -> String? {
            let table = self == .subscripted ? Self.subscripts : Self.superscripts
            var result = ""
            for character in text {
                guard let mapped = table[character] else { return nil }
                result.append(mapped)
            }
            return result.isEmpty ? nil : result
        }

        private static let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "n": "ₙ",
        ]

        private static let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "n": "ⁿ", "i": "ⁱ", "s": "ˢ", "t": "ᵗ", "r": "ʳ",
            "d": "ᵈ", "h": "ʰ", "*": "*",
        ]
    }

    // MARK: - One tag

    /// A single tag, taken apart.
    private struct Tag {
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool

        /// Keyed by lowercased name; HTML attribute names are
        /// case-insensitive and every reader of this expects lowercase.
        var attributes: [String: String]

        /// The tag exactly as written, for the cases that put it back.
        var source: String

        /// A destination attribute, trimmed, and wrapped in angle brackets
        /// when it holds a space — which is CommonMark's own escape and the
        /// only way `<img src="my logo.png">` survives becoming a markdown
        /// link, where a space ends the destination.
        func destination(for key: String) -> String? {
            let raw = (attributes[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            return raw.contains(" ") ? "<\(raw)>" : raw
        }

        var alignment: MarkdownTable.Alignment? {
            let named = (attributes["align"] ?? "").lowercased()
            let style = (attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")

            func alignment(_ value: String) -> MarkdownTable.Alignment? {
                switch value {
                case "center", "centre", "middle": .center
                case "right", "end": .trailing
                case "left", "start": .leading
                default: nil
                }
            }

            if let found = alignment(named) { return found }
            guard let range = style.range(of: "text-align:") else { return nil }
            let value = style[range.upperBound...].prefix { $0.isLetter }
            return alignment(String(value))
        }

        /// Nil when this is not a tag: a `<` that opens nothing, a name that
        /// does not start with a letter, or a tag with no `>` before the end
        /// of the text.
        static func scan(_ text: String, from start: String.Index) -> (tag: Tag, next: String.Index)? {
            var index = text.index(after: start)
            guard index < text.endIndex else { return nil }

            var isClosing = false
            if text[index] == "/" {
                isClosing = true
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index].isLetter else { return nil }

            var name = ""
            while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "-" {
                name.append(text[index])
                index = text.index(after: index)
            }

            var attributes: [String: String] = [:]
            var isSelfClosing = false
            var isClosed = false

            while index < text.endIndex {
                let character = text[index]
                if character == ">" {
                    isClosed = true
                    index = text.index(after: index)
                    break
                }
                if character == "/" {
                    isSelfClosing = true
                    index = text.index(after: index)
                    continue
                }
                if character.isWhitespace {
                    index = text.index(after: index)
                    continue
                }

                var key = ""
                while index < text.endIndex, !"=/> \t\n\r".contains(text[index]) {
                    key.append(text[index])
                    index = text.index(after: index)
                }

                /// `align = "center"` is legal HTML, so the `=` is looked for
                /// past any spaces rather than at the character the name
                /// stopped on — which would read the value as another
                /// attribute and drop it.
                var probe = index
                while probe < text.endIndex, text[probe] == " " || text[probe] == "\t" {
                    probe = text.index(after: probe)
                }

                var value = ""
                if probe < text.endIndex, text[probe] == "=" {
                    index = text.index(after: probe)
                    while index < text.endIndex, text[index].isWhitespace {
                        index = text.index(after: index)
                    }
                    /// A quoted value is the only place a `>` can appear
                    /// without ending the tag, which is why this cannot be a
                    /// scan to the next `>`.
                    if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                        let quote = text[index]
                        index = text.index(after: index)
                        while index < text.endIndex, text[index] != quote {
                            value.append(text[index])
                            index = text.index(after: index)
                        }
                        if index < text.endIndex { index = text.index(after: index) }
                    } else {
                        while index < text.endIndex, !" \t\n\r>".contains(text[index]) {
                            value.append(text[index])
                            index = text.index(after: index)
                        }
                    }
                }

                if !key.isEmpty { attributes[key.lowercased()] = value }
            }

            guard isClosed else { return nil }

            let tag = Tag(
                name: name.lowercased(),
                isClosing: isClosing,
                isSelfClosing: isSelfClosing,
                attributes: attributes,
                source: String(text[start..<index])
            )
            return (tag, index)
        }
    }
}

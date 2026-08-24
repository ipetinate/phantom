import AppKit

/// The inline half of markdown: emphasis, code spans, links, images.
///
/// This is the part Foundation genuinely earns. `AttributedString(markdown:)`
/// resolves nested emphasis, escapes, autolinks, strikethrough, hard breaks
/// and reference links correctly, and every one of those is a small pile of
/// state nobody should hand-write twice. What it will not do is tell you
/// where a block started — see `MarkdownParser` — so the division is that
/// the blocks are found by hand and their prose is handed here.
///
/// Two things it will not do either, both found by reading its output rather
/// than its documentation, and both handled here before it is asked:
///
/// - **Inline HTML comes back as source.** A `<br>`, a `<kbd>`, an `<img>` in
///   a paragraph arrives as a run of literal text tagged `inlineHTML`. So the
///   markup is reduced to markdown first — see `MarkdownHTML`.
/// - **A link wrapping an image loses the image.** `[![alt](img)](href)` parses
///   to one run carrying the link and *no* `imageURL` at all, which is why a
///   README's logo line rendered as bare alt text. Only that shape is scanned
///   here; a plain `![alt](img)` is reported correctly and is left to
///   Foundation.
enum MarkdownInline {
    /// `text` is one block's prose; `definitions` are the document's
    /// `[label]: url` lines.
    static func render(
        _ text: String,
        style: MarkdownStyle,
        definitions: [MarkdownLinkDefinition] = [],
        baseURL: URL? = nil
    ) -> NSAttributedString {
        let prose = MarkdownHTML.prose(text)

        let linked = linkedImages(in: prose)
        guard !linked.isEmpty else {
            return parse(prose, style: style, definitions: definitions, baseURL: baseURL)
        }

        /// Split only where a linked image was actually found, so the ordinary
        /// paragraph keeps going through Foundation in one piece — emphasis
        /// spanning a segment boundary is a real cost, and one worth paying
        /// exactly on the line that needs it.
        let result = NSMutableAttributedString()
        var cursor = prose.startIndex
        for image in linked {
            if cursor < image.range.lowerBound {
                result.append(
                    parse(
                        String(prose[cursor..<image.range.lowerBound]),
                        style: style,
                        definitions: definitions,
                        baseURL: baseURL
                    )
                )
            }
            result.append(self.linked(image, style: style, baseURL: baseURL))
            cursor = image.range.upperBound
        }
        if cursor < prose.endIndex {
            result.append(
                parse(String(prose[cursor...]), style: style, definitions: definitions, baseURL: baseURL)
            )
        }
        return result
    }

    /// One stretch of prose, through Foundation.
    ///
    /// The definitions are appended to the string before parsing, which
    /// looks like a hack and is the only thing that can work: a reference
    /// link is resolved against definitions *in the same parse*, and this
    /// parser only ever sees one block at a time. They contribute no
    /// characters of their own, so the result is the block and nothing
    /// else.
    private static func parse(
        _ text: String,
        style: MarkdownStyle,
        definitions: [MarkdownLinkDefinition],
        baseURL: URL?
    ) -> NSAttributedString {
        let source = definitions.isEmpty
            ? text
            : text + "\n\n" + definitions.map(\.source).joined(separator: "\n")

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            /// Markdown has no syntax errors, so this is a parser that gave
            /// up rather than a document that was wrong — showing the text
            /// as typed beats showing nothing.
            return NSAttributedString(string: text, attributes: [
                .font: style.bodyFont,
                .foregroundColor: style.textColor,
            ])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed.characters[run.range])
            guard !piece.isEmpty else { continue }

            if let image = run.imageURL {
                result.append(self.image(at: image, alt: piece, style: style, baseURL: baseURL))
                continue
            }

            result.append(NSAttributedString(string: piece, attributes: attributes(for: run, style: style)))
        }
        return result
    }

    private static func attributes(
        for run: AttributedString.Runs.Run,
        style: MarkdownStyle
    ) -> [NSAttributedString.Key: Any] {
        let intent = run.inlinePresentationIntent ?? []
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.textColor,
        ]

        if intent.contains(.code) {
            attributes[.font] = style.codeFont
            attributes[.backgroundColor] = style.fillColor
        } else {
            attributes[.font] = font(
                style.bodyFont,
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized)
            )
        }

        if intent.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = style.secondaryColor
        }

        /// Markup that got past the reduction — a `<table>` in the middle of a
        /// sentence, a JSX component, a `Vec<String>` that only looks like a
        /// tag — is shown as the source it is rather than silently dropped.
        /// `MarkdownHTML` has already rewritten everything this build can draw,
        /// so what reaches here is exactly what it declined, and the reader can
        /// see there is markup there.
        if intent.contains(.inlineHTML) || intent.contains(.blockHTML) {
            attributes[.font] = style.codeFont
            attributes[.foregroundColor] = style.secondaryColor
        }

        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = style.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = style.linkColor.withAlphaComponent(0.4)
        }

        return attributes
    }

    static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }

        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    // MARK: - A link wrapping an image

    /// `[![alt](source)](destination)`, and where it sits in the prose.
    struct LinkedImage: Equatable {
        var range: Range<String.Index>
        var alt: String
        var source: String
        var destination: String
    }

    /// Every linked image in one block's prose, in order.
    ///
    /// A regular expression rather than a scanner because the shape is fixed
    /// and small, and because the interesting part is which forms are
    /// accepted: a title on either destination (`(a.png "Logo")`) and spaces
    /// inside the brackets, both of which a badge row in the wild uses.
    static func linkedImages(in text: String) -> [LinkedImage] {
        guard text.contains("[!["), let expression = linkedImageExpression else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let source = Range(match.range(at: 2), in: text),
                  let destination = Range(match.range(at: 3), in: text)
            else { return nil }

            let alt = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            return LinkedImage(
                range: whole,
                alt: alt,
                source: String(text[source]),
                destination: String(text[destination])
            )
        }
    }

    /// Both destinations accept CommonMark's angle-bracket form as well as a
    /// bare one, because that is how a path holding a space survives — see
    /// `MarkdownHTML`, which emits it.
    private static let linkedImageExpression = try? NSRegularExpression(
        pattern: #"\[\s*!\[([^\]]*)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)\s*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#
    )

    /// A linked image: the picture when it can be drawn, and what Foundation
    /// would have shown when it cannot.
    ///
    /// That fallback is deliberate rather than lazy. Nearly every linked image
    /// in a README is a badge — a remote SVG this preview declines to fetch —
    /// and a row of five "image: https://…" chips is worse to read than the
    /// row of labelled links the alt text already gives.
    private static func linked(
        _ image: LinkedImage,
        style: MarkdownStyle,
        baseURL: URL?
    ) -> NSAttributedString {
        let destination = URL(string: unbracketed(image.destination))

        if let source = URL(string: unbracketed(image.source)),
           let drawable = self.drawable(source, style: style, baseURL: baseURL) {
            let result = NSMutableAttributedString(attributedString: attachment(drawable, style: style))
            if let destination {
                result.addAttribute(.link, value: destination, range: NSRange(location: 0, length: result.length))
            }
            return result
        }

        guard !alt(image.alt).isEmpty else {
            return placeholder(alt: "", note: image.source, style: style, link: destination)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.textColor,
        ]
        if let destination {
            attributes[.link] = destination
            attributes[.foregroundColor] = style.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = style.linkColor.withAlphaComponent(0.4)
        }
        return NSAttributedString(string: alt(image.alt), attributes: attributes)
    }

    /// CommonMark's escape for a destination holding a space, which
    /// `MarkdownHTML` emits and a file path has to have removed again.
    private static func unbracketed(_ destination: String) -> String {
        guard destination.hasPrefix("<"), destination.hasSuffix(">") else { return destination }
        return String(destination.dropFirst().dropLast())
    }

    // MARK: - Images

    /// An image, drawn if it can be read off disk and named honestly if it
    /// cannot.
    ///
    /// The two failures are different and are worth telling apart in the
    /// text: a path that resolves to nothing is a broken link in the
    /// document, and a remote URL is one this preview declined to fetch —
    /// see `MarkdownStyle.loadsRemoteImages`. Drawing nothing for either
    /// would leave the reader wondering which.
    private static func image(
        at url: URL,
        alt: String,
        style: MarkdownStyle,
        baseURL: URL?
    ) -> NSAttributedString {
        if let image = drawable(url, style: style, baseURL: baseURL) {
            return attachment(image, style: style)
        }

        guard let resolved = resolve(url, against: baseURL), !resolved.isFileURL else {
            return placeholder(alt: alt, note: url.relativeString, style: style, link: nil)
        }
        return placeholder(alt: alt, note: resolved.absoluteString, style: style, link: resolved)
    }

    /// The picture a destination names, or nil when there is nothing to draw.
    ///
    /// A local file has to exist *and* decode: an `NSImage` refuses a `.webp`
    /// this system has no decoder for as flatly as it refuses a path that was
    /// mistyped, and both mean the same thing here — no picture. Nothing else
    /// in the app loads a markdown image, so there is no second path to keep
    /// in step: `MediaDocument` and `EditorSVGPane` both take a *whole
    /// document* and give it a pane, while this is one attachment inside a
    /// paragraph. What they establish is that `NSImage` is the app's loader,
    /// including for the SVG a README uses as its logo, and that is exactly
    /// what this asks.
    private static func drawable(_ url: URL, style: MarkdownStyle, baseURL: URL?) -> NSImage? {
        guard let resolved = resolve(url, against: baseURL) else { return nil }

        /// The one deliberate refusal. See `MarkdownStyle.loadsRemoteImages`:
        /// a preview re-renders while the reader types, and this is the line
        /// that keeps it from announcing the open file to a badge host on
        /// every keystroke.
        if !resolved.isFileURL {
            guard style.loadsRemoteImages else { return nil }
            return NSImage(contentsOf: resolved)
        }

        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return NSImage(contentsOf: resolved)
    }

    /// Relative paths resolve against the document's own directory, which
    /// is why the renderer has to be told where the file lives — `./docs/a.png`
    /// means nothing on its own.
    ///
    /// Joined with `appendingPathComponent` rather than
    /// `URL(fileURLWithPath:relativeTo:)`, which only appends when the base
    /// is known to be a directory: given a base with no trailing slash it
    /// treats the last component as a file and *replaces* it, so
    /// `docs/` + `./a.png` came out as a sibling of `docs`.
    private static func resolve(_ url: URL, against baseURL: URL?) -> URL? {
        if url.isFileURL { return url.standardizedFileURL }
        if url.scheme != nil { return url }

        let path = url.relativeString.removingPercentEncoding ?? url.relativeString
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }

        guard let baseURL else { return nil }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    private static func attachment(_ image: NSImage, style: MarkdownStyle) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image

        let size = image.size
        if size.width > 0, size.height > 0 {
            let scale = min(1, style.maxImageWidth / size.width)
            attachment.bounds = CGRect(
                x: 0,
                y: 0,
                width: (size.width * scale).rounded(),
                height: (size.height * scale).rounded()
            )
        }
        return NSAttributedString(attachment: attachment)
    }

    /// The alt text as a reader should see it.
    ///
    /// Foundation puts an object-replacement character where an image with no
    /// alt text stood, so `![](logo.png)` arrives with `U+FFFC` as its whole
    /// description — a glyph that draws as a hollow box and reads as
    /// corruption.
    private static func alt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func placeholder(
        alt: String,
        note: String,
        style: MarkdownStyle,
        link: URL?
    ) -> NSAttributedString {
        let described = self.alt(alt)
        let label = described.isEmpty ? note : "\(described) — \(note)"
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.codeFont,
            .foregroundColor: style.secondaryColor,
            .backgroundColor: style.fillColor,
        ]
        if let link {
            attributes[.link] = link
            attributes[.foregroundColor] = style.linkColor
        }
        return NSAttributedString(string: " image: \(label) ", attributes: attributes)
    }
}

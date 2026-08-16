import AppKit

/// The inline half of markdown: emphasis, code spans, links, images.
///
/// This is the part Foundation genuinely earns. `AttributedString(markdown:)`
/// resolves nested emphasis, escapes, autolinks, strikethrough, hard breaks
/// and reference links correctly, and every one of those is a small pile of
/// state nobody should hand-write twice. What it will not do is tell you
/// where a block started — see `MarkdownParser` — so the division is that
/// the blocks are found by hand and their prose is handed here.
enum MarkdownInline {
    /// `text` is one block's prose; `definitions` are the document's
    /// `[label]: url` lines.
    ///
    /// The definitions are appended to the string before parsing, which
    /// looks like a hack and is the only thing that can work: a reference
    /// link is resolved against definitions *in the same parse*, and this
    /// parser only ever sees one block at a time. They contribute no
    /// characters of their own, so the result is the block and nothing
    /// else.
    static func render(
        _ text: String,
        style: MarkdownStyle,
        definitions: [MarkdownLinkDefinition] = [],
        baseURL: URL? = nil
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

        /// Raw HTML inside prose — a `<br>` or a `<kbd>` — is shown as the
        /// source it is rather than silently dropped. The reader can see
        /// there is markup there, which is the honest reading of a preview
        /// that does not run a browser.
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
        guard let resolved = resolve(url, against: baseURL) else {
            return placeholder(alt: alt, note: url.relativeString, style: style, link: nil)
        }

        if !resolved.isFileURL {
            guard style.loadsRemoteImages, let remote = NSImage(contentsOf: resolved) else {
                return placeholder(alt: alt, note: resolved.absoluteString, style: style, link: resolved)
            }
            return attachment(remote, style: style)
        }

        guard FileManager.default.fileExists(atPath: resolved.path),
              let image = NSImage(contentsOf: resolved)
        else {
            return placeholder(alt: alt, note: url.relativeString, style: style, link: nil)
        }
        return attachment(image, style: style)
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

    private static func placeholder(
        alt: String,
        note: String,
        style: MarkdownStyle,
        link: URL?
    ) -> NSAttributedString {
        let label = alt.isEmpty ? note : "\(alt) — \(note)"
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

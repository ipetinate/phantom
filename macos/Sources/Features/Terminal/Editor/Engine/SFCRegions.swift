import Foundation

/// Splits a document made of several languages into the languages it is
/// actually made of.
///
/// A `.vue` file is not one language. Lexing the whole thing as JavaScript —
/// which is what happens when the extension maps straight to it — colours
/// `class` in the template as a JavaScript keyword, leaves every HTML tag
/// plain, and does nothing at all with the stylesheet. Three regions, three
/// rule sets. An HTML document has the same problem in the other direction:
/// lexed as markup from end to end, the `<script>` block's `const` and `//`
/// are not code and every `name =` in it is painted as an *attribute*.
///
/// **The boundary rule differs by container, and that is the whole reason
/// there are two.** An SFC's blocks start at column zero — that is how the
/// splitter tells the file's own `<template>` from a `<template #slot>`
/// nested inside it, which is indented, always, because it is inside
/// something. An HTML document's `<script>` is indented too, inside `<head>`
/// or `<body>`, so the same rule would find nothing there. It is a
/// convention rather than a parse in both cases, so the failure mode is
/// worth stating: in an SFC a nested block written flush to the left margin
/// would end the outer one early, and in HTML a `<script>` written inside a
/// comment is still found. Every formatter in this ecosystem indents the
/// nested block, and the alternative is carrying a real HTML parser to
/// colour text.
///
/// **This is a colouring-pass tool, and the colouring pass runs on every
/// keystroke** — `CodeTextStorage` re-highlights the edited line, which asks
/// here first. That is why the answer is cached: measured with
/// `ContinuousClock`, `-O`, 50 iterations, one scan of a 5000-line SFC
/// (226 KB) costs **2.9 ms**, and it is the *scanning* that costs it, not the
/// compiling — hoisting the three expressions into statics moved 2907 µs to
/// 2893 µs. Comparing the document against the last one costs 110 µs at the
/// same size and usually far less, since a length that differs settles it.
/// Anything reacting to a keypress still wants a probe rather than a
/// partition where one will do; `CodeTagClose` carries one.
enum SFCRegions {
    struct Region: Equatable {
        let range: NSRange
        let language: CodeLanguage
    }

    /// A document that holds other languages, and how its blocks are found.
    enum Container: Equatable, Sendable {
        /// `.vue` and `.svelte`: template, script and style, at column zero.
        case singleFileComponent

        /// An HTML document: `<script>` and `<style>` wherever they sit, and
        /// markup everywhere else. No `<template>` — in HTML that element
        /// holds markup, which is what the document is already lexed as.
        case markup
    }

    /// The container a language is, or nil for a language that is only
    /// itself.
    ///
    /// Asked by the highlighter before it lexes anything, so this is the one
    /// place that decides which file types are made of blocks.
    static func container(of language: CodeLanguage) -> Container? {
        switch language {
        case .vue: return .singleFileComponent
        case .html: return .markup
        default: return nil
        }
    }

    /// The block names a container can have, and what is inside them.
    ///
    /// `<script>` covers `<script setup>`, `<script lang="ts">` and
    /// `<script type="text/babel">` alike: the attributes change what the
    /// compiler does, not how the body is lexed. `<style>` covers
    /// `lang="scss"` for the same reason — the CSS rules already understand
    /// nesting and `//` comments.
    private static func blocks(of container: Container) -> [(name: String, language: CodeLanguage)] {
        switch container {
        case .singleFileComponent:
            return [("template", .html), ("script", .javascript), ("style", .css)]
        case .markup:
            return [("script", .javascript), ("style", .css)]
        }
    }

    /// Finds each top-level block, in the order they appear.
    ///
    /// Text between or around the blocks is not claimed here: what to do with
    /// it is the container's business, and the two containers answer
    /// differently — an SFC's frame is a frame, an HTML document's is the
    /// document.
    static func regions(in text: String, of container: Container = .singleFileComponent) -> [Region] {
        cache.regions(in: text, of: container)
    }

    /// Which language a given offset falls in, or nil for the frame that
    /// holds the blocks together.
    static func language(
        at offset: Int,
        in text: String,
        of container: Container = .singleFileComponent
    ) -> CodeLanguage? {
        regions(in: text, of: container)
            .first { NSLocationInRange(offset, $0.range) }?
            .language
    }

    private static func scan(_ text: String, _ container: Container) -> [Region] {
        let ns = text as NSString
        var found: [Region] = []

        for block in patterns(of: container) {
            block.pattern.enumerateMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let match else { return }
                // Group 1 is the body: the tags themselves belong to the
                // markup around them, not to the language inside.
                let body = match.range(at: 1)
                guard body.location != NSNotFound, body.length > 0 else { return }
                found.append(Region(range: body, language: block.language))
            }
        }

        return found.sorted { $0.range.location < $1.range.location }
    }

    /// One expression per block, built once per container.
    ///
    /// The SFC form anchors both tags to the start of a line; the markup form
    /// anchors neither and is case-insensitive, because `<SCRIPT>` is a
    /// perfectly ordinary thing to find in an HTML file and `<script>` inside
    /// `<head>` is indented in every one of them.
    ///
    /// A `</script>` inside a JavaScript string ends the block here. That is
    /// not a bug being tolerated — it is what a browser does with the same
    /// bytes, which is why `"<\/script>"` is written the way it is.
    private static func patterns(
        of container: Container
    ) -> [(language: CodeLanguage, pattern: NSRegularExpression)] {
        switch container {
        case .singleFileComponent: return componentPatterns
        case .markup: return markupPatterns
        }
    }

    private static let componentPatterns = compile(.singleFileComponent) { name in
        (pattern: "^<\(name)(?:\\s[^>]*)?>([\\s\\S]*?)^</\(name)>", options: [.anchorsMatchLines])
    }

    private static let markupPatterns = compile(.markup) { name in
        (
            pattern: "<\(name)(?:\\s[^>]*)?>([\\s\\S]*?)</\(name)\\s*>",
            options: [.caseInsensitive]
        )
    }

    private static func compile(
        _ container: Container,
        _ form: (String) -> (pattern: String, options: NSRegularExpression.Options)
    ) -> [(language: CodeLanguage, pattern: NSRegularExpression)] {
        blocks(of: container).compactMap { block in
            let shape = form(block.name)
            guard let pattern = try? NSRegularExpression(
                pattern: shape.pattern,
                options: shape.options
            ) else { return nil }
            return (language: block.language, pattern: pattern)
        }
    }

    private static let cache = Cache()

    /// The last few documents' answers.
    ///
    /// Keyed by the document text itself, which is the identity of the thing
    /// being cached — same text, same blocks — and the only key available:
    /// `regions(in:)` is handed a string and knows nothing about versions or
    /// file names. Comparing strings is what makes that affordable, and it is
    /// affordable because the comparison is the cheap operation here: 110 µs
    /// against 2.9 ms for the scan it replaces, and a length that differs
    /// answers without reading a character.
    ///
    /// Four entries rather than one because a split view highlights two
    /// documents and both redraw on any layout change, so a single slot would
    /// be evicted by the other pane between two keystrokes in this one. Four
    /// rather than unbounded because each entry holds a document alive.
    private final class Cache: @unchecked Sendable {
        private static let ceiling = 4

        private struct Entry {
            let text: String
            let container: Container
            let regions: [Region]
        }

        private var entries: [Entry] = []
        private let lock = NSLock()

        func regions(in text: String, of container: Container) -> [Region] {
            lock.lock()
            if let hit = entries.first(where: { $0.container == container && $0.text == text }) {
                lock.unlock()
                return hit.regions
            }
            lock.unlock()

            /// Scanned outside the lock. Two threads asking about the same
            /// document at once do the work twice, which costs a scan; doing
            /// it inside would make every *other* document wait behind a
            /// 2.9 ms answer it does not want.
            let found = SFCRegions.scan(text, container)

            lock.lock()
            entries.insert(Entry(text: text, container: container, regions: found), at: 0)
            if entries.count > Self.ceiling { entries.removeLast(entries.count - Self.ceiling) }
            lock.unlock()

            return found
        }
    }
}

/// The tokens of a single-file component's own block tags.
///
/// `<script setup lang="ts">` drew as plain text, and so did
/// `<template lang="pug">` and `<style scoped lang="scss">`. ``SFCRegions``
/// leaves the tags outside the block on purpose — they are markup, not
/// script — and the container they are markup *of* has no rules at all:
/// `.vue` answers with an empty ``SyntaxRules``, so the frame lexed to
/// nothing.
///
/// **Taken apart here rather than given a rule set, and the reason is the
/// other container's documented failure.** Markup's rules read "a name
/// before an equals sign" as an attribute, and an SFC's frame is not only
/// its tags: a `<script>` block still being typed has no closing tag, so
/// ``SFCRegions`` declines to claim it and the whole of it arrives here as
/// frame. Markup's rules would paint every assignment in it. A block tag is
/// one line with a fixed shape, so its pieces are found and named instead.
///
/// The `<`, `>` and `=` become ``TokenKind/punctuation``, which nothing else
/// in this build produces and which every theme already carries a colour
/// for.
enum SFCBlockTag {
    /// `<script setup lang="ts">`, `</script>`, and a custom block's
    /// `<i18n>` alike — any tag written flush to the left margin.
    ///
    /// Column zero is ``SFCRegions``' own convention, and it is what keeps a
    /// `<div>` in the template out of this: the template's markup is a
    /// region lexed by HTML's rules, and only the frame between the regions
    /// is offered here.
    ///
    /// A quoted value may hold a `>`, so the attribute run alternates quoted
    /// runs with plain characters rather than taking everything up to the
    /// first `>`. Neither crosses a line: an unterminated quote in a file
    /// being typed would otherwise swallow the rest of it.
    private static let tag = try? NSRegularExpression(
        pattern: #"^<(/?)([A-Za-z][A-Za-z0-9-]*)((?:"[^"\n]*"|'[^'\n]*'|[^>"'\n])*)>"#,
        options: [.anchorsMatchLines]
    )

    /// One attribute of a block tag: `setup` on its own, or `lang="ts"`.
    private static let attribute = try? NSRegularExpression(
        pattern: #"([A-Za-z_:@][-A-Za-z0-9_:.]*)(?:\s*(=)\s*("[^"\n]*"|'[^'\n]*'|[^\s"'>]+))?"#
    )

    static func tokens(in text: String, range: NSRange) -> [SyntaxHighlighter.Token] {
        guard let tag else { return [] }

        var tokens: [SyntaxHighlighter.Token] = []
        /// `withoutAnchoringBounds` so `^` keeps meaning a line of the
        /// document. Without it the anchor also matches wherever the range
        /// begins, and the editor's ranges begin mid-line — they are the
        /// edited line padded by a screenful either side.
        tag.enumerateMatches(
            in: text,
            options: [.withoutAnchoringBounds],
            range: range
        ) { match, _, _ in
            guard let match else { return }
            let whole = match.range(at: 0)
            let name = match.range(at: 2)
            let attributes = match.range(at: 3)

            tokens.append(
                SyntaxHighlighter.Token(
                    range: NSRange(
                        location: whole.location,
                        length: 1 + match.range(at: 1).length),
                    kind: .punctuation)
            )
            if name.length > 0 {
                tokens.append(SyntaxHighlighter.Token(range: name, kind: .keyword))
            }
            if attributes.length > 0 {
                tokens += attributeTokens(in: text, range: attributes)
            }
            tokens.append(
                SyntaxHighlighter.Token(
                    range: NSRange(location: NSMaxRange(whole) - 1, length: 1),
                    kind: .punctuation)
            )
        }
        return tokens
    }

    private static func attributeTokens(
        in text: String,
        range: NSRange
    ) -> [SyntaxHighlighter.Token] {
        guard let attribute else { return [] }

        let kinds: [(group: Int, kind: TokenKind)] = [
            (1, .attribute),
            (2, .punctuation),
            (3, .string),
        ]

        var tokens: [SyntaxHighlighter.Token] = []
        attribute.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for (group, kind) in kinds {
                let found = match.range(at: group)
                guard found.location != NSNotFound, found.length > 0 else { continue }
                tokens.append(SyntaxHighlighter.Token(range: found, kind: kind))
            }
        }
        return tokens
    }
}

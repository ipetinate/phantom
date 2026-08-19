import Foundation

/// The Markdown constructs people type by hand, as snippet bodies.
///
/// A catalogue, not an engine: every body here is a string in the grammar
/// `CodeSnippet.parse` already reads, and every row is an ordinary
/// `CodeCompletionItem` with `isSnippet` set. Nothing in this file inserts
/// text, moves a caret or knows what a window is — it answers "what could be
/// offered here", and the view that already accepts snippets does the rest.
///
/// **The hard part of Markdown completion is not the list, it is the
/// silence.** Every other language this editor completes is made of
/// identifiers, so a list that opens on any word is a list that opens on
/// something you meant. Markdown is made of sentences: `table`, `link`,
/// `image`, `quote` and `code` are words people write *about* things at least
/// as often as they are markup somebody is reaching for. A catalogue that
/// fires on all of them turns writing a paragraph into dismissing a popup,
/// which is worse than having no snippets at all — and in this editor it is
/// worse than that again, for a reason spelled out on
/// `trigger(line:caretInLine:)`, which is where the whole question is settled
/// and is deliberately the most-tested thing here.
enum MarkdownSnippets {
    /// Which catalogue a file gets.
    ///
    /// A separate axis from `CodeLanguage`, which folds `.mdx` into
    /// `.markdown` — correctly, because the two are lexed identically at the
    /// level the highlighter works at. They are *not* completed identically:
    /// an `import` line is right in one and prose in the other, so the
    /// distinction the highlighter can throw away has to be kept here.
    enum Flavor: String, CaseIterable, Equatable, Sendable {
        case markdown
        case mdx
    }

    /// One offer: what you type, what it inserts, and what the row says.
    ///
    /// The body is the single source of truth for the row *and* its
    /// documentation — the card's preview is `CodeSnippet.parse(body).text`
    /// rather than a second copy of the expansion written by hand. A stored
    /// preview is a copy that drifts, and it drifts silently: the row keeps
    /// promising the old shape while inserting the new one.
    struct Entry: Equatable, Sendable {
        /// The word that summons it. Also the row's label — these are the same
        /// string on purpose, so what you type and what you read can never be
        /// two facts that disagree.
        let trigger: String

        /// The right-hand column.
        let detail: String

        /// One line of prose for the documentation card, above the preview.
        let summary: String

        /// The snippet body, in `CodeSnippet`'s grammar.
        let body: String

        /// Stable across launches and across a refilter, and distinct from
        /// anything a server could hand back — `documentation(for:)` looks
        /// rows up by it.
        var id: String { "markdown-snippet:\(trigger)" }

        /// The row, optionally told which span of the document it replaces.
        ///
        /// `replacing` matters more here than for an ordinary completion: the
        /// span the user typed begins with a `/` that has to disappear with
        /// the insertion, and the view's own fallback — the identifier
        /// characters behind the caret — cannot see a slash.
        func item(replacing range: NSRange? = nil) -> CodeCompletionItem {
            CodeCompletionItem(
                kind: .snippet,
                label: trigger,
                detail: detail,
                insertText: body,
                replaceRange: range,
                isSnippet: true,
                source: .keyword,
                id: id
            )
        }
    }

    // MARK: The catalogue

    /// Plain Markdown, in the order they were written rather than the order
    /// they will be shown — ranking is `CodeCompletionFilter`'s job, and a
    /// second opinion here would be one more thing to keep in step.
    static let markdownEntries: [Entry] = [
        Entry(
            trigger: "code",
            detail: "Fenced code block",
            summary: "A fenced block, with the language first so the highlighter has it before you start typing.",
            body: """
            ```${1:swift}
            $0
            ```
            """
        ),
        Entry(
            trigger: "table",
            detail: "Table (2 columns)",
            summary: "Header, separator, one row. The separator is the line nobody remembers, and the one that decides whether any of it renders as a table at all.",
            body: """
            | ${1:Column} | ${2:Column} |
            | --- | --- |
            | ${3:Cell} | ${4:Cell} |
            $0
            """
        ),
        Entry(
            trigger: "link",
            detail: "Inline link",
            summary: "Text first, destination second — the order you think in.",
            body: "[${1:text}](${2:https://})$0"
        ),
        Entry(
            trigger: "image",
            detail: "Image",
            summary: "The bang is the whole difference from a link, and it is the character that gets left off.",
            body: "![${1:alt}](${2:path})$0"
        ),
        Entry(
            trigger: "reflink",
            detail: "Reference link and its definition",
            summary: "Both halves at once. A reference with no definition renders as literal brackets, and it renders that way three paragraphs from where you were looking.",
            body: """
            [${1:text}][${2:label}]

            [${2}]: ${3:https://}$0
            """
        ),
        Entry(
            trigger: "task",
            detail: "Task list item",
            summary: "An unchecked box. The space between the brackets is load-bearing.",
            body: "- [ ] ${1:task}$0"
        ),
        Entry(
            trigger: "quote",
            detail: "Blockquote",
            summary: "One quoted line.",
            body: "> ${1:quote}$0"
        ),
        Entry(
            trigger: "details",
            detail: "Collapsible section",
            summary: "HTML, because Markdown has no fold of its own. The blank lines around the body are what let the Markdown inside it render.",
            body: """
            <details>
            <summary>${1:Summary}</summary>

            ${2:Details}

            </details>
            $0
            """
        ),
        Entry(
            trigger: "frontmatter",
            detail: "YAML front matter",
            summary: "Only valid as the very first thing in the file — anywhere else the fences render as horizontal rules.",
            body: """
            ---
            title: ${1:Title}
            ---

            $0
            """
        ),
        Entry(
            trigger: "footnote",
            detail: "Footnote and its definition",
            summary: "Reference and definition together, for the same reason as the reference link: the half that is easy to forget is the half that breaks the render.",
            body: """
            [^${1:note}]

            [^${1}]: ${2:Explanation}
            $0
            """
        ),
        Entry(
            trigger: "hr",
            detail: "Horizontal rule",
            summary: "Three hyphens on their own line, with a blank line after so the next paragraph is not read as a heading underline.",
            body: """
            ---

            $0
            """
        ),
        Entry(
            trigger: "bold",
            detail: "Bold text",
            summary: "Two asterisks each side.",
            body: "**${1:text}**$0"
        ),
        Entry(
            trigger: "italic",
            detail: "Italic text",
            summary: "One asterisk each side.",
            body: "*${1:text}*$0"
        ),
        Entry(
            trigger: "strike",
            detail: "Struck-through text",
            summary: "Two tildes each side.",
            body: "~~${1:text}~~$0"
        ),
        heading(level: 1),
        heading(level: 2),
        heading(level: 3),
        heading(level: 4),
        heading(level: 5),
        heading(level: 6),
    ]

    /// The MDX-only half: Markdown plus JSX.
    ///
    /// Kept as a second array rather than merged in, so a `.md` file is never
    /// offered an `import`. **MDX gets everything Markdown gets** — a `.mdx`
    /// file is a Markdown file that can also do this — which is why
    /// `entries(for:)` concatenates rather than switches.
    static let jsxEntries: [Entry] = [
        Entry(
            trigger: "import",
            detail: "Import a component",
            summary: "MDX imports sit at the top of the file, above the prose.",
            body: """
            import ${1:Component} from '${2:./components/Component}'
            $0
            """
        ),
        Entry(
            trigger: "export",
            detail: "Export a constant",
            summary: "Metadata by export, which is how MDX carries it when the toolchain does not read YAML front matter.",
            body: """
            export const ${1:name} = ${2:value}

            $0
            """
        ),
        Entry(
            trigger: "component",
            detail: "JSX element with children",
            summary: "The closing tag repeats the opening name, which is the edit people forget when they rename one.",
            body: """
            <${1:Component}>
              ${2:children}
            </${1}>$0
            """
        ),
        Entry(
            trigger: "expr",
            detail: "JSX expression",
            summary: "Braces around a JavaScript expression, evaluated where it stands.",
            body: "{${1:expression}}$0"
        ),
    ]

    /// `#` through `######`, built rather than written out six times.
    private static func heading(level: Int) -> Entry {
        Entry(
            trigger: "h\(level)",
            detail: "Heading \(level)",
            summary: "A level-\(level) heading, with a blank line after it.",
            body: """
            \(String(repeating: "#", count: level)) ${1:Heading}

            $0
            """
        )
    }

    static func entries(for flavor: Flavor) -> [Entry] {
        switch flavor {
        case .markdown: return markdownEntries
        case .mdx: return markdownEntries + jsxEntries
        }
    }

    /// The rows, all of them replacing the same span.
    ///
    /// One range for the whole list because there is only one thing being
    /// replaced — the trigger the user typed — and every row replaces it.
    ///
    /// `nil` is the **explicit-invocation** shape: on ⌃Space there is no
    /// slash to swallow, so the rows have no opinion about their span and the
    /// view falls back to the word behind the caret, which is exactly right
    /// there.
    static func items(for flavor: Flavor, replacing range: NSRange? = nil) -> [CodeCompletionItem] {
        entries(for: flavor).map { $0.item(replacing: range) }
    }

    /// The rows for a trigger found on a line, with the trigger's span placed
    /// in the document.
    ///
    /// The arithmetic is here rather than at the call site because it is the
    /// one step in wiring this up that can be wrong without looking wrong:
    /// `Trigger.range` is measured in the line, the item needs it measured in
    /// the document, and an insertion at the wrong offset eats a character of
    /// somebody's paragraph.
    static func items(for flavor: Flavor, trigger: Trigger, lineStart: Int) -> [CodeCompletionItem] {
        items(
            for: flavor,
            replacing: NSRange(
                location: lineStart + trigger.range.location,
                length: trigger.range.length
            )
        )
    }

    /// What the documentation card should say about one of these rows, or nil
    /// when the row did not come from here.
    ///
    /// The preview is the parsed body — literally what will land in the
    /// file — so it cannot describe a shape the snippet does not insert.
    static func documentation(for item: CodeCompletionItem) -> CodeDocumentation? {
        guard let entry = byID[item.id] else { return nil }
        return CodeDocumentation(
            format: .plainText,
            text: "\(entry.summary)\n\n\(CodeSnippet.parse(entry.body).text)"
        )
    }

    private static let byID: [String: Entry] = Dictionary(
        uniqueKeysWithValues: (markdownEntries + jsxEntries).map { ($0.id, $0) }
    )

    /// Which catalogue a file name asks for, or nil when it asks for none.
    ///
    /// Nil rather than `.markdown` for everything else, because "not a
    /// Markdown file" and "a Markdown file" are the two answers the caller has
    /// to tell apart before it offers anything at all.
    static func flavor(forFileName fileName: String) -> Flavor? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "mdx": return .mdx
        default: return nil
        }
    }

    // MARK: Not firing in prose

    /// A trigger the user actually typed, and the span to replace.
    struct Trigger: Equatable, Sendable {
        /// UTF-16 offsets **into the line**, and **including the `/`** — the
        /// slash is part of what the insertion replaces, so a row accepted
        /// here leaves no sigil behind in the file.
        var range: NSRange

        /// What to match rows against, without the slash.
        ///
        /// Empty is a real and useful state: a bare `/` means "show me
        /// everything", which is how somebody learns these triggers without
        /// being told them.
        var query: String
    }

    /// Whether the catalogue may open here, and on what.
    ///
    /// **One way in, and it is a `/`.** Nothing anybody can type as prose
    /// opens this list — you ask for it with a character that is never part of
    /// a word.
    ///
    /// That is stricter than it looks like it needs to be, and the reason is
    /// `CodeTextView.completionCommand`: **while a list is open,
    /// Return accepts the highlighted row.** Return is the most-pressed key in
    /// a document made of paragraphs. Any implicit trigger is therefore live
    /// at precisely the moment the user is about to press the key that
    /// accepts — a line ending in the word `code` becomes a fenced block, a
    /// bullet reading `- link` becomes `[text](https://)` — and the damage
    /// lands in the file rather than on the screen. Every softer rule that was
    /// considered has this shape: "at the start of a line's content, lowercase
    /// only, nothing after the caret" is a good filter for prose *and* an
    /// exact description of the caret's position when someone finishes a line.
    /// The two overlap perfectly, which is what rules it out.
    ///
    /// What the slash costs is discoverability, and that is paid for twice
    /// over: a bare `/` lists the whole catalogue, and explicit invocation —
    /// ⌃Space, via `items(for:replacing:)` with no span — offers everything
    /// with no slash at all. What it buys is that the list can never open
    /// while someone is writing English.
    ///
    /// The boundary check is not decoration. Without it `https://tab`,
    /// `docs/table`, `and/or` and `24/7` all open a list, which would put the
    /// one escape hatch straight back into the middle of ordinary prose. The
    /// rule is that the character before the slash must not be a word
    /// character or another slash; punctuation, whitespace and the start of
    /// the line all qualify.
    ///
    /// What it cannot see is the document. A line inside a fenced code block
    /// looks like any other line from here, and suppressing there is the
    /// caller's call — it is the side that knows where the fences are.
    static func trigger(line: String, caretInLine: Int) -> Trigger? {
        let text = line as NSString
        let caret = max(0, min(caretInLine, text.length))

        var start = caret
        while start > 0, isTriggerCharacter(text.character(at: start - 1)) {
            start -= 1
        }

        guard start > 0, text.character(at: start - 1) == slash else { return nil }
        let sigil = start - 1

        if sigil > 0 {
            let before = text.character(at: sigil - 1)
            guard before != slash, !isTriggerCharacter(before) else { return nil }
        }

        return Trigger(
            range: NSRange(location: sigil, length: caret - sigil),
            query: text.substring(with: NSRange(location: start, length: caret - start))
        )
    }

    private static let slash: unichar = 0x2F

    /// Letters and digits, which is every character any trigger is made of.
    ///
    /// Narrower than `CodeCompletionTrigger.isIdentifier` by `_` and `$`, on
    /// purpose: neither appears in a trigger, and both are likelier to be code
    /// or prose here than the tail of one — `path/to_thing` should be a word
    /// ending in `to_thing` for the boundary check to reject, not a trigger
    /// called `thing`.
    ///
    /// A surrogate half stops the scan, as it does in `CodeSnippet`: on its
    /// own it is not a character, and no trigger is spelled with one.
    private static func isTriggerCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        let character = Character(scalar)
        return character.isLetter || character.isNumber
    }
}

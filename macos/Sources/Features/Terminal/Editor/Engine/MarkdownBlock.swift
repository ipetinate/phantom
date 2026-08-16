import Foundation

/// A markdown document reduced to blocks.
///
/// The split is the whole design. Foundation can already do the *inline*
/// half of markdown — emphasis, links, code spans, images — and does it
/// well; what it will not hand back is a structure you can lay out, because
/// an `AttributedString` is one flat run of characters with attributes on
/// it and a document is a stack of things with different shapes. So the
/// blocks are found here, and each block's prose is handed to Foundation
/// afterwards.
///
/// Everything in this file is a value with no behaviour beyond arithmetic
/// on what it already holds, which is what lets `MarkdownParser` be a pure
/// function and the tests be a list of strings and expectations.
struct MarkdownDocument: Equatable {
    var blocks: [MarkdownBlock] = []

    /// `[label]: https://…` definitions, lifted out of the text.
    ///
    /// They are not prose and must not be drawn, but they cannot simply be
    /// dropped either: a README's badge row is usually
    /// `[![build](img)][ci]` with the destinations collected at the bottom
    /// of the file, and an inline parser handed one paragraph at a time has
    /// no way to resolve them. The renderer appends these to whatever block
    /// it is about to parse, which is what makes the reference form work at
    /// all.
    var linkDefinitions: [MarkdownLinkDefinition] = []

    /// The dialect this was parsed as.
    ///
    /// Kept on the document because the *renderer* needs it and the parser
    /// is the only thing that knows: an uppercase tag is a JSX component
    /// worth labelling as unrendered in an `.mdx` file, and ordinary markup
    /// not worth remarking on in a `.md` one.
    var flavor: MarkdownParser.Flavor = .markdown

    var isEmpty: Bool { blocks.isEmpty }
}

/// One block, and where in the file it came from.
struct MarkdownBlock: Equatable {
    /// What the block *is*. Deliberately a closed set: these are the
    /// constructs a README actually uses, and a kind nothing can draw is a
    /// kind that will be drawn wrong.
    indirect enum Kind: Equatable {
        /// `# Title`, or a setext underline. Level is 1...6.
        case heading(level: Int, text: String)

        /// Prose. Newlines are kept, because the inline pass is the one
        /// that knows a single newline is a space and a two-space ending
        /// is a line break.
        case paragraph(text: String)

        case code(MarkdownCodeBlock)
        case list(MarkdownList)

        /// A block quote holds blocks, not text: `> ## Note` is a heading
        /// inside a quote, and flattening it to prose loses that.
        case quote([MarkdownBlock])

        case table(MarkdownTable)
        case thematicBreak

        /// Raw HTML, and the same door MDX's JSX comes through.
        case html(String)

        /// The `---` fenced YAML a static site generator puts at the top.
        case frontMatter(String)

        /// MDX's `import`/`export` lines.
        ///
        /// Not prose and not markdown; drawn as what they are — code —
        /// because the alternative is a paragraph reading
        /// "import Callout from '../components'", which is worse than
        /// either hiding it or admitting what it is.
        case script(String)
    }

    var kind: Kind

    /// The source lines this block was built from: zero-based, inclusive,
    /// counted in the document the parser was handed.
    ///
    /// Carried because the preview is meant to sit *beside* the raw text in
    /// a split, and scrolling one side has to find the other side's
    /// matching place. Glyphs alone leave nothing to match on, and the
    /// mapping cannot be recovered afterwards — an `AttributedString`
    /// carries no offsets back to the markdown that produced it. Cheap to
    /// record here, impossible to reconstruct later.
    var sourceLines: ClosedRange<Int>
}

/// A fenced or indented code block.
struct MarkdownCodeBlock: Equatable {
    /// The fence's info string, verbatim and untrimmed of its own content:
    /// `swift`, or `ts title="app.ts"`. Nil for an indented block, which
    /// has nowhere to say.
    var info: String?

    /// The code, without the fences and without the block's own indent.
    var code: String

    /// False when the fence ran to the end of the file without a closer.
    ///
    /// The normal state of a file somebody is halfway through typing, and
    /// worth keeping rather than repairing: the preview can mark it, and
    /// the alternative — treating the rest of the document as prose —
    /// makes the whole page flicker between two layouts on one keystroke.
    var isClosed: Bool = true

    /// The first word of the info string, lowercased.
    ///
    /// What a highlighter can act on. `ts title="app.ts"` is a real fence
    /// in a docs site and its language is `ts`, so the rest is dropped
    /// rather than being looked up and missed.
    var languageHint: String? {
        guard let info else { return nil }
        let word = info
            .trimmingCharacters(in: .whitespaces)
            .prefix { !$0.isWhitespace && $0 != "," }
        return word.isEmpty ? nil : word.lowercased()
    }
}

/// A bullet or numbered list at one level of nesting.
///
/// Nesting is *recursive*, not a depth number: a nested list is a `.list`
/// block inside its parent item's `blocks`. That costs nothing here and
/// buys the case a flat model gets wrong — a numbered list nested inside a
/// bulleted one, where a single `isOrdered` on the outer list would be a
/// lie about half its contents.
struct MarkdownList: Equatable {
    struct Item: Equatable {
        /// The number as written, or nil for a bullet.
        ///
        /// Verbatim, so a list that starts at 3 still starts at 3 — which
        /// is how a README numbers the steps of a procedure that continued
        /// across a code block.
        var ordinal: Int?

        /// A GFM task box: `- [x] done`. Nil when the item had none.
        var isChecked: Bool?

        var blocks: [MarkdownBlock]
    }

    var items: [Item] = []

    /// True when a blank line separates any two items.
    ///
    /// CommonMark's own distinction, and the only thing that decides
    /// whether the items are drawn packed or with air between them.
    var isTight: Bool = true

    /// Decided by the first item, because that is the marker the reader
    /// sees first and lists do not change their mind halfway in practice.
    var isOrdered: Bool { items.first?.ordinal != nil }
}

/// A GFM table.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading
        case center
        case trailing
    }

    var headers: [String] = []

    /// One entry per column; nil where the separator row gave no colon.
    var alignments: [Alignment?] = []

    /// Padded and truncated to the header's column count.
    ///
    /// A ragged table is normal in a hand-edited README, and the
    /// rectangle is fixed *here* so that every renderer does not have to
    /// re-decide it — and so the decision has a test.
    var rows: [[String]] = []

    var columnCount: Int { headers.count }
}

/// A `[label]: destination "title"` line.
struct MarkdownLinkDefinition: Equatable {
    /// Lowercased: reference labels are matched case-insensitively.
    var label: String
    var destination: String
    var title: String?

    /// The line put back together, for handing to an inline parser that
    /// only resolves references it can see in its own input.
    var source: String {
        var line = "[\(label)]: \(destination)"
        if let title { line += " \"\(title)\"" }
        return line
    }
}

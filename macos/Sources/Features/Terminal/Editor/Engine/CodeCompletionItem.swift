import Foundation

/// A replacement of `range` with `newText`, in the document the completion
/// came from.
///
/// Carried alongside a completion rather than applied by whoever produced it,
/// because the two have to land together: an auto-import is an edit at the top
/// of the file and an identifier at the caret, and applying one without the
/// other leaves the file broken in a way the user did not ask for.
struct CodeTextEdit: Equatable, Sendable {
    var range: NSRange
    var newText: String
}

/// One row of the completion list.
///
/// **`Sendable` is the whole point of this type's shape.** The list is fetched
/// on an `async` path and the values cross back to the main actor to be drawn,
/// so nothing in here may be a reference to a mutable object — and in
/// particular nothing may be an `NSColor`. `CodeHoverInfo.Problem` does carry
/// one and gets away with it because it is built and drawn in the same
/// main-actor breath; copying that shape here would make every completion a
/// data race waiting for a slow server. Colour is derived at draw time from
/// `Kind.tokenKind` instead, which is also what keeps the icon beside a call
/// the same colour the call itself is painted two lines up.
///
/// A plain value for the same reason as `CodeTheme`: the engine is handed
/// these and knows nothing about language servers, buffers or keyword lists.
struct CodeCompletionItem: Equatable, Identifiable, Sendable {
    /// What sort of thing the row offers.
    ///
    /// Deliberately smaller than LSP's twenty-five kinds, in the spirit of
    /// `TokenKind`: these are the distinctions that change either the icon or
    /// the colour. A richer set would be precision the row has no room to
    /// show, and every extra case is another mapping for a bridge to get
    /// wrong.
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case keyword
        case variable
        case function
        case method
        case property
        case type
        case module
        case constant
        case enumeration
        case enumCase
        case snippet
        case file
        case value
        case text

        /// The SF Symbol drawn in the icon column.
        ///
        /// Letter glyphs for the kinds that are just *names* of things, and a
        /// picture only where one reads faster than a letter would. A column
        /// this narrow is scanned, not read, so consistency beats
        /// expressiveness: fourteen unrelated pictograms take longer to learn
        /// than a lettered alphabet with four exceptions in it.
        ///
        /// The one shape that carries meaning of its own is `enumCase`'s
        /// circle: against `enumeration`'s square it reads as a member of the
        /// thing listed beside it rather than another one of them.
        var symbolName: String {
            switch self {
            case .keyword: return "k.square"
            case .variable: return "v.square"
            case .function: return "f.square"
            case .method: return "m.square"
            case .property: return "p.square"
            case .type: return "t.square"
            case .module: return "cube"
            case .constant: return "c.square"
            case .enumeration: return "e.square"
            case .enumCase: return "e.circle"
            case .snippet: return "chevron.left.forwardslash.chevron.right"
            case .file: return "doc"
            case .value: return "equal.square"
            case .text: return "textformat.abc"
            }
        }

        /// The token whose colour this kind borrows.
        ///
        /// The rule is *what the highlighter would paint this identifier if it
        /// were already in the file* — not "a nice colour for functions". That
        /// is what makes the list look like it belongs to the code under it:
        /// the icon next to a call is the colour the call is drawn in, the icon
        /// next to a property is the colour an object key is drawn in. Kinds
        /// the highlighter has no opinion about — a plain local, a word
        /// scraped from the buffer — come out `.plain`, which is exactly how
        /// they appear in the text.
        ///
        /// `file` follows the same rule to a place that looks like an
        /// exception and is not: a path is a string literal wherever it
        /// appears in code, and the string colour is the only hint the row
        /// gets that it is about to insert one.
        var tokenKind: TokenKind {
            switch self {
            case .keyword, .snippet: return .keyword
            case .variable, .constant, .text: return .plain
            case .function, .method: return .function
            case .property, .enumCase: return .attribute
            case .type, .module, .enumeration: return .type
            case .file: return .string
            case .value: return .number
            }
        }
    }

    /// Where the row came from, which the ranking uses to make sure a real
    /// symbol never loses to a word scraped out of the file.
    enum Source: String, CaseIterable, Equatable, Sendable {
        case server
        case buffer
        case keyword
    }

    var kind: Kind

    /// What the row reads as. Shown, ranked against, and **not** necessarily
    /// what gets typed — see `insertText` and `filterText`.
    var label: String

    /// The right-hand column: a type, a module, `./db/connect`, `keyword`.
    ///
    /// The single most valuable thing on the row and the thing the old
    /// `[String]` list threw away — without it, six overloads of `connect`
    /// are six identical lines.
    var detail: String?

    /// The text that actually goes into the document.
    ///
    /// Separate from `label` because servers routinely differ: TypeScript
    /// offers an optional member as `label: "foo?"`, and inserting the label
    /// there would write the question mark into the file.
    var insertText: String

    /// Whether `insertText` is a `CodeSnippet` body rather than literal text.
    var isSnippet: Bool

    /// What the query is matched against, when that is not the label.
    ///
    /// The other half of the TypeScript optional-member case: `label: "foo?"`
    /// arrives with `filterText: "foo"`, so the query has to be matched
    /// against this — and this must never be inserted.
    var filterText: String?

    /// The server's own ordering key, compared **scalar-wise**.
    ///
    /// Honoured because servers use it to say things they cannot say any
    /// other way: `typescript-language-server` prefixes auto-import items
    /// with `U+FFFF` to sink them below everything local, and
    /// `kotlin-language-server` emits a zero-padded index. Locale-aware
    /// collation destroys both, which is why `CodeCompletionFilter` compares
    /// these by scalar value and never by `localizedStandardCompare`.
    var sortText: String?

    /// Edits that must be applied together with this one — an import line at
    /// the top of the file, most of the time.
    var additionalEdits: [CodeTextEdit]

    /// Whether the server asked for this row to be the one selected on open.
    var isPreselected: Bool

    var source: Source

    /// An opaque handle the host uses to ask the server for the rest of this
    /// item later.
    ///
    /// Opaque on purpose: the engine must not learn that a resolve request
    /// exists, so this is an integer the host assigns and interprets. Nil
    /// means there is nothing more to fetch.
    var resolveToken: Int?

    /// Stable identity for the list view.
    ///
    /// Derived from the fields that distinguish one row from another when the
    /// caller does not supply one, because a table that reuses rows needs
    /// identities that survive a refilter — and two rows sharing an id makes
    /// the wrong one highlight.
    var id: String

    /// `insertText` and `id` default to something derived rather than being
    /// required, because the two cheapest sources — words from the buffer and
    /// the language's keywords — have nothing else to say: for those the label
    /// *is* the insertion.
    init(
        kind: Kind,
        label: String,
        detail: String? = nil,
        insertText: String? = nil,
        isSnippet: Bool = false,
        filterText: String? = nil,
        sortText: String? = nil,
        additionalEdits: [CodeTextEdit] = [],
        isPreselected: Bool = false,
        source: Source = .server,
        resolveToken: Int? = nil,
        id: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.insertText = insertText ?? label
        self.isSnippet = isSnippet
        self.filterText = filterText
        self.sortText = sortText
        self.additionalEdits = additionalEdits
        self.isPreselected = isPreselected
        self.source = source
        self.resolveToken = resolveToken
        self.id = id ?? Self.derivedID(
            kind: kind,
            label: label,
            detail: detail,
            source: source,
            resolveToken: resolveToken
        )
    }

    /// What the query is matched against: the filter text when the server
    /// supplied one, the label otherwise.
    var matchText: String { filterText ?? label }

    /// Separated by `U+0001`, a character no label, detail or module name
    /// contains — so two different rows cannot collide by one field ending
    /// where the next begins.
    private static func derivedID(
        kind: Kind,
        label: String,
        detail: String?,
        source: Source,
        resolveToken: Int?
    ) -> String {
        [
            source.rawValue,
            kind.rawValue,
            label,
            detail ?? "",
            resolveToken.map(String.init) ?? "",
        ].joined(separator: "\u{1}")
    }
}

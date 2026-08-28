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
    ///
    /// Four of LSP's kinds are folded away by that rule rather than
    /// forgotten, and each fold is a claim worth being able to check.
    /// `Namespace` renders exactly as `module` does — same glyph, same
    /// colour — so it would be a case that changes nothing. `Field` and
    /// `Property` are the *same* concept spelled by different servers,
    /// TypeScript saying one and Kotlin the other, so splitting them would
    /// draw a distinction between two language servers rather than between
    /// two things in the file. `Unit` and `Color` are the CSS server's, and
    /// what makes them legible in VS Code is a swatch this row cannot
    /// draw — without it they are values. `Operator` is the one that would
    /// have changed both glyph and colour, and it is out because an operator
    /// row's label *is* the operator: the glyph would be repeating the two
    /// characters printed beside it.
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case keyword
        case variable
        case function
        case method
        case property
        case type

        /// Kept apart from `type` because choosing between a class and a
        /// protocol is the choice the row is there to inform — in every
        /// language wired here that has both, they are implemented against
        /// rather than instantiated.
        case interface

        /// And apart for the sibling reason, in the languages this editor is
        /// written in: `struct` against `class` in Swift is a decision about
        /// copies, and sourcekit-lsp is careful to say which one it means.
        case structure

        case module
        case constant
        case enumeration
        case enumCase
        case snippet
        case file
        case value
        case text

        /// `<div`, in markup.
        case tag

        /// `class=`, `v-if=`, `:disabled=` — the name half of a markup
        /// attribute.
        case attribute

        /// `@click`, `onSubmit`. Split from `attribute` because it is the one
        /// markup distinction that survives being scanned rather than read:
        /// a list of a component's props with its events mixed in is two
        /// different questions answered in one column.
        case event

        /// The quoted half — `flex` after `display=`, a route name after
        /// `to=`.
        case attributeValue

        /// The SF Symbol drawn in the icon column.
        ///
        /// Letter glyphs for the kinds that are just *names* of things, and a
        /// picture only where one reads faster than a letter would. A column
        /// this narrow is scanned, not read, so consistency beats
        /// expressiveness: twenty unrelated pictograms take longer to learn
        /// than a lettered alphabet with a handful of exceptions in it.
        ///
        /// The one shape that carries meaning of its own is `enumCase`'s
        /// circle: against `enumeration`'s square it reads as a member of the
        /// thing listed beside it rather than another one of them.
        ///
        /// This is the **fallback**, not the default: when the host has
        /// handed the list a Codicons font, `codicon` below is what gets
        /// drawn. It stays complete and stays tested because the font is a
        /// bundled resource that can fail to register, and a completion list
        /// with an empty icon column reads as a layout bug rather than as a
        /// missing font.
        var symbolName: String {
            switch self {
            case .keyword: return "k.square"
            case .variable: return "v.square"
            case .function: return "f.square"
            case .method: return "m.square"
            case .property: return "p.square"
            case .type: return "t.square"
            case .interface: return "i.square"
            case .structure: return "s.square"
            case .module: return "cube"
            case .constant: return "c.square"
            case .enumeration: return "e.square"
            case .enumCase: return "e.circle"
            case .snippet: return "chevron.left.forwardslash.chevron.right"
            case .file: return "doc"
            case .value: return "equal.square"
            case .text: return "textformat.abc"
            case .tag: return "tag"
            case .attribute: return "a.square"
            case .event: return "bolt.square"
            case .attributeValue: return "text.quote"
            }
        }

        /// The Codicon drawn in the icon column when the host supplied the
        /// font, as a codepoint rather than a name.
        ///
        /// A codepoint because nothing in the bundle carries the names: the
        /// font maps `symbol-method` to `U+EA8C` and ships no lookup table,
        /// so a name here would be a key with nothing to look it up in. The
        /// names each one has upstream, for checking this against
        /// `codicon.csv` without a font editor:
        ///
        ///     keyword   EB62 symbol-keyword     file           EB60 symbol-file
        ///     variable  EA88 symbol-variable    value          EA95 symbol-value
        ///     function  EA8C symbol-method      text           EA93 symbol-text
        ///     method    EA8C symbol-method      tag            EA66 tag
        ///     property  EB65 symbol-property    attribute      EA92 symbol-parameter
        ///     type      EB5B symbol-class       event          EA86 symbol-event
        ///     interface EB61 symbol-interface   attributeValue EB8D symbol-string
        ///     structure EA91 symbol-structure   enumCase       EB5E symbol-enum-member
        ///     module    EA8B symbol-namespace   enumeration    EA95 symbol-enum
        ///     constant  EB5D symbol-constant    snippet        EB66 symbol-snippet
        ///
        /// **VS Code's own `symbol-*` assignment, deliberately.** These
        /// glyphs are recognised before they are read by anyone who has used
        /// an editor in the last decade, and a private dialect of them would
        /// spend that recognition to gain nothing. Two of its collisions come
        /// along with it and are not bugs here either: a function and a
        /// method share `U+EA8C` — VS Code draws them identically too, and
        /// the SF Symbol fallback above is the only place they differ — and a
        /// value shares `U+EA95` with an enum, where the colour tells them
        /// apart because `value` borrows the number's and `enumeration`
        /// borrows the type's.
        ///
        /// `attribute` is the one departure. Upstream's HTML server calls an
        /// attribute a `Value`, which would draw `class=` with the enum's
        /// glyph; `symbol-parameter` is what an attribute actually is — the
        /// thing a tag is parameterised by — and it was otherwise unused.
        var codicon: Unicode.Scalar {
            switch self {
            case .keyword: return "\u{EB62}"
            case .variable: return "\u{EA88}"
            case .function, .method: return "\u{EA8C}"
            case .property: return "\u{EB65}"
            case .type: return "\u{EB5B}"
            case .interface: return "\u{EB61}"
            case .structure: return "\u{EA91}"
            case .module: return "\u{EA8B}"
            case .constant: return "\u{EB5D}"
            case .enumeration: return "\u{EA95}"
            case .enumCase: return "\u{EB5E}"
            case .snippet: return "\u{EB66}"
            case .file: return "\u{EB60}"
            case .value: return "\u{EA95}"
            case .text: return "\u{EA93}"
            case .tag: return "\u{EA66}"
            case .attribute: return "\u{EA92}"
            case .event: return "\u{EA86}"
            case .attributeValue: return "\u{EB8D}"
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
        ///
        /// The four markup kinds were read off `SyntaxRules.rules(for:
        /// .html)` rather than chosen, and one of them is a surprise worth
        /// keeping: **a tag is painted as a keyword**, because the rule that
        /// catches `</?[A-Za-z][A-Za-z0-9-]*` is the keyword one. It is the
        /// right answer under this file's rule and the wrong answer under
        /// "pick a nice colour for tags", which is exactly why the rule is
        /// the one written down. `attribute` and `event` share the attribute
        /// colour because they share the rule that matches them — that
        /// regex's character class opens with `[A-Za-z_:@]`, so `@click` and
        /// `:disabled` are attributes to the highlighter — and an attribute's
        /// value is a quoted string to it, as it is to anyone reading the
        /// file.
        var tokenKind: TokenKind {
            switch self {
            case .keyword, .snippet, .tag: return .keyword
            case .variable, .constant, .text: return .plain
            case .function, .method: return .function
            case .property, .enumCase, .attribute, .event: return .attribute
            case .type, .interface, .structure, .module, .enumeration: return .type
            case .file, .attributeValue: return .string
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

    /// The span `insertText` replaces, when whoever produced the row named
    /// one. Offsets into the document the row was built for.
    ///
    /// `nil` is "this row has no opinion", and only then may the view fall
    /// back to the word the caret sits at the end of — which is the only
    /// thing a word scraped out of the buffer could ever mean.
    ///
    /// It travels on the row rather than being reconstructed at accept time
    /// because the reconstruction is wrong for real servers, and wrong in the
    /// direction that damages the file. A range routinely starts **before**
    /// the caret: TypeScript builds dot-accessor rows whose range covers the
    /// `.` and whose text includes it again, so replacing only the typed word
    /// writes `foo..bar`. And a range routinely ends **after** the caret,
    /// which is how a server says "and the rest of this identifier too".
    /// Neither is expressible as "the prefix being typed", so the prefix
    /// cannot stand in for it.
    var replaceRange: NSRange?

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
        replaceRange: NSRange? = nil,
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
        self.replaceRange = replaceRange
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

    /// Whether this row's producer may still be holding edits it has not sent.
    ///
    /// The protocol reason, and it is the whole of the auto-import bug:
    /// computing an import line for every row of a list is expensive, so a
    /// server is allowed to leave `additionalEdits` empty in the list and fill
    /// them in only when asked about the one row that was chosen. Measured on
    /// `typescript-language-server`, a list of 1097 rows arrives with the
    /// import edit on **none** of them, and the same rows answer with one when
    /// asked individually. A client that never asks therefore inserts the
    /// identifier and no import, which is indistinguishable from a server that
    /// had no import to offer.
    ///
    /// Three conditions, and each one excludes a row nobody can be asked
    /// about. A word scraped out of the buffer has no producer; a row with no
    /// `resolveToken` is one whose list has been replaced, and asking about it
    /// gets it back **unchanged rather than refused**; and a row that already
    /// carries edits has nothing to gain — a second answer that omitted them
    /// would overwrite what is already right.
    var mayHaveUnsentEdits: Bool {
        source == .server && resolveToken != nil && additionalEdits.isEmpty
    }

    /// This row, with whatever the second request added to it.
    ///
    /// **Only `additionalEdits` crosses over, and that is the specification
    /// rather than caution.** A resolve may fill in the properties the client
    /// declared it would wait for and may not change the rest: the label,
    /// the sort key and the text to insert belong to the row the reader
    /// looked at and chose, and taking those from a reply would let a late
    /// answer insert a different symbol than the one on screen.
    ///
    /// A reply about some other row is refused outright. It is not a
    /// hypothetical: a server that cannot recognise the item it was handed
    /// answers with that item unchanged, so identity is the only evidence
    /// that the answer is about this row at all.
    func finished(by resolved: CodeCompletionItem?) -> CodeCompletionItem {
        guard let resolved, resolved.id == id, !resolved.additionalEdits.isEmpty else { return self }

        var item = self
        item.additionalEdits = resolved.additionalEdits
        return item
    }

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

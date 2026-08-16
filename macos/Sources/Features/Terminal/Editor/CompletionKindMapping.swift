import Foundation

/// LSP's twenty-five completion kinds, folded onto the twenty the list draws.
///
/// Outside `Editor/Engine/` for the same reason `CompletionBridge` is: these
/// integers are the language server protocol's, and the engine is forbidden
/// from learning that a language server exists. This is the only place in the
/// app that knows both numbers and names.
///
/// **The numbers are the protocol's own and are not negotiable** — they are
/// `CompletionItemKind` in the specification, one-based, in that order, and a
/// server sends the integer with no name attached. They are written out as a
/// switch rather than looked up in a table so that a case nobody thought about
/// is a compile error in this file rather than a wrong icon in the list.
///
/// **Three kinds cannot come out of here at all, and that is the honest
/// answer rather than a gap.** `tag`, `attribute` and `attributeValue` have no
/// number: the HTML and Vue servers spend LSP's *generic* kinds on them — a
/// tag arrives as `Property`, an attribute as `Value` — and nothing in the
/// integer separates those from a real property on a real object. Guessing
/// from the document's language would be the tempting fix and would be wrong
/// in the case that matters: a `.vue` file is mostly TypeScript, so the same
/// guess that painted its template correctly would paint every object key in
/// its `<script>` block as a markup attribute.
///
/// Those three reach a row the other way, and the seam is already there:
/// `CodeCompletionItem` takes its `Kind` at `init`, so whatever scans the
/// buffer's markup builds
/// `CodeCompletionItem(kind: .tag, label: "div", source: .buffer)` directly
/// and never comes through this function. A local scanner is the *only* thing
/// that can know a row is a tag, because it is the only thing that knows the
/// caret is inside a `<`.
///
/// `event` is the exception that proves it: the protocol does name `Event`, at
/// 23, so a server that says so is believed. Whether the servers wired here
/// ever send it is a separate question and not one this file has to answer —
/// mapping it to anything else would be wrong on the day one does.
enum CompletionKindMapping {
    /// What a server sending no kind at all gets.
    ///
    /// `text` rather than `variable`, because that is what the row honestly is:
    /// a server that declined to say what it is offering is offering a word,
    /// and `text` is the kind that draws in the plain colour a word has in the
    /// file. Guessing `variable` would be the same colour with a claim attached.
    static let unknown = CodeCompletionItem.Kind.text

    static func kind(lsp raw: Int?) -> CodeCompletionItem.Kind {
        guard let raw else { return unknown }

        switch raw {
        case 1: return .text
        case 2: return .method
        case 3: return .function

        /// A constructor is the method you call to get one, and every server
        /// that sends this also sends the type beside it in `detail`.
        case 4: return .method

        /// **`Field` and `Property` are the same thing spelled by different
        /// servers** — TypeScript says one about a class member and Kotlin says
        /// the other about the same member. Keeping them apart would draw a
        /// distinction between two language servers rather than between two
        /// things in the file.
        case 5: return .property

        case 6: return .variable
        case 7: return .type
        case 8: return .interface
        case 9: return .module
        case 10: return .property

        /// `Unit` and `Color` are the CSS server's, and what makes them legible
        /// in VS Code is a swatch this row has no way to draw. Without it they
        /// are values, which is what `px` and `rebeccapurple` are.
        case 11: return .value
        case 12: return .value

        case 13: return .enumeration
        case 14: return .keyword
        case 15: return .snippet
        case 16: return .value
        case 17: return .file

        /// `Reference` is barely emitted by anything, and when it is, the row
        /// has nothing to say past its label.
        case 18: return .variable

        /// A folder is a path, and a path is a string wherever it appears —
        /// the same rule that puts `file` in the string colour.
        case 19: return .file

        case 20: return .enumCase
        case 21: return .constant
        case 22: return .structure
        case 23: return .event

        /// An operator belongs to the language's grammar rather than to the
        /// file's vocabulary, which is exactly what the keyword colour means.
        /// It gets no case of its own: an operator row's label *is* the
        /// operator, so a glyph beside it would be repeating the two characters
        /// printed next to it.
        case 24: return .keyword

        /// A `T` is a type at every use site, and nothing about the row would
        /// read differently if it said so.
        case 25: return .type

        default: return unknown
        }
    }
}

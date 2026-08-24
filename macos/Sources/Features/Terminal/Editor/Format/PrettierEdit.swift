import Foundation

/// The smallest replacement that turns the buffer into the formatted text.
///
/// Replacing the whole buffer would be one line of code and would cost the
/// reader their place: `NSTextView` puts the caret at the end of a wholesale
/// replacement, the scroll position follows it, and the undo stack gets one
/// enormous entry whose sole ⌘Z undoes the formatting *and* whatever they were
/// typing. Formatting a file usually changes a handful of lines, so trimming
/// the identical head and tail leaves an edit small enough that the caret and
/// the viewport can survive it.
///
/// Deliberately the same two fields, under the same names, as `CodeTextEdit`
/// — it is the shape `CodeTextView` already applies. It is a separate type
/// only so this stays compilable and testable on its own, with nothing of the
/// completion machinery behind it.
///
/// The arithmetic itself lives on `CodeTextEdit` and is delegated to here.
/// It moved there when the text view started needing the same computation for
/// every *other* replacement a host makes — a language server's formatting, a
/// rename, a reload — and two copies of a surrogate-pair rule is one copy too
/// many.
struct PrettierEdit: Equatable, Sendable {
    /// UTF-16 offsets into the *old* text, which is what `NSTextStorage`
    /// indexes by.
    var range: NSRange
    var newText: String
}

extension PrettierEdit {
    /// The minimal edit between two texts, or nil when there is nothing to do.
    /// See ``CodeTextEdit/minimal(from:to:)`` for why it counts UTF-16 units
    /// and why it refuses to split a surrogate pair.
    static func minimal(from old: String, to new: String) -> PrettierEdit? {
        guard let edit = CodeTextEdit.minimal(from: old, to: new) else { return nil }
        return PrettierEdit(range: edit.range, newText: edit.newText)
    }

    /// Applies the edit to the text it was computed from.
    func applied(to text: String) -> String {
        asCodeTextEdit.applied(to: text)
    }

    /// Where a caret sitting at `offset` should end up. See
    /// ``CodeTextEdit/movedCaret(from:)``.
    func movedCaret(from offset: Int) -> Int {
        asCodeTextEdit.movedCaret(from: offset)
    }

    private var asCodeTextEdit: CodeTextEdit {
        CodeTextEdit(range: range, newText: newText)
    }
}

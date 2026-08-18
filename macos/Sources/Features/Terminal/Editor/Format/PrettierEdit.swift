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
struct PrettierEdit: Equatable, Sendable {
    /// UTF-16 offsets into the *old* text, which is what `NSTextStorage`
    /// indexes by.
    var range: NSRange
    var newText: String
}

extension PrettierEdit {
    /// The minimal edit between two texts, or nil when there is nothing to do.
    ///
    /// ## Why UTF-16 and not `Character`
    ///
    /// The buffer is `NSString`-indexed, so any offset handed back has to be
    /// in UTF-16 code units. Trimming by `Character` and converting afterwards
    /// is not the same computation, because Swift's `Character` is a grapheme
    /// cluster:
    ///
    /// - `"\r\n"` is **one** `Character` and **two** code units. A file
    ///   converted from CRLF to LF differs at every line ending, and a
    ///   grapheme-counted prefix would be short by one unit per line already
    ///   passed — an offset that drifts further from the truth the further
    ///   into the file the first real change is.
    /// - `"👩‍👩‍👧"` is one `Character` and eight code units, and every flag,
    ///   skin tone and combining accent has its own ratio.
    ///
    /// Counting the units the buffer counts removes the conversion entirely.
    ///
    /// ## Why the boundaries get nudged
    ///
    /// A code-unit boundary can fall *inside* a surrogate pair: `"😀"` and
    /// `"😁"` share their leading unit, so the naive common prefix is one unit
    /// long and the replacement text would begin with an unpaired trailing
    /// surrogate. Swift cannot hold one — `String(decoding:as: UTF16.self)`
    /// substitutes U+FFFD — so the emoji would come back as a replacement
    /// character. Both boundaries are therefore pulled back off any pair they
    /// would have split.
    static func minimal(from old: String, to new: String) -> PrettierEdit? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)

        /// Compared as code units rather than as `String`s on purpose. `==`
        /// on `String` is canonical equivalence, so a text that differs only
        /// in Unicode normalisation reads as unchanged — and the buffer would
        /// keep bytes Prettier did not produce.
        guard oldUnits != newUnits else { return nil }

        var prefix = 0
        let shorter = min(oldUnits.count, newUnits.count)
        while prefix < shorter, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        if prefix > 0, isHighSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < shorter - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, isLowSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }

        let range = NSRange(location: prefix, length: oldUnits.count - suffix - prefix)
        let replacement = newUnits[prefix..<(newUnits.count - suffix)]
        return PrettierEdit(range: range, newText: String(decoding: replacement, as: UTF16.self))
    }

    /// Applies the edit to the text it was computed from.
    ///
    /// For callers with no text view — and for tests, which is the honest way
    /// to assert a minimal edit: that it reconstructs the formatted text
    /// exactly, not merely that its numbers look plausible.
    func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: newText)
    }

    /// Where a caret sitting at `offset` should end up.
    ///
    /// The point of the whole exercise. A caret before the edit does not move;
    /// one after it shifts by however much the edit grew or shrank the text.
    /// A caret *inside* the rewritten span has no honest answer — the text it
    /// was pointing at is gone — so it is held where it is, clamped to the end
    /// of the replacement, which for the common case of a reindented line
    /// leaves it on the same line.
    func movedCaret(from offset: Int) -> Int {
        guard offset > range.location else { return offset }

        let replacementLength = (newText as NSString).length
        let end = range.location + range.length
        if offset >= end { return offset + replacementLength - range.length }
        return min(offset, range.location + replacementLength)
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}

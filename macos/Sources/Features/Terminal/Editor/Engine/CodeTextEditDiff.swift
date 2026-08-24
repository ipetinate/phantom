import Foundation

/// The smallest replacement that turns one text into another, and where a
/// caret ends up once it has been applied.
///
/// Lives on `CodeTextEdit` because two unrelated callers need exactly this
/// arithmetic and neither may own it. ``PrettierEdit`` reduces a reformat to
/// a splice so the reader keeps their place; `CodeTextView.Coordinator`
/// reduces *any* host replacement — a language server's formatting, a rename,
/// a file reloaded from disk — to the same splice, so the buffer is edited
/// rather than rebuilt. Replacing the whole storage is one line of code and
/// costs the reader their caret, their scroll position and their undo stack
/// in one go, because none of the three survive a buffer that was thrown away
/// and made again.
extension CodeTextEdit {
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
    static func minimal(from old: String, to new: String) -> CodeTextEdit? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)

        /// Compared as code units rather than as `String`s on purpose. `==`
        /// on `String` is canonical equivalence, so a text that differs only
        /// in Unicode normalisation reads as unchanged — and the buffer would
        /// keep bytes the writer did not produce.
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
        return CodeTextEdit(range: range, newText: String(decoding: replacement, as: UTF16.self))
    }

    /// Applies the edit to the text it was computed from.
    ///
    /// For callers with no text view — and for tests, which is the honest way
    /// to assert a minimal edit: that it reconstructs the target text exactly,
    /// not merely that its numbers look plausible.
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

    /// A selection carried across the edit, both ends mapped by the rule
    /// above.
    ///
    /// Both ends rather than the location plus the old length: an edit inside
    /// a selection changes how long that selection is, and keeping the length
    /// would leave the far end pointing past the text it was covering — or
    /// past the end of the buffer, which is a crash rather than a wrong
    /// highlight.
    func movedSelection(_ selection: NSRange) -> NSRange {
        let start = movedCaret(from: selection.location)
        let end = movedCaret(from: selection.location + selection.length)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    private static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}

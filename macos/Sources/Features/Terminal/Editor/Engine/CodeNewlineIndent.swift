import Foundation

/// What Return should put on the next line.
///
/// Until now it put nothing: every new line started at column zero, so the
/// first thing anybody did after pressing Return was re-type the indentation
/// they were already at. Two rules cover almost every case, and both are
/// decided from the caret's own line — no document scan, on a path that runs
/// on a keystroke.
///
/// Pure, and the reason is the same one `CodeCompletionTrigger` gives: a
/// decision made of three integers and a string can be pinned down
/// exhaustively in a test, and only the insertion needs a text view.
struct CodeNewlineIndent {
    /// One edit: what to type, what to remove first, and where the caret ends
    /// up inside what was typed.
    struct Insertion: Equatable {
        /// Always begins with the newline itself.
        let text: String

        /// Characters immediately before the caret to remove as part of the
        /// same edit. Only ever non-zero for an empty list item, where Return
        /// clears the marker instead of repeating it.
        let deletingBefore: Int

        /// Where the caret lands, counted from the start of `text`. Differs
        /// from `text.count` only when a closer was pushed onto its own line
        /// and the caret belongs on the blank line above it.
        let caretOffset: Int

        init(text: String, deletingBefore: Int = 0, caretOffset: Int? = nil) {
            self.text = text
            self.deletingBefore = deletingBefore
            self.caretOffset = caretOffset ?? text.utf16.count
        }
    }

    /// - Parameters:
    ///   - line: the caret's line, without its terminator.
    ///   - caretInLine: the caret's offset in UTF-16 units from the line start.
    ///   - indentUnit: one level of indentation — spaces or a tab, whichever
    ///     the reader configured. A value, because the engine is not allowed
    ///     to read preferences.
    ///   - continuesLists: whether this document's lists continue themselves.
    ///     Markdown's do; a `.swift` file has no such thing, and treating
    ///     `- x` in a comment as a list would fight the code rule.
    static func insertion(
        forLine line: String,
        caretInLine: Int,
        indentUnit: String,
        continuesLists: Bool
    ) -> Insertion {
        let text = line as NSString
        let caret = max(0, min(caretInLine, text.length))
        let before = text.substring(to: caret)
        let after = text.substring(from: caret)

        if continuesLists, let list = listInsertion(before: before, after: after) {
            return list
        }
        return codeInsertion(before: before, after: after, indentUnit: indentUnit)
    }

    // MARK: - Code

    /// The leading whitespace, plus a level when the line opens a block.
    ///
    /// **The closer moves too.** Auto-closing means `{` is usually already
    /// `{}` with the caret between them, and Return there has to produce the
    /// three-line shape rather than pushing `}` along the same line as the
    /// caret. That is the case the whole feature is most visible in.
    private static func codeInsertion(
        before: String,
        after: String,
        indentUnit: String
    ) -> Insertion {
        let indent = leadingWhitespace(of: before)
        let opener = before.last { !$0.isWhitespace }

        guard let opener, isOpener(opener) else {
            return Insertion(text: "\n" + indent)
        }

        let inner = indent + indentUnit
        guard let closer = after.first(where: { !$0.isWhitespace }), closer == match(for: opener) else {
            return Insertion(text: "\n" + inner)
        }

        let text = "\n" + inner + "\n" + indent
        return Insertion(text: text, caretOffset: ("\n" + inner).utf16.count)
    }

    private static func isOpener(_ character: Character) -> Bool {
        character == "{" || character == "[" || character == "("
    }

    private static func match(for opener: Character) -> Character? {
        switch opener {
        case "{": "}"
        case "[": "]"
        case "(": ")"
        default: nil
        }
    }

    // MARK: - Lists

    /// A bullet, an ordered number, or a quote — repeated on the next line.
    ///
    /// Returns nil when the line is not a list item at all, so the code rule
    /// handles it. That is also what makes a fenced code block inside a
    /// Markdown file behave: its lines are not list items, so they indent.
    private static func listInsertion(before: String, after: String) -> Insertion? {
        guard let item = ListItem(line: before) else { return nil }

        /// An empty item ends the list rather than growing it, which is what
        /// every Markdown editor does and what makes a list finishable without
        /// reaching for Backspace. The marker goes with it — leaving the
        /// indentation behind would put trailing whitespace on the line.
        if item.content.isEmpty, after.isEmpty {
            return Insertion(
                text: "\n",
                deletingBefore: (before as NSString).length
            )
        }

        return Insertion(text: "\n" + item.nextMarker)
    }

    /// One list item's parts, read off the front of a line.
    private struct ListItem {
        let indent: String
        let marker: String
        let spacing: String
        let checkbox: Bool
        let content: String

        init?(line: String) {
            let text = line as NSString
            var index = 0

            /// Indentation first, and it is kept verbatim: a list nested with
            /// tabs must continue with tabs.
            while index < text.length, isSpace(text.character(at: index)) { index += 1 }
            let indent = text.substring(to: index)

            guard index < text.length else { return nil }
            let marker: String

            if let bullet = Self.bullet(at: index, in: text) {
                marker = bullet
            } else if let ordered = Self.ordered(at: index, in: text) {
                marker = ordered
            } else {
                return nil
            }
            index += (marker as NSString).length

            /// At least one space after the marker, or it is not a list — `-x`
            /// is a word and `1.5` is a number.
            let spacingStart = index
            while index < text.length, isSpace(text.character(at: index)) { index += 1 }
            guard index > spacingStart else { return nil }
            let spacing = text.substring(with: NSRange(location: spacingStart, length: index - spacingStart))

            var checkbox = false
            if let box = Self.checkbox(at: index, in: text) {
                checkbox = true
                index += (box as NSString).length
                while index < text.length, isSpace(text.character(at: index)) { index += 1 }
            }

            self.indent = indent
            self.marker = marker
            self.spacing = spacing
            self.checkbox = checkbox
            self.content = text.substring(from: index)
        }

        /// The same marker, except that an ordered one counts on and a ticked
        /// box comes back empty — the next task is not done yet.
        var nextMarker: String {
            let next: String
            if let number = Int(marker.dropLast()) {
                next = "\(number + 1)\(marker.suffix(1))"
            } else {
                next = marker
            }
            return indent + next + spacing + (checkbox ? "[ ] " : "")
        }

        private static func bullet(at index: Int, in text: NSString) -> String? {
            let unit = text.character(at: index)
            guard unit == 0x2D || unit == 0x2A || unit == 0x2B || unit == 0x3E else { return nil }
            return text.substring(with: NSRange(location: index, length: 1))
        }

        /// `1.` and `1)`, up to nine digits — past that it is not a list
        /// somebody is typing.
        private static func ordered(at index: Int, in text: NSString) -> String? {
            var end = index
            while end < text.length, isDigit(text.character(at: end)), end - index < 9 { end += 1 }
            guard end > index, end < text.length else { return nil }

            let terminator = text.character(at: end)
            guard terminator == 0x2E || terminator == 0x29 else { return nil }
            return text.substring(with: NSRange(location: index, length: end - index + 1))
        }

        private static func checkbox(at index: Int, in text: NSString) -> String? {
            guard index + 2 < text.length, text.character(at: index) == 0x5B else { return nil }
            let inner = text.character(at: index + 1)
            guard inner == 0x20 || inner == 0x78 || inner == 0x58 else { return nil }
            guard text.character(at: index + 2) == 0x5D else { return nil }
            return text.substring(with: NSRange(location: index, length: 3))
        }
    }

    // MARK: - Shared

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

}

/// File-scope rather than static members of `CodeNewlineIndent`, because the
/// nested `ListItem` cannot see the enclosing type's statics unqualified and
/// two spellings of the same predicate is how they drift apart.
private func isSpace(_ unit: unichar) -> Bool {
    unit == 0x20 || unit == 0x09
}

private func isDigit(_ unit: unichar) -> Bool {
    unit >= 0x30 && unit <= 0x39
}

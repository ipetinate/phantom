import Foundation

/// A completion body with tab stops in it, and the arithmetic that keeps those
/// tab stops in the right place while the user types over them.
///
/// The session itself belongs to the view — it is the thing that owns a caret
/// and hears about edits — but every *decision* it makes is here, where it can
/// be tested with three integers. `adjust` in particular is where every "the
/// user did something we did not model" case is settled, and it is the one
/// function in this feature whose bugs would corrupt a file rather than merely
/// annoy someone.
///
/// **`snippetSupport: true` must not be announced to a server before this
/// exists.** Turning the capability on without a parser writes
/// `console.log(${1:message})` into the user's file, literally.
struct CodeSnippet: Equatable {
    /// One tab stop, with the text that was inserted for it.
    struct Field: Equatable {
        /// The number in the marker: `1` for `${1:name}`. Tab order is
        /// ascending in this, which is LSP's rule and not ours to change.
        let index: Int

        /// Where the placeholder text ended up, in UTF-16 offsets into `text`.
        /// Length zero for a bare `$1`, which is a real field with nothing in it
        /// rather than an absent one.
        let range: NSRange

        let placeholder: String
    }

    /// The body with every marker replaced by the text it inserts.
    let text: String

    /// The navigable stops, ascending by index. `$0` is not among them — it is
    /// not a stop you edit, it is where the caret lands when you are finished,
    /// which is what `finalCaret` is for.
    let fields: [Field]

    /// Where `$0` asked the caret to end up, in UTF-16 offsets into `text`, or
    /// nil when the body did not say. Nil means the end of the insertion, which
    /// is the caller's default to apply.
    let finalCaret: Int?

    // MARK: Parsing

    /// Reads the subset of LSP's snippet grammar this editor supports.
    ///
    /// Handled: `$1`, `${1}`, `${1:default}`, `$0`, `${0}`, `${1|a,b,c|}` — of
    /// which the first option is taken, there being no choice UI in v1 — and the
    /// escapes `\$`, `\}` and `\\`. Nested placeholders such as
    /// `${1:${2:inner}}` are parsed recursively and **flattened**: both stops
    /// come out as ordinary fields, and their ranges overlap, because that is
    /// what the text actually looks like.
    ///
    /// **A malformed marker passes through as literal text**, deliberately. A
    /// dropped marker leaves a snippet that looks like it worked and quietly
    /// inserted the wrong thing; a `${1:` left on screen is a wrong insertion
    /// the user can see and fix in one keystroke. When something here cannot be
    /// understood, the failure should be visible.
    ///
    /// **No mirroring in v1**, declared as a cut. A repeated index keeps its
    /// first occurrence as the navigable field and inserts that index's default
    /// text at the others, so `for (let ${1:i} = 0; $1 < n; $1++)` comes out
    /// reading correctly — but editing the first `i` afterwards does not change
    /// the other two. Live mirroring needs the session to own every occurrence
    /// and rewrite them on each keystroke, which is a different feature.
    static func parse(_ body: String) -> CodeSnippet {
        Parser(body).run()
    }

    // MARK: Field arithmetic

    /// Where the fields end up after an edit inside the active one.
    ///
    /// Returns **nil to mean end the session**, and that is the important half
    /// of the contract. A session that survives an edit it did not understand
    /// starts moving the wrong ranges, and the symptom of that is a Tab press
    /// selecting a piece of the user's own code — so anything unmodelled ends
    /// the session instead, which costs a Tab and corrupts nothing.
    ///
    /// Unmodelled means: `active` is not a field; the edit begins before the
    /// active field or ends after it — pasting over a placeholder and its
    /// closing paren, say; or the arithmetic would leave a negative length.
    ///
    /// What it does model: the active field grows by `delta`, and every field
    /// that begins at or after the active field's end shifts by the same amount.
    /// A field lying *inside* the active one — the nested-placeholder case — is
    /// deliberately left alone, because v1 does not navigate nested stops and
    /// guessing which side of the edit it belongs on would be inventing an
    /// answer.
    static func adjust(
        fields: [NSRange],
        active: Int,
        editedRange: NSRange,
        delta: Int
    ) -> [NSRange]? {
        guard fields.indices.contains(active) else { return nil }

        let field = fields[active]
        let end = field.location + field.length
        guard editedRange.location >= field.location else { return nil }
        guard editedRange.location + editedRange.length <= end else { return nil }
        guard field.length + delta >= 0 else { return nil }

        var result = fields
        result[active].length += delta
        for other in fields.indices where other != active && fields[other].location >= end {
            result[other].location += delta
        }
        return result
    }

    // MARK: Scanner

    /// Works in UTF-16 code units throughout, so the field ranges it produces
    /// are the offsets `NSTextView` and `NSRange` already speak in — building
    /// them from `String` indices and converting afterwards is one conversion
    /// too many on a path where an off-by-one writes into the user's file.
    private final class Parser {
        private static let dollar: unichar = 0x24
        private static let openBrace: unichar = 0x7B
        private static let closeBrace: unichar = 0x7D
        private static let colon: unichar = 0x3A
        private static let pipe: unichar = 0x7C
        private static let comma: unichar = 0x2C
        private static let backslash: unichar = 0x5C

        /// Six digits of tab stop index is already five more than anyone writes.
        /// A bound here is what stops a body of nothing but digits from being
        /// read as one enormous number.
        private static let maximumIndexDigits = 6

        private let units: [unichar]
        private var cursor = 0
        private var out: [unichar] = []
        private var found: [Field] = []
        private var defaults: [Int: [unichar]] = [:]
        private var finalCaret: Int?

        init(_ body: String) {
            self.units = Array(body.utf16)
            out.reserveCapacity(units.count)
        }

        func run() -> CodeSnippet {
            _ = scan(stoppingAtBrace: false)
            return CodeSnippet(
                text: String(decoding: out, as: UTF16.self),
                fields: found.sorted { ($0.index, $0.range.location) < ($1.index, $1.range.location) },
                finalCaret: finalCaret
            )
        }

        /// Copies input to output, turning markers into text as it goes.
        ///
        /// Returns true when it stopped on a closing brace it consumed, which is
        /// how the recursive call for a `${1:default}` reports that the default
        /// was actually terminated — and false when the input simply ran out,
        /// which makes the enclosing marker malformed.
        private func scan(stoppingAtBrace: Bool) -> Bool {
            while cursor < units.count {
                let unit = units[cursor]

                if unit == Self.backslash,
                   cursor + 1 < units.count,
                   Self.isEscapable(units[cursor + 1]) {
                    out.append(units[cursor + 1])
                    cursor += 2
                    continue
                }

                if stoppingAtBrace, unit == Self.closeBrace {
                    cursor += 1
                    return true
                }

                if unit == Self.dollar, consumeMarker() { continue }

                out.append(unit)
                cursor += 1
            }
            return false
        }

        /// Tries to read a marker, putting everything back if it cannot.
        ///
        /// The rollback is what makes "malformed passes through as literal text"
        /// true rather than aspirational: a half-read `${1:` has already
        /// appended characters and may have recorded nested fields, and all of
        /// that has to disappear before the `$` is emitted as itself.
        private func consumeMarker() -> Bool {
            let savedCursor = cursor
            let savedOut = out.count
            let savedFound = found.count
            let savedFinal = finalCaret
            let savedDefaults = defaults

            if parseMarker() { return true }

            cursor = savedCursor
            out.removeLast(out.count - savedOut)
            found.removeLast(found.count - savedFound)
            finalCaret = savedFinal
            defaults = savedDefaults
            return false
        }

        private func parseMarker() -> Bool {
            cursor += 1

            guard cursor < units.count else { return false }
            guard units[cursor] == Self.openBrace else {
                guard let index = parseIndex() else { return false }
                emitTabStop(index)
                return true
            }

            cursor += 1
            guard let index = parseIndex(), cursor < units.count else { return false }

            switch units[cursor] {
            case Self.closeBrace:
                cursor += 1
                emitTabStop(index)
                return true

            case Self.colon:
                cursor += 1
                let start = out.count
                guard scan(stoppingAtBrace: true) else { return false }
                emitPlaceholder(index, start: start, text: Array(out[start...]))
                return true

            case Self.pipe:
                cursor += 1
                guard let first = parseChoices() else { return false }
                let start = out.count
                out.append(contentsOf: first)
                emitPlaceholder(index, start: start, text: first)
                return true

            default:
                return false
            }
        }

        private func parseIndex() -> Int? {
            var digits = 0
            var value = 0
            while cursor < units.count, (0x30...0x39).contains(units[cursor]) {
                guard digits < Self.maximumIndexDigits else { return nil }
                value = value * 10 + Int(units[cursor] - 0x30)
                digits += 1
                cursor += 1
            }
            return digits > 0 ? value : nil
        }

        /// Reads `a,b,c|}` and hands back `a`.
        ///
        /// The whole list is parsed rather than only the first option, because
        /// the marker is only well-formed if it is *terminated* — and finding out
        /// that it is not is what sends the body through as literal text instead
        /// of silently eating the rest of the line.
        private func parseChoices() -> [unichar]? {
            var first: [unichar]?
            var current: [unichar] = []

            while cursor < units.count {
                let unit = units[cursor]

                if unit == Self.backslash,
                   cursor + 1 < units.count,
                   Self.isChoiceEscapable(units[cursor + 1]) {
                    current.append(units[cursor + 1])
                    cursor += 2
                    continue
                }

                if unit == Self.pipe {
                    guard cursor + 1 < units.count, units[cursor + 1] == Self.closeBrace else {
                        return nil
                    }
                    cursor += 2
                    return first ?? current
                }

                if unit == Self.comma {
                    if first == nil { first = current }
                    current = []
                    cursor += 1
                    continue
                }

                current.append(unit)
                cursor += 1
            }
            return nil
        }

        /// `$1` or `${1}`: a stop with nothing in it — except when the index has
        /// been seen before, where it becomes the static stand-in for mirroring
        /// and re-inserts that index's default.
        private func emitTabStop(_ index: Int) {
            guard index != 0 else {
                if finalCaret == nil { finalCaret = out.count }
                return
            }
            if found.contains(where: { $0.index == index }) {
                out.append(contentsOf: defaults[index] ?? [])
                return
            }
            found.append(Field(index: index, range: NSRange(location: out.count, length: 0), placeholder: ""))
            defaults[index] = []
        }

        /// `${1:default}` or `${1|a,b|}`: the text is already in `out` by the
        /// time this is called, so a repeated index keeps it and only declines to
        /// become a second navigable field.
        private func emitPlaceholder(_ index: Int, start: Int, text: [unichar]) {
            guard index != 0 else {
                if finalCaret == nil { finalCaret = start }
                return
            }
            guard !found.contains(where: { $0.index == index }) else { return }

            found.append(Field(
                index: index,
                range: NSRange(location: start, length: text.count),
                placeholder: String(decoding: text, as: UTF16.self)
            ))
            defaults[index] = text
        }

        /// `\$`, `\}` and `\\`, which is the set LSP defines outside a choice.
        /// `\{` is not among them, so it stays two characters — the same answer
        /// the grammar gives.
        private static func isEscapable(_ unit: unichar) -> Bool {
            unit == dollar || unit == closeBrace || unit == backslash
        }

        /// Inside a choice the separators become escapable too, since a comma or
        /// a bar is otherwise structure rather than text.
        private static func isChoiceEscapable(_ unit: unichar) -> Bool {
            isEscapable(unit) || unit == comma || unit == pipe
        }
    }
}

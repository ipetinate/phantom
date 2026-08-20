import Foundation

/// Whether a caret sits inside the value of a class attribute, and which class
/// it is sitting in.
///
/// This exists because of one measured fact about the Tailwind language
/// server: its `triggerCharacters` are `"`, `'`, `` ` ``, space, `-` and `:`.
/// It expects to be asked *inside a string* — which is the one place
/// `CodeCompletionTrigger` refuses to ask, since prose is nothing but
/// identifier characters and a 1-character trigger inside a comment is the
/// worst the list ever behaves. The exception has to be narrow enough that
/// the rule keeps its value, and "the caret is in a class attribute's value"
/// is that: it is decided by markup, not by a language, and it is nowhere
/// near ordinary prose.
///
/// **A class token is not an identifier**, and that is the second reason this
/// type exists. `w-1/2`, `bg-[#fff]`, `hover:underline` and `[&>*]:mt-2` are
/// all one class each, so the run the reader is completing ends at whitespace
/// or at the quote — never at the first character that is not a letter. Ask
/// the identifier rule for the prefix of `w-` and it answers *empty*, which
/// filters 11,000 candidates against nothing and shows them in the order the
/// server happened to send.
///
/// Line-local, and it stops at a newline for that reason. A `class="…"` is
/// always on one line in practice — Prettier cannot break inside a string
/// literal without changing it — so the bound costs nothing real and keeps
/// this affordable on the keystroke path.
struct CodeClassAttribute {
    /// The attribute names whose value is a list of classes.
    ///
    /// The first four are the Tailwind server's own `classAttributes` default,
    /// which is what makes this list a fact rather than a guess. `classlist`
    /// is here for Solid. Compared lowercased, so `className` and `CLASS`
    /// both match — HTML attribute names are case-insensitive, and JSX's are
    /// not but no dialect spells it a third way.
    ///
    /// Framework binding forms are handled by normalising the name rather
    /// than by listing them: Vue's `:class` and `v-bind:class`, Alpine's
    /// `x-bind:class` and Angular's `[ngClass]` all reduce to a name in this
    /// set. See `normalised(_:)`.
    static let attributeNames: Set<String> = [
        "class",
        "classname",
        "ngclass",
        "class:list",
        "classlist",
    ]

    /// The class the caret is inside, or nil when it is not in a class
    /// attribute at all.
    ///
    /// The range is in the same units and coordinates as `text` — UTF-16
    /// offsets from the start of whatever was handed in — because both
    /// callers already work that way: the trigger passes one line, the view
    /// passes the whole document.
    ///
    /// An **empty** range is a real answer and not a refusal: it is what
    /// `class="|"` produces, the moment the whole list should appear.
    static func tokenRange(
        in text: NSString,
        caret: Int,
        names: Set<String> = attributeNames
    ) -> NSRange? {
        let caret = max(0, min(caret, text.length))
        guard let quote = openingQuote(in: text, before: caret) else { return nil }
        guard let name = attributeName(in: text, endingAt: quote), names.contains(name) else {
            return nil
        }

        /// Back to the start of this class: whitespace separates one class
        /// from the next, and the quote bounds the first one.
        var start = caret
        while start > quote + 1, !isSpace(text.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    // MARK: Private

    /// The quote of the string the caret is in, scanning back over this line.
    ///
    /// The *nearest* quote, which is not the same as parsing the line's
    /// strings, and is right for a reason worth stating: when the caret is
    /// outside any string the nearest quote behind it is some string's
    /// *closing* quote, and the attribute-name check that follows then reads
    /// the string's own last characters and fails. `<p class="a" title="b|">`
    /// resolves; `<p class="a"|>` does not. The wrong guess is rejected one
    /// step later rather than avoided by a scan this path cannot afford.
    private static func openingQuote(in text: NSString, before caret: Int) -> Int? {
        var index = caret
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x0A || unit == 0x0D { return nil }
            if unit == 0x22 || unit == 0x27 || unit == 0x60 { return index - 1 }
            index -= 1
        }
        return nil
    }

    /// The attribute name immediately before a quote, normalised, or nil when
    /// what precedes the quote is not `name=` at all.
    private static func attributeName(in text: NSString, endingAt quote: Int) -> String? {
        var index = quote
        index = skippingSpace(in: text, from: index)

        /// JSX puts a brace between the `=` and the string —
        /// `` className={`flex ${x}`} `` and `className={"flex"}` are both
        /// ordinary React — so one is skipped. Only a brace: a paren would
        /// mean `className={cn("flex")}`, and a class *function* is a
        /// different rule with a different configuration behind it, which
        /// this version does not implement.
        if index > 0, text.character(at: index - 1) == 0x7B {
            index = skippingSpace(in: text, from: index - 1)
        }

        guard index > 0, text.character(at: index - 1) == 0x3D else { return nil }
        index = skippingSpace(in: text, from: index - 1)

        let end = index
        while index > 0, isNameUnit(text.character(at: index - 1)) {
            index -= 1
        }
        guard index < end else { return nil }

        return normalised(text.substring(with: NSRange(location: index, length: end - index)))
    }

    private static func skippingSpace(in text: NSString, from index: Int) -> Int {
        var index = index
        while index > 0, isSpace(text.character(at: index - 1)) {
            index -= 1
        }
        return index
    }

    /// `:class`, `v-bind:class`, `x-bind:class` and `[ngClass]` down to the
    /// name they bind.
    ///
    /// A prefix rule rather than five more entries in the set, because the
    /// list of frameworks that spell a binding with a prefix is open and the
    /// thing being bound is always the last segment. The brackets go first so
    /// Angular's form reduces before the colon rule looks at it.
    private static func normalised(_ name: String) -> String {
        let trimmed = name.lowercased().trimmingCharacters(in: bracket)
        guard let colon = trimmed.lastIndex(of: ":") else { return trimmed }

        /// `class:list` is a whole name, not a binding — Astro and Svelte
        /// spell it that way — so a suffix that is itself a known name is
        /// kept rather than reduced to `list`.
        let bound = String(trimmed[trimmed.index(after: colon)...])
        return attributeNames.contains(trimmed) ? trimmed : bound
    }

    private static let bracket = CharacterSet(charactersIn: "[]")

    /// Space and tab only. A newline is not "space" here — it ends the line,
    /// and the scan that meets one has left the attribute.
    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// What an attribute name is made of. `-`, `:` and `.` are in because
    /// `data-foo`, `v-bind:class` and Vue's `.prop` modifiers are, and
    /// brackets because Angular writes `[ngClass]`.
    private static func isNameUnit(_ unit: unichar) -> Bool {
        if unit == 0x2D || unit == 0x5F || unit == 0x3A || unit == 0x2E { return true }
        if unit == 0x5B || unit == 0x5D { return true }
        if unit >= 0x30, unit <= 0x39 { return true }
        if unit >= 0x41, unit <= 0x5A { return true }
        if unit >= 0x61, unit <= 0x7A { return true }
        return false
    }
}

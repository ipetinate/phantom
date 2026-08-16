import Foundation

/// Whether a keystroke should open the completion list, refine it, or put it
/// away.
///
/// Pure, and the reason is rule 2 of this feature's design: every *decision*
/// the popup makes is a function of values, and only the presentation touches a
/// window. A test host has no `NSApplication` event loop, so anything that
/// reaches `orderFront` hangs the whole suite rather than failing it — so the
/// interesting half of the popup lives here, where a test is three integers and
/// a string.
///
/// It also hardcodes no policy. The prefix length that opens the list and the
/// characters that force it open both arrive as values, because one is a user
/// preference and the other is a fact about whichever language server happens
/// to be attached.
struct CodeCompletionTrigger {
    /// Everything the decision needs, and nothing more.
    ///
    /// **The line, not the document.** This runs on the per-keystroke path, and
    /// a document-wide scan there is precisely the cost the rest of this editor
    /// is arranged to avoid — `CodeTextView` already declines to highlight
    /// whole files for the same reason. Whoever calls this knows the caret's
    /// line; asking them for it costs nothing and bounds the work at the length
    /// of one line.
    struct Context: Equatable {
        /// The caret's line, without its terminator.
        var line: String

        /// The caret's offset **in UTF-16 code units from the start of
        /// `line`**, matching the units TextKit and `NSRange` count in.
        var caretInLine: Int

        /// The character this keystroke inserted, or nil when the caret moved
        /// for some other reason — an arrow key, a click, a paste.
        ///
        /// Nil falls through to the last rule and closes an open list, which is
        /// the right answer to the question this function answers: a caret that
        /// arrived without typing anything arrived somewhere the list was not
        /// built for.
        ///
        /// **Deletion does not come through here, by design.** Backspace
        /// refines the list rather than closing it — the behaviour that was
        /// chosen, and what VS Code does — and the view drives that directly:
        /// it recomputes the prefix and calls `refilter` while the caret is
        /// still inside the prefix range the list was opened on, closing only
        /// when the prefix would empty out or the caret leaves it. That is the
        /// view's call and not this function's, because only the view knows
        /// which range the open list belongs to. Routing deletion through
        /// `decide` would mean guessing that from a single character, so do
        /// not "fix" the nil case to try.
        var typed: Character?

        /// Whether the caret sits inside a string literal or a comment.
        ///
        /// Taken as a value rather than worked out here, because deciding it
        /// properly needs the highlighter's tokens and this function is not
        /// allowed to walk the document to get them.
        var isInStringOrComment: Bool

        /// The characters the attached server said should force a request —
        /// `.` for most languages, `:` and `>` for some. Empty when there is no
        /// server, which is a legitimate state and not an error.
        var triggerCharacters: Set<Character>

        /// How many identifier characters must be typed before the list opens
        /// on its own.
        ///
        /// Defaults to 1, which is VS Code's behaviour and what was chosen
        /// here deliberately: a list that waits for three characters is a list
        /// you stop expecting. The cost is that at one character the list is
        /// large, which is paid for in `CodeCompletionFilter`'s ordering rather
        /// than by making the trigger shy.
        var minimumPrefix: Int = 1

        init(
            line: String,
            caretInLine: Int,
            typed: Character? = nil,
            isInStringOrComment: Bool = false,
            triggerCharacters: Set<Character> = [],
            minimumPrefix: Int = 1
        ) {
            self.line = line
            self.caretInLine = caretInLine
            self.typed = typed
            self.isInStringOrComment = isInStringOrComment
            self.triggerCharacters = triggerCharacters
            self.minimumPrefix = minimumPrefix
        }
    }

    /// What the view should do about this keystroke.
    ///
    /// Every case carrying a prefix range reports it **relative to
    /// `Context.line`**, since that is the only text the decision was allowed
    /// to see. The caller adds the line's own start offset to place it in the
    /// document.
    ///
    /// `close` and `ignore` differ only when a list is already open, and that
    /// difference matters: `close` ends the session, `ignore` says this
    /// keystroke was none of completion's business and the session — if there
    /// is one — should be left exactly as it was.
    enum Decision: Equatable {
        case open(prefix: NSRange)
        case refilter(prefix: NSRange)
        case close
        case ignore
    }

    /// The characters an identifier is made of, in every language this editor
    /// completes. TypeScript, Go, Swift and Kotlin agree; `$` is in because
    /// JavaScript puts it in names and jQuery made a whole idiom of it.
    static func isIdentifier(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }

    /// The identifier characters immediately behind the caret.
    ///
    /// Empty rather than nil when the caret follows something else: an empty
    /// prefix is a real state — it is what `.` and ⌃Space produce — not a
    /// failure to find one.
    ///
    /// Walks UTF-16 units directly instead of slicing substrings, because this
    /// runs on every keystroke and a line of nothing but identifier characters
    /// would otherwise allocate one `String` per character to throw it away
    /// again.
    static func prefixRange(in context: Context) -> NSRange {
        let line = context.line as NSString
        let caret = max(0, min(context.caretInLine, line.length))

        var start = caret
        while start > 0, isIdentifier(unit: line.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    /// The same rule at the code-unit level.
    ///
    /// A surrogate half stops the scan — `Unicode.Scalar.init` rejects one, and
    /// that is the answer we want: taken alone it is not a character at all,
    /// and none of the languages here put astral-plane symbols in identifiers,
    /// so stopping loses nothing real and keeps the walk allocation-free.
    private static func isIdentifier(unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return isIdentifier(Character(scalar))
    }

    /// The rules, in the order they are checked — the order is the design.
    ///
    /// 1. **Explicit wins outright.** ⌃Space opens with whatever prefix there
    ///    is, including none, and it deliberately ignores the string-and-comment
    ///    suppression below: asking for completions on purpose inside a string
    ///    is a request, not an accident, and refusing it would be the editor
    ///    telling the user they did not mean it.
    /// 2. **Inside a string or comment, every implicit trigger closes.** This
    ///    is where a 1-character trigger would otherwise be at its worst —
    ///    prose is nothing but identifier characters.
    /// 3. **A trigger character opens regardless of prefix length**, because
    ///    the prefix after `.` is empty by definition and that is exactly the
    ///    moment the list is most wanted.
    /// 4. **An identifier character opens at `minimumPrefix` and refines above
    ///    it.**
    /// 5. **Anything else closes.**
    static func decide(_ context: Context, isListOpen: Bool, isExplicit: Bool) -> Decision {
        let prefix = prefixRange(in: context)

        if isExplicit { return .open(prefix: prefix) }
        if context.isInStringOrComment { return .close }

        guard let typed = context.typed else { return .close }

        if context.triggerCharacters.contains(typed) { return .open(prefix: prefix) }

        if isIdentifier(typed) {
            if prefix.length < context.minimumPrefix {
                return isListOpen ? .refilter(prefix: prefix) : .ignore
            }
            return isListOpen ? .refilter(prefix: prefix) : .open(prefix: prefix)
        }

        return .close
    }
}

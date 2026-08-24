import Foundation

/// Which characters close themselves as they are typed, per language.
///
/// One table served every language until Rust. There `'` opens a lifetime
/// far more often than a character literal, and `&'a str` typed left to
/// right slips past the "touches a word" guard cleanly — at the instant the
/// `'` lands there is no letter on either side of it yet — so the editor
/// helped by producing `&''`, and a keystroke later `&'a'`. A missing closer
/// costs one keystroke. A spurious one costs two and a re-read of the line
/// to work out what happened, which is the cost that gets a feature like
/// this switched off.
///
/// `<` is in no table at all. In nearly every language it is less-than, and
/// comparison outnumbers markup even in a `.tsx` file. Tags are closed by
/// `CodeTagClose`, which decides at `>` and at `</` — the two places where
/// there is enough context to be right — and never at `<`.
struct CodeAutoClosePairs: Equatable, Sendable {
    private let pairs: [Character: Character]
    private let closers: Set<Character>
    private let quotes: Set<Character>

    /// The closer for an opener, or nil when the character opens nothing.
    ///
    /// Quotes map to themselves: typing one is either "open a string" or
    /// "step over the one already there" depending on what surrounds the
    /// caret, and both halves of that decision have to recognise the same
    /// character.
    func closer(for opener: Character) -> Character? {
        pairs[opener]
    }

    /// Whether typing this character could be a step-over rather than an
    /// insertion.
    ///
    /// Derived from the pair table rather than listed separately, so a
    /// language that drops a pair drops its step-over with it — in Rust,
    /// nothing ever auto-inserted a `'`, so there is never one to step over.
    func isCloser(_ character: Character) -> Bool {
        closers.contains(character)
    }

    /// Whether the touches-a-word rule applies to this character.
    func isQuote(_ character: Character) -> Bool {
        quotes.contains(character)
    }

    private init(pairs: [Character: Character], quotes: Set<Character>) {
        self.pairs = pairs
        self.closers = Set(pairs.values)
        self.quotes = quotes
    }

    /// Built once and shared: the tables are constant, and rebuilding a
    /// dictionary on every keystroke to look one character up in it is the
    /// kind of cost that only shows up on someone else's machine.
    private static let standard = CodeAutoClosePairs(
        pairs: ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"],
        quotes: ["\"", "'", "`"]
    )

    private static let withoutTheSingleQuote = CodeAutoClosePairs(
        pairs: ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`"],
        quotes: ["\"", "`"]
    )

    static func resolve(_ language: CodeLanguage) -> CodeAutoClosePairs {
        switch language {
        case .rust: return withoutTheSingleQuote
        case .javascript, .vue, .swift, .kotlin, .go, .python, .ruby, .shell,
             .json, .yaml, .toml, .markdown, .html, .css, .sql, .zig, .c, .php,
             .terraform, .plain:
            return standard
        }
    }
}

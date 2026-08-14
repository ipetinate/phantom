import Foundation

/// Turns source text into colored ranges.
///
/// **One regex, not one per kind.** The rules are compiled into a single
/// pattern with a named group per token kind and scanned left to right, so
/// each match consumes its whole range and nothing inside it is looked at
/// again. That is what makes the two cases naive highlighters get wrong
/// come out right:
///
/// - `const url = "http://x"` — the string alternative starts at the quote,
///   which comes first, so it swallows the `//` and no comment appears
/// - `// see "quoted"` — the comment starts first and swallows the quotes,
///   so no unterminated string bleeds into the rest of the file
///
/// Applying separate expressions and letting later ones overwrite earlier
/// ones cannot do this: both would match, and which won would depend on
/// the order they happened to run in.
struct SyntaxHighlighter {
    struct Token: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    let language: CodeLanguage

    /// The rules actually in force. For a file whose language this build
    /// ships this is just `language`'s own syntax; for one a contribution
    /// described, it carries that description.
    let syntax: LanguageSyntax

    private let regex: NSRegularExpression?

    /// Order is the precedence used when two kinds could start at the same
    /// index. Comment and string lead because they are the ones that must
    /// win — everything else is a detail inside them.
    private static let precedence: [TokenKind] = [
        .comment, .string, .attribute, .number, .keyword, .type, .function,
    ]

    /// Compiled once per language: building an `NSRegularExpression` is far
    /// more expensive than running one, and the viewport highlights on
    /// every scroll.
    private static let cache = Cache()

    init(language: CodeLanguage) {
        self.init(syntax: .builtIn(language))
    }

    init(syntax: LanguageSyntax) {
        self.language = syntax.base
        self.syntax = syntax
        self.regex = Self.cache.regex(for: syntax)
    }

    /// Tokens inside `range`, which the caller keeps to the visible
    /// viewport — highlighting a whole file on every keystroke is the cost
    /// this design exists to avoid.
    func tokens(in text: String, range: NSRange) -> [Token] {
        // A single-file component has no rules of its own: it is split into
        // its blocks and each is lexed by the language it actually holds.
        // The sub-languages are never `.vue`, so this cannot recurse.
        if language == .vue, syntax.isBuiltIn {
            return SFCRegions.regions(in: text).flatMap { region -> [Token] in
                let clipped = NSIntersectionRange(region.range, range)
                guard clipped.length > 0 else { return [] }
                return SyntaxHighlighter(language: region.language)
                    .tokens(in: text, range: clipped)
            }
        }

        guard let regex else { return [] }

        var tokens: [Token] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            for kind in Self.precedence {
                let group = match.range(withName: kind.rawValue)
                guard group.location != NSNotFound, group.length > 0 else { continue }
                tokens.append(Token(range: group, kind: kind))
                return
            }
        }
        return tokens
    }

    /// Builds the combined pattern. Exposed for the tests, which assert on
    /// the shape rather than only on results.
    static func pattern(for language: CodeLanguage) -> String? {
        pattern(for: .builtIn(language))
    }

    static func pattern(for syntax: LanguageSyntax) -> String? {
        let rules = SyntaxRules.rules(for: syntax)
        let byKind: [(TokenKind, String?)] = [
            (.comment, rules.comment),
            (.string, rules.string),
            (.attribute, rules.attribute),
            (.number, rules.number),
            (.keyword, rules.keyword),
            (.type, rules.type),
            (.function, rules.function),
        ]

        let groups = byKind.compactMap { kind, pattern -> String? in
            guard let pattern, !pattern.isEmpty else { return nil }
            return "(?<\(kind.rawValue)>\(pattern))"
        }
        return groups.isEmpty ? nil : groups.joined(separator: "|")
    }

    /// `NSRegularExpression` is safe to use from several threads once
    /// built, so instances are shared; only the building is serialized.
    ///
    /// The two halves are kept apart because they are keyed and bounded
    /// differently.
    ///
    /// A built-in language's rules are constant, so the enum is a complete
    /// key and the dictionary can hold at most one entry per case.
    ///
    /// A contributed language's rules are **not** constant for its id: the
    /// same `elixir` can be edited on disk and reloaded, and a cache keyed
    /// by the id would then answer with the rules the file used to have.
    /// So the key is the built pattern itself, which is exactly the identity
    /// of the thing being cached — same pattern, same regex — and the id
    /// never enters it at all. That also removes the collision between a
    /// contribution and a built-in of the same name, which is the state a
    /// promoted contribution is in by definition.
    ///
    /// Building the pattern on every lookup is the cost of that
    /// correctness; it is string concatenation against
    /// `NSRegularExpression` compilation, which is the expensive half and
    /// still cached. The ceiling is here because the key now comes from a
    /// file: an unbounded dictionary keyed by third-party input is a memory
    /// cost somebody else gets to choose.
    private final class Cache: @unchecked Sendable {
        /// Enough for far more contributed languages than a machine will
        /// have installed; small enough that the worst case is a rebuild,
        /// not a leak.
        static let contributedCeiling = 32

        private var builtIn: [CodeLanguage: NSRegularExpression] = [:]
        private var contributed: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(for syntax: LanguageSyntax) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }

            if syntax.isBuiltIn, let cached = builtIn[syntax.base] { return cached }

            guard let pattern = SyntaxHighlighter.pattern(for: syntax) else { return nil }
            if !syntax.isBuiltIn, let cached = contributed[pattern] { return cached }

            guard let built = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            ) else { return nil }

            if syntax.isBuiltIn {
                builtIn[syntax.base] = built
            } else {
                if contributed.count >= Self.contributedCeiling { contributed.removeAll() }
                contributed[pattern] = built
            }
            return built
        }
    }
}

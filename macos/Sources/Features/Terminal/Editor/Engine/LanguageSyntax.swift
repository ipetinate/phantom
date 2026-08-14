import Foundation

/// One language's lexical facts, as a value.
///
/// The highlighter and the comment commands take a `CodeLanguage` today,
/// and that was enough while every language was compiled in. A language
/// contributed from disk has no case in that enum to be: `CodeLanguage` is
/// `RawRepresentable`, so it cannot grow a `case custom(String)` — an
/// associated value has no raw value — and its `allCases` is iterated by
/// the tests that prove every language lexes.
///
/// So the engine takes this instead: the language it lexes *like*, plus the
/// handful of facts a contribution replaces. Nothing here is read from a
/// file. A manifest is parsed, validated and escaped outside the engine,
/// and what crosses the boundary is this value — which is how the engine
/// keeps naming nothing that touches a disk or a preference.
struct LanguageSyntax: Equatable, Sendable {
    struct BlockComment: Equatable, Sendable {
        let open: String
        let close: String
    }

    /// The language's identity: its `languageId` for a contribution, the
    /// enum's raw value for a built-in.
    ///
    /// Identity of the *language*, not of its rules. The same id can be
    /// edited on disk and mean something else a reload later, which is
    /// exactly why nothing caches compiled rules under it — see
    /// `SyntaxHighlighter.Cache`.
    let id: String

    /// The compiled-in language whose rules this one starts from.
    let base: CodeLanguage

    /// Words to paint as keywords. Empty for a built-in syntax, whose
    /// keywords live in `SyntaxRules` and are far richer than a list.
    let keywords: [String]

    let lineComment: String?
    let blockComment: BlockComment?

    /// Whether every field above came from the compiled-in tables.
    ///
    /// Two rules turn on it, and both are wrong the other way round. A
    /// contributed language's comment markers *replace* the base's comment
    /// pattern — the base is chosen for the shape of its strings and
    /// numbers, and `php` also matching `#` is not something `elixir`
    /// should inherit. And a contributed language with no keywords has *no*
    /// keywords, rather than quietly painting its base's.
    let isBuiltIn: Bool

    /// Private so a contributed syntax cannot be built claiming to be a
    /// built-in one: `isBuiltIn` decides how much of the base survives, and
    /// it is not a field a caller should be able to set.
    private init(
        id: String,
        base: CodeLanguage,
        keywords: [String],
        lineComment: String?,
        blockComment: BlockComment?,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.base = base
        self.keywords = keywords
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.isBuiltIn = isBuiltIn
    }

    /// The syntax of a language this build ships.
    static func builtIn(_ language: CodeLanguage) -> LanguageSyntax {
        LanguageSyntax(
            id: language.rawValue,
            base: language,
            keywords: [],
            lineComment: language.lineComment,
            blockComment: language.blockComment.map {
                BlockComment(open: $0.open, close: $0.close)
            },
            isBuiltIn: true
        )
    }

    /// The syntax of a language something outside the engine described.
    ///
    /// Every string here is expected to have been validated already — the
    /// keywords to an identifier charset in particular. The engine escapes
    /// them again on the way into a pattern anyway, because two independent
    /// defences is the only arrangement where removing one is survivable.
    static func contributed(
        id: String,
        base: CodeLanguage,
        keywords: [String],
        lineComment: String?,
        blockComment: BlockComment?
    ) -> LanguageSyntax {
        LanguageSyntax(
            id: id,
            base: base,
            keywords: keywords,
            lineComment: lineComment,
            blockComment: blockComment,
            isBuiltIn: false
        )
    }

    static let plain = LanguageSyntax.builtIn(.plain)
}

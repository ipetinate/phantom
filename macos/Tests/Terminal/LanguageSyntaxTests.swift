import Foundation
@testable import Ghostty
import Testing

/// The value a contributed language reaches the engine as, and the two
/// defences that keep a list of words from becoming a regex.
///
/// The keyword list is spliced into an alternation the highlighter runs over
/// the viewport on **every keystroke**, so a word containing `|`, `(` or
/// `.*` is not a cosmetic problem — it is injection on the hottest path in
/// the editor. The defences are independent on purpose: the manifest parser
/// keeps only identifier-shaped words, and this layer escapes whatever it is
/// handed anyway. The tests below deliberately bypass the first to prove the
/// second exists, because a single defence is one refactor from being no
/// defence.
struct LanguageSyntaxTests {
    private func tokens(_ syntax: LanguageSyntax, in text: String) -> [SyntaxHighlighter.Token] {
        SyntaxHighlighter(syntax: syntax).tokens(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private func contributed(
        id: String = "elixir",
        base: CodeLanguage = .plain,
        keywords: [String] = [],
        lineComment: String? = nil,
        blockComment: LanguageSyntax.BlockComment? = nil
    ) -> LanguageSyntax {
        .contributed(
            id: id,
            base: base,
            keywords: keywords,
            lineComment: lineComment,
            blockComment: blockComment
        )
    }

    // MARK: Built-in passthrough

    /// A built-in language's rules are the hand-written ones, untouched. They
    /// know things a pair of comment markers cannot say — that Markdown's
    /// "comment" is a block quote, that this build's CSS rules take `//`
    /// even though the language does not.
    @Test func aBuiltInSyntaxUsesTheHandWrittenRules() {
        for language in CodeLanguage.allCases {
            let direct = SyntaxRules.rules(for: language)
            let throughValue = SyntaxRules.rules(for: .builtIn(language))
            #expect(direct.comment == throughValue.comment, "\(language)")
            #expect(direct.keyword == throughValue.keyword, "\(language)")
            #expect(direct.string == throughValue.string, "\(language)")
        }
    }

    @Test func aBuiltInSyntaxCarriesTheLanguagesOwnCommentSyntax() {
        #expect(LanguageSyntax.builtIn(.swift).lineComment == "//")
        #expect(LanguageSyntax.builtIn(.swift).blockComment
            == LanguageSyntax.BlockComment(open: "/*", close: "*/"))
        #expect(LanguageSyntax.builtIn(.json).lineComment == nil)
        #expect(LanguageSyntax.builtIn(.swift).id == "swift")
        #expect(LanguageSyntax.builtIn(.swift).isBuiltIn)
        #expect(LanguageSyntax.builtIn(.swift).keywords.isEmpty)
    }

    /// A single-file component is still split into its blocks. The check that
    /// decides that now also asks whether the syntax is a built-in one, and
    /// getting it wrong would silently stop highlighting every `.vue` file.
    @Test func aBuiltInSFCStillLexesItsBlocks() {
        let source = """
        <script setup>
        const answer = 42
        </script>
        """
        #expect(!tokens(.builtIn(.vue), in: source).isEmpty)
    }

    // MARK: Contributed rules

    @Test func aContributedSyntaxReplacesTheKeywordsAndKeepsTheStrings() {
        let syntax = contributed(base: .python, keywords: ["defmodule", "do", "end"])
        let rules = SyntaxRules.rules(for: syntax)

        #expect(rules.keyword == SyntaxRules.words(["defmodule", "do", "end"]))
        #expect(rules.string == SyntaxRules.rules(for: .python).string)
        #expect(rules.number == SyntaxRules.rules(for: .python).number)
    }

    /// A contributed language with no keywords has *no* keywords. Painting
    /// its base's — Python's, for anything with `#` comments — would put
    /// `elif` in a language that has never heard of it.
    @Test func aContributedSyntaxWithNoKeywordsHasNoKeywordRule() {
        #expect(SyntaxRules.rules(for: contributed(base: .python)).keyword == nil)
        #expect(SyntaxRules.rules(for: .builtIn(.python)).keyword != nil)
    }

    /// The comment pattern is rebuilt from the manifest's own markers, not
    /// inherited: the base was chosen for the shape of its strings, and
    /// `python`'s decorator rule or `php`'s second comment marker are not
    /// things another language should acquire by association.
    @Test func aContributedSyntaxBuildsItsCommentFromItsOwnMarkers() {
        let syntax = contributed(
            base: .python,
            lineComment: "%",
            blockComment: LanguageSyntax.BlockComment(open: "%{", close: "%}")
        )
        let rules = SyntaxRules.rules(for: syntax)
        #expect(rules.comment == #"%[^\n]*|%\{[\s\S]*?%\}"#)

        #expect(!tokens(syntax, in: "% a comment").isEmpty)
        #expect(tokens(syntax, in: "# not a comment here").isEmpty)
    }

    @Test func aContributedSyntaxWithNoMarkersHasNoCommentRule() {
        #expect(SyntaxRules.rules(for: contributed(base: .python)).comment == nil)
    }

    // MARK: Escaping — the second defence

    /// The parser would never let this keyword through. It is constructed
    /// directly so that the escaping is proved on its own: unescaped,
    /// `a|b` would make the alternation match a bare `a`.
    @Test func aKeywordThatIsARegexIsMatchedLiterallyAndNotAsAPattern() {
        let syntax = contributed(keywords: ["a|b"])

        #expect(tokens(syntax, in: "a and b").isEmpty)
        #expect(!tokens(syntax, in: "a|b").isEmpty)
    }

    /// A word list from outside is escaped even when it looks harmless, so
    /// that nothing depends on remembering which lists were checked.
    @Test func escapingWordsQuotesEveryMetacharacter() {
        let pattern = SyntaxRules.words(escaping: [".*", "(a+)+$", "def"])
        #expect(pattern.contains(#"\.\*"#))
        #expect(pattern.contains(#"\(a\+\)\+\$"#))
        #expect(pattern.contains("def"))
        #expect(throws: Never.self) {
            try NSRegularExpression(pattern: pattern)
        }
    }

    /// Comment markers are escaped too — `*/` and `/*` are metacharacters
    /// before they are comments.
    @Test func commentMarkersAreEscaped() {
        let syntax = contributed(
            lineComment: "*",
            blockComment: LanguageSyntax.BlockComment(open: "(", close: ")")
        )
        let pattern = try? NSRegularExpression(
            pattern: SyntaxRules.rules(for: syntax).comment ?? ""
        )
        #expect(pattern != nil)
        #expect(!tokens(syntax, in: "* a comment").isEmpty)
    }

    /// Every rule set a hostile-but-parseable contribution can produce still
    /// compiles. A pattern that failed to build would turn highlighting off
    /// for the language rather than fail loudly.
    @Test func everyContributedPatternCompiles() {
        let candidates: [LanguageSyntax] = [
            contributed(keywords: ["a|b", "(", ")", "[", "]", "\\", "$", "^", "*"]),
            contributed(base: .javascript, keywords: ["def"], lineComment: "\\"),
            contributed(base: .css, lineComment: "|", blockComment: .init(open: "[", close: "]")),
            contributed(keywords: []),
        ]

        for syntax in candidates {
            guard let pattern = SyntaxHighlighter.pattern(for: syntax) else { continue }
            #expect(throws: Never.self) {
                try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            }
        }
    }

    // MARK: The rule cache

    /// The defect this test was written from: a cache keyed by the language
    /// id answers with the rules the file *used to* have. An id is stable
    /// across an edit — that is what an id is for — so editing a manifest
    /// and reloading kept the old keywords, and only a restart fixed it.
    @Test func editingAContributionChangesItsRulesUnderTheSameID() {
        let before = contributed(id: "elixir", keywords: ["defmodule"])
        let after = contributed(id: "elixir", keywords: ["defrecord"])

        #expect(!tokens(before, in: "defmodule Foo").isEmpty)
        #expect(tokens(after, in: "defmodule Foo").isEmpty)
        #expect(!tokens(after, in: "defrecord Foo").isEmpty)
    }

    /// The cache used to be keyed by a twenty-case enum and could not grow.
    /// Contributed entries are kept apart from built-in ones, so a
    /// contribution cannot poison the entry of a language it shares a name
    /// with — the state a promoted contribution is in by definition.
    /// The impostor is built first, so a shared cache key would already be
    /// populated by it when the real language is asked for.
    @Test func aContributedSyntaxCannotPoisonTheBuiltInOfTheSameName() {
        let impostor = contributed(id: "swift", keywords: ["zzz"])

        #expect(!tokens(impostor, in: "zzz").isEmpty)
        #expect(tokens(impostor, in: "func f() {}").isEmpty)

        let real = tokens(.builtIn(.swift), in: "func f() {}")
        #expect(real.contains { $0.kind == .keyword })
    }

    @Test func theSameContributedSyntaxTwiceBehavesTheSameWay() {
        let syntax = contributed(keywords: ["defmodule"], lineComment: "#")
        let first = tokens(syntax, in: "defmodule Foo # hi")
        let second = tokens(syntax, in: "defmodule Foo # hi")
        #expect(first == second)
        #expect(first.contains { $0.kind == .keyword })
        #expect(first.contains { $0.kind == .comment })
    }

    // MARK: End to end from a manifest

    @Test func aManifestsLanguageLexesThroughTheEngineWithoutTheManifest() throws {
        let json = #"""
        {
          "id": "acme.elixir",
          "contributes": {
            "languages": [{
              "languageId": "elixir",
              "extensions": ["ex"],
              "keywords": ["defmodule", "do", "end"],
              "lineComment": "#"
            }]
          }
        }
        """#
        let manifest = try #require(LanguageManifest.parse(
            data: Data(json.utf8),
            url: URL(fileURLWithPath: "/tmp/acme.elixir/extension.json"),
            root: URL(fileURLWithPath: "/tmp/acme.elixir"),
            scope: .user
        ))

        let syntax = try #require(manifest.languages.first).syntax
        #expect(syntax.id == "elixir")
        #expect(!syntax.isBuiltIn)
        #expect(syntax.base == .python)

        let found = tokens(syntax, in: "defmodule Foo do\n  # a note\nend")
        #expect(found.filter { $0.kind == .keyword }.count == 3)
        #expect(found.contains { $0.kind == .comment })
    }
}

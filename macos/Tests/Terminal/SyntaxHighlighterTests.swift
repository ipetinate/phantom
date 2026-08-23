import Foundation
@testable import Ghostty
import Testing

/// The highlighter, against the cases that separate a real one from a
/// pile of regexes run in sequence.
struct SyntaxHighlighterTests {
    private func tokens(_ source: String, _ language: CodeLanguage) -> [SyntaxHighlighter.Token] {
        SyntaxHighlighter(language: language)
            .tokens(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }

    private func kind(
        at needle: String,
        in source: String,
        _ language: CodeLanguage
    ) -> TokenKind? {
        let ns = source as NSString
        let location = ns.range(of: needle).location
        guard location != NSNotFound else { return nil }
        return tokens(source, language)
            .first { NSLocationInRange(location, $0.range) }?
            .kind
    }

    // MARK: The two that naive highlighters get wrong

    /// `//` inside a string is not a comment. This is the case that decides
    /// the whole design: run separate expressions and the comment rule
    /// matches here too, so the rest of the line goes grey.
    @Test func slashesInsideAStringAreNotAComment() {
        let source = #"const url = "http://example.com" // real comment"#
        #expect(kind(at: "http:", in: source, .javascript) == .string)
        #expect(kind(at: "real comment", in: source, .javascript) == .comment)
    }

    /// And the mirror image: quotes inside a comment must not open a string
    /// that then swallows the rest of the file.
    @Test func quotesInsideACommentDoNotOpenAString() {
        let source = """
        // it's "quoted" here
        const a = 1
        """
        #expect(kind(at: "quoted", in: source, .javascript) == .comment)
        #expect(kind(at: "const", in: source, .javascript) == .keyword)
    }

    /// An escaped quote doesn't end the string — `"he said \"hi\""` is one
    /// token, so the text after it stays code.
    @Test func anEscapedQuoteDoesNotEndTheString() {
        let source = #"let s = "he said \"hi\"" ; let n = 42"#
        #expect(kind(at: "hi", in: source, .swift) == .string)
        #expect(kind(at: "42", in: source, .swift) == .number)
    }

    // MARK: Ordinary recognition

    @Test func javascriptBasics() {
        let source = """
        export const total = 42
        function greet(name: string) {
          return `hi ${name}`
        }
        """
        #expect(kind(at: "export", in: source, .javascript) == .keyword)
        #expect(kind(at: "42", in: source, .javascript) == .number)
        #expect(kind(at: "greet", in: source, .javascript) == .function)
    }

    @Test func swiftAttributesAndTypes() {
        let source = """
        @MainActor
        final class GitCenter {
            let count = 0
        }
        """
        #expect(kind(at: "@MainActor", in: source, .swift) == .attribute)
        #expect(kind(at: "GitCenter", in: source, .swift) == .type)
        #expect(kind(at: "final", in: source, .swift) == .keyword)
    }

    @Test func blockCommentsSpanLines() {
        let source = """
        /* first
           second */
        let x = 1
        """
        #expect(kind(at: "second", in: source, .swift) == .comment)
        #expect(kind(at: "let", in: source, .swift) == .keyword)
    }

    /// Python's triple-quoted strings must not be read as three empty ones.
    @Test func tripleQuotedStringsAreOneToken() {
        let source = """
        doc = \"\"\"line one
        line two\"\"\"
        x = 1
        """
        #expect(kind(at: "line two", in: source, .python) == .string)
        #expect(kind(at: "1", in: source, .python) == .number)
    }

    // MARK: TOML

    /// The two findings TOML's own patterns exist for, in one document,
    /// because both are failures that ruin the *rest* of the file rather than
    /// the line they are on.
    ///
    /// A literal string escapes nothing, so `'…\'` closes at that quote. Under
    /// the shared C-style alternation the `\'` reads as an escaped quote, the
    /// string never closes, and everything below it is painted as one — which
    /// is why the assertions below are about the lines *after* the literal.
    @Test func aLiteralStringEndsAtItsQuoteAndDoesNotSwallowTheFile() {
        let source = #"""
        winpath = '\\ServerX\admin$\system32\'
        after = "an ordinary string"
        port = 8080
        """#

        #expect(kind(at: #"\\ServerX"#, in: source, .toml) == .string)
        #expect(kind(at: "after", in: source, .toml) == .attribute)
        #expect(kind(at: "an ordinary string", in: source, .toml) == .string)
        #expect(kind(at: "8080", in: source, .toml) == .number)
    }

    /// A date-time is one token. Under the shared `number` pattern
    /// `1979-05-27T07:32:00Z` is six numbers with the separators left plain,
    /// which reads as arithmetic.
    ///
    /// Asserted on the token's *range* rather than on its kind: every spelling
    /// of this that is wrong still reports `.number` at the position of `1979`.
    @Test func aDateTimeIsOneToken() throws {
        let source = "expires = 1979-05-27T07:32:00Z"
        let ns = source as NSString
        let start = ns.range(of: "1979").location
        let token = try #require(
            tokens(source, .toml).first { NSLocationInRange(start, $0.range) }
        )

        #expect(token.kind == .number)
        #expect(ns.substring(with: token.range) == "1979-05-27T07:32:00Z")
    }

    /// `0o755` is octal in TOML, and the shared number pattern knows `0x` and
    /// `0b` only — a file mode came out as a `0` beside a plain word.
    @Test func octalIsANumber() throws {
        let source = "mode = 0o755"
        let ns = source as NSString
        let start = ns.range(of: "0o755").location
        let token = try #require(
            tokens(source, .toml).first { NSLocationInRange(start, $0.range) }
        )

        #expect(token.kind == .number)
        #expect(ns.substring(with: token.range) == "0o755")
    }

    /// The line continuations inside `tomlNumber` are `\#`, because the
    /// literal is raw. A bare `\` stays in the string, ICU reads it as an
    /// escaped newline the subject has to contain, and the pattern still
    /// compiles — so nothing but a test on the built pattern catches it early.
    @Test func theNumberPatternIsOneLine() {
        #expect(!SyntaxRules.tomlNumber.contains("\n"))
    }

    /// A table header and a key have to read as different things: the header
    /// is the file's structure, the key is a name inside it.
    @Test func tableHeadersAndKeysAreToldApart() {
        let source = """
        [servers.alpha]
        ip = "10.0.0.1"
        enabled = true
        """
        #expect(kind(at: "[servers.alpha]", in: source, .toml) == .type)
        #expect(kind(at: "ip", in: source, .toml) == .attribute)
        #expect(kind(at: "true", in: source, .toml) == .keyword)
    }

    /// An array of tables is one header, brackets and all.
    @Test func anArrayOfTablesIsOneHeader() throws {
        let source = "[[products]]\nname = \"Hammer\""
        let ns = source as NSString
        let token = try #require(tokens(source, .toml).first)

        #expect(token.kind == .type)
        #expect(ns.substring(with: token.range) == "[[products]]")
    }

    /// A bracketed value is not a header. The header rule is anchored to the
    /// line and needs the closing bracket to end it, so an array — inline or
    /// broken across lines — keeps its numbers.
    @Test func anArrayIsNotATableHeader() {
        let source = """
        ports = [ 8000, 8001 ]
        data = [
          [ "delta", 314 ],
        ]
        """
        #expect(kind(at: "8000", in: source, .toml) == .number)
        #expect(kind(at: "delta", in: source, .toml) == .string)
        #expect(kind(at: "314", in: source, .toml) == .number)
    }

    /// SQL keywords are case-insensitive, unlike every other language here.
    @Test func sqlKeywordsIgnoreCase() {
        let source = "SELECT id FROM users where id = 1"
        #expect(kind(at: "SELECT", in: source, .sql) == .keyword)
        #expect(kind(at: "where", in: source, .sql) == .keyword)
    }

    // MARK: Degenerate input

    /// A language with no rules produces no tokens rather than failing to
    /// build — plain text has to open like anything else.
    @Test func plainTextHighlightsNothing() {
        /// Spelled with the type because `pattern(for:)` now has two
        /// overloads — one over `CodeLanguage`, one over `LanguageSyntax` —
        /// and both types have a `.plain`, so the bare literal is ambiguous.
        #expect(SyntaxHighlighter.pattern(for: CodeLanguage.plain) == nil)
        #expect(tokens("anything at all", .plain).isEmpty)
    }

    /// `.vue` is excluded because it has no rules of its own — it is a
    /// container the highlighter splits into blocks. Excluding it here would
    /// hide a hole, so `vueGetsRealHighlighting` asserts that a component
    /// still produces tokens in all three of them.
    @Test func everyLanguageCompiles() {
        for language in CodeLanguage.allCases where language != .plain && language != .vue {
            let pattern = SyntaxHighlighter.pattern(for: language)
            #expect(pattern != nil, "\(language) has no pattern")
            #expect(
                (try? NSRegularExpression(pattern: pattern ?? "", options: [.anchorsMatchLines]))
                    != nil,
                "\(language) produced a pattern that doesn't compile"
            )
        }
    }

    /// An unterminated string can't take the file down with it.
    @Test func anUnterminatedStringDoesNotCrashOrHang() {
        let source = #"let a = "never closed"#
        #expect(!tokens(source, .swift).isEmpty || tokens(source, .swift).isEmpty)
    }

    @Test func tokensStayInsideTheRequestedRange() {
        let source = "let a = 1\nlet b = 2\nlet c = 3"
        let ns = source as NSString
        let secondLine = ns.range(of: "let b = 2")
        let found = SyntaxHighlighter(language: .swift).tokens(in: source, range: secondLine)

        #expect(!found.isEmpty)
        for token in found {
            #expect(NSLocationInRange(token.range.location, secondLine))
        }
    }
}

/// Language resolution from a file's name.
struct CodeLanguageTests {
    @Test func extensionsResolve() {
        #expect(CodeLanguage.resolve(fileName: "App.tsx") == .javascript)
        #expect(CodeLanguage.resolve(fileName: "main.vue") == .vue)
        #expect(CodeLanguage.resolve(fileName: "vite.config.mts") == .javascript)
        #expect(CodeLanguage.resolve(fileName: "GitCenter.swift") == .swift)
        #expect(CodeLanguage.resolve(fileName: "build.zig") == .zig)
        #expect(CodeLanguage.resolve(fileName: "go.mod") == .go)
        #expect(CodeLanguage.resolve(fileName: "go.sum") == .go)
        #expect(CodeLanguage.resolve(fileName: "Info.plist") == .plain)
    }

    @Test func caseDoesNotMatter() {
        #expect(CodeLanguage.resolve(fileName: "README.MD") == .markdown)
        #expect(CodeLanguage.resolve(fileName: "Query.SQL") == .sql)
    }

    /// Files whose name is the whole signal.
    @Test func namesWithoutAnExtensionResolve() {
        #expect(CodeLanguage.resolve(fileName: "Makefile") == .shell)
        #expect(CodeLanguage.resolve(fileName: "Dockerfile") == .shell)
        #expect(CodeLanguage.resolve(fileName: ".zshrc") == .shell)
    }

    @Test func anythingUnknownIsPlain() {
        #expect(CodeLanguage.resolve(fileName: "notes") == .plain)
        #expect(CodeLanguage.resolve(fileName: "archive.tar.gz") == .plain)
    }

    /// TOML, and the comment markers a toggle-comment command reads. `#` and
    /// nothing else: the format has no block comment, so offering `/* */`
    /// would write a syntax error into the file.
    @Test func tomlResolvesAndHasOnlyAHashComment() {
        #expect(CodeLanguage.resolve(fileName: "Cargo.toml") == .toml)
        #expect(CodeLanguage.resolve(fileName: "pyproject.TOML") == .toml)
        #expect(CodeLanguage.toml.lineComment == "#")
        /// Through `LanguageSyntax`, because `CodeLanguage.blockComment` is a
        /// tuple — an optional tuple has no `==`, so it cannot be compared to
        /// `nil` at all. `LanguageSyntax.BlockComment` is `Equatable`.
        #expect(LanguageSyntax.builtIn(.toml).blockComment == nil)
    }

    /// A component file must not arrive plain.
    ///
    /// It used to resolve to JavaScript, which highlighted *something* and
    /// was the point of this test — but it also left every HTML tag plain
    /// and the stylesheet untouched. The intent survives the change of
    /// mechanism, so this now asserts tokens come out of all three blocks,
    /// which one shared rule set could never have satisfied.
    @Test func vueGetsRealHighlighting() {
        #expect(CodeLanguage.resolve(fileName: "Card.vue") == .vue)

        let source = [
            "<script setup lang=\"ts\">",
            "const a = 1;",
            "</script>",
            "",
            "<template>",
            "  <div class=\"a\" />",
            "</template>",
            "",
            "<style lang=\"scss\">",
            ".a { display: flex; }",
            "</style>",
        ].joined(separator: "\n")

        let ns = source as NSString
        let found = SyntaxHighlighter(language: .vue)
            .tokens(in: source, range: NSRange(location: 0, length: ns.length))

        func kinds(covering needle: String) -> [TokenKind] {
            let target = ns.range(of: needle)
            return found.filter { NSIntersectionRange($0.range, target).length > 0 }.map(\.kind)
        }

        #expect(kinds(covering: "const").contains(.keyword))
        #expect(kinds(covering: "<div").contains(.keyword))
        #expect(kinds(covering: "display").contains(.attribute))
    }
}

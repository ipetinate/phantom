import Foundation
@testable import Ghostty
import Testing

struct SyntaxOverlayTests {
    private func tokens(_ syntax: LanguageSyntax, in text: String) -> [SyntaxHighlighter.Token] {
        SyntaxHighlighter(syntax: syntax).tokens(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private func kinds(_ syntax: LanguageSyntax, in text: String) -> [TokenKind] {
        tokens(syntax, in: text).map(\.kind)
    }

    private func lua(patterns: LanguageSyntax.Patterns) -> LanguageSyntax {
        .contributed(
            id: "lua",
            base: .sql,
            keywords: ["local", "function", "end"],
            lineComment: "--",
            blockComment: LanguageSyntax.BlockComment(open: "--[[", close: "]]"),
            patterns: patterns
        )
    }

    private static let luaString = #"\[=*\[[\s\S]*?\]=*\]|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#

    // MARK: Each kind

    @Test func aContributedStringPatternReplacesTheBases() {
        let syntax = lua(patterns: .init(string: Self.luaString))
        let rules = SyntaxRules.rules(for: syntax)

        #expect(rules.string == Self.luaString)
        #expect(rules.string != SyntaxRules.rules(for: .sql).string)
        #expect(kinds(syntax, in: #"x = [[a long bracket string]]"#).contains(.string))
        #expect(kinds(syntax, in: #"x = "double quoted""#).contains(.string))
    }

    @Test func aContributedNumberPatternReplacesTheBases() {
        let hexOnly = #"\b0[xX][0-9a-fA-F]+\b"#
        let syntax = lua(patterns: .init(number: hexOnly))

        #expect(SyntaxRules.rules(for: syntax).number == hexOnly)
        #expect(kinds(syntax, in: "0xFF").contains(.number))
        #expect(!kinds(syntax, in: "42").contains(.number))
    }

    @Test func aContributedTypePatternReplacesTheBases() {
        let syntax = lua(patterns: .init(type: SyntaxRules.capitalizedType))

        #expect(SyntaxRules.rules(for: .sql).type == nil)
        #expect(SyntaxRules.rules(for: syntax).type == SyntaxRules.capitalizedType)
        #expect(kinds(syntax, in: "Player").contains(.type))
    }

    @Test func aContributedFunctionPatternReplacesTheBases() {
        let syntax = lua(patterns: .init(function: SyntaxRules.callBeforeParen))

        #expect(SyntaxRules.rules(for: .sql).function == nil)
        #expect(SyntaxRules.rules(for: syntax).function == SyntaxRules.callBeforeParen)
        #expect(kinds(syntax, in: "print(1)").contains(.function))
    }

    @Test func aContributedAttributePatternReplacesTheBases() {
        let label = "::[A-Za-z_][A-Za-z0-9_]*::"
        let syntax = lua(patterns: .init(attribute: label))

        #expect(SyntaxRules.rules(for: syntax).attribute == label)
        #expect(kinds(syntax, in: "::continue::").contains(.attribute))
    }

    // MARK: What stays

    @Test func aKindWithoutAPatternKeepsTheBases() {
        let syntax = lua(patterns: .init(string: Self.luaString))
        let rules = SyntaxRules.rules(for: syntax)
        let base = SyntaxRules.rules(for: .sql)

        #expect(rules.number == base.number)
        #expect(rules.type == base.type)
        #expect(rules.function == base.function)
        #expect(rules.attribute == base.attribute)
    }

    @Test func keywordsAndCommentsStillComeFromTheContribution() {
        let syntax = lua(patterns: .init(
            string: Self.luaString,
            number: SyntaxRules.number,
            type: SyntaxRules.capitalizedType,
            function: SyntaxRules.callBeforeParen,
            attribute: "::[A-Za-z_]+::"
        ))
        let rules = SyntaxRules.rules(for: syntax)

        #expect(rules.keyword == SyntaxRules.words(["local", "function", "end"]))
        #expect(rules.comment == SyntaxRules.comment(
            line: "--",
            block: LanguageSyntax.BlockComment(open: "--[[", close: "]]")
        ))
        #expect(kinds(syntax, in: "-- a comment") == [.comment])
        #expect(kinds(syntax, in: "local x").first == .keyword)
    }

    @Test func aBuiltInSyntaxIgnoresPatternsEntirely() {
        for language in CodeLanguage.allCases {
            let direct = SyntaxRules.rules(for: language)
            let viaValue = SyntaxRules.rules(for: .builtIn(language))
            #expect(direct.string == viaValue.string, "\(language)")
            #expect(direct.attribute == viaValue.attribute, "\(language)")
        }
        #expect(LanguageSyntax.builtIn(.swift).patterns.isEmpty)
    }

    @Test func patternsGiveAPlainBasedContributionRealHighlighting() {
        let syntax = LanguageSyntax.contributed(
            id: "mylang",
            base: .plain,
            keywords: ["let"],
            lineComment: "#",
            blockComment: nil,
            patterns: .init(
                string: SyntaxRules.cStyleString,
                number: SyntaxRules.number,
                type: SyntaxRules.capitalizedType,
                function: SyntaxRules.callBeforeParen
            )
        )

        let found = Set(kinds(syntax, in: #"let x = foo(Bar, "hi", 42) # done"#))
        #expect(found == [.keyword, .type, .function, .string, .number, .comment])
    }

    @Test func changingAPatternUnderTheSameIDChangesTheRules() {
        let before = lua(patterns: .init(number: #"\b\d+\b"#))
        let after = lua(patterns: .init(number: #"\b0x[0-9a-f]+\b"#))

        #expect(kinds(before, in: "42").contains(.number))
        #expect(!kinds(after, in: "42").contains(.number))
        #expect(kinds(after, in: "0xff").contains(.number))
    }
}

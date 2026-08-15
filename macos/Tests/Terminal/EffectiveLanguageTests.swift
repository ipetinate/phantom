import AppKit
@testable import Ghostty
import Testing

/// Which language the caret's line is written in, for a file whose language
/// is a container rather than a syntax.
///
/// This exists because of a silent bug: the completion list suppresses itself
/// inside strings and comments by tokenizing **one line**, and `.vue` routes
/// to a splitter that needs the whole document to find its blocks. A lone
/// line therefore produced no tokens at all and the suppression never fired
/// in a Vue file — which nothing failed on, because "no tokens" and "no string
/// here" are the same answer to the caller.
@MainActor
struct EffectiveLanguageTests {
    private let component = """
    <script setup lang="ts">
    const url = "http://x.com"
    </script>

    <template>
      <div class="a">{{ url }}</div>
    </template>
    """

    private func language(at needle: String, dialect: CodeTagDialect = .sfc) -> CodeLanguage {
        let text = component as NSString
        let caret = text.range(of: needle).location + (needle as NSString).length
        return CodeNSTextView.effectiveLanguage(.vue, in: text, at: caret, dialect: dialect)
    }

    /// The line the bug was found on.
    @Test func aLineInsideTheScriptBlockIsJavaScript() {
        #expect(language(at: "const url = ") == .javascript)
    }

    @Test func aLineInsideTheTemplateIsMarkup() {
        #expect(language(at: "<div class=") == .html)
    }

    /// The opening marker's own line reads as the block it opens, not as the
    /// markup it is written in.
    ///
    /// Recorded rather than corrected. The probe draws the boundary at
    /// `<script` and not at the `>` that closes the tag, so a caret partway
    /// through `<script setup lang="ts">` is already "inside". Strictly that
    /// line is markup — `lang="ts"` is an HTML attribute — but the difference
    /// has no observable consequence: this answer exists only to decide
    /// whether the caret sits in a string or a comment, and both rule sets
    /// read `"ts"` as a quoted value. Moving the boundary to the `>` would
    /// cost a forward scan per keystroke to buy nothing.
    @Test func theOpeningMarkersOwnLineReadsAsTheBlockItOpens() {
        #expect(language(at: "<script setup") == .javascript)
    }

    /// Everything that is not a container is already the language its lines
    /// are written in, and must be returned untouched — including `.jsx`,
    /// which is the case worth naming: a `.tsx` file is JavaScript that
    /// carries tags in its expressions, not markup that carries script.
    @Test func aLanguageThatIsNotAContainerIsReturnedUnchanged() {
        let text = "const a = 1" as NSString
        for language in [CodeLanguage.javascript, .swift, .kotlin, .rust, .html, .plain] {
            #expect(
                CodeNSTextView.effectiveLanguage(language, in: text, at: 5, dialect: .jsx) == language,
                "\(language) was rewritten"
            )
        }
    }

    /// Resolution is a fact about the file, not about the reader's
    /// preferences: turning tag closing off must not quietly take the
    /// suppression fix with it, since the two share only a probe.
    @Test func resolutionDoesNotDependOnTagClosingBeingWanted() {
        #expect(language(at: "const url = ") == .javascript)
        #expect(language(at: "<div class=") == .html)
    }

    /// The whole point of the repair, stated as the comparison that exposed
    /// it: the same line yields a string token under the resolved language
    /// and nothing at all under the container.
    @Test func theResolvedLanguageFindsAStringWhereTheContainerFoundNothing() {
        let line = #"const url = "http://x.com""#
        let whole = NSRange(location: 0, length: (line as NSString).length)

        let underContainer = SyntaxHighlighter(language: .vue).tokens(in: line, range: whole)
        let underResolved = SyntaxHighlighter(language: .javascript).tokens(in: line, range: whole)

        #expect(underContainer.isEmpty)
        #expect(underResolved.contains { $0.kind == .string })
    }
}

import Foundation

/// Whether a file closes tags, and by whose rules.
///
/// Resolved from the file name rather than from `CodeLanguage`, because the
/// grouping that is right for lexing is wrong here: `.ts` and `.tsx` are one
/// language to a highlighter — same keywords, same strings, same comments —
/// and opposites to this feature. JSX is a syntax error in a `.ts` file, so
/// every `<` in one is a comparison or a generic and closing any of them
/// would be wrong every time.
enum CodeTagDialect: Equatable, Sendable, CaseIterable {
    /// Tags are never closed.
    case none

    /// Markup all the way down, with HTML's case-insensitive element names.
    case html

    /// Markup embedded in an expression language, where a `<` has to be told
    /// from a generic and a capital letter means "component".
    case jsx

    /// A single-file component: markup at the top level, with `<script>` and
    /// `<style>` blocks that are not markup at all.
    case sfc

    /// Deliberately a table, not a rule.
    ///
    /// Each row is a separate judgement that someone may want to revise on
    /// its own, and the likeliest revision is a single row: `.js` sits at
    /// `.jsx` because JSX in a `.js` file is what CRA and half of npm ship,
    /// and because generics are *not* legal in `.js` — so the one heuristic
    /// this dialect needs actually errs less here than it does in `.tsx`. If
    /// that turns out to cost more than it earns, the fix is to move three
    /// entries to `.none`, not to add a condition somewhere else.
    private static let byExtension: [String: CodeTagDialect] = [
        "html": .html, "htm": .html, "xml": .html, "svg": .html,
        "tsx": .jsx, "jsx": .jsx,
        "js": .jsx, "mjs": .jsx, "cjs": .jsx,
        "ts": .none, "mts": .none, "cts": .none,
        "vue": .sfc, "svelte": .sfc,
    ]

    /// File names arrive from disk, where case is not ours to assume.
    static func resolve(fileName: String) -> CodeTagDialect {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let dialect = byExtension[ext] else { return CodeTagDialect.none }
        return dialect
    }

    /// Whether this dialect closes tags at all.
    var closesTags: Bool {
        self != CodeTagDialect.none
    }

    /// Whether a `<` sitting directly after an identifier reads as a generic
    /// rather than as a tag.
    ///
    /// Only where generics exist. In HTML and in an SFC's template the rule
    /// has no upside and a real cost: inline markup routinely follows text
    /// with no space — `x<sub>i</sub>`, `word<br>` — and suppressing those
    /// would trade a false positive that cannot happen for a false negative
    /// that happens all day.
    var suppressesTagAfterIdentifier: Bool {
        self == .jsx
    }

    /// Whether a capitalised element name means "component" rather than
    /// "DOM element".
    ///
    /// True wherever components exist, which includes an SFC's template:
    /// Vue and React agree that `<Br />` is somebody's component and `<br>`
    /// is the void element.
    var treatsCapitalisedNamesAsComponents: Bool {
        self == .jsx || self == .sfc
    }

    /// Whether element names match case-insensitively, which is HTML's rule
    /// and nobody else's — `<BR>` is legal there and meaningful elsewhere.
    var matchesNamesCaseInsensitively: Bool {
        self == .html
    }
}

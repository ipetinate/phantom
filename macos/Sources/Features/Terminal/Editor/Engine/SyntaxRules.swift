import Foundation

/// The patterns for one language, one per token kind.
///
/// A kind gets a single pattern — alternate inside it rather than adding a
/// second entry — because the highlighter compiles these into one regex
/// with a named group per kind, and a name can only appear once.
struct SyntaxRules {
    var comment: String?
    var string: String?
    var number: String?
    var keyword: String?
    var type: String?
    var function: String?
    var attribute: String?

    /// `\b(?:a|b|c)\b` from a word list.
    ///
    /// The list is spliced into a regex verbatim, which is safe for the
    /// tables in this file and **not** safe for a list from anywhere else —
    /// see `words(escaping:)`.
    static func words(_ list: [String]) -> String {
        "\\b(?:" + list.joined(separator: "|") + ")\\b"
    }

    /// `words(_:)` for a list this file did not write.
    ///
    /// `words(_:)` joins its arguments into an alternation, so a word
    /// containing `|`, `(` or `.*` is not a word at all — it is regex
    /// injected into the pattern the highlighter runs on every keystroke,
    /// costing wrong colours at best and catastrophic backtracking at
    /// worst. Escaping here is the second of two independent defences; the
    /// first is the identifier charset a contributed keyword has to pass
    /// before it reaches this type. Either alone is one refactor away from
    /// being the only one.
    static func words(escaping list: [String]) -> String {
        words(list.map { NSRegularExpression.escapedPattern(for: $0) })
    }

    /// A comment pattern from a language's own markers.
    ///
    /// Only used for contributed languages: a built-in keeps the hand-written
    /// pattern from the table below, which knows things a pair of markers
    /// cannot say — that Markdown's "comment" is a block quote, that CSS
    /// takes `//` even though the language does not.
    static func comment(
        line: String?,
        block: LanguageSyntax.BlockComment?
    ) -> String? {
        var alternatives: [String] = []
        if let line, !line.isEmpty {
            alternatives.append(NSRegularExpression.escapedPattern(for: line) + #"[^\n]*"#)
        }
        if let block, !block.open.isEmpty, !block.close.isEmpty {
            alternatives.append(
                NSRegularExpression.escapedPattern(for: block.open)
                    + #"[\s\S]*?"#
                    + NSRegularExpression.escapedPattern(for: block.close)
            )
        }
        return alternatives.isEmpty ? nil : alternatives.joined(separator: "|")
    }

    /// A double- or single-quoted run that ends at the closing quote and
    /// **survives escapes**: `"he said \"hi\""` is one string, not two.
    /// `(?:[^"\\]|\\.)*` is what does it — any character that isn't a quote
    /// or a backslash, or a backslash followed by anything at all.
    static let cStyleString =
        #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#

    static let cStyleComment = #"//[^\n]*|/\*[\s\S]*?\*/"#

    static let hashComment = #"#[^\n]*"#

    /// TOML's four string forms, and the one place its strings differ from
    /// every other language in this file: a *literal* string escapes nothing.
    ///
    /// `path = 'C:\dir\'` is the spec's own example of why literal strings
    /// exist, and the C-style alternation reads that `\'` as an escaped quote
    /// — so the string never closes and the rest of the file is painted as
    /// one. A literal string ends at the next `'`, and cannot span a line.
    static let tomlString =
        #""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\]|\\.)*"|'[^'\n]*'"#

    /// TOML's numbers, which are the shared `number` plus the two spellings a
    /// configuration format uses and a programming language does not.
    ///
    /// A date-time is one token: `expires = 1979-05-27T07:32:00Z` under the
    /// shared pattern is six numbers with the separators left plain, which
    /// reads as arithmetic. And `0o755` is octal here — the shared pattern
    /// knows `0x` and `0b` only, so a file mode came out as a `0` beside a
    /// word. The date alternative leads because the alternation is
    /// first-match, not longest-match: `\d[\d_]*` would take `1979` and stop.
    ///
    /// The line continuations are `\#` and not `\`, because this is a **raw**
    /// multi-line literal: inside `#"""…"""#` the escape marker is `\#`, so a
    /// bare `\` before the newline stays in the string and ICU reads it as an
    /// escaped newline the subject has to contain. Written that way the whole
    /// pattern compiles and matches almost nothing — `0o755` was the one
    /// alternative that survived, because it is the only one with a `|` on
    /// both sides of it on the same line.
    static let tomlNumber = #"""
    \b(?:\#
    \d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})?)?\#
    |\d{2}:\d{2}:\d{2}(?:\.\d+)?\#
    |0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+\#
    |\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?\#
    )\b
    """#

    /// A TOML table header: `[table]`, or `[[array.of.tables]]`.
    ///
    /// The structural spine of the format, and the one thing in a TOML file
    /// that is neither a key nor a value — so it takes the `type` slot rather
    /// than sharing a colour with either.
    ///
    /// **Anchored to the line, and the closing bracket has to end the line.**
    /// A bare "bracketed run" is also every array, and the reason for both
    /// guards is a multi-line array of arrays: the anchor keeps
    /// `data = [ [1], [2] ]` out, and the lookahead keeps the inner `[ 1 ],`
    /// of the version broken across lines out. What is left is an inner
    /// element on its own line with no trailing comma — legal for the last
    /// one — which is painted as a header. The character class already
    /// excludes `,`, so that edge needs an array of exactly one element
    /// written across three lines to reach.
    static let tomlTableHeader =
        #"^[ \t]*\[\[?[A-Za-z0-9_. \t"'-]*\]\]?(?=[ \t]*(?:#|$))"#

    /// A TOML bare key, dotted or not: the `a.b` of `a.b = 1`.
    ///
    /// The same shape the Terraform rules already call an attribute — a name
    /// before `=` — widened to the dotted form, which in TOML is a key and
    /// not two. Digits are in the charset because a bare key may be all
    /// digits: `1979 = "x"` is a key, and `attribute` outranks `number` in
    /// the highlighter's precedence, so it reads as one.
    ///
    /// **Anchored to the line**, so the keys of an inline table stay plain.
    /// That is the trade-off `propertyBeforeColon` documents for the
    /// JavaScript family, and the same one: a key at the start of its line is
    /// every key in a formatted file. A quoted key is left to the string rule,
    /// which outranks this one and is already painting it.
    static let tomlKey =
        #"^[ \t]*[A-Za-z0-9_-]+(?:[ \t]*\.[ \t]*[A-Za-z0-9_-]+)*(?=[ \t]*=)"#

    /// Decimals, hex, binary, floats and exponents, with `_` separators.
    static let number =
        #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#

    /// The values that actually appear, rather than every value CSS has.
    ///
    /// A closed list on purpose: matching "any bare word inside a
    /// declaration" would also catch element selectors and the inside of
    /// `url(...)`, and the property names are already claimed by the
    /// attribute rule — which takes precedence, so `display` stays a
    /// property and `flex` becomes a value.
    static let cssValues = [
        "absolute", "auto", "baseline", "block", "bold", "border-box", "both",
        "bottom", "center", "column", "contain", "content-box", "cover",
        "dashed", "dotted", "ellipsis", "end", "fixed", "flex", "flex-end",
        "flex-start", "grid", "hidden", "inherit", "initial", "inline",
        "inline-block", "inline-flex", "italic", "left", "middle", "none",
        "normal", "nowrap", "pointer", "relative", "right", "row",
        "space-around", "space-between", "space-evenly", "solid", "start",
        "static", "sticky", "top", "transparent", "underline", "uppercase",
        "unset", "visible", "wrap",
    ]

    /// Capitalized identifiers. A heuristic, not a type checker — it is
    /// right often enough to help and never wrong in a way that misleads,
    /// and PR 3's semantic tokens replace it with the truth.
    static let capitalizedType = #"\b[A-Z][A-Za-z0-9_]*\b"#

    /// An identifier immediately before `(`.
    static let callBeforeParen = #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#

    /// A call, including one whose argument is a *type*.
    ///
    /// `defineProps<{ … }>()` is a call, and the version that only looked
    /// for `(` left it plain — which is most of what a `<script setup>`
    /// block does. The `<` branch demands the bracket be followed
    /// immediately by something type-shaped and with **no space**, so a
    /// comparison like `x < y` doesn't become a function. `x<y` still would;
    /// that is the documented edge, and nobody writes comparisons that way.
    static let callBeforeParenOrGeneric =
        #"\b[a-z_][A-Za-z0-9_]*(?=\s*\(|<[A-Za-z_{\[])"#

    /// TypeScript's primitives.
    ///
    /// Lowercase and not keywords, so neither `capitalizedType` nor the word
    /// list reached them — every `: number` and `: string` in an annotation
    /// came out as plain text.
    static let typescriptPrimitives = [
        "any", "bigint", "boolean", "never", "number", "object", "string",
        "symbol", "unknown",
    ]

    /// A JSX element's tag, in the language JSX is written in.
    ///
    /// JavaScript's rules had nothing for it, so `<div className="card">` came
    /// out as a bare string with two plain words around it, and the tag of a
    /// `<script type="text/babel">` block in an HTML file was only ever
    /// coloured by accident — by the *markup* rules, which were also painting
    /// its `const` as nothing and its `name =` as an attribute.
    ///
    /// **Three branches, and the asymmetry between the first two is the whole
    /// design.** In JavaScript `<` is an operator, so a tag has to be told
    /// from a comparison and from a type argument:
    ///
    /// - A closing tag needs no guard. `</` cannot begin a comparison, and it
    ///   must work with nothing but text behind it — `<p>hello</p>` is the
    ///   commonest shape there is.
    /// - An opening tag is only a tag where an *expression* can start: after
    ///   whitespace, an opening bracket, a comma, an arrow, a logical
    ///   operator. That negative lookbehind is what keeps `Array<string>`,
    ///   `Map<K, V>` and `useState<Foo>()` out of it — the `<` there sits
    ///   against a letter, which is a place no JSX tag can begin.
    /// - The fragment, `<>` and `</>`, which no other construct spells.
    ///
    /// The edge it declines to solve: `a <b` — a comparison written with the
    /// space on the wrong side — is painted as a tag. It is the same edge
    /// `callBeforeParenOrGeneric` already documents, and the same answer:
    /// nobody writes comparisons that way. Attributes inside the tag stay
    /// plain, because "a name before `=`" in JavaScript is *every assignment*
    /// — knowing that one is inside a tag needs a parser, not a pattern.
    ///
    /// **Every branch begins with the literal `<`, and that is a cost
    /// decision rather than a style one.** The readable spelling puts the
    /// guard first — `(?<![^\s…])<` — and that makes the engine evaluate a
    /// lookbehind at *every position in the file* before failing on a
    /// character that was never a `<`. Measured over the 401 `.ts` files of
    /// `front-app-eita`, one line re-highlighted each, best of three: 6.1 ms
    /// before this rule, **9.4 ms** with the guard first, **6.8 ms** with the
    /// literal first. Same tokens, 1.8 µs per keystroke per file instead of
    /// 8.2. So the lookbehind is written after the `<` it guards, spanning
    /// both characters, which is why it reads as awkwardly as it does.
    static let jsxTag =
        #"</[A-Za-z][A-Za-z0-9._-]*|<(?<=(?:^|[\s(\[{,;=>&|?:!])<)[A-Za-z][A-Za-z0-9._-]*|</?>"#

    /// A property name in an object literal or a type: `label:`.
    ///
    /// Same shape the CSS rules already call an attribute — a name before a
    /// colon — so the two stay consistent. `\??` covers `totalPages?:`.
    ///
    /// **Anchored to the start of a line**, and that is the whole subtlety.
    /// A bare "name before a colon" also matches the middle of a ternary —
    /// `cond ? value : other` would paint `value` as a property — and
    /// `attribute` outranks `keyword` in the highlighter's precedence, so it
    /// would win. Object keys and type members sit at the start of their line
    /// in any formatted code; a one-line `{ a: 1 }` is missed, which is the
    /// right way round to be wrong.
    ///
    /// `default:` and `case x:` are excluded explicitly: they are keywords
    /// that happen to precede a colon, and the precedence order would
    /// otherwise take them away from the keyword slot.
    static let propertyBeforeColon =
        #"^[ \t]*(?!default\b|case\b)[A-Za-z_$][A-Za-z0-9_$]*\??(?=\s*:)"#

    /// The rules for a language described as a value rather than named by
    /// the enum below.
    ///
    /// Starts from the base — which is where strings, numbers and the
    /// capitalized-type and call heuristics come from, and those are the
    /// parts a list of keywords cannot describe — then replaces exactly the
    /// two things a contribution gets to say: its keywords and its comment
    /// markers. A built-in syntax passes straight through, because the
    /// hand-written rules are strictly better than anything reconstructed
    /// from `CodeLanguage`'s two comment properties.
    static func rules(for syntax: LanguageSyntax) -> SyntaxRules {
        var rules = self.rules(for: syntax.base)
        guard !syntax.isBuiltIn else { return rules }

        rules.keyword = syntax.keywords.isEmpty
            ? nil
            : words(escaping: syntax.keywords)
        rules.comment = comment(line: syntax.lineComment, block: syntax.blockComment)
        return rules
    }

    static func rules(for language: CodeLanguage) -> SyntaxRules {
        switch language {
        case .javascript:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "abstract", "as", "async", "await", "break", "case", "catch", "class",
                    "const", "continue", "debugger", "declare", "default", "delete", "do",
                    "else", "enum", "export", "extends", "finally", "for", "from", "function",
                    "get", "if", "implements", "import", "in", "instanceof", "interface", "is",
                    "keyof", "let", "namespace", "new", "of", "private", "protected", "public",
                    "readonly", "return", "satisfies", "set", "static", "super", "switch",
                    "this", "throw", "try", "type", "typeof", "var", "void", "while", "yield",
                    "true", "false", "null", "undefined",
                ]) + "|" + jsxTag,
                type: capitalizedType + "|" + words(typescriptPrimitives),
                function: callBeforeParenOrGeneric,
                // Decorators and object/type property names share this slot:
                // both are "a name that labels something else", and the CSS
                // rules already spell property names this way.
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*|"# + propertyBeforeColon
            )

        case .swift:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""""[\s\S]*?"""|"(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words([
                    "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
                    "catch", "class", "consuming", "continue", "convenience", "default",
                    "defer", "deinit", "didSet", "do", "dynamic", "each", "else", "enum",
                    "extension", "fallthrough", "fileprivate", "final", "for", "func", "get",
                    "guard", "if", "import", "in", "indirect", "infix", "init", "inout",
                    "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated",
                    "nonmutating", "open", "operator", "optional", "override", "package",
                    "postfix", "precedencegroup", "prefix", "private", "protocol", "public",
                    "repeat", "required", "rethrows", "return", "self", "Self", "set", "some",
                    "static", "struct", "subscript", "super", "switch", "throw", "throws",
                    "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
                    "true", "false",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .kotlin:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""""[\s\S]*?"""|"(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words([
                    "abstract", "as", "break", "by", "catch", "class", "companion", "const",
                    "constructor", "continue", "data", "do", "else", "enum", "external",
                    "final", "finally", "for", "fun", "get", "if", "implements", "import",
                    "in", "infix", "init", "inline", "interface", "internal", "is", "lateinit",
                    "new", "object", "open", "operator", "override", "package", "private",
                    "protected", "public", "return", "sealed", "set", "super", "suspend",
                    "this", "throw", "try", "typealias", "val", "var", "vararg", "when",
                    "where", "while", "true", "false", "null",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .rust:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                    "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
                    "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                    "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                    "use", "where", "while",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"#!?\[[^\]]*\]"#
            )

        case .go:
            return SyntaxRules(
                comment: cStyleComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "break", "case", "chan", "const", "continue", "default", "defer", "else",
                    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                    "map", "package", "range", "return", "select", "struct", "switch", "type",
                    "var", "nil", "true", "false",
                ]),
                type: capitalizedType,
                function: callBeforeParen
            )

        case .python:
            return SyntaxRules(
                comment: hashComment,
                string: #""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: words([
                    "and", "as", "assert", "async", "await", "break", "class", "continue",
                    "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
                    "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
                    "raise", "return", "try", "while", "with", "yield", "True", "False", "None",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"@[A-Za-z_][A-Za-z0-9_.]*"#
            )

        case .ruby:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "alias", "and", "begin", "break", "case", "class", "def", "do", "else",
                    "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
                    "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
                    "then", "true", "unless", "until", "when", "while", "yield",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"[@$][A-Za-z_][A-Za-z0-9_]*"#
            )

        case .shell:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words([
                    "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
                    "until", "do", "done", "function", "return", "export", "local",
                    "readonly", "source", "alias", "unset", "shift", "exit",
                ]),
                function: callBeforeParen,
                attribute: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#
            )

        case .json:
            return SyntaxRules(
                string: #""(?:[^"\\]|\\.)*""#,
                number: number,
                keyword: words(["true", "false", "null"])
            )

        case .yaml:
            return SyntaxRules(
                comment: hashComment,
                string: cStyleString,
                number: number,
                keyword: words(["true", "false", "null", "yes", "no", "on", "off"]),
                attribute: #"^\s*[-\w.]+(?=\s*:)"#
            )

        case .toml:
            return SyntaxRules(
                comment: hashComment,
                string: tomlString,
                number: tomlNumber,
                // The complete list, not a selection: these four words are
                // every bare value TOML has. YAML's row above needs `yes`,
                // `no`, `on` and `off` as well, and painting those here
                // would colour four ordinary strings as literals.
                keyword: words(["true", "false", "inf", "nan"]),
                type: tomlTableHeader,
                attribute: tomlKey
            )

        case .markdown:
            return SyntaxRules(
                comment: #"^>.*$"#,
                string: #"`[^`\n]*`|```[\s\S]*?```"#,
                keyword: #"^#{1,6}\s.*$"#,
                type: #"\[[^\]]*\]\([^)]*\)"#,
                attribute: #"\*\*[^*]+\*\*|__[^_]+__"#
            )

        case .html:
            return SyntaxRules(
                comment: #"<!--[\s\S]*?-->"#,
                string: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                keyword: #"</?[A-Za-z][A-Za-z0-9-]*"#,
                attribute: #"\b[A-Za-z_:@][-A-Za-z0-9_:.]*(?=\s*=)"#
            )

        case .css:
            return SyntaxRules(
                // `//` as well as `/* */`: SCSS and Less both have it, and
                // `.scss` is what a Vue `<style>` block is written in here.
                comment: #"//[^\n]*|/\*[\s\S]*?\*/"#,
                string: cStyleString,
                number: #"\b\d[\d_]*(?:\.\d+)?(?:px|em|rem|fr|ch|vmin|vmax|%|vh|vw|s|ms|deg)?\b"#,
                // At-rules, SCSS variables, custom properties, `!important`
                // — and the values themselves, which is the difference
                // between a stylesheet that reads and a wall of one colour.
                keyword: #"@[A-Za-z-]+|\$[A-Za-z_][-A-Za-z0-9_]*|--[A-Za-z0-9_-]+|!important|"#
                    + words(cssValues),
                // Selectors: classes, ids, and SCSS's `&` nesting — without
                // the last one every `&__element` in a BEM stylesheet, which
                // is most of the lines in one, came out plain.
                type: #"&[-A-Za-z0-9_]*|\.[A-Za-z_][-A-Za-z0-9_]*|#[A-Za-z_][-A-Za-z0-9_]*"#,
                function: #"\b[a-z-]+(?=\()"#,
                attribute: #"\b[a-z-]+(?=\s*:)"#
            )

        case .sql:
            return SyntaxRules(
                comment: #"--[^\n]*|/\*[\s\S]*?\*/"#,
                string: #"'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: #"(?i)"# + words([
                    "select", "from", "where", "insert", "into", "values", "update", "set",
                    "delete", "create", "table", "alter", "drop", "index", "join", "left",
                    "right", "inner", "outer", "on", "group", "by", "order", "having",
                    "limit", "offset", "as", "and", "or", "not", "null", "distinct", "union",
                    "with", "case", "when", "then", "else", "end",
                ])
            )

        case .zig:
            return SyntaxRules(
                comment: #"//[^\n]*"#,
                string: #""(?:[^"\\]|\\.)*"|\\\\[^\n]*"#,
                number: number,
                keyword: words([
                    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async",
                    "await", "break", "catch", "comptime", "const", "continue", "defer",
                    "else", "enum", "errdefer", "error", "export", "extern", "fn", "for",
                    "if", "inline", "noalias", "nosuspend", "opaque", "or", "orelse",
                    "packed", "pub", "resume", "return", "struct", "suspend", "switch",
                    "test", "threadlocal", "try", "union", "unreachable", "usingnamespace",
                    "var", "volatile", "while", "true", "false", "null", "undefined",
                ]),
                type: capitalizedType,
                function: callBeforeParen
            )

        case .c:
            return SyntaxRules(
                comment: cStyleComment,
                string: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#,
                number: number,
                keyword: words([
                    "auto", "break", "case", "char", "const", "continue", "default", "do",
                    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
                    "int", "long", "register", "return", "short", "signed", "sizeof", "static",
                    "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                    "while", "class", "namespace", "template", "public", "private", "protected",
                    "virtual", "true", "false", "nullptr",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                attribute: #"^\s*#\s*[a-z]+"#
            )

        case .php:
            return SyntaxRules(
                comment: #"//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/"#,
                string: cStyleString,
                number: number,
                keyword: words([
                    "abstract", "and", "array", "as", "break", "callable", "case", "catch",
                    "class", "clone", "const", "continue", "declare", "default", "do", "echo",
                    "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif",
                    "endswitch", "endwhile", "extends", "final", "finally", "fn", "for",
                    "foreach", "function", "global", "goto", "if", "implements", "include",
                    "include_once", "instanceof", "insteadof", "interface", "isset", "list",
                    "match", "namespace", "new", "or", "print", "private", "protected", "public",
                    "require", "require_once", "return", "static", "switch", "throw", "trait",
                    "try", "unset", "use", "var", "while", "xor", "yield", "true", "false", "null",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                // A `$variable` is the one thing PHP marks visually that
                // nothing else in this table already covers.
                attribute: #"\$[A-Za-z_][A-Za-z0-9_]*"#
            )

        case .terraform:
            return SyntaxRules(
                comment: #"#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/"#,
                string: cStyleString,
                number: number,
                keyword: words([
                    "resource", "data", "variable", "output", "module", "provider", "locals",
                    "terraform", "for_each", "count", "depends_on", "lifecycle", "dynamic",
                    "provisioner", "connection", "true", "false", "null", "if", "else", "endif",
                    "for", "in", "endfor",
                ]),
                type: capitalizedType,
                function: callBeforeParen,
                // `key = value` rather than `key:` — HCL's own assignment,
                // not the colon-property pattern the JS-family rules use.
                attribute: #"^[ \t]*[A-Za-z_][A-Za-z0-9_-]*(?=\s*=(?!=))"#
            )

        // A single-file component has no rules of its own: the highlighter
        // splits it into blocks and asks for the rules of each. Reaching
        // here would mean something tried to lex the container itself.
        case .vue, .plain:
            return SyntaxRules()
        }
    }
}

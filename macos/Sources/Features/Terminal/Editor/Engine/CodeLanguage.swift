import Foundation

/// A language the highlighter knows, resolved from a file's name.
///
/// Grouped by how they are *lexed*, not by how they differ as languages:
/// TypeScript, JavaScript and Vue share one entry because at this level —
/// keywords, strings, comments, numbers — they are the same, and splitting
/// them would mean three copies of one rule set to keep in step.
enum CodeLanguage: String, CaseIterable, Equatable, Sendable {
    case javascript

    /// A single-file component: markup, script and stylesheet in one file.
    ///
    /// Not a language of its own so much as a container for three, which is
    /// why it is the one entry here that the highlighter treats specially —
    /// see `SFCRegions`.
    case vue
    case swift
    case kotlin
    case rust
    case go
    case python
    case ruby
    case shell
    case json
    case yaml
    case markdown
    case html
    case css
    case sql
    case zig
    case c
    case php
    case terraform
    case plain

    /// Extensions are matched longest-first, so `component.spec.ts` can be
    /// told from `.ts` if that ever matters — the same rule the file icon
    /// theme already uses.
    private static let byExtension: [String: CodeLanguage] = [
        "ts": .javascript, "tsx": .javascript, "mts": .javascript, "cts": .javascript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "vue": .vue, "svelte": .vue,
        "swift": .swift,
        // A module's public interface, which is what go-to-definition lands
        // in when the symbol lives in a framework rather than in your code.
        // It is Swift, and without this line it arrived as plain text.
        "swiftinterface": .swift,
        "kt": .kotlin, "kts": .kotlin, "java": .kotlin,
        "rs": .rust,
        "go": .go,
        "py": .python, "pyi": .python,
        "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "json": .json, "jsonc": .json,
        "yml": .yaml, "yaml": .yaml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "html": .html, "htm": .html, "xml": .html, "svg": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sql": .sql,
        "zig": .zig, "zon": .zig,
        "c": .c, "h": .c, "cpp": .c, "hpp": .c, "cc": .c, "m": .c, "mm": .c,
        "php": .php,
        "tf": .terraform, "tfvars": .terraform,
    ]

    /// Files whose name carries the language, with no extension to read.
    ///
    /// This table and `LSPServerRegistry.languageIDByFileName` have to
    /// agree, and a test says so: a file painted as JSON while its server
    /// is told it is something else — or told nothing — is worse than
    /// either answer alone, because the two halves of the editor then
    /// disagree in front of the reader. The `rc` files below, and why they
    /// are JSON when several of them are allowed to be YAML, are argued
    /// where the server side of the pair is declared.
    private static let byName: [String: CodeLanguage] = [
        "Makefile": .shell,
        "Dockerfile": .shell,
        ".zshrc": .shell,
        ".bashrc": .shell,
        ".zshenv": .shell,
        ".gitignore": .plain,
        ".env": .shell,
        // By name, not extension: `.mod` and `.sum` belong to plenty of
        // things that are not Go — a Fortran module, a checksum list — and
        // matching the extension gave all of them Go's syntax.
        "go.mod": .go,
        "go.sum": .go,
        "go.work": .go,
        ".prettierrc": .json,
        ".babelrc": .json,
        ".eslintrc": .json,
        ".jscsrc": .json,
        ".jshintrc": .json,
        ".swcrc": .json,
    ]

    /// The names in the table above, folded to lower case.
    ///
    /// For whoever has to answer "does this build already own that file
    /// name" about a name that came from outside — `resolve(fileName:)`
    /// cannot answer it, because the table is matched case-sensitively
    /// while a name from a file is not, and `makefile` would look free
    /// while `Makefile` is taken.
    static var namedFiles: Set<String> {
        Set(byName.keys.map { $0.lowercased() })
    }

    static func resolve(fileName: String) -> CodeLanguage {
        if let byName = byName[fileName] { return byName }

        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .plain }
        return byExtension[ext] ?? .plain
    }

    /// The comment syntax, used both by the highlighter and by a
    /// comment-toggling command.
    var lineComment: String? {
        switch self {
        case .javascript, .swift, .kotlin, .rust, .go, .zig, .c, .css, .php: return "//"
        case .python, .ruby, .shell, .yaml, .terraform: return "#"
        case .sql: return "--"
        // An SFC has no single answer — it depends which block you are in —
        // so it declines to give one rather than give the wrong one.
        case .json, .markdown, .html, .vue, .plain: return nil
        }
    }

    var blockComment: (open: String, close: String)? {
        switch self {
        case .javascript, .swift, .kotlin, .rust, .go, .c, .css, .php, .terraform: return ("/*", "*/")
        // The top level of an SFC is markup, whatever the blocks contain.
        case .html, .vue: return ("<!--", "-->")
        case .python, .ruby, .shell, .yaml, .sql, .json, .markdown, .zig, .plain: return nil
        }
    }
}

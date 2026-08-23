import AppKit

/// What the preview draws with.
///
/// A value handed in by the host, like `CodeTheme` and for the same reason:
/// the engine is told what a link looks like, it does not ask the app. Every
/// colour here is derived from the terminal palette the reader already
/// chose, rather than invented — a preview in its own colour scheme beside
/// an editor in theirs looks like a different application.
struct MarkdownStyle: Equatable {
    var theme: CodeTheme

    /// The prose font. Proportional on purpose: a README is text, and
    /// setting it in the editor's monospace is the single thing that makes
    /// a preview look like a terminal instead of a document.
    var bodyFont: NSFont

    /// Code spans, fences, and anything shown as source.
    var codeFont: NSFont

    /// Point sizes for heading levels one to six.
    var headingSizes: [CGFloat]

    /// The widest an image is drawn, before its aspect ratio scales the
    /// height to match.
    var maxImageWidth: CGFloat = 460

    /// Whether an image at an `http(s)` URL may be fetched.
    ///
    /// Off, and not as an oversight. Every badge in a README is a remote
    /// image, and fetching them would have a *preview* — something that
    /// re-renders while you type — announce the file you have open to half
    /// a dozen third parties on every keystroke. A local image is a file
    /// the reader already has; a remote one is a request made on their
    /// behalf, and that is the host's call to switch on, not this file's to
    /// assume.
    var loadsRemoteImages: Bool = false

    var textColor: NSColor { theme.foreground }
    var secondaryColor: NSColor { theme.color(for: .comment) }
    var linkColor: NSColor { theme.color(for: .function) }

    /// Alpha over the reader's own background rather than a fixed grey, so
    /// it lands correctly on a light theme and a dark one without the
    /// engine being told which it is.
    var fillColor: NSColor { theme.foreground.withAlphaComponent(0.06) }
    var ruleColor: NSColor { theme.foreground.withAlphaComponent(0.20) }

    func headingSize(_ level: Int) -> CGFloat {
        headingSizes[min(max(level, 1), headingSizes.count) - 1]
    }

    /// Derived from the editor's own configuration, so changing the editor
    /// font size moves the preview with it.
    static func standard(theme: CodeTheme, configuration: CodeEditorConfiguration) -> MarkdownStyle {
        let base = min(max(configuration.font.pointSize + 1, 11), 22)
        return MarkdownStyle(
            theme: theme,
            bodyFont: .systemFont(ofSize: base),
            codeFont: .monospacedSystemFont(ofSize: base - 1, weight: .regular),
            headingSizes: [base * 1.9, base * 1.55, base * 1.3, base * 1.15, base, base * 0.92]
        )
    }

    static var fallback: MarkdownStyle {
        standard(theme: .fallback, configuration: .default)
    }
}

extension CodeLanguage {
    /// The language a fence's info string names.
    ///
    /// Nil rather than `.plain` when nothing matches, because the two mean
    /// different things to the renderer: `.plain` is a language with no
    /// rules, nil is "do not run the highlighter at all", which is the
    /// right answer for `text`, `diff`, `mermaid` and every fence whose
    /// content is not source code.
    ///
    /// Separate from `resolve(fileName:)` because fences and files disagree
    /// about names — a fence says `bash` and `console`, a file says `.sh`,
    /// and no extension is spelled `typescript`.
    static func resolve(fenceInfo: String?) -> CodeLanguage? {
        guard let fenceInfo, !fenceInfo.isEmpty else { return nil }
        return byFenceName[fenceInfo.lowercased()]
    }

    private static let byFenceName: [String: CodeLanguage] = [
        "js": .javascript, "javascript": .javascript, "jsx": .javascript,
        "ts": .javascript, "typescript": .javascript, "tsx": .javascript,
        "mjs": .javascript, "cjs": .javascript, "node": .javascript,
        "vue": .vue, "svelte": .vue,
        "swift": .swift,
        "kotlin": .kotlin, "kt": .kotlin, "kts": .kotlin, "java": .kotlin,
        "rust": .rust, "rs": .rust,
        "go": .go, "golang": .go,
        "python": .python, "py": .python,
        "ruby": .ruby, "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell, "shell": .shell,
        "fish": .shell, "console": .shell, "terminal": .shell, "make": .shell,
        "dockerfile": .shell,
        "json": .json, "jsonc": .json, "json5": .json,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "markdown": .markdown, "md": .markdown, "mdx": .markdown,
        "html": .html, "xml": .html, "svg": .html, "vue-html": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sql": .sql, "postgres": .sql, "postgresql": .sql, "mysql": .sql,
        "zig": .zig, "zon": .zig,
        "c": .c, "h": .c, "cpp": .c, "c++": .c, "objc": .c, "objective-c": .c,
        "php": .php,
        "terraform": .terraform, "tf": .terraform, "hcl": .terraform,
    ]
}

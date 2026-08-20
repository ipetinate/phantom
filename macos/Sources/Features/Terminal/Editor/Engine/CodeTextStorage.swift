import AppKit

/// The document, and the coloring applied to it.
///
/// Highlighting runs over a **range**, never the whole file, and the caller
/// passes the visible one. That is the difference between an editor that
/// stays responsive in a 2MB file and one that recolors a megabyte on every
/// keystroke.
///
/// It also holds the invalidation rule, which is subtler than it looks: an
/// edit can change how text *earlier and later* in the file is colored — type
/// `/*` and everything below it becomes a comment — so a repaint has to
/// cover more than the characters that changed.
final class CodeTextStorage {
    /// How this file is lexed.
    ///
    /// A `LanguageSyntax` rather than a `CodeLanguage`, because a language
    /// contributed by an extension has no `CodeLanguage` case of its own —
    /// it lexes as some base with its own keywords and comment markers laid
    /// over the top. Holding only the base is what made a contributed
    /// language get a language server and no colour: the server side already
    /// resolved through the catalogue while this side still asked the
    /// filename.
    private(set) var syntax: LanguageSyntax

    /// The base the syntax lexes as, for the callers that genuinely mean the
    /// family — a hover card, the choice of markup dialect — rather than
    /// this file's exact rules.
    var language: CodeLanguage { syntax.base }

    private var highlighter: SyntaxHighlighter
    var theme: CodeTheme
    var configuration: CodeEditorConfiguration

    init(
        syntax: LanguageSyntax,
        theme: CodeTheme,
        configuration: CodeEditorConfiguration
    ) {
        self.syntax = syntax
        self.highlighter = SyntaxHighlighter(syntax: syntax)
        self.theme = theme
        self.configuration = configuration
    }

    convenience init(
        language: CodeLanguage,
        theme: CodeTheme,
        configuration: CodeEditorConfiguration
    ) {
        self.init(syntax: .builtIn(language), theme: theme, configuration: configuration)
    }

    func setSyntax(_ syntax: LanguageSyntax) {
        guard syntax != self.syntax else { return }
        self.syntax = syntax
        self.highlighter = SyntaxHighlighter(syntax: syntax)
    }

    func setLanguage(_ language: CodeLanguage) {
        setSyntax(.builtIn(language))
    }

    /// Applies colors to `range` of `storage`.
    ///
    /// Everything in range is reset to the plain foreground first. Without
    /// that, deleting the closing `*/` of a comment would leave the text
    /// grey: the tokens for it simply stop being produced, and attributes
    /// nobody clears are attributes that stay.
    ///
    /// That reset is right for every attribute this pass owns and wrong for
    /// every attribute it doesn't, which is what `preserving` is for. A
    /// diagnostic underline belongs to another pass entirely, and editing a
    /// line wiped it: the recolour of the edited region took the underline
    /// style with it and, worse, the underline *colour*, which is the whole
    /// of the severity — a warning and an error look the same once the colour
    /// is gone. The keys arrive as a value rather than as knowledge, so this
    /// type still knows nothing about diagnostics: only that some attributes
    /// in the range are somebody else's, and are to be put back.
    func highlight(
        _ storage: NSTextStorage,
        in range: NSRange,
        preserving: Set<NSAttributedString.Key> = [.underlineStyle, .underlineColor]
    ) {
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard safe.length > 0 else { return }

        let borrowed = runs(of: preserving, in: storage, over: safe)

        storage.beginEditing()
        storage.setAttributes(
            [
                .font: configuration.font,
                .foregroundColor: theme.foreground,
            ],
            range: safe
        )

        let text = storage.string
        for token in highlighter.tokens(in: text, range: safe) {
            let clipped = NSIntersectionRange(token.range, safe)
            guard clipped.length > 0 else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: theme.color(for: token.kind),
                range: clipped
            )
        }

        for run in borrowed {
            storage.addAttribute(run.key, value: run.value, range: run.range)
        }
        storage.endEditing()
    }

    /// Where each of `keys` is set inside `range`, read before the reset so it
    /// can be written back after it.
    ///
    /// One enumeration per key over the recolour range — never the document,
    /// which is the whole point of highlighting a range in the first place.
    private func runs(
        of keys: Set<NSAttributedString.Key>,
        in storage: NSTextStorage,
        over range: NSRange
    ) -> [(key: NSAttributedString.Key, value: Any, range: NSRange)] {
        guard !keys.isEmpty else { return [] }

        var found: [(key: NSAttributedString.Key, value: Any, range: NSRange)] = []
        for key in keys {
            storage.enumerateAttribute(key, in: range, options: []) { value, subrange, _ in
                guard let value else { return }
                found.append((key: key, value: value, range: subrange))
            }
        }
        return found
    }

    /// The range to recolor after an edit.
    ///
    /// Grown to whole lines and then padded by a screenful either side. A
    /// tighter range is wrong for exactly the reasons that make this hard:
    /// typing `/*` recolors everything after it, and typing `*/` recolors
    /// everything before. The padding doesn't make that correct in general —
    /// only a reparse does — but it covers what the reader can actually see,
    /// and the viewport pass fixes the rest as they scroll.
    static func invalidationRange(
        for edited: NSRange,
        in text: NSString,
        padding: Int = 4096
    ) -> NSRange {
        let lines = text.lineRange(for: NSIntersectionRange(
            edited,
            NSRange(location: 0, length: text.length)
        ))
        let start = max(0, lines.location - padding)
        let end = min(text.length, lines.location + lines.length + padding)
        return NSRange(location: start, length: end - start)
    }
}

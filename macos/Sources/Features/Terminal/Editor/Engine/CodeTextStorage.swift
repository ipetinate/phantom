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
    /// The language an installed extension gave this file, or nil for a file
    /// nothing claims. It is a name and nothing more: how the file is coloured
    /// is decided by the grammar that extension ships, and there is no
    /// compiled-in fallback to reach for when it ships none.
    private(set) var languageID: String?

    private(set) var highlighter: GrammarHighlighter
    private var cache: LineTokenizationCache?
    /// Highlighting and bracket colours request the same range on each edit.
    /// Keep that result until the text or grammar changes so the second pass
    /// does not run the TextMate tokenizer over the file again.
    private var lastTokens: (range: NSRange, seedWhenBehind: Bool, tokens: [GrammarHighlighter.Token])?
    var theme: CodeTheme
    var configuration: CodeEditorConfiguration

    init(
        languageID: String?,
        highlighter: GrammarHighlighter,
        theme: CodeTheme,
        configuration: CodeEditorConfiguration
    ) {
        self.languageID = languageID
        self.highlighter = highlighter
        self.cache = highlighter.initialState.map(LineTokenizationCache.init(initialState:))
        self.theme = theme
        self.configuration = configuration
    }

    func setHighlighter(_ highlighter: GrammarHighlighter, languageID: String?) {
        guard highlighter !== self.highlighter || languageID != self.languageID else { return }
        self.languageID = languageID
        self.highlighter = highlighter
        self.cache = highlighter.initialState.map(LineTokenizationCache.init(initialState:))
        lastTokens = nil
    }

    /// Forgets the tokenizer state from the line holding `location` onwards.
    /// Called before the recolour that follows an edit, so the lines below it
    /// are lexed again from what the edited line now ends in.
    func invalidate(from location: Int) {
        lastTokens = nil
        cache?.invalidate(from: location)
    }

    /// The tokens in `range`, from the same cache the recolour uses.
    ///
    /// `seedWhenBehind` is for a document too large to lex from the top: the
    /// first visible line starts from a clean state instead. See
    /// ``LineTokenizationCache/tokens(in:range:highlighter:seedWhenBehind:)``.
    func tokens(in text: String, range: NSRange, seedWhenBehind: Bool = false) -> [GrammarHighlighter.Token] {
        guard let cache else { return [] }
        if let lastTokens,
           lastTokens.range == range,
           lastTokens.seedWhenBehind == seedWhenBehind {
            return lastTokens.tokens
        }
        let tokens = cache.tokens(
            in: text as NSString,
            range: range,
            highlighter: highlighter,
            seedWhenBehind: seedWhenBehind
        )
        lastTokens = (range, seedWhenBehind, tokens)
        return tokens
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
    /// diagnostic mark belongs to another pass entirely, and editing a line
    /// wiped it: the recolour of the edited region took the mark with it and,
    /// worse, took its *colour*, which is the whole of the severity — a
    /// warning and an error look the same once the colour is gone. The keys
    /// arrive as a value rather than as knowledge, so this type still knows
    /// nothing about diagnostics: only that some attributes in the range are
    /// somebody else's, and are to be put back.
    ///
    /// Three keys in the default rather than one. `codeDiagnosticUnderline`
    /// is what a problem is marked with now — a wave, drawn by
    /// `CodeSquiggleView`, because `NSUnderlineStyle` has no wave. The two
    /// straight-underline keys stay in the set because a buffer marked up by
    /// an earlier build can still be on screen when this one runs, and a rule
    /// half-erased by a recolour is worse than one left whole.
    func highlight(
        _ storage: NSTextStorage,
        in range: NSRange,
        preserving: Set<NSAttributedString.Key> = [
            .codeDiagnosticUnderline,
            .underlineStyle,
            .underlineColor,
        ],
        seedWhenBehind: Bool = false
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

        for token in tokens(in: storage.string, range: safe, seedWhenBehind: seedWhenBehind) {
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

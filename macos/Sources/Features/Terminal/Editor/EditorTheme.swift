import AppKit
import SwiftUI

/// Turns the terminal's palette into editor colors.
///
/// This is the whole meaning of "syntax highlighting from the active
/// theme". A terminal theme is **sixteen ANSI colors and a background** —
/// it has no notion of a keyword or a string, so somebody has to decide
/// which slot each one borrows. That decision is here, and it follows what
/// terminal editors have always done, which is why the result looks like it
/// belongs in this app rather than like a web editor dropped into it.
enum EditorTheme {
    /// ANSI indices, by their conventional names.
    private enum ANSI {
        static let red = 1
        static let green = 2
        static let yellow = 3
        static let blue = 4
        static let magenta = 5
        static let cyan = 6
        static let brightBlack = 8
    }

    /// The mapping, kept as data so the reasoning is inspectable and the
    /// tests can assert it.
    ///
    /// Comment takes bright black because that is the one slot every theme
    /// makes deliberately dim; string takes green and keyword magenta
    /// because that pairing is what `vim` and every 16-color scheme has
    /// used for decades, so it reads as familiar rather than invented.
    static let ansiSlots: [TokenKind: Int] = [
        .keyword: ANSI.magenta,
        .string: ANSI.green,
        .comment: ANSI.brightBlack,
        .number: ANSI.yellow,
        .type: ANSI.cyan,
        .function: ANSI.blue,
        .attribute: ANSI.red,
        .punctuation: ANSI.brightBlack,
    ]

    @MainActor
    static func make(from palette: ThemePalette) -> CodeTheme {
        make(colors: palette.colors, background: palette.background)
    }

    /// The pure half, so the mapping can be tested against a palette that
    /// isn't the running app's.
    ///
    /// A theme with fewer than sixteen colors — or none at all, before the
    /// config has loaded — falls back rather than reaching past the end of
    /// the array. Highlighting that is briefly plain is a great deal better
    /// than a crash on launch.
    static func make(colors: [NSColor], background: NSColor?) -> CodeTheme {
        guard colors.count >= 16 else { return .fallback }

        let backgroundColor = background ?? .textBackgroundColor
        let foreground = colors[7]

        var tokens: [TokenKind: NSColor] = [:]
        for (kind, slot) in ansiSlots {
            tokens[kind] = colors[slot]
        }
        tokens[.plain] = foreground

        return CodeTheme(
            foreground: foreground,
            background: backgroundColor,
            tokens: tokens,
            lineNumber: colors[ANSI.brightBlack],
            currentLineNumber: foreground,
            currentLineBackground: foreground.withAlphaComponent(0.06)
        )
    }
}

/// Where the editor's preferences live, and their defaults.
///
/// `UserDefaults` rather than `GuiConfigStore`: an unknown key in
/// `gui-settings` makes Ghostty's own core raise a "Configuration Errors"
/// popup, so everything Phantom adds has to stay out of it.
enum EditorSettings {
    static let fontSizeKey = "EditorFontSize"
    static let fontFamilyKey = "EditorFontFamily"
    static let wrapsLinesKey = "EditorWrapsLines"
    static let showsLineNumbersKey = "EditorShowsLineNumbers"
    static let tabWidthKey = "EditorTabWidth"
    static let showsMinimapKey = "EditorShowsMinimap"
    static let colorsBracketPairsKey = "EditorColorsBracketPairs"

    /// The three halves of auto-closing, kept apart because they are three
    /// different opinions.
    ///
    /// Brackets are almost universally wanted; quotes annoy people who write
    /// a lot of prose in comments, where an apostrophe is not an opener; tags
    /// are the one with a heuristic behind it, and therefore the one most
    /// likely to be switched off after a bad guess. One switch for all three
    /// would mean losing the two that work in order to escape the one that
    /// misfired. They live in `UserDefaults` rather than in the Ghostty
    /// config, because an unrecognised key in `gui-settings` makes the core
    /// raise a configuration error at the user.
    static let closesBracketsKey = "EditorClosesBrackets"
    static let closesQuotesKey = "EditorClosesQuotes"
    static let closesTagsKey = "EditorClosesTags"

    /// Tidy the file with the project's formatter when it is saved.
    ///
    /// Off by default. Formatting on save is a preference people hold
    /// strongly in both directions, and the direction that surprises nobody
    /// is the one where saving writes exactly what is on screen.
    static let formatOnSaveKey = "EditorFormatOnSave"

    /// Let a project's own Prettier format the files it handles, in place of
    /// the language server.
    ///
    /// On by default, because a repository that carries a Prettier config has
    /// already decided how its files are written, and a language server
    /// formatting them another way is the wrong answer arriving faster.
    ///
    /// Worth a switch at all because honouring that decision means running
    /// `node_modules/.bin/prettier` **from the repository that was opened** —
    /// the only way the project's own version and plugins apply, and the same
    /// thing every editor does, but still code from a folder rather than from
    /// this app. Turning this off keeps formatting on the language server.
    static let usesPrettierKey = "EditorUsesPrettier"

    /// Offer the Markdown snippet catalogue when a `/` is typed.
    ///
    /// On by default, and worth a switch because the trigger it installs is a
    /// character people also type as punctuation — in a path, in a date, in
    /// `and/or`. The catalogue refuses to open in those places, but somebody
    /// who writes enough of them may still want the whole thing gone, and
    /// turning it off should silence the trigger rather than just the rows.
    static let markdownSnippetsKey = "EditorMarkdownSnippets"

    /// How wide the Markdown preview lets its prose run — one of
    /// `MarkdownPreviewWidth`'s raw values.
    ///
    /// A preference rather than a property of the file, like the split
    /// direction beside it: someone who reads their READMEs in a column wants
    /// the next one in a column too.
    static let markdownPreviewWidthKey = "EditorMarkdownPreviewWidth"

    static let defaultFontSize = 12.0
    static let defaultTabWidth = 4

    /// Contained, which is the answer this setting exists to give: the preview
    /// drew edge to edge and a full-screen window ran it to twice a readable
    /// line. Someone who wants the old behaviour is one click from it, and
    /// that click is remembered.
    static let defaultMarkdownPreviewWidth = MarkdownPreviewWidth.contained

    /// The editor's own font if one is set, else the interface family, else
    /// the system monospace.
    ///
    /// Falls back whenever the named family fails to produce a font, which
    /// is what happens when a font is uninstalled after being chosen — the
    /// editor should keep working, not come up blank.
    static func font(size: Double, family: String) -> NSFont {
        let chosen = UserDefaults.standard.string(forKey: fontFamilyKey) ?? ""
        let name = chosen.isEmpty ? family : chosen

        if !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

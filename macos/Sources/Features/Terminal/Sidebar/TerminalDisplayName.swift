import Foundation

/// What to call a terminal, wherever one is named.
///
/// A terminal carries two names, and they do not have equal standing. The
/// shell — and the agent running in it — rewrites the terminal's own title as
/// it goes, so a new title replaces the one before it. The name the reader
/// typed for a tab is a decision instead: it outlives every title the
/// terminal reports afterwards, exactly like the icon and the colour chosen
/// beside it.
///
/// A type of its own because four places name the same terminal — the sidebar
/// row, the editor's tab bar, the command palette and the MCP tools — and the
/// rule used to be written out again in each of them. Two of the four
/// disagreed: renaming a row left the editor's tab bar showing the title from
/// before, because that bar reads the window's title and the window knows
/// nothing about the name.
enum TerminalDisplayName {
    /// What a terminal that has reported no title at all is called.
    static let fallback = "Terminal"

    /// The name to draw, or nil when neither source offers one.
    ///
    /// Blanks are not a name. The rename sheet trims what it saves, and a
    /// title of spaces would otherwise draw a tab with nothing on it — one
    /// the reader cannot tell apart from its neighbours.
    static func name(custom: String?, terminalTitle: String?) -> String? {
        nonBlank(custom) ?? nonBlank(terminalTitle)
    }

    /// The same rule for the callers that must draw something regardless.
    ///
    /// The fallback is a parameter because it is the one part that belongs to
    /// the caller: a tab bar says "Terminal", while a tool answering a
    /// question about a terminal would rather say where that terminal is.
    static func resolve(
        custom: String?,
        terminalTitle: String?,
        fallback: String = fallback
    ) -> String {
        name(custom: custom, terminalTitle: terminalTitle) ?? fallback
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

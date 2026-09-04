import AppKit
import SwiftUI

/// The middle step: what this app does, and where each of those things is.
///
/// **No keyboard shortcuts are printed here.** Every one of them is
/// configurable — the menu's key equivalents are synced from the Ghostty
/// config at launch, and the editor's come from `PhantomShortcutAction`, which
/// Settings lets a reader rebind. A welcome panel that printed ⌘T would be
/// wrong for anybody who had changed it, and wrong silently. So each row says
/// where the thing *is*: a menu, a sidebar tab, a button — and the rows that
/// have a settings pane of their own offer to open it.
struct WelcomeBasicsStep: View {
    struct Row: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String

        /// Where in Settings this is configured, when it is configured at all.
        let section: SettingsRootView.SettingsSection?
    }

    /// One line each, and that is the whole design rule.
    ///
    /// The first cut gave every row two or three sentences of prose, and seven
    /// of those is a wall: nothing stands out, so nothing is read. What somebody
    /// meeting this app needs from a row is *that the thing exists* and where to
    /// find it — the depth is in the app, one click away, and in the docs.
    static let rows: [Row] = [
        Row(
            symbol: "terminal",
            title: "Terminals, tabs and groups",
            detail: "File → New Tab, or the + in the sidebar. Drag tabs together to group them.",
            section: .sidebar),
        Row(
            symbol: "arrow.triangle.branch",
            title: "Worktrees",
            detail: "Every checkout of a repository, and a terminal in any of them. No stashing.",
            section: .worktrees),
        Row(
            symbol: "arrow.trianglehead.pull",
            title: "Git, without leaving",
            detail: "Stage, commit, push, and resolve a conflict in a real diff.",
            section: .sidebar),
        Row(
            symbol: "rectangle.split.2x1",
            title: "Branch review",
            detail: "What your branch would put in a pull request — before you push it.",
            section: nil),
        Row(
            symbol: "curlybraces",
            title: "An editor with language servers",
            detail: "Hover, completion, go to definition, rename, diagnostics — on a click.",
            section: .languageServers),
        Row(
            symbol: "text.alignleft",
            title: "Formatters",
            detail: "The project's own Prettier, its language server, or the language's tool.",
            section: .files),
        Row(
            symbol: "paintpalette",
            title: "Themes and appearance",
            detail: "Theme, font, transparency, blur, app icon — terminal and editor together.",
            section: .appearance),
        Row(
            symbol: "sparkles",
            title: "Agents, and letting them drive",
            detail: "Hooks show what an agent is doing. Its MCP server lets it work this window.",
            section: .mcp),
    ]

    @ObservedObject private var palette: ThemePalette = .shared

    /// Two columns of cards rather than seven full-width rows.
    ///
    /// Same grid as the agents step, for the same reason it was given one: a
    /// card is a shape the eye can skip through, and a stack of full-width
    /// paragraphs is not. It also lets the window be what a window full of short
    /// facts should be — wider than it is tall — instead of a column somebody
    /// scrolls.
    /// Two columns, and as many rows as the cards need.
    private static let columns = 2
    private static var rowCount: Int { (rows.count + columns - 1) / columns }
    private static let spacing: CGFloat = 10

    /// Tall enough that the rows fill the step exactly.
    ///
    /// Eight cards in two columns is four full rows — which is why there are
    /// eight: seven left a hole in the last one, and a grid with a hole in it
    /// reads as a card that failed to load. The height is then what those rows
    /// divide between them rather than a number picked by eye, so the step is
    /// full at the top and the bottom.
    static var cardHeight: CGFloat {
        let available = WelcomeWindowController.size.height
            - WelcomeView.chromeHeight
            - spacing * CGFloat(rowCount - 1)
        return (available / CGFloat(rowCount)).rounded(.down)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Self.spacing),
                count: Self.columns),
            spacing: Self.spacing
        ) {
            ForEach(Self.rows) { row in
                card(row)
            }
        }
    }

    /// One card: a tinted chip holding the symbol, the name, one line about
    /// it, and — where there is something to configure — a gear that goes
    /// there.
    ///
    /// The gear replaces a "Settings" link that sat at the far right edge of a
    /// full-width row, three hundred points from the sentence it belonged to.
    /// A word that far from its subject reads as a column of links down the
    /// side of the window rather than as part of anything.
    private func card(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: row.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(row.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let section = row.section {
                SettingsGearButton { open(section) }
            } else {
                /// The gear's width, kept even where there is no gear, so the
                /// sentences of two cards side by side end at the same place.
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(12)
        /// Centred in the card rather than pinned to its top: the cards are
        /// as tall as four rows of them need to be, and text hugging the top
        /// of a tall box reads as a box that failed to fill.
        .frame(height: Self.cardHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14)))
    }

    private var accent: Color { palette.accent ?? .accentColor }

    /// The same two lines the editor's server banner uses: name the place
    /// first, because the first open is when the settings views are built and
    /// they read the request as they appear, then ask for the window through
    /// the menu's own action.
    private func open(_ section: SettingsRootView.SettingsSection) {
        SettingsNavigation.shared.target = SettingsNavigation.Target(section: section, row: nil)
        _ = NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil)
    }
}

/// The gear on a welcome card: quiet until it is pointed at.
///
/// A `Button` with a symbol rather than the word "Settings", because the word
/// was the widest thing in a row that is otherwise a sentence — and because
/// seven of them down one edge is a list of links, which is not what any of
/// those rows are about.
///
/// Used by the agent cards too, for the agent that is already set up: the same
/// gesture, in the same place, meaning the same thing.
struct SettingsGearButton: View {
    let action: () -> Void
    var help = "Open this in Settings"

    @State private var isHovered = false
    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? (palette.accent ?? .accentColor) : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

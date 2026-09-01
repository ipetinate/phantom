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

    static let rows: [Row] = [
        Row(
            symbol: "terminal",
            title: "Terminals, tabs and groups",
            detail: """
                File → New Tab, or the + in the sidebar's Terminals pane. Drag \
                tabs together into a group, or make one from a folder so every \
                terminal you open there joins it.
                """,
            section: .sidebar),
        Row(
            symbol: "arrow.triangle.branch",
            title: "Worktrees",
            detail: """
                The Worktrees pane lists every checkout of a repository, and \
                the icon on a tab or a group header opens a terminal in one — \
                two branches, two terminals, no stashing.
                """,
            section: .worktrees),
        Row(
            symbol: "rectangle.split.2x1",
            title: "Branch review",
            detail: """
                The Git pane's Branch Review shows what your branch would put \
                in a pull request — the commits, the files, the diffs, and \
                whether it would conflict — before you push it.
                """,
            section: nil),
        Row(
            symbol: "curlybraces",
            title: "A real editor, with language servers",
            detail: """
                Click a file to open it here: hover for types, completion as \
                you type, go to definition, rename, diagnostics. Install a \
                language's server from Settings and it applies everywhere.
                """,
            section: .languageServers),
        Row(
            symbol: "text.alignleft",
            title: "Formatters",
            detail: """
                ⇧⌘F formats the file with whatever the project uses — its own \
                Prettier, the language server, or the language's usual tool. \
                Turn on Format on Save to have it happen when you write.
                """,
            section: .files),
        Row(
            symbol: "paintpalette",
            title: "Themes and appearance",
            detail: """
                Pick a theme, a font, the window's transparency and blur, even \
                the app icon. The terminal and the editor follow the same one.
                """,
            section: .appearance),
        Row(
            symbol: "sparkles",
            title: "Agents, and letting them drive",
            detail: """
                Phantom installs each agent's hooks, so a tab shows whether it \
                is working, waiting on you, or done — and registers an MCP \
                server the agent can use to work this window itself: open a \
                file, read a terminal's output, add a worktree, make a group. \
                The next step sets that up.
                """,
            section: .mcp),
    ]

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.accent ?? .accentColor)
                            .frame(width: 22, alignment: .center)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 12.5, weight: .semibold))

                            Text(row.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if let section = row.section {
                            Button("Settings") { open(section) }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The same two lines the editor's server banner uses: name the place
    /// first, because the first open is when the settings views are built and
    /// they read the request as they appear, then ask for the window through
    /// the menu's own action.
    private func open(_ section: SettingsRootView.SettingsSection) {
        SettingsNavigation.shared.target = SettingsNavigation.Target(section: section, row: nil)
        _ = NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil)
    }
}

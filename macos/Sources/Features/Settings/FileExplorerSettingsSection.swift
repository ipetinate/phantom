import SwiftUI

/// The file explorer's preferences, as a section of the Sidebar pane.
///
/// It sits with the sidebar rather than with the editor because the
/// explorer is one of the sidebar's panes. Reaching it under Editor meant
/// answering "how is the explorer set up" in the room named after the thing
/// the explorer opens — the wrong-room problem this pass exists to remove.
///
/// A section rather than inlined code, for the same reason
/// `CompletionSettingsSection` is one: it carries its own storage and its
/// own icon-theme plumbing, and folding that into `SidebarSettingsView`
/// would put three unrelated concerns in one type.
struct FileExplorerSettingsSection: View {
    /// Read through the keys the explorer's own model reads, so this screen
    /// and the gear menu are two views of one preference rather than two
    /// preferences that have to be kept in step.
    @AppStorage(WorkspaceRootMode.defaultsKey)
    private var rootMode = WorkspaceRootMode.auto.rawValue

    @AppStorage(FileExplorerModel.showHiddenKey) private var showsHiddenFiles = true

    /// The third one has a publisher of its own, so it is observed rather
    /// than stored: `select(_:)` writes the same key the gear menu writes
    /// and repaints every explorer on screen.
    @ObservedObject private var icons: FileIconProvider = .shared

    var body: some View {
        Section {
            Picker("Root Folder", selection: $rootMode) {
                ForEach(WorkspaceRootMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }

            Toggle("Show Hidden Files", isOn: $showsHiddenFiles)
                .toggleStyle(.switch)

            /// No empty state, because there is no empty: a theme ships in
            /// the app bundle and `FileIconProvider` selects it by default,
            /// so the list always holds at least one entry besides the
            /// fallback. Guarding for none would draw a state nobody can
            /// reach.
            Picker("Icon Theme", selection: iconTheme) {
                Text("No Theme (SF Symbols)").tag(FileIconProvider.symbolsOnly)
                ForEach(iconThemeRows, id: \.name) { row in
                    Text(verbatim: row.label).tag(row.name)
                }
            }
        } header: {
            Text("File Explorer")
        } footer: {
            Text("""
            The same three sit in the explorer's own gear menu, which \
            stays the quick way to reach them. All three are one answer \
            for the whole app rather than one per window, and an \
            explorer already open takes the change as you make it.

            Any SVG-based VS Code icon theme works: copy the extension's \
            folder into `\(iconThemesPath)` and it is listed here, with \
            no install step. A theme that draws from a font instead \
            parses cleanly and can draw nothing, so it is listed as \
            having no artwork.

            SF Symbols is the built-in table rather than a theme, and it \
            is what every theme falls back to for a file it has no icon \
            for. Symbols — the theme Phantom ships with and selects by \
            default — is a separate thing with a similar name.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Icon themes

    /// Reads and writes through `FileIconProvider` rather than through an
    /// `@AppStorage` on the same key, because selecting is more than a
    /// write: it re-resolves which theme is active and drops the image
    /// cache, and a raw write would leave every open explorer drawing the
    /// old artwork.
    private var iconTheme: Binding<String> {
        Binding(
            get: { icons.selectedName },
            set: { icons.select($0) }
        )
    }

    /// One row per installed theme, plus a row for a selection that is no
    /// longer installed — without it the picker draws blank after a theme
    /// directory is deleted, and nothing on screen says why.
    private var iconThemeRows: [IconThemeRow] {
        var rows = icons.themes.map { theme in
            let title = theme.contributedBy.map { "\(theme.name) — \($0)" } ?? theme.name.capitalized
            return IconThemeRow(
                name: theme.name,
                label: theme.isSupported ? title : title + " (No Artwork)"
            )
        }

        let selected = icons.selectedName
        if selected != FileIconProvider.symbolsOnly, !rows.contains(where: { $0.name == selected }) {
            rows.append(IconThemeRow(name: selected, label: selected.capitalized + " (Not Installed)"))
        }

        return rows
    }

    private var iconThemesPath: String {
        (GuiConfigStore.shared.iconThemesDirURL.path as NSString).abbreviatingWithTildeInPath
    }
}

/// One row of the icon theme picker: the stored name, and what to call it
/// on screen when it cannot draw or is not there any more.
private struct IconThemeRow {
    let name: String
    let label: String
}

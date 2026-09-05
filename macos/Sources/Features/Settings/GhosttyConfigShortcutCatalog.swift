import SwiftUI

/// One Ghostty action Settings is willing to name.
struct GhosttyConfigShortcut: Identifiable, Equatable {
    /// The action string, spelled exactly as the configuration file spells it
    /// on the right of a `keybind =`. It is also what `ghostty_config_trigger`
    /// is asked for, so a typo here is a row that silently never appears.
    let action: String

    /// What the reader is shown. Taken from the menu item that carries the
    /// action wherever one exists, so the pane and the menu bar say the same
    /// words about the same key.
    let title: String

    var id: String { action }
}

/// Every Ghostty action the Keyboard Shortcuts pane is prepared to show,
/// grouped the way the menu bar groups them.
///
/// **Why this is written out by hand.** libghostty offers a lookup —
/// `ghostty_config_trigger(config, action)` — and no enumeration: there is no
/// way to ask a loaded configuration "what have you got". So the app has to
/// name the actions it wants back, which is what `AppDelegate` already does,
/// one `syncMenuShortcut` call per menu item. This table is the same idea for
/// the reader instead of for the menu bar, and it deliberately runs past the
/// menu: `clear_screen`, `goto_tab`, `jump_to_prompt` and the scrolling
/// commands have no menu item, so today nothing in the app admits they exist.
///
/// **What it cannot show, and why that is not a bug here.** A binding Ghostty
/// marks *performable* — one it offers to the terminal first and only handles
/// if the terminal declines — is kept out of the reverse map on purpose (see
/// `Binding.Set.reverse`), so the lookup answers nil for it however firmly it
/// is bound. The default ⌘K on `clear_screen` is the one that stings, because
/// it is the pairing the editor's ⌘K is explained against. Rows are listed
/// anyway: an action whose binding cannot be read simply does not draw, and
/// the section's footer says so rather than pretending the list is complete.
///
/// The values are the shipped defaults' actions plus the ones a reader is
/// likely to bind by hand; an action nobody has bound costs one hash lookup
/// and draws nothing.
enum GhosttyConfigShortcutCatalog {
    struct Group: Identifiable, Equatable {
        let title: String
        let entries: [GhosttyConfigShortcut]

        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Application", entries: [
            GhosttyConfigShortcut(action: "open_config", title: "Open Configuration"),
            GhosttyConfigShortcut(action: "reload_config", title: "Reload Configuration"),
            GhosttyConfigShortcut(action: "check_for_updates", title: "Check for Updates"),
            GhosttyConfigShortcut(action: "toggle_secure_input", title: "Secure Keyboard Entry"),
            GhosttyConfigShortcut(action: "quit", title: "Quit"),
        ]),

        Group(title: "Windows and Tabs", entries: [
            GhosttyConfigShortcut(action: "new_window", title: "New Window"),
            GhosttyConfigShortcut(action: "new_tab", title: "New Tab"),
            GhosttyConfigShortcut(action: "close_surface", title: "Close"),
            GhosttyConfigShortcut(action: "close_tab", title: "Close Tab"),
            GhosttyConfigShortcut(action: "close_window", title: "Close Window"),
            GhosttyConfigShortcut(action: "close_all_windows", title: "Close All Windows"),
            GhosttyConfigShortcut(action: "previous_tab", title: "Previous Tab"),
            GhosttyConfigShortcut(action: "next_tab", title: "Next Tab"),
            GhosttyConfigShortcut(action: "goto_tab:1", title: "Go to Tab 1"),
            GhosttyConfigShortcut(action: "goto_tab:2", title: "Go to Tab 2"),
            GhosttyConfigShortcut(action: "goto_tab:3", title: "Go to Tab 3"),
            GhosttyConfigShortcut(action: "goto_tab:4", title: "Go to Tab 4"),
            GhosttyConfigShortcut(action: "goto_tab:5", title: "Go to Tab 5"),
            GhosttyConfigShortcut(action: "goto_tab:6", title: "Go to Tab 6"),
            GhosttyConfigShortcut(action: "goto_tab:7", title: "Go to Tab 7"),
            GhosttyConfigShortcut(action: "goto_tab:8", title: "Go to Tab 8"),
            GhosttyConfigShortcut(action: "last_tab", title: "Go to Last Tab"),
            GhosttyConfigShortcut(action: "prompt_surface_title", title: "Change Terminal Title"),
            GhosttyConfigShortcut(action: "prompt_tab_title", title: "Change Tab Title"),
            GhosttyConfigShortcut(action: "toggle_fullscreen", title: "Toggle Full Screen"),
            GhosttyConfigShortcut(action: "reset_window_size", title: "Return to Default Size"),
            GhosttyConfigShortcut(action: "toggle_window_float_on_top", title: "Float on Top"),
            GhosttyConfigShortcut(action: "toggle_quick_terminal", title: "Quick Terminal"),
            GhosttyConfigShortcut(action: "toggle_visibility", title: "Show/Hide All Terminals"),
        ]),

        Group(title: "Splits", entries: [
            GhosttyConfigShortcut(action: "new_split:right", title: "Split Right"),
            GhosttyConfigShortcut(action: "new_split:left", title: "Split Left"),
            GhosttyConfigShortcut(action: "new_split:down", title: "Split Down"),
            GhosttyConfigShortcut(action: "new_split:up", title: "Split Up"),
            GhosttyConfigShortcut(action: "goto_split:previous", title: "Select Previous Split"),
            GhosttyConfigShortcut(action: "goto_split:next", title: "Select Next Split"),
            GhosttyConfigShortcut(action: "goto_split:up", title: "Select Split Above"),
            GhosttyConfigShortcut(action: "goto_split:down", title: "Select Split Below"),
            GhosttyConfigShortcut(action: "goto_split:left", title: "Select Split Left"),
            GhosttyConfigShortcut(action: "goto_split:right", title: "Select Split Right"),
            GhosttyConfigShortcut(action: "resize_split:up,10", title: "Move Divider Up"),
            GhosttyConfigShortcut(action: "resize_split:down,10", title: "Move Divider Down"),
            GhosttyConfigShortcut(action: "resize_split:left,10", title: "Move Divider Left"),
            GhosttyConfigShortcut(action: "resize_split:right,10", title: "Move Divider Right"),
            GhosttyConfigShortcut(action: "equalize_splits", title: "Equalize Splits"),
            GhosttyConfigShortcut(action: "toggle_split_zoom", title: "Zoom Split"),
        ]),

        Group(title: "Text", entries: [
            GhosttyConfigShortcut(action: "copy_to_clipboard", title: "Copy"),
            GhosttyConfigShortcut(action: "paste_from_clipboard", title: "Paste"),
            GhosttyConfigShortcut(action: "paste_from_selection", title: "Paste Selection"),
            GhosttyConfigShortcut(action: "select_all", title: "Select All"),
            GhosttyConfigShortcut(action: "undo", title: "Undo"),
            GhosttyConfigShortcut(action: "redo", title: "Redo"),

            /// A row for a binding whose action is a byte sequence rather than
            /// a name, which is the only kind in this table.
            ///
            /// It is here because a reader looking for the shortcut every other
            /// macOS text field has will look here, and because the pane is
            /// also where they would go to rebind it. The action string is what
            /// `Binding.Action.parse` makes of `esc:\x7f` and what the reverse
            /// map is keyed on — payloads are hashed and compared by bytes
            /// (`hashIncremental` uses `.DeepRecursive`), so the lookup does
            /// resolve. Pinned by `ghostty_config_trigger: default keybind` in
            /// `CApi.zig`, because a row whose action does not resolve draws
            /// nothing and says nothing about why.
            GhosttyConfigShortcut(action: "esc:\u{5C}x7f", title: "Delete Word Left"),
        ]),

        Group(title: "Find", entries: [
            GhosttyConfigShortcut(action: "start_search", title: "Find"),
            GhosttyConfigShortcut(action: "end_search", title: "Hide Find Bar"),
            GhosttyConfigShortcut(action: "search_selection", title: "Use Selection for Find"),
            GhosttyConfigShortcut(action: "navigate_search:next", title: "Find Next"),
            GhosttyConfigShortcut(action: "navigate_search:previous", title: "Find Previous"),
            GhosttyConfigShortcut(action: "scroll_to_selection", title: "Jump to Selection"),
        ]),

        Group(title: "Scrollback", entries: [
            GhosttyConfigShortcut(action: "scroll_page_up", title: "Scroll Page Up"),
            GhosttyConfigShortcut(action: "scroll_page_down", title: "Scroll Page Down"),
            GhosttyConfigShortcut(action: "scroll_to_top", title: "Scroll to Top"),
            GhosttyConfigShortcut(action: "scroll_to_bottom", title: "Scroll to Bottom"),
            GhosttyConfigShortcut(action: "jump_to_prompt:-1", title: "Jump to Previous Prompt"),
            GhosttyConfigShortcut(action: "jump_to_prompt:1", title: "Jump to Next Prompt"),
            GhosttyConfigShortcut(action: "write_screen_file:copy", title: "Write Screen to a File, Copy Its Path"),
            GhosttyConfigShortcut(action: "write_screen_file:paste", title: "Write Screen to a File, Paste Its Path"),
            GhosttyConfigShortcut(action: "write_screen_file:open", title: "Write Screen to a File, Open It"),
        ]),

        Group(title: "Terminal", entries: [
            GhosttyConfigShortcut(action: "clear_screen", title: "Clear Screen"),
            GhosttyConfigShortcut(action: "increase_font_size:1", title: "Increase Font Size"),
            GhosttyConfigShortcut(action: "decrease_font_size:1", title: "Decrease Font Size"),
            GhosttyConfigShortcut(action: "reset_font_size", title: "Reset Font Size"),
            GhosttyConfigShortcut(action: "toggle_command_palette", title: "Command Palette"),
            GhosttyConfigShortcut(action: "inspector:toggle", title: "Terminal Inspector"),
        ]),
    ]

    /// Every action in the table, flattened — for the tests that hold it to
    /// being a table of distinct, well-formed action strings.
    static var allEntries: [GhosttyConfigShortcut] { groups.flatMap(\.entries) }
}

/// One catalog entry that the loaded configuration actually has keys for.
struct GhosttyConfigBinding: Identifiable, Equatable {
    let entry: GhosttyConfigShortcut

    /// Already rendered — "⇧⌘P" — through the same `KeyboardShortcut`
    /// extension the command palette draws its hints with, so the two
    /// surfaces spell a chord the same way.
    let keys: String

    var id: String { entry.action }
}

/// A catalog group, narrowed to what is bound and to what the reader searched
/// for. Empty groups are dropped by the resolver, so this never draws a header
/// over nothing.
struct GhosttyConfigBindingGroup: Identifiable, Equatable {
    let title: String
    let bindings: [GhosttyConfigBinding]

    var id: String { title }
}

extension GhosttyConfigShortcutCatalog {
    /// The catalog, resolved against a loaded configuration.
    ///
    /// - Parameter keys: how an action's chord is looked up, injected so the
    ///   grouping and the dropping of empty groups can be tested without a
    ///   `ghostty_config_t` — building one in a test would read the machine's
    ///   own configuration files and answer differently on every machine.
    /// - Parameter include: which entries survive the reader's search.
    static func resolved(
        keys: (String) -> String?,
        include: (GhosttyConfigShortcut) -> Bool = { _ in true }
    ) -> [GhosttyConfigBindingGroup] {
        groups.compactMap { group in
            let bindings = group.entries.compactMap { entry -> GhosttyConfigBinding? in
                guard include(entry), let keys = keys(entry.action) else { return nil }
                return GhosttyConfigBinding(entry: entry, keys: keys)
            }
            guard !bindings.isEmpty else { return nil }
            return GhosttyConfigBindingGroup(title: group.title, bindings: bindings)
        }
    }

    /// The same thing against the app's live configuration.
    ///
    /// Main-actor only, because resolving a physical trigger reads the
    /// current keyboard layout.
    @MainActor static func resolved(
        in config: Ghostty.Config,
        include: (GhosttyConfigShortcut) -> Bool = { _ in true }
    ) -> [GhosttyConfigBindingGroup] {
        resolved(
            keys: { action in config.keyboardShortcut(for: action)?.description },
            include: include)
    }
}

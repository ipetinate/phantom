import AppKit
import SwiftUI

/// Whether a row survives the pane's search field.
///
/// A free function rather than a method on the view so that all three
/// sections filter by the same rule and a test can hold that rule still. The
/// fields handed in are the ones the row *shows*: searching on something
/// invisible is how a reader ends up staring at a list that hid a row for
/// reasons it never displayed.
enum KeyboardShortcutSearch {
    static func matches(query: String, in fields: String...) -> Bool {
        matches(query: query, fields: fields)
    }

    static func matches(query: String, fields: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(needle) }
    }
}

/// Where the app's configurable shortcuts live — and, under them, the keys
/// this window deliberately does not configure.
///
/// Three sections, and only the first is editable.
///
/// **Commands.** Everything Phantom owns and can be told to answer for on
/// different keys, grouped by the surface that answers — see
/// `ShortcutCaptureView` for the recording and `ShortcutCollisionChecker` for
/// what a combination is checked against before it sticks. Driven off
/// `PhantomShortcutAction.allCases` rather than spelled out, so a new command
/// appears here by existing.
///
/// **Fixed.** The chords Phantom answers for in code. They were reachable
/// only by accident before this: nothing named them until you happened to
/// record one of them yourself and got told it was taken.
///
/// **From Your Config.** What the Ghostty configuration file binds — fifty-one
/// keys out of the box, most of the app's keyboard surface, and until now the
/// pane spoke for fifteen of them and never mentioned the rest. Read-only on
/// purpose: this window writes `gui-settings`, the main config is hand-edited,
/// and where the two meet the window *shows* while the file *owns*.
struct KeyboardShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = PhantomShortcutStore.shared

    @State private var search = ""

    /// Bumped when the configuration reloads, which is the whole reason it
    /// exists: the Ghostty bindings below are read straight out of the loaded
    /// configuration, and nothing else in this view would notice the file
    /// changing under it while the window is open.
    @State private var configRevision = 0

    /// The pane is built by `SettingsView` with no arguments and cannot grow
    /// one without editing it, so the app is reached the way the command
    /// palette reaches it. Nil in a preview, which the config section treats
    /// as "nothing to show" rather than as an error.
    private var ghostty: Ghostty.App? {
        (NSApp.delegate as? AppDelegate)?.ghostty
    }

    var body: some View {
        /// Resolved once and passed down, rather than read from a computed
        /// property in three places: the empty state has to know whether the
        /// Ghostty list came back empty, and asking libghostty the same sixty
        /// questions again to find out would be answering them twice per
        /// keystroke in the search field.
        let config = configGroups

        return Form {
            Section { searchField }

            commandSections
            fixedSection
            configSection(config)

            if isEmpty(config: config) {
                Section {
                    Text(verbatim: "No shortcut matches “\(search)”.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcuts")
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)) { _ in
            configRevision += 1
        }
    }

    // MARK: Commands

    @ViewBuilder
    private var commandSections: some View {
        ForEach(PhantomShortcutGroup.allCases) { group in
            let actions = matchingActions(in: group)
            if !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        ShortcutCaptureView(action: action, store: shortcuts)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text(group.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A command matches on its name and on the sentence under it, because
    /// both are on screen and somebody searching "caret" is searching the
    /// sentence.
    private func matchingActions(in group: PhantomShortcutGroup) -> [PhantomShortcutAction] {
        PhantomShortcutAction.actions(in: group).filter {
            KeyboardShortcutSearch.matches(query: search, in: $0.title, $0.detail)
        }
    }

    // MARK: Fixed

    @ViewBuilder
    private var fixedSection: some View {
        let pane = matchingFixed(ShortcutCollisionChecker.paneShortcuts)
        let explorer = matchingFixed(ShortcutCollisionChecker.fileExplorerShortcuts)

        if !pane.isEmpty || !explorer.isEmpty {
            Section {
                if !pane.isEmpty {
                    subheading("Editor Pane")
                    ForEach(pane, id: \.owner) { fixed in
                        readOnlyRow(title: fixed.owner, keys: fixed.shortcut.displayString)
                    }
                }

                if !explorer.isEmpty {
                    subheading("File Explorer")
                    ForEach(explorer, id: \.owner) { fixed in
                        readOnlyRow(title: fixed.owner, keys: fixed.shortcut.displayString)
                    }
                }
            } header: {
                Text("Fixed")
            } footer: {
                Text("Phantom answers these in code and nothing can rebind them. The pane chords work whenever the editor pane has a file open; the explorer keys work while the file explorer has focus. They are listed here because the only other place they appear is the warning you get for recording one of them yourself.\n\nOne warning about ⌃␣, which is above in the editable list rather than here: macOS ships Select the Previous Input Source on the same keys, under System Settings → Keyboard → Keyboard Shortcuts → Input Sources, and a system shortcut is taken before any app is offered it. If suggestions never appear, either switch that one off or give Suggest Completions a different chord. Escape asks for the same list either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The engine's shape for a chord, in the shape this window draws.
    ///
    /// Only for drawing: `PhantomShortcut` is what knows that a space is
    /// spelled ␣ rather than as the nothing it actually reports, which is how
    /// the file explorer's own keys once appeared here as blanks.
    private static func displayed(_ shortcut: EditorShortcut) -> PhantomShortcut {
        var modifiers: Set<PhantomShortcutModifier> = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        return PhantomShortcut(key: shortcut.key, modifiers: modifiers)
    }

    /// Straight from the table the collision checker refuses recordings
    /// against, so the two cannot drift apart.
    private func matchingFixed(
        _ entries: [(owner: String, shortcut: PhantomShortcut)]
    ) -> [(owner: String, shortcut: PhantomShortcut)] {
        entries.filter {
            KeyboardShortcutSearch.matches(query: search, in: $0.owner, $0.shortcut.displayString)
        }
    }

    // MARK: From Your Config

    @ViewBuilder
    private func configSection(_ groups: [GhosttyConfigBindingGroup]) -> some View {
        if let ghostty, !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    subheading(group.title)
                    ForEach(group.bindings) { binding in
                        readOnlyRow(
                            title: binding.entry.title,
                            caption: binding.entry.action,
                            keys: binding.keys)
                    }
                }

                LabeledContent("Main Config File") {
                    Button("Open in Editor") { ghostty.openConfig() }
                }
            } header: {
                Text("From Your Config")
            } footer: {
                Text("These come from your main configuration file, not from this window — edit its keybind lines to change them. A key press is offered to whatever is on screen before it reaches the menu bar, which is how the editor's ⌘W closes a file tab while a file has focus and the menu's Close Tab takes it everywhere else; anything neither the editor nor a menu item claims falls through to the terminal. One kind of binding is missing here rather than unbound: a chord Phantom marks performable — it offers the key to the terminal first and acts only if the terminal declines, as the default ⌘K for Clear Screen does — cannot be read back from a loaded configuration at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            /// The one read of `configRevision`, and the reason it exists:
            /// this section is the only part of the pane whose content comes
            /// from outside the app's own defaults.
            .id(configRevision)
        }
    }

    /// Resolved against the live configuration every time the body runs.
    ///
    /// Recomputed rather than cached, and cheap enough to be: each row is one
    /// action-string parse and one hash lookup inside libghostty, and a cache
    /// would need invalidating on exactly the reload `configRevision` is
    /// already read here to catch.
    private var configGroups: [GhosttyConfigBindingGroup] {
        guard let config = ghostty?.config else { return [] }
        return GhosttyConfigShortcutCatalog.resolved(in: config) { entry in
            KeyboardShortcutSearch.matches(query: search, in: entry.title, entry.action)
        }
    }

    // MARK: Rows

    private func isEmpty(config: [GhosttyConfigBindingGroup]) -> Bool {
        PhantomShortcutGroup.allCases.allSatisfy { matchingActions(in: $0).isEmpty }
            && matchingFixed(ShortcutCollisionChecker.fixedShortcuts).isEmpty
            && config.isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $search, prompt: Text("Search commands"))
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The label over a run of rows inside a section that already has a
    /// header. Two of them, because the fixed table answers on two different
    /// surfaces and the Ghostty list is far too long to read unbroken.
    private func subheading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// A shortcut nobody can change, drawn like a command's chip but flat:
    /// a bordered button here would invite the click that does nothing.
    private func readOnlyRow(title: String, caption: String? = nil, keys: String) -> some View {
        LabeledContent {
            Text(verbatim: keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                if let caption {
                    Text(verbatim: caption)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

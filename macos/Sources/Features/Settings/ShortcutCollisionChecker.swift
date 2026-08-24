import AppKit

/// One shortcut already claimed by something else, described for a warning.
struct ShortcutCollision: Equatable {
    /// Who the claim belongs to, which decides what the reader is told.
    ///
    /// `sameCommand` is its own case because it is not really a conflict:
    /// binding a command to a combination it already answers to would change
    /// nothing at all, and "already used by Format Document" — when the
    /// command *is* Format Document — reads like a bug in the app rather
    /// than a duplicate in the list.
    enum Source: Equatable {
        case sameCommand
        case otherCommand
        case fixed
        case menu
    }

    /// Who owns it: a command's name, a menu item title, or the name of a
    /// fixed pane action.
    let owner: String
    let shortcut: PhantomShortcut
    let source: Source

    /// What the alert says. Here rather than in the view so the wording is
    /// something a test can hold on to.
    var message: String {
        switch source {
        case .sameCommand:
            return "“\(shortcut.displayString)” is already one of \(owner)'s shortcuts, so adding it again would change nothing. Press different keys, or discard this change."
        case .otherCommand, .fixed, .menu:
            return "“\(shortcut.displayString)” is already used by \(owner). Press the keys again for a different shortcut, or discard this change."
        }
    }
}

/// Finds out whether a proposed shortcut is already taken.
///
/// Three sources, and one deliberate omission.
///
/// **The menu**, walked live, because a menu key equivalent answers whatever
/// has focus — that is what makes it a real collision. Config bindings that
/// are synced onto menu items are covered by this, which is most of them.
///
/// **The fixed table** below: shortcuts Phantom answers for in code that
/// never reach a menu item, so nothing else would report them.
///
/// **The configurable commands**, which claim whatever the reader gave them.
///
/// What is deliberately *not* checked: a Ghostty config binding with no menu
/// item — `clear_screen` on ⌘K, the split-focus chords, ⌘1–9. Those reach
/// the terminal surface and only while it has focus, and every command this
/// checker guards is focus-scoped too (`PhantomShortcutGroup.detail` says so,
/// and `CodeTextView.performKeyEquivalent` now enforces it). Two commands
/// that can never both answer are not in collision, and refusing the
/// recording would block a pairing the app already ships — ⌘K attaches a
/// line in the editor and clears the screen in the terminal, on purpose.
///
/// An earlier reading of this called the omission a bug. It is one only if
/// the focus scoping is not real; keep them together.
///
/// The third door is the one that got likelier when a command stopped being
/// limited to a single shortcut: a reader adding a second binding is, by
/// definition, reaching for keys that were free a moment ago and may not be.
@MainActor
struct ShortcutCollisionChecker {
    /// The editor pane's own chords, answered in
    /// `SidebarSplitView.performKeyEquivalent` and only while the pane has
    /// at least one open file — see `EditorCommands.paneCommand`.
    static let paneShortcuts: [(owner: String, shortcut: PhantomShortcut)] = [
        ("Toggle terminal pane", PhantomShortcut(key: "\\", modifiers: [.command, .option])),
        ("Select file tab 1", PhantomShortcut(key: "1", modifiers: [.command, .option])),
        ("Select file tab 2", PhantomShortcut(key: "2", modifiers: [.command, .option])),
        ("Select file tab 3", PhantomShortcut(key: "3", modifiers: [.command, .option])),
        ("Select file tab 4", PhantomShortcut(key: "4", modifiers: [.command, .option])),
        ("Select file tab 5", PhantomShortcut(key: "5", modifiers: [.command, .option])),
        ("Select file tab 6", PhantomShortcut(key: "6", modifiers: [.command, .option])),
        ("Select file tab 7", PhantomShortcut(key: "7", modifiers: [.command, .option])),
        ("Select file tab 8", PhantomShortcut(key: "8", modifiers: [.command, .option])),
        ("Select file tab 9", PhantomShortcut(key: "9", modifiers: [.command, .option])),
    ]

    /// The file explorer's own navigation, handled in
    /// `FileExplorerView.handle(press:)`. Unmodified keys, which is exactly
    /// why they need naming here: nothing else in the app would report them
    /// as taken, so a command recorded on Return or Delete would be accepted
    /// without a word and then fight the tree.
    static let fileExplorerShortcuts: [(owner: String, shortcut: PhantomShortcut)] = [
        ("Rename in the file explorer", PhantomShortcut(key: "\r", modifiers: [])),
        ("Move to Trash in the file explorer", PhantomShortcut(key: PhantomShortcut.deleteKey, modifiers: [])),
        ("Open a file in the file explorer", PhantomShortcut(key: " ", modifiers: [])),
        ("Move up in the file explorer", PhantomShortcut(key: "\u{f700}", modifiers: [])),
        ("Move down in the file explorer", PhantomShortcut(key: "\u{f701}", modifiers: [])),
        ("Collapse in the file explorer", PhantomShortcut(key: "\u{f702}", modifiers: [])),
        ("Expand in the file explorer", PhantomShortcut(key: "\u{f703}", modifiers: [])),
    ]

    /// Shortcuts Phantom answers for outside the menu system **and** outside
    /// the configurable list — the two groups above, in one table.
    ///
    /// The editor's own keys used to be here too. They are configurable
    /// commands now, so listing them here as well would make every one of
    /// them collide with itself the moment somebody re-recorded it.
    ///
    /// Assembled rather than spelled out a third time: Settings lists these
    /// under **Fixed** and needs them grouped by the surface that answers
    /// them, and a second hand-written copy of these seventeen entries is how
    /// the pane ends up promising a key the app no longer holds.
    static let fixedShortcuts: [(owner: String, shortcut: PhantomShortcut)] =
        paneShortcuts + fileExplorerShortcuts

    /// Every shortcut currently claimed, from the fixed table and the live
    /// menu. The menu is walked rather than enumerated so a config binding
    /// the user changed is checked against what it changed *to*.
    static func allClaimed(menu: NSMenu?) -> [(owner: String, shortcut: PhantomShortcut)] {
        var claimed = fixedShortcuts
        collect(menu: menu, into: &claimed)
        return claimed
    }

    /// The owners (if any) already using `candidate`, most specific first.
    ///
    /// - Parameter action: the command the candidate is being recorded for,
    ///   so a clash inside its own list can be told from a clash with
    ///   somebody else's.
    /// - Parameter current: the shortcut being replaced, skipped so that
    ///   re-recording what is already assigned doesn't warn about itself.
    ///   Nil when a shortcut is being *added*, since then nothing is
    ///   being given up.
    /// - Parameter bindings: every configurable command's shortcuts, checked
    ///   across commands and within this one.
    static func collisions(
        with candidate: PhantomShortcut,
        for action: PhantomShortcutAction,
        excluding current: PhantomShortcut?,
        bindings: PhantomShortcutMap,
        menu: NSMenu?
    ) -> [ShortcutCollision] {
        var result: [ShortcutCollision] = []

        for (command, shortcut) in bindings.claimed
        where shortcut != current && shortcut == candidate {
            result.append(ShortcutCollision(
                owner: command.title,
                shortcut: shortcut,
                source: command == action ? .sameCommand : .otherCommand
            ))
        }

        for (owner, shortcut) in fixedShortcuts
        where shortcut != current && shortcut == candidate {
            result.append(ShortcutCollision(owner: owner, shortcut: shortcut, source: .fixed))
        }

        var claimedByMenu: [(owner: String, shortcut: PhantomShortcut)] = []
        collect(menu: menu, into: &claimedByMenu)
        for (owner, shortcut) in claimedByMenu
        where shortcut != current && shortcut == candidate {
            result.append(ShortcutCollision(owner: owner, shortcut: shortcut, source: .menu))
        }

        return result.sorted { lhs, rhs in rank(lhs.source) < rank(rhs.source) }
    }

    /// Which collision the alert leads with: the reader's own list first,
    /// since that is the one they can fix without knowing anything about
    /// the rest of the app.
    private static func rank(_ source: ShortcutCollision.Source) -> Int {
        switch source {
        case .sameCommand: return 0
        case .otherCommand: return 1
        case .fixed: return 2
        case .menu: return 3
        }
    }

    private static func collect(menu: NSMenu?, into result: inout [(owner: String, shortcut: PhantomShortcut)]) {
        guard let menu else { return }

        for item in menu.items {
            if let submenu = item.submenu {
                collect(menu: submenu, into: &result)
            }

            guard !item.keyEquivalent.isEmpty else { continue }
            guard item.isEnabled else { continue }

            let flags = item.keyEquivalentModifierMask
                .intersection([.command, .shift, .option, .control])
            var modifiers: Set<PhantomShortcutModifier> = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }

            result.append((
                owner: item.title.isEmpty ? "(menu item)" : item.title,
                shortcut: PhantomShortcut(key: item.keyEquivalent, modifiers: modifiers)
            ))
        }
    }
}

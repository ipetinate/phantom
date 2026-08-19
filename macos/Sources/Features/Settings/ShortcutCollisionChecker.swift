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
/// Three sources exist because shortcuts reach the app through three doors.
/// Everything in the menu system carries a key equivalent — including the
/// Ghostty config bindings, which are synced onto the menu items — so the
/// live `NSApp.mainMenu` is the authoritative list of *those*. The pane
/// shortcuts (⌥⌘\, ⌥⌘1–9) are handled in code and never appear on a menu
/// item, so they get a fixed table of their own. And the configurable
/// commands claim whatever the reader gave them, which is the map.
///
/// The third door is the one that got likelier when a command stopped being
/// limited to a single shortcut: a reader adding a second binding is, by
/// definition, reaching for keys that were free a moment ago and may not be.
@MainActor
struct ShortcutCollisionChecker {
    /// Shortcuts Phantom answers for outside the menu system **and** outside
    /// the configurable list.
    ///
    /// The editor's own keys used to be here too. They are configurable
    /// commands now, so listing them here as well would make every one of
    /// them collide with itself the moment somebody re-recorded it.
    static let fixedShortcuts: [(owner: String, shortcut: PhantomShortcut)] = [
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

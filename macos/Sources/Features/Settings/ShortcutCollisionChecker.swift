import AppKit

/// One shortcut already claimed by something else, described for a warning.
struct ShortcutCollision: Equatable {
    /// Who owns it: a menu item title, or the name of a fixed pane action.
    let owner: String
    let shortcut: PhantomShortcut
}

/// Finds out whether a proposed shortcut is already taken.
///
/// Two sources exist because shortcuts reach the app through two doors.
/// Everything in the menu system carries a key equivalent — including the
/// Ghostty config bindings, which are synced onto the menu items — so the
/// live `NSApp.mainMenu` is the authoritative list of *those*. The pane
/// shortcuts (⌥⌘\, ⌥⌘1–9, and the editor's own keys) are handled in code
/// and never appear on a menu item, so they get a fixed table of their own.
@MainActor
struct ShortcutCollisionChecker {
    /// Shortcuts Phantom answers for outside the menu system.
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
        ("Rename symbol", PhantomShortcut(key: "r", modifiers: [.command, .control])),
        ("Find references", PhantomShortcut(key: "g", modifiers: [.command, .control])),
        ("Format document", PhantomShortcut(key: "f", modifiers: [.command, .option])),
        ("Search workspace", PhantomShortcut(key: "f", modifiers: [.command, .shift])),
    ]

    /// Every shortcut currently claimed, from the fixed table and the live
    /// menu. The menu is walked rather than enumerated so a config binding
    /// the user changed is checked against what it changed *to*.
    static func allClaimed(menu: NSMenu?) -> [(owner: String, shortcut: PhantomShortcut)] {
        var claimed = fixedShortcuts
        collect(menu: menu, into: &claimed)
        return claimed
    }

    /// The owners (if any) already using `candidate`.
    ///
    /// - Parameter current: the shortcut being replaced, skipped so that
    ///   re-recording what is already assigned doesn't warn about itself.
    /// - Parameter otherPhantom: the other user-configurable shortcut and
    ///   its action's name, so the two can be told apart from menu owners.
    static func collisions(
        with candidate: PhantomShortcut,
        excluding current: PhantomShortcut?,
        otherPhantom: (action: PhantomShortcutAction, shortcut: PhantomShortcut)?,
        menu: NSMenu?
    ) -> [ShortcutCollision] {
        var result: [ShortcutCollision] = []

        for (owner, shortcut) in allClaimed(menu: menu) where shortcut != current {
            if shortcut == candidate {
                result.append(ShortcutCollision(owner: owner, shortcut: shortcut))
            }
        }

        if let otherPhantom,
           otherPhantom.shortcut != current,
           otherPhantom.shortcut == candidate {
            result.append(ShortcutCollision(
                owner: otherPhantom.action.title,
                shortcut: otherPhantom.shortcut
            ))
        }

        return result
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

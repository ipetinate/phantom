import AppKit
import SwiftUI
import GhosttyKit

extension Ghostty {
    /// The manager that's responsible for updating shortcuts of Ghostty's app menu
    @MainActor
    class MenuShortcutManager {

        /// Ghostty menu items indexed by their normalized shortcut. This avoids traversing
        /// the entire menu tree on every key equivalent event.
        ///
        /// We store a weak reference so this cache can never be the owner of menu items.
        /// If multiple items map to the same shortcut, the most recent one wins.
        private var menuItemsByShortcut: [MenuShortcutKey: Weak<NSMenuItem>] = [:]

        /// Reset our shortcut index since we're about to rebuild all menu bindings.
        func reset() {
            menuItemsByShortcut.removeAll(keepingCapacity: true)
        }

        /// Syncs a single menu shortcut for the given action. The action string is the same
        /// action string used for the Ghostty configuration.
        /// The shortcut macOS gives each standard editing command, used when
        /// the configuration has no answer for it.
        ///
        /// These four are here and nothing else is, because these are the ones
        /// whose menu action goes to the **first responder**: they do the right
        /// thing in a text view and in a terminal alike, so supplying a
        /// shortcut cannot make the menu advertise something that does not
        /// work. A Ghostty-only action — Split Right, say — has nothing to fall
        /// back to and should keep clearing.
        static let standardEditingShortcuts: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [
            "undo": ("z", .command),
            "redo": ("z", [.command, .shift]),
            "copy_to_clipboard": ("c", .command),
            "paste_from_clipboard": ("v", .command),
        ]

        func syncMenuShortcut(_ config: Ghostty.Config, action: String?, menuItem: NSMenuItem?) {
            guard let menu = menuItem else { return }
            guard !updateMenuShortcut(config, action: action, menuItem: menu) else { return }

            /// **This is where ⌘Z went.** `keyboardShortcut(for:)` answers nil
            /// for an action bound more than once, and `undo` is bound twice by
            /// default — `super+z` and `super+shift+t`. Clearing on that nil
            /// left the item with no shortcut at all, and the nib ships none
            /// of its own: `MainMenu.xib` gives Undo the `undo:` action and an
            /// empty modifier mask, expecting this sync to supply the keys.
            ///
            /// Measured through the accessibility API on a running build:
            /// every synced item whose action has two bindings — Undo, Copy,
            /// Paste — reported no command character, while Select All, whose
            /// action has one, kept its ⌘A.
            ///
            /// The item still *worked* when clicked, because `undo:` reaches
            /// the editor through the first responder. Only the keystroke was
            /// missing, which is why two earlier attempts at this bug examined
            /// the action and found nothing wrong with it.
            let fallback = action.flatMap { Self.standardEditingShortcuts[$0] }
            menu.keyEquivalent = fallback?.key ?? ""
            menu.keyEquivalentModifierMask = fallback?.modifiers ?? []
            menu.allowsAutomaticKeyEquivalentLocalization = true
            menu.allowsAutomaticKeyEquivalentMirroring = true
        }

        /// Attempts to perform a menu key equivalent only for menu items that represent
        /// Ghostty keybind actions. This is important because it lets our surface dispatch
        /// bindings through the menu so they flash but also lets our surface override macOS built-ins
        /// like Cmd+H.
        func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
            // Physical bindings take precedence over Unicode bindings in the core.
            let physicalKey = MenuShortcutKey(
                physicalKeyCode: event.keyCode,
                modifiers: event.modifierFlags)
            if let result = performMenuItem(for: physicalKey) {
                return result
            }

            guard let key = MenuShortcutKey(event: event) else { return false }
            return performMenuItem(for: key) ?? false
        }

        private func performMenuItem(for key: MenuShortcutKey) -> Bool? {
            // If we don't have an entry for this key combo, no Ghostty-owned
            // menu shortcut exists for this event.
            guard let weakItem = menuItemsByShortcut[key] else {
                return nil
            }

            // Weak references can be nil if a menu item was deallocated after sync.
            guard let item = weakItem.value else {
                menuItemsByShortcut.removeValue(forKey: key)
                return false
            }

            guard let parentMenu = item.menu else {
                return false
            }

            // Keep enablement state fresh in case menu validation hasn't run yet.
            parentMenu.update()
            guard item.isEnabled else {
                return false
            }

            /// Quit never goes through `performActionForItem`. Performed from
            /// inside key-equivalent dispatch, `terminate:` was observed —
            /// under lldb, on a breakpoint at `exit` — reaching `exit()`
            /// without ever consulting `applicationShouldTerminate` or
            /// `applicationWillTerminate`: no confirm dialog over running
            /// processes, and no final session save, so the quit lost
            /// whatever the debounced save hadn't flushed. The same
            /// `terminate:` sent outside the menu-perform machinery consults
            /// the delegate normally, so the quit binding is deferred out of
            /// this event and sent clean.
            if Self.handledAsDeferredQuit(item) { return true }

            let index = parentMenu.index(of: item)
            guard index >= 0 else {
                return false
            }

            parentMenu.performActionForItem(at: index)
            return true
        }
    }
}

extension Ghostty.MenuShortcutManager {
    /// How the quit binding leaves the key-equivalent dispatch. Replaceable
    /// so a test can observe the routing without terminating the test host —
    /// the default is the real thing.
    static var deferredQuit: () -> Void = {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Answers a quit-bound menu item by deferring `terminate:` instead of
    /// performing the item. See `performGhosttyBindingMenuKeyEquivalent` for
    /// why: performed from inside key-equivalent dispatch, `terminate:` was
    /// observed reaching `exit()` without consulting the app delegate — no
    /// confirmation, no final session save.
    static func handledAsDeferredQuit(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(NSApplication.terminate(_:)) else { return false }
        WindowBreadcrumbs.note(
            "quit binding: deferring terminate out of key-equivalent dispatch")
        deferredQuit()
        return true
    }
}

private extension Ghostty.MenuShortcutManager {
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Ghostty configuration.
    ///
    /// - Returns: Whether the menu item is updated and saved in ``menuItemsByShortcut``
    func updateMenuShortcut(_ config: Ghostty.Config, action: String?, menuItem menu: NSMenuItem) -> Bool {
        guard
            let action,
            let trigger = config.keybindTrigger(for: action),
            let shortcut = Ghostty.keyboardShortcut(for: trigger)
        else { return false }

        let isPhysical = trigger.tag == GHOSTTY_TRIGGER_PHYSICAL
        let physicalKeyCode = isPhysical ? Ghostty.Input.Key(cKey: trigger.key.physical)?.keyCode : nil
        // Build a direct lookup for key-equivalent dispatch so we don't need to
        // linearly walk the full menu hierarchy at event time.
        guard let key = MenuShortcutKey(shortcut, physicalKeyCode: physicalKeyCode) else {
            return false
        }

        menu.keyEquivalent = shortcut.key.character.description
        menu.keyEquivalentModifierMask = key.modifierFlags
        // The key equivalent was already localized from the physical keycode.
        menu.allowsAutomaticKeyEquivalentLocalization = !isPhysical
        menu.allowsAutomaticKeyEquivalentMirroring = !isPhysical

        // Later registrations intentionally override earlier ones for the same key.
        menuItemsByShortcut[key] = .init(menu)
        return true
    }
}

extension Ghostty.MenuShortcutManager {
    /// Hashable key for a menu shortcut match, normalized for quick lookup.
    struct MenuShortcutKey: Hashable {
        private enum Identity: Hashable {
            case keyEquivalent(String)
            case physicalKeyCode(UInt16)
        }

        private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

        private let identity: Identity
        private let modifiersRawValue: UInt

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        }

        init?(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
            let normalized = keyEquivalent.lowercased()
            guard !normalized.isEmpty else { return nil }
            var mods = modifiers.intersection(Self.shortcutModifiers)
            if
                keyEquivalent.lowercased() != keyEquivalent.uppercased(),
                normalized.uppercased() == keyEquivalent {
                // If key equivalent is case sensitive and
                // it's originally uppercased, then we need to add `shift` to the modifiers
                mods.insert(.shift)
            }
            self.identity = .keyEquivalent(normalized)
            self.modifiersRawValue = mods.rawValue
        }

        init(physicalKeyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            self.identity = .physicalKeyCode(physicalKeyCode)
            self.modifiersRawValue = modifiers.intersection(Self.shortcutModifiers).rawValue
        }

        init?(event: NSEvent) {
            guard let keyEquivalent = event.charactersIgnoringModifiers else { return nil }
            self.init(keyEquivalent: keyEquivalent, modifiers: event.modifierFlags)
        }

        /// Create from a SwiftUI `KeyboardShortcut`.
        init?(_ shortcut: KeyboardShortcut, physicalKeyCode: UInt16? = nil) {
            let modifiers = NSEvent.ModifierFlags(swiftUIFlags: shortcut.modifiers)
            if let physicalKeyCode {
                self.init(physicalKeyCode: physicalKeyCode, modifiers: modifiers)
            } else {
                self.init(
                    keyEquivalent: shortcut.key.character.description,
                    modifiers: modifiers)
            }
        }
    }
}

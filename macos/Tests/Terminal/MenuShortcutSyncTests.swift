import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The sync that writes each menu item's key equivalent from the config.
///
/// This is where ⌘Z was lost for three releases, and it was lost in the one
/// place nothing tested: the *shortcut*, not the action. The Undo item worked
/// when clicked the whole time, because `undo:` reaches the editor through the
/// first responder — so every test written about the action passed, twice, over
/// a keystroke that did nothing.
///
/// Built against a real `Ghostty.Config` rather than a stub, because the fault
/// was in what the core answers: `keyboardShortcut(for:)` returns nothing for
/// an action bound more than once, and `undo` is bound twice by default —
/// ⌘Z and the browser's ⇧⌘T. What made it answer for `undo` again is a
/// separate change, recorded below.
@MainActor
struct MenuShortcutSyncTests {
    private func manager() -> Ghostty.MenuShortcutManager {
        Ghostty.MenuShortcutManager()
    }

    private func item() -> NSMenuItem {
        /// Exactly what `MainMenu.xib` ships for Undo: the action, and no keys.
        /// A test that pre-loaded ⌘Z here would pass while the bug was present.
        let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        return item
    }

    // MARK: - The cause

    /// `undo` answers again, and the reason is worth writing down because it
    /// was not this file's doing.
    ///
    /// Two things kept it silent. It is bound twice, which the lookup refuses
    /// — and both of those bindings were *performable*, a flag that keeps a
    /// binding out of the core's reverse map entirely. Dropping the flag, so
    /// that ⌘Z stops typing a `z` into whatever is reading input, is what let
    /// the lookup speak at all. What it says is ⌘Z, pinned on the Zig side in
    /// `ghostty_config_trigger: default keybind`.
    ///
    /// The fallback further down is not dead. It covers every action the
    /// config still cannot answer for, which is any action bound twice that
    /// is not one of these.
    @Test func undoAnswersNowThatItsBindingsAreNotPerformable() throws {
        let config = try TemporaryConfig("")
        #expect(config.keyboardShortcut(for: "undo") != nil)
    }


    /// And one bound once resolves, which is what makes the line above a
    /// statement about ambiguity rather than about the lookup being broken.
    @Test func anActionBoundOnceResolves() throws {
        let config = try TemporaryConfig("keybind = clear\nkeybind = super+j=undo")
        #expect(config.keyboardShortcut(for: "undo") != nil)
    }

    // MARK: - The regression

    /// The whole bug in one assertion: after a sync, Undo has ⌘Z.
    ///
    /// It arrives from the config now rather than from the fallback, and the
    /// assertion is deliberately the same either way — what the reader
    /// presses is the contract, not which of the two supplied it.
    @Test func undoKeepsCommandZ() throws {
        let config = try TemporaryConfig("")
        let undo = item()

        manager().syncMenuShortcut(config, action: "undo", menuItem: undo)

        #expect(undo.keyEquivalent == "z")
        #expect(undo.keyEquivalentModifierMask == .command)
    }

    @Test func redoKeepsShiftCommandZ() throws {
        let config = try TemporaryConfig("")
        let redo = item()

        manager().syncMenuShortcut(config, action: "redo", menuItem: redo)

        #expect(redo.keyEquivalent == "z")
        #expect(redo.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test(arguments: [("copy_to_clipboard", "c"), ("paste_from_clipboard", "v")])
    func copyAndPasteKeepTheirs(action: String, key: String) throws {
        let config = try TemporaryConfig("")
        let menuItem = item()

        manager().syncMenuShortcut(config, action: action, menuItem: menuItem)

        #expect(menuItem.keyEquivalent == key)
        #expect(menuItem.keyEquivalentModifierMask == .command)
    }

    /// The reader's own binding still wins. A fallback that overrode the
    /// config would be a different bug wearing the same shape.
    @Test func aConfiguredBindingBeatsTheFallback() throws {
        let config = try TemporaryConfig("keybind = clear\nkeybind = super+j=undo")
        let undo = item()

        manager().syncMenuShortcut(config, action: "undo", menuItem: undo)

        #expect(undo.keyEquivalent == "j")
    }

    /// An action with no standard shortcut still clears, which is the
    /// behaviour the fallback is carved out of. Splitting a pane is not a
    /// macOS command and has nothing to fall back to.
    @Test func anActionWithNoStandardShortcutStillClears() throws {
        let config = try TemporaryConfig("keybind = clear")
        let split = item()
        split.keyEquivalent = "d"
        split.keyEquivalentModifierMask = .command

        manager().syncMenuShortcut(config, action: "new_split:right", menuItem: split)

        #expect(split.keyEquivalent.isEmpty)
        #expect(split.keyEquivalentModifierMask.isEmpty)
    }

    /// A nil action is what a menu item with no Ghostty equivalent passes, and
    /// it must not pick up a shortcut from anywhere.
    @Test func aNilActionGetsNothing() throws {
        let config = try TemporaryConfig("")
        let menuItem = item()

        manager().syncMenuShortcut(config, action: nil, menuItem: menuItem)

        #expect(menuItem.keyEquivalent.isEmpty)
    }

    // MARK: - The table

    /// Only the commands whose menu action goes to the **first responder** may
    /// carry a fallback. Supplying one for a Ghostty-only action would put a
    /// shortcut in the menu for something the responder chain cannot perform.
    @Test func onlyFirstResponderCommandsHaveAFallback() {
        let table = Ghostty.MenuShortcutManager.standardEditingShortcuts

        #expect(Set(table.keys) == [
            "undo",
            "redo",
            "copy_to_clipboard",
            "paste_from_clipboard",
        ])
        #expect(table["undo"]?.key == "z")
        #expect(table["redo"]?.modifiers == [.command, .shift])
        #expect(table.values.allSatisfy { $0.modifiers.contains(.command) })
    }

    /// The fallbacks are deliberately absent from the shortcut index, and this
    /// pins it: that index is how the terminal surface routes a Ghostty binding
    /// through the menu, and an entry for ⌘Z there would send the terminal's
    /// own undo to a menu item whose action goes to the surface — which does
    /// not answer `undo:`, so nothing would happen at all.
    @Test func aFallbackIsNotRegisteredForBindingDispatch() throws {
        let config = try TemporaryConfig("")
        let manager = manager()
        let undo = item()

        manager.syncMenuShortcut(config, action: "undo", menuItem: undo)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        ))

        #expect(!manager.performGhosttyBindingMenuKeyEquivalent(with: event))
    }
}

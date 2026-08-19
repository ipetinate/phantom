import AppKit

/// One command's binding, flattened: the command's id and the keys it
/// answers to.
///
/// Exists so a component that must not know about the store — the editor
/// engine — can still be *told* what its keys are. It carries no reference
/// to anything: an id string, a value, and two accessors spelling the pair
/// the way AppKit wants it for a menu item's key equivalent.
struct PhantomShortcutBinding: Equatable, Hashable, Sendable {
    /// `PhantomShortcutAction.id` — the stable string, not the enum, so the
    /// receiving side needn't name the enum to switch on it.
    let id: String
    let shortcut: PhantomShortcut

    var keyEquivalent: String { shortcut.key }
    var modifierFlags: NSEvent.ModifierFlags { shortcut.eventModifierFlags }
}

/// Every command's shortcuts, resolved, as one value.
///
/// This is the part with no view, no window and no `UserDefaults` in it: the
/// store owns the *editing*, this owns the *answering*. Handing it around as
/// a value is what lets the editor be told its bindings instead of reaching
/// for a singleton, and what lets "which command is ⌥⌘F?" be a test that
/// runs in microseconds.
struct PhantomShortcutMap: Equatable, Sendable {
    private let bindings: [PhantomShortcutAction: [PhantomShortcut]]

    init(_ bindings: [PhantomShortcutAction: [PhantomShortcut]] = [:]) {
        self.bindings = bindings
    }

    /// What a reader who has changed nothing has.
    static let defaults = PhantomShortcutMap(
        Dictionary(uniqueKeysWithValues: PhantomShortcutAction.allCases.map { ($0, $0.defaultShortcuts) })
    )

    /// Every combination the command answers to. Empty is a real answer: it
    /// means the reader took the last one away.
    func shortcuts(for action: PhantomShortcutAction) -> [PhantomShortcut] {
        bindings[action] ?? []
    }

    /// The one to *show* — on a menu item, which has room for exactly one
    /// key equivalent.
    ///
    /// Order inside a command's list means nothing else, but it has to mean
    /// this much: "the first one" is stable across launches because the list
    /// is stored as a list, whereas "whichever the dictionary hands back"
    /// would move a menu's key equivalent around between runs.
    func primary(for action: PhantomShortcutAction) -> PhantomShortcut? {
        shortcuts(for: action).first
    }

    /// Which command a combination triggers, or nil for a combination
    /// nothing claims.
    ///
    /// `allCases` order rather than the dictionary's, so two commands
    /// claiming the same keys — which the settings UI refuses, and a
    /// hand-edited plist does not — resolve to the same one every launch.
    func action(for shortcut: PhantomShortcut) -> PhantomShortcutAction? {
        PhantomShortcutAction.allCases.first { shortcuts(for: $0).contains(shortcut) }
    }

    /// The same question asked with a SwiftUI key press's parts.
    func action(key: Character, modifiers: Set<PhantomShortcutModifier>) -> PhantomShortcutAction? {
        action(for: PhantomShortcut(key: String(key), modifiers: modifiers))
    }

    /// The same question asked with an AppKit key event. Nil for a bare
    /// modifier, which is not a shortcut.
    func action(matching event: NSEvent) -> PhantomShortcutAction? {
        guard let pressed = PhantomShortcut(event: event) else { return nil }
        return action(for: pressed)
    }

    /// One surface's bindings, flattened for whoever has to answer for them.
    ///
    /// Grouped by command in `allCases` order and, within a command, in the
    /// reader's own order — so the first entry carrying a given id is that
    /// command's `primary`, and a menu built by walking this list shows the
    /// same key equivalent the settings window shows first.
    func bindings(in group: PhantomShortcutGroup) -> [PhantomShortcutBinding] {
        PhantomShortcutAction.actions(in: group).flatMap { action in
            shortcuts(for: action).map { PhantomShortcutBinding(id: action.id, shortcut: $0) }
        }
    }

    /// Every configured binding with the command that owns it, in the same
    /// stable order — what the collision check walks.
    var claimed: [(action: PhantomShortcutAction, shortcut: PhantomShortcut)] {
        PhantomShortcutAction.allCases.flatMap { action in
            shortcuts(for: action).map { (action: action, shortcut: $0) }
        }
    }
}

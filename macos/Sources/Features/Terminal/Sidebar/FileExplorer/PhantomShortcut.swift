import AppKit
import SwiftUI

/// One modifier that can be part of a shortcut.
enum PhantomShortcutModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case control
    case option
    case shift
    case command

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

/// A key combination Phantom lets the user configure — every command in
/// `PhantomShortcutAction`, each of which may answer to several of these.
///
/// A value type so the settings window can hand it to a key recorder, the
/// explorer and the editor can match against key presses, and all of them
/// can share the same serialization without any depending on the other.
struct PhantomShortcut: Equatable, Hashable, Codable, Sendable {
    /// The plain key, lowercased — "n" for ⇧⌘N, "\\" for ⌥⌘\.
    let key: String
    let modifiers: Set<PhantomShortcutModifier>

    init(key: String, modifiers: Set<PhantomShortcutModifier>) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Reads a combination out of a key-down event. Returns nil when the
    /// event is a modifier by itself, which is not a shortcut.
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1
        else { return nil }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var modifiers: Set<PhantomShortcutModifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        self.init(key: characters, modifiers: modifiers)
    }

    /// Modifier glyphs in the order macOS spells a shortcut — control,
    /// option, shift, command — then the key in capitals.
    var displayString: String {
        let prefix = Self.displayOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        return prefix + key.uppercased()
    }

    /// The stable form persisted and read back: "shift+command+n".
    var serialized: String {
        let modifiers = Self.displayOrder
            .filter { self.modifiers.contains($0) }
            .map(\.rawValue)
            .joined(separator: "+")
        return modifiers.isEmpty ? key : modifiers + "+" + key
    }

    init?(serialized: String) {
        // The key is whatever follows the last separator, taken by position
        // rather than by splitting. `+` is a perfectly ordinary key, and
        // splitting on it made ⌘+ serialize to "command++" and read back as
        // "command" with no key at all — so the shortcut silently reverted
        // to its default on the next launch.
        guard let lastSeparator = serialized.lastIndex(of: "+") else {
            guard serialized.count == 1 else { return nil }
            self.init(key: serialized, modifiers: [])
            return
        }

        let key = String(serialized[serialized.index(after: lastSeparator)...])
        let modifierPart = String(serialized[serialized.startIndex..<lastSeparator])

        // A trailing separator means the key *is* `+`, and the modifiers are
        // everything before the separator that precedes it.
        if key.isEmpty {
            guard let previous = modifierPart.lastIndex(of: "+") else {
                guard let onlyModifier = PhantomShortcutModifier(rawValue: modifierPart)
                else { return nil }
                self.init(key: "+", modifiers: [onlyModifier])
                return
            }
            let head = String(modifierPart[modifierPart.startIndex..<previous])
            let tail = String(modifierPart[modifierPart.index(after: previous)...])
            guard tail.isEmpty || PhantomShortcutModifier(rawValue: tail) != nil
            else { return nil }
            var modifiers = Self.parseModifiers(head)
            if let tailModifier = PhantomShortcutModifier(rawValue: tail) {
                modifiers?.insert(tailModifier)
            }
            guard let modifiers else { return nil }
            self.init(key: "+", modifiers: modifiers)
            return
        }

        guard key.count == 1, let modifiers = Self.parseModifiers(modifierPart)
        else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// Nil when any component is not a modifier this app knows.
    private static func parseModifiers(_ raw: String) -> Set<PhantomShortcutModifier>? {
        guard !raw.isEmpty else { return [] }
        var modifiers: Set<PhantomShortcutModifier> = []
        for part in raw.split(separator: "+").map(String.init) {
            guard let modifier = PhantomShortcutModifier(rawValue: part) else { return nil }
            modifiers.insert(modifier)
        }
        return modifiers
    }

    /// Whether a key press the explorer saw is this shortcut. `modifiers`
    /// is the press's command/shift/option/control set, already narrowed.
    ///
    /// The press's character carries the shift state ("N" for ⇧⌘N), so it is
    /// lowercased here — the stored key is normalized lowercase already.
    func matches(modifiers: Set<PhantomShortcutModifier>, key: Character) -> Bool {
        modifiers == self.modifiers && key.lowercased() == self.key
    }

    /// The same modifiers as AppKit flags — what a menu item's key
    /// equivalent takes, and what a key event carries.
    var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// The command/shift/option/control set of a SwiftUI key press,
    /// ignoring caps lock and the function-key flag that ride along on
    /// some presses.
    static func modifiers(from pressModifiers: EventModifiers) -> Set<PhantomShortcutModifier> {
        var modifiers: Set<PhantomShortcutModifier> = []
        if pressModifiers.contains(.command) { modifiers.insert(.command) }
        if pressModifiers.contains(.shift) { modifiers.insert(.shift) }
        if pressModifiers.contains(.option) { modifiers.insert(.option) }
        if pressModifiers.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private static let displayOrder: [PhantomShortcutModifier] = [
        .control, .option, .shift, .command,
    ]
}

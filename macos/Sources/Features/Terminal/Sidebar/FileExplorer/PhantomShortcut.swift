import AppKit
import SwiftUI

/// One modifier that can be part of a shortcut.
enum PhantomShortcutModifier: String, CaseIterable, Codable, Hashable {
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

/// A key combination Phantom lets the user configure — for now the file
/// explorer's new-file and new-folder shortcuts.
///
/// A value type so the settings window can hand it to a key recorder, the
/// explorer can match against key presses, and both can share the same
/// serialization without either depending on the other.
struct PhantomShortcut: Equatable, Codable {
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
        let parts = serialized.split(separator: "+").map(String.init)
        guard let last = parts.last, last.count == 1 else { return nil }

        var modifiers: Set<PhantomShortcutModifier> = []
        for part in parts.dropLast() {
            guard let modifier = PhantomShortcutModifier(rawValue: part) else { return nil }
            modifiers.insert(modifier)
        }

        self.init(key: last, modifiers: modifiers)
    }

    /// Whether a key press the explorer saw is this shortcut. `modifiers`
    /// is the press's command/shift/option/control set, already narrowed.
    ///
    /// The press's character carries the shift state ("N" for ⇧⌘N), so it is
    /// lowercased here — the stored key is normalized lowercase already.
    func matches(modifiers: Set<PhantomShortcutModifier>, key: Character) -> Bool {
        modifiers == self.modifiers && key.lowercased() == self.key
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

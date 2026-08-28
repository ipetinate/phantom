import AppKit

/// One key combination bound to an editor command.
///
/// The engine's own shape for a shortcut, so the host can hand over whatever
/// the reader configured without the engine naming the app's store. A list of
/// these per command is what "more than one shortcut for the same command"
/// means from in here.
struct EditorShortcut: Equatable, Sendable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Whether an event is this combination.
    ///
    /// Narrowed to the four modifiers a binding can name, and not to
    /// `deviceIndependentFlagsMask` as it was: that mask *includes* caps lock,
    /// the numeric pad bit and the function-key bit, so an equality against it
    /// failed on every event that carried one. Two consequences, both real —
    /// no remapped shortcut worked while caps lock was down, and an arrow key,
    /// which always sets the function bit, could not be bound at all.
    func matches(_ event: NSEvent) -> Bool {
        guard !key.isEmpty, Self.key(of: event) == key else { return false }
        return event.modifierFlags.intersection(Self.bindable) == modifiers.intersection(Self.bindable)
    }

    /// The key an event is on, as a binding spells it.
    ///
    /// `charactersIgnoringModifiers` is the answer for every key except one.
    /// Control and the space bar produce U+0000 — the control character the
    /// combination *sends* — on layouts where the property is filled in from
    /// the sent text rather than from the unmodified key, and an empty string
    /// on some others. Either way ⌃Space compares equal to nothing and a
    /// binding on it can never match, which is one of the ways the completion
    /// list could not be asked for.
    ///
    /// Recovered from the key code, which is what the hardware sends and what
    /// AppKit always fills in — the same reasoning `EditorCommands.divideZone`
    /// gives for matching the arrows that way.
    private static func key(of event: NSEvent) -> String {
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard event.keyCode == spaceKeyCode else { return typed }
        return typed.isEmpty || typed == "\u{0}" ? " " : typed
    }

    /// `kVK_Space`, spelled out rather than imported: Carbon's key codes come
    /// from `HIToolbox`, which nothing else in the editor engine links.
    private static let spaceKeyCode: UInt16 = 49

    private static let bindable: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
}

/// A command the editor's right-click menu offers.
///
/// Exists because the menu used to be `NSTextView`'s own with four items
/// prepended, and that menu is written for a word processor: spelling and
/// grammar, substitutions, transformations, speech, layout orientation, font,
/// writing direction. Substitutions is worse than useless in source — it turns
/// quotes into curly quotes — and the commands worth having sat above a wall of
/// submenus.
///
/// A value rather than menu-building code so the rule can be checked without an
/// `NSEvent`: which commands exist, in what order, and where a separator falls.
enum EditorContextCommand: Equatable, CaseIterable {
    case goToDefinition
    case findReferences
    case rename
    case format
    case attachLine
    case cut
    case copy
    case paste
    case selectAll

    /// The remappable command this is, as the app's own action id.
    ///
    /// A string rather than the app's enum because this file is inside the
    /// editor engine, which may not name the app — and because the id is a
    /// stored key either way, so a shared string is the honest currency.
    ///
    /// Nil for the clipboard: those are `NSTextView`'s own key equivalents,
    /// bound by AppKit and not ours to rebind.
    var actionID: String? {
        switch self {
        case .goToDefinition: "goToDefinition"
        case .findReferences: "findReferences"
        case .rename: "renameSymbol"
        case .format: "formatDocument"
        case .attachLine: "attachLineToAgent"
        case .cut, .copy, .paste, .selectAll: nil
        }
    }

    var title: String {
        switch self {
        case .goToDefinition: "Go to Definition"
        case .findReferences: "Find All References"
        case .rename: "Rename Symbol…"
        case .format: "Format Document"
        case .attachLine: "Attach Line to Agent"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        }
    }

    /// Which run of items this belongs to. A separator goes wherever the group
    /// changes, so removing a command cannot leave a rule against nothing.
    ///
    /// Language commands first because they are the reason somebody
    /// right-clicked a word. The clipboard next, where every other app keeps
    /// it. Select All apart from the clipboard, as `TextEdit` has it.
    var group: Int {
        switch self {
        case .goToDefinition, .findReferences, .rename, .format, .attachLine: 0
        case .cut, .copy, .paste: 1
        case .selectAll: 2
        }
    }

    /// The shortcut the menu displays when the host has bound nothing.
    ///
    /// A default, not the truth: `CodeNSTextView.commandShortcuts` overrides
    /// it with whatever the reader configured, and the menu shows that. Kept
    /// here so an editor with no host wiring still draws a usable menu.
    ///
    /// Displayed, not enforced: the clipboard four are `NSTextView`'s own key
    /// equivalents, and the language four are claimed in
    /// `CodeTextView.performKeyEquivalent` while the editor holds focus. A
    /// menu that showed a different key from the one that works would be worse
    /// than one showing none, so these have to agree with that method — the
    /// tests hold both to the same table.
    var key: String {
        switch self {
        case .goToDefinition: "j"
        case .findReferences: "g"
        case .rename: "r"
        case .format: "f"
        case .attachLine: "k"
        case .cut: "x"
        case .copy: "c"
        case .paste: "v"
        case .selectAll: "a"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        /// ⌃⌘J, on the same modifiers as the two below it — see
        /// `PhantomShortcutAction.defaultShortcuts` for why not ⌃⌘D.
        case .goToDefinition: [.command, .control]

        case .findReferences: [.command, .control]
        case .rename: [.command, .control]

        /// ⇧⌘F, asked for by name. It was ⌥⌘F, which is what VS Code uses,
        /// and workspace search moved off ⇧⌘F to make room — see
        /// `performKeyEquivalent`.
        case .format: [.command, .shift]

        /// ⌘K, the Cursor and VS Code habit for "add this to the chat".
        case .attachLine: [.command]

        case .cut, .copy, .paste, .selectAll: [.command]
        }
    }

    /// The standard selector for the clipboard commands, so `NSTextView` keeps
    /// validating them — copy greys itself over an empty selection, which is
    /// the honest state of a caret in a file, and judging that here would be
    /// judging it worse.
    ///
    /// Nil for the four this app implements itself, which ride a closure.
    var selector: Selector? {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .goToDefinition, .findReferences, .rename, .format, .attachLine: nil
        }
    }
}

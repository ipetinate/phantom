import AppKit

/// The two keys that ask the editor for help with the code under the caret.
///
/// ⌃Space asks for the completion list; ⌃. asks what can be done about what
/// is wrong there. Both are the combinations VS Code ships, which is the
/// habit a reader most likely arrives with.
///
/// ## Why these are here and not beside the other commands
///
/// Every other editor command is a case of the app's configurable action
/// list, and these two belong there as well — the entry is written up in
/// `KeyboardShortcutsSettingsView` under **Fixed** and says so. Until they
/// are promoted, the chords have to live somewhere the engine can read, and
/// the engine may not name the app's store.
///
/// So this is a table of defaults, and it is read the way the engine already
/// reads every other default: `CodeNSTextView.commandShortcuts` wins wherever
/// the host supplies an entry for the same action id, and this answers where
/// it does not. That is the rule the host already states — a missing id means
/// "use the default", an empty list means "no shortcut" — so promoting these
/// later takes them over rather than colliding with them.
enum EditorAssistCommand: String, CaseIterable, Sendable {
    /// Ask for the completion list, whether or not one would have opened by
    /// itself.
    case triggerSuggest

    /// Ask what can be done about the problem, or the code, under the caret.
    case quickFix

    /// The action id the engine dispatches on, and the key the host would use
    /// if it ever stored a binding for this.
    var actionID: String { rawValue }

    var title: String {
        switch self {
        case .triggerSuggest: return "Suggest Completions"
        case .quickFix: return "Quick Fix"
        }
    }

    /// What the reader is told the key does, in the shortcuts pane.
    var detail: String {
        switch self {
        case .triggerSuggest:
            return "Opens the completion list at the caret, without waiting for a pause"
        case .quickFix:
            return "Offers the fixes and refactors available where the caret is"
        }
    }

    /// The chord, as the engine matches it.
    ///
    /// ⌃Space carries a warning worth keeping next to it: macOS ships
    /// **Select the previous input source** on the same combination, under
    /// Keyboard Shortcuts → Input Sources, and a system shortcut is taken
    /// before any application sees the key. On a machine where that is still
    /// switched on this one never arrives, however correctly it is bound —
    /// which is why Escape asks for the same list, and why the shortcuts pane
    /// says so.
    var shortcut: EditorShortcut {
        switch self {
        case .triggerSuggest: return EditorShortcut(key: " ", modifiers: [.control])
        case .quickFix: return EditorShortcut(key: ".", modifiers: [.control])
        }
    }

    /// The table the engine falls back to, keyed by action id.
    static let defaults: [String: [EditorShortcut]] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.actionID, [$0.shortcut]) }
    )

    /// The command an id names, or nil for one of the host's own.
    static func named(_ id: String) -> EditorAssistCommand? {
        EditorAssistCommand(rawValue: id)
    }
}

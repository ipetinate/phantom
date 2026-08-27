import Foundation

/// The editor's optional behaviours, and whether the reader wants them.
///
/// ## Why these are settings at all
///
/// Everything here is something the editor does *for* the reader without
/// being asked: it writes an import they did not type, it prints a
/// colleague's name beside a line they are reading, it draws a card when the
/// pointer rests. Each is useful and each is an opinion, and an opinion the
/// reader cannot turn off is an imposition.
///
/// So the rule for what belongs here: a behaviour is a setting when it puts
/// something on screen, or in the file, that the reader did not ask for in
/// that moment. Things they invoke — a rename, a format, a jump — are not
/// settings; they already chose.
///
/// ## Where it is kept
///
/// In `UserDefaults`, and **never** in `GuiConfigStore`. That store writes
/// `gui-settings`, which the main config pulls in with `config-file`, and the
/// Ghostty core rejects a key it does not know — so the first switch a reader
/// flipped would raise a configuration error naming `editor-git-lens` as an
/// unknown field, and raise it again on every launch until they deleted the
/// line by hand.
///
/// This is the rule `CompletionSettingsStore` and `EditorSettings` already
/// follow, written down in both of them and asserted by a test. The first
/// version of this file broke it, which is worth leaving here: everything
/// Phantom adds stays out of `gui-settings` unless it also exists in
/// `src/config/Config.zig`.
///
/// Every key defaults to **on**: this describes an editor somebody is already
/// using, and a release that silently switched a feature off would read as a
/// regression.
@MainActor
final class EditorFeatureSettings: ObservableObject {
    static let shared = EditorFeatureSettings()

    /// Bumped whenever a value changes, for the views that cannot observe a
    /// computed property.
    @Published private(set) var revision = 0

    private init() {}

    // MARK: The behaviours

    /// Whether accepting a completion may add the import it needs.
    ///
    /// On by default, because a name inserted without its import is a line
    /// that does not compile and the reader has to go and fix it. Off for
    /// somebody who orders their imports by hand, or whose project rejects an
    /// import written the way the language server writes it.
    ///
    /// Turning it off does **not** turn off the completion — only the extra
    /// edit that comes with it. It also skips the `completionItem/resolve`
    /// round trip on accept, so the insertion stops waiting on the server at
    /// all.
    var autoImport: Bool { flag(Key.autoImport) }

    /// Whether the line under the caret shows who last changed it.
    ///
    /// On by default. Off for anybody who finds a name beside their cursor
    /// distracting, and for screen sharing, where it puts colleagues' names
    /// in a recording.
    var gitLens: Bool { flag(Key.gitLens) }

    /// Whether resting the pointer over a symbol opens its documentation.
    var hoverCards: Bool { flag(Key.hoverCards) }

    /// Whether the margin marks lines that differ from the committed file.
    var diffMarks: Bool { flag(Key.diffMarks) }

    /// Whether a list of completions appears as the reader types.
    ///
    /// Off does not disable completion: ⌃Space still asks for it. This is
    /// only about the list that arrives unasked.
    var completionWhileTyping: Bool { flag(Key.completionWhileTyping) }

    /// Whether problems are underlined in the text.
    var inlineDiagnostics: Bool { flag(Key.inlineDiagnostics) }

    /// Whether an agent pointing at a line may scroll the editor to it.
    ///
    /// The strongest case in the app for something happening that the reader
    /// did not ask for in that moment: an agent calls `reveal_line`, and the
    /// viewport moves under somebody who was reading something else — opening
    /// the file too, if it was closed.
    ///
    /// Separate from ``agentGutterMark`` on purpose. Wanting to be taken to
    /// the line and wanting an icon left beside it afterwards are different
    /// wants, and one switch for both would force a reader who dislikes one
    /// to give up the other.
    var agentReveal: Bool { flag(Key.agentReveal) }

    /// Whether the line an agent pointed at keeps its brand icon in the
    /// margin afterwards.
    var agentGutterMark: Bool { flag(Key.agentGutterMark) }

    // MARK: Reading and writing

    enum Key: String, CaseIterable {
        case autoImport = "editor-auto-import"
        case gitLens = "editor-git-lens"
        case hoverCards = "editor-hover-cards"
        case diffMarks = "editor-diff-marks"
        case completionWhileTyping = "editor-completion-while-typing"
        case inlineDiagnostics = "editor-inline-diagnostics"
        case agentReveal = "editor-agent-reveal"
        case agentGutterMark = "editor-agent-gutter-mark"

        /// What the settings window calls it.
        var title: String {
            switch self {
            case .autoImport: return "Add imports automatically"
            case .gitLens: return "Show who last changed the current line"
            case .hoverCards: return "Show documentation on hover"
            case .diffMarks: return "Mark changed lines in the margin"
            case .completionWhileTyping: return "Suggest completions while typing"
            case .inlineDiagnostics: return "Underline problems in the text"
            case .agentReveal: return "Let agents scroll the editor to a line"
            case .agentGutterMark: return "Mark the line an agent pointed at"
            }
        }

        /// The sentence under it, which says what turning it off costs rather
        /// than restating the title.
        var detail: String {
            switch self {
            case .autoImport:
                return "When a suggestion names something this file does not import yet, "
                    + "accepting it adds the import. Off inserts only the name."
            case .gitLens:
                return "The author and commit message for the line the cursor is on, "
                    + "in grey at the end of it."
            case .hoverCards:
                return "Resting the pointer over a symbol opens its documentation."
            case .diffMarks:
                return "A + beside a new line and a \u{2212} beside one that changed or "
                    + "was removed, measured against the last commit."
            case .completionWhileTyping:
                return "Off still leaves \u{2303}Space, which asks for the list directly."
            case .inlineDiagnostics:
                return "Errors and warnings underlined where they are, rather than only "
                    + "in the problems list."
            case .agentReveal:
                return "An agent that points at a line moves the editor to it, opening "
                    + "the file if it was closed. Off leaves your place alone."
            case .agentGutterMark:
                return "The agent's icon stays in the margin beside the line it pointed "
                    + "at, until the line is edited."
            }
        }
    }

    func isEnabled(_ key: Key) -> Bool { flag(key) }

    func set(_ key: Key, to enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key.rawValue)
        revision += 1
    }

    /// Absent means on. A key nobody has written is a reader who has never
    /// been to this pane, and they should have the whole editor.
    ///
    /// Read through `object(forKey:)` rather than `bool(forKey:)`, because
    /// `bool(forKey:)` answers `false` for a key that was never written — it
    /// cannot tell "switched off" from "never touched", and using it here
    /// would ship every one of these behaviours off by default.
    private func flag(_ key: Key) -> Bool {
        UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? true
    }
}

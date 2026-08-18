import Foundation

/// Which surface a command belongs to, which is also how Settings groups
/// the list and how the editor asks for "only the bindings that are mine".
enum PhantomShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case fileExplorer
    case editor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileExplorer: return "File Explorer"
        case .editor: return "Editor"
        }
    }

    /// The sentence under the section, explaining when its keys apply.
    var detail: String {
        switch self {
        case .fileExplorer:
            return "These answer while the file explorer has focus. Click a shortcut and press the new keys to record it, “+” to give one command a second shortcut, and the arrow to put the defaults back. A command with no shortcut at all is allowed — remove its last one and it simply stops answering to keys."
        case .editor:
            return "These answer while a file is open and focused, so the terminal keeps its own keys everywhere else. If a combination is already claimed — by a menu item, by another command here, or by the same command twice — you'll be asked to choose again or discard the change."
        }
    }
}

/// A command Phantom answers for, and can be told to answer for on
/// different keys.
///
/// Every command is one case, and the raw value is its **storage key**: it
/// names the `UserDefaults` entry holding that command's shortcuts and it
/// crosses to the editor engine as a plain string. Renaming a case silently
/// abandons whatever the reader had configured, so the raw values are
/// spelled out rather than derived.
///
/// Declaration order is meaningful in one way only: it decides which command
/// wins if two of them somehow claim the same combination. The settings UI
/// prevents that, but a hand-edited defaults plist cannot be, and a resolver
/// that answered differently between two launches would be worse than one
/// that answers the first-declared every time.
enum PhantomShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newFile
    case newFolder
    case save
    case saveAll
    case closeTab
    case findInFile
    case searchWorkspace
    case goToDefinition
    case findReferences
    case renameSymbol
    case formatDocument

    var id: String { rawValue }

    var group: PhantomShortcutGroup {
        switch self {
        case .newFile, .newFolder: return .fileExplorer
        default: return .editor
        }
    }

    var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .save: return "Save"
        case .saveAll: return "Save All"
        case .closeTab: return "Close File Tab"
        case .findInFile: return "Find in File"
        case .searchWorkspace: return "Search Workspace"
        case .goToDefinition: return "Go to Definition"
        case .findReferences: return "Find All References"
        case .renameSymbol: return "Rename Symbol"
        case .formatDocument: return "Format Document"
        }
    }

    var detail: String {
        switch self {
        case .newFile: return "Creates a file next to the selection"
        case .newFolder: return "Creates a folder next to the selection"
        case .save: return "Writes the focused file to disk"
        case .saveAll: return "Writes every open file with unsaved changes"
        case .closeTab: return "Closes the focused file tab"
        case .findInFile: return "Opens the find bar for the focused file"
        case .searchWorkspace: return "Searches every file in the project"
        case .goToDefinition: return "Jumps to where the symbol under the caret is defined"
        case .findReferences: return "Lists everywhere the symbol under the caret is used"
        case .renameSymbol: return "Renames the symbol under the caret across the project"
        case .formatDocument: return "Formats the focused file"
        }
    }

    /// What the command answers to out of the box.
    ///
    /// A list rather than one shortcut so a default can be *nothing*, which
    /// is the honest answer for a command that has only ever been reachable
    /// from the context menu: inventing a combination for it here would
    /// claim keys the reader never agreed to give up. It is also the state
    /// the reader can put any command into, so it had better be a state the
    /// defaults can express.
    var defaultShortcuts: [PhantomShortcut] {
        switch self {
        case .newFile: return [PhantomShortcut(key: "n", modifiers: [.command, .shift])]
        case .newFolder: return [PhantomShortcut(key: "m", modifiers: [.command, .shift])]
        case .save: return [PhantomShortcut(key: "s", modifiers: [.command])]
        case .saveAll: return [PhantomShortcut(key: "s", modifiers: [.command, .shift])]
        case .closeTab: return [PhantomShortcut(key: "w", modifiers: [.command])]
        case .findInFile: return [PhantomShortcut(key: "f", modifiers: [.command])]
        /// ⌥⌘F, which is where it went when Format took ⇧⌘F by name. The two
        /// swapped rather than one of them losing a shortcut, and both are
        /// remappable from here — which is the point of the swap being a
        /// default rather than a constant somewhere in the editor.
        case .searchWorkspace: return [PhantomShortcut(key: "f", modifiers: [.command, .option])]
        case .goToDefinition: return []
        case .findReferences: return [PhantomShortcut(key: "g", modifiers: [.command, .control])]
        case .renameSymbol: return [PhantomShortcut(key: "r", modifiers: [.command, .control])]
        case .formatDocument: return [PhantomShortcut(key: "f", modifiers: [.command, .shift])]
        }
    }

    /// The commands on one surface, in declaration order.
    static func actions(in group: PhantomShortcutGroup) -> [PhantomShortcutAction] {
        allCases.filter { $0.group == group }
    }
}

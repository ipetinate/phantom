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
    case moveLineUp
    case moveLineDown
    case attachLineToAgent
    case attachLineToAgentPicker
    case triggerSuggest
    case quickFix

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
        case .triggerSuggest: return "Suggest Completions"
        case .quickFix: return "Quick Fix"
        case .goToDefinition: return "Go to Definition"
        case .findReferences: return "Find All References"
        case .renameSymbol: return "Rename Symbol"
        case .formatDocument: return "Format Document"
        case .moveLineUp: return "Move Line Up"
        case .moveLineDown: return "Move Line Down"
        case .attachLineToAgent: return "Attach Line to Agent"
        case .attachLineToAgentPicker: return "Attach Line to a Chosen Terminal…"
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
        case .triggerSuggest:
            return "Asks for the completion list without waiting for it to appear on its own"
        case .quickFix:
            return "Offers the fixes and refactors the language server has for what is "
                + "under the caret"
        case .goToDefinition: return "Jumps to where the symbol under the caret is defined"
        case .findReferences: return "Lists everywhere the symbol under the caret is used"
        case .renameSymbol: return "Renames the symbol under the caret across the project"
        case .formatDocument: return "Formats the focused file"
        case .moveLineUp: return "Swaps the caret's line — or every selected line — with the one above"
        case .moveLineDown: return "Swaps the caret's line — or every selected line — with the one below"
        case .attachLineToAgent: return "Types @file:line for the selection into this tab's terminal"
        case .attachLineToAgentPicker: return "Asks which terminal, then types @file:line into it"
        }
    }

    /// What the command answers to out of the box.
    ///
    /// A list rather than one shortcut, and an empty list is a legal answer:
    /// it is the state the reader can put any command into by removing its
    /// last shortcut, so it had better be a state the defaults can express
    /// too. Nothing ships in it today — Go to Definition was the last one,
    /// and shipping the only symbol command with no keys read as an
    /// oversight rather than as the decision the empty list is meant to be.
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
        /// ⌃⌘J, which puts the three symbol commands on one pair of
        /// modifiers — definition, references, rename — so that learning any
        /// of them teaches the other two.
        ///
        /// J rather than the D everything about the word "definition"
        /// suggests: macOS spends ⌃⌘D on Look Up in every text view, and
        /// this is one. ⌃⌘J is also where Xcode keeps Jump to Definition,
        /// which is the habit a reader most likely arrives with.
        /// ⌃Space and ⌃. are what every other editor uses, so they are the
        /// defaults — but ⌃Space is also macOS's "Select the Previous Input
        /// Source", and a system shortcut is taken before any app sees the
        /// key. That is the reason these two are rebindable rather than fixed:
        /// a reader who uses more than one input source cannot have ours, and
        /// needs somewhere to move it to.
        case .triggerSuggest: return [PhantomShortcut(key: " ", modifiers: [.control])]
        case .quickFix: return [PhantomShortcut(key: ".", modifiers: [.control])]
        case .goToDefinition: return [PhantomShortcut(key: "j", modifiers: [.command, .control])]
        case .findReferences: return [PhantomShortcut(key: "g", modifiers: [.command, .control])]
        case .renameSymbol: return [PhantomShortcut(key: "r", modifiers: [.command, .control])]
        case .formatDocument: return [PhantomShortcut(key: "f", modifiers: [.command, .shift])]

        /// ⌥↑ and ⌥↓, the pairing VS Code and JetBrains both ship for this.
        ///
        /// These shadow AppKit's own ⌥-arrow paragraph motion, which is the
        /// one real cost: a reader who expects ⌥↑ to jump a paragraph gets a
        /// moved line instead. Taken deliberately — every editor this fork is
        /// measured against binds move-line here, and paragraph motion has
        /// ⌘↑/⌘↓ and the mouse.
        ///
        /// It also leaves ⇧⌥↑/↓ free, which is where duplicate-line goes if
        /// it is ever built: the same editors pair the two commands on
        /// exactly those keys, so move-line sitting on ⇧⌥ was occupying the
        /// obvious home of the command that comes after it.
        ///
        /// Nothing inside Phantom competes: not the main menu, and not the
        /// completion list, which claims the `moveUp:`/`moveDown:` selectors
        /// the *bare* arrows send, and only while it is open. The terminal is
        /// a near miss worth writing down — Ghostty's defaults bind ⌥← and
        /// ⌥→ to the shell's word motion and leave ⌥↑/↓ alone, so the pair
        /// taken here is free and the pair beside it is not.
        case .moveLineUp:
            return [PhantomShortcut(key: PhantomShortcut.upArrow, modifiers: [.option])]
        case .moveLineDown:
            return [PhantomShortcut(key: PhantomShortcut.downArrow, modifiers: [.option])]

        /// ⌘K, the combination Cursor and VS Code taught for "add this line
        /// to the chat". The terminal's own ⌘K is untouched: the editor and
        /// the terminal are mutually hidden siblings, so whichever is on
        /// screen answers.
        case .attachLineToAgent:
            return [PhantomShortcut(key: "k", modifiers: [.command])]
        case .attachLineToAgentPicker:
            return [PhantomShortcut(key: "k", modifiers: [.command, .shift])]
        }
    }

    /// The commands on one surface, in declaration order.
    static func actions(in group: PhantomShortcutGroup) -> [PhantomShortcutAction] {
        allCases.filter { $0.group == group }
    }
}

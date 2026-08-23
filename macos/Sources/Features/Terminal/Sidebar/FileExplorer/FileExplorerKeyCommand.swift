import Foundation

/// What a bare key press means to the file tree once navigation has had its
/// say: the two commands that act on whatever row is selected.
///
/// A value rather than a branch inside the view, for the reason
/// `FileTreeNavigation` is one — except that what is worth being sure about
/// here is not which row comes next, it is *when a file leaves the disk*. The
/// refusals below have to be checkable without a window, a focus state or an
/// `NSEvent`, because a Delete answered at the wrong moment is silent and
/// there is no key press that undoes it.
enum FileExplorerKeyCommand: Equatable {
    case rename(path: String)
    case moveToTrash(path: String)

    /// What Return reports, which is also what `SwiftUI.KeyEquivalent.return`
    /// holds — the coincidence that kept rename working while trash did not.
    static let renameCharacter: Character = "\r"

    /// What the Delete key reports.
    ///
    /// This is the whole of the bug. The view used to compare a press against
    /// `SwiftUI.KeyEquivalent.delete`, which holds U+0008 — the ASCII
    /// backspace — while a key-down from the Delete key carries U+007F, the
    /// character AppKit names `NSDeleteCharacter` and the character
    /// `PhantomShortcut` and `ShortcutCollisionChecker` already store for it.
    /// `SwiftUI.KeyPress.key` passes the event's own character through
    /// untouched rather than normalising it — measured, by hosting a focusable
    /// view and sending it both spellings — so the comparison never matched
    /// and the branch was dead from the day it was written.
    static let moveToTrashCharacter = Character(PhantomShortcut.deleteKey)

    /// What the press amounts to, or nil when the tree must let it pass.
    ///
    /// Three refusals, and each one is a bug that has to stay fixed. Without
    /// focus, because the explorer shares its window with a terminal that is
    /// being typed into, and a Delete answered from there would trash a row
    /// the reader last clicked minutes ago. Mid-edit, because a name field is
    /// open and Delete is a backspace inside it. Without a selection, because
    /// there is nothing to act on and the key belongs to whoever else wants
    /// it.
    static func resolve(
        character: Character,
        hasFocus: Bool,
        isEditing: Bool,
        selection: String?
    ) -> FileExplorerKeyCommand? {
        guard hasFocus, !isEditing, let selection else { return nil }

        switch character {
        case renameCharacter: return .rename(path: selection)
        case moveToTrashCharacter: return .moveToTrash(path: selection)
        default: return nil
        }
    }
}

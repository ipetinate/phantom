import Foundation

/// How one row in the file explorer is marked.
///
/// A value because the rule it encodes was got wrong by accident: three
/// different facts were drawn as the same thing at three strengths — the row
/// last clicked, the file open in the focused tab, and the terminal's working
/// directory — and two of them could be true of *different* rows at the same
/// time. What that looks like on screen is two highlights, one brighter, and a
/// reader working out which shade means what.
///
/// The rule now: exactly one row is filled, and it is the file open in the
/// focused tab. That is the question a tree answers — where am I — and it has
/// one answer.
struct FileExplorerRowEmphasis: Equatable {
    /// What the row is painted with. Only one row in the list can be `.open`,
    /// and `.hover` follows the pointer, so no two rows are ever filled for a
    /// reason the reader has to disambiguate.
    enum Fill: Equatable {
        case none
        case hover
        case open
    }

    let fill: Fill

    /// Whether the row is outlined as the selection.
    ///
    /// Selection survives as a fact because three commands read it — Return
    /// renames it, Delete trashes it, a new file lands beside it — so a tree
    /// without one is a tree where those three have nothing to act on. It stops
    /// being a *fill* so it no longer competes with the open file for the same
    /// visual language.
    let showsSelectionRing: Bool

    /// - Parameters:
    ///   - isOpenInEditor: the file this row is, is the one in the focused tab.
    ///   - isSelected: the row was clicked, or a keyboard command moved here.
    ///   - isHovered: the pointer is over it.
    static func resolve(
        isOpenInEditor: Bool,
        isSelected: Bool,
        isHovered: Bool
    ) -> FileExplorerRowEmphasis {
        let fill: Fill = if isOpenInEditor {
            .open
        } else if isHovered {
            .hover
        } else {
            .none
        }

        /// No ring on the row that is already filled. After a click the two
        /// facts coincide — that is the common case — and drawing both would
        /// put two marks on one row for one thing.
        return FileExplorerRowEmphasis(
            fill: fill,
            showsSelectionRing: isSelected && !isOpenInEditor
        )
    }
}

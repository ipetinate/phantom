@testable import Ghostty
import Testing

/// One filled row in the explorer, and it is the file open in the focused tab.
///
/// Three facts used to be drawn as the same thing at three strengths — clicked,
/// open, and the terminal's directory — and two of them could be true of
/// different rows at once. The report was the plainest possible statement of
/// that: click one file, switch tabs, and two rows are lit.
struct FileExplorerRowEmphasisTests {
    private func emphasis(
        open: Bool = false,
        selected: Bool = false,
        hovered: Bool = false
    ) -> FileExplorerRowEmphasis {
        .resolve(isOpenInEditor: open, isSelected: selected, isHovered: hovered)
    }

    /// The reported scenario, as the test: a row is clicked, then the editor
    /// moves to another file. Exactly one row is filled, and it is the second.
    @Test func clickingOneFileAndOpeningAnotherLeavesOneFill() {
        let clicked = emphasis(open: false, selected: true)
        let opened = emphasis(open: true, selected: false)

        #expect(clicked.fill == .none, "the clicked row kept a fill")
        #expect(opened.fill == .open)
        #expect(clicked.showsSelectionRing, "the selection stopped being visible at all")
    }

    @Test func theOpenFileIsAlwaysTheFilledRow() {
        #expect(emphasis(open: true).fill == .open)
        #expect(emphasis(open: true, selected: true).fill == .open)
        #expect(emphasis(open: true, hovered: true).fill == .open)
    }

    /// The open file wins over the pointer, or the fill would move as the mouse
    /// crossed the list and "where am I" would answer differently every second.
    @Test func hoverNeverOutranksTheOpenFile() {
        #expect(emphasis(open: true, hovered: true).fill == .open)
        #expect(emphasis(open: false, hovered: true).fill == .hover)
    }

    /// After a click the two facts are the same row, and one mark is enough.
    @Test func theOpenFileIsNotAlsoRinged() {
        #expect(!emphasis(open: true, selected: true).showsSelectionRing)
        #expect(emphasis(open: false, selected: true).showsSelectionRing)
    }

    /// Nothing about the selection was removed — three commands read it — so a
    /// selected row off screen from the editor still says so.
    @Test func aSelectionAwayFromTheEditorIsStillMarked() {
        let elsewhere = emphasis(open: false, selected: true, hovered: false)

        #expect(elsewhere.showsSelectionRing)
        #expect(elsewhere.fill == .none)
    }

    @Test func anUntouchedRowIsUnmarked() {
        #expect(emphasis() == FileExplorerRowEmphasis(fill: .none, showsSelectionRing: false))
    }
}

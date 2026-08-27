import Foundation
import Testing

@testable import Ghostty

/// Which lines are the reader's own, as distinct from which glyph the margin
/// draws beside them.
///
/// These two questions were treated as one, and the git lens got the wrong
/// answer because of it. `-` is drawn for a line changed in place *and* for a
/// line that merely survived a deletion; only the first is text the reader
/// wrote. Filtering the marks for `.added` therefore covered a line typed on a
/// new row and missed every line edited in place — which is the commonest
/// edit, and the one that was reported.
struct EditorChangedLinesTests {
    private func lines(_ text: String) -> [String] {
        EditorDiffMarks.lines(of: text)
    }

    // MARK: The case the ghost text got wrong

    /// The reported bug, reduced. Line 2 is edited in place: the margin marks
    /// it `-`, and it must still count as changed.
    @Test func aLineEditedInPlaceCounts() {
        let base = lines("one\ntwo\nthree\n")
        let current = lines("one\ntwo edited\nthree\n")

        #expect(EditorDiffMarks.changedLines(current: current, base: base) == [2])
        #expect(EditorDiffMarks.marks(current: current, base: base)[2] == .removed,
                "the glyph really is a minus — which is why the glyph cannot answer this")
    }

    @Test func aNewLineCounts() {
        let base = lines("one\ntwo\n")
        let current = lines("one\ninserted\ntwo\n")

        #expect(EditorDiffMarks.changedLines(current: current, base: base) == [2])
    }

    /// The other half, and the reason this cannot simply take every marked
    /// line: a line that survived a deletion wears a `-` about its neighbour.
    /// Its own text is untouched, so `git blame` is still right about it.
    @Test func aLineThatMerelySurvivedADeletionDoesNotCount() {
        let base = lines("one\ntwo\nthree\n")
        let current = lines("one\nthree\n")

        let marks = EditorDiffMarks.marks(current: current, base: base)
        #expect(marks.values.contains(.removed), "something is marked")
        #expect(EditorDiffMarks.changedLines(current: current, base: base).isEmpty,
                "but no surviving line's text is the reader's")
    }

    @Test func anUnchangedFileHasNoChangedLines() {
        let base = lines("one\ntwo\n")

        #expect(EditorDiffMarks.changedLines(current: base, base: base).isEmpty)
    }

    @Test func everyLineOfANewFileCounts() {
        #expect(EditorDiffMarks.changedLines(current: lines("a\nb\n"), base: []).isEmpty,
                "no baseline means nothing can be compared, not that everything changed")
    }

    @Test func severalEditsAreAllReported() {
        let base = lines("one\ntwo\nthree\nfour\n")
        let current = lines("one edited\ntwo\nthree edited\nfour\n")

        #expect(EditorDiffMarks.changedLines(current: current, base: base) == [1, 3])
    }

    /// A file past the budget answers nothing rather than walking it.
    @Test func anEnormousFileIsRefused() {
        let huge = (0..<(EditorDiffMarks.lineBudget + 1)).map(String.init)

        #expect(EditorDiffMarks.changedLines(current: huge, base: ["x"]).isEmpty)
    }
}

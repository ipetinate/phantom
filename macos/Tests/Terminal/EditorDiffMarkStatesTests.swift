import Foundation
import Testing

@testable import Ghostty

/// The three states the margin can put beside a line, and the one it puts
/// between two of them.
///
/// The second state existed and the third did not, so a line whose text had
/// been edited in place was filed as `removed` — a minus sign beside a line
/// the reader could see. Reported from a real file where a reformat joined
/// seven lines into two, and reported again when a freshly typed line inside
/// that same block came back marked the same way.
struct EditorDiffMarkStatesTests {
    private func lines(_ text: String) -> [String] {
        EditorDiffMarks.lines(of: text)
    }

    // MARK: The report

    /// The reformat, reduced from the file it was reported on: a multi-line
    /// element written on one line instead.
    @Test func aReformatIsChangedRatherThanRemoved() {
        let base = lines("""
            <template>
              <WSelect
                v-bind="form.attendanceCategory.value"
                label="Categoria"
              >
            </template>
            """)
        let current = lines("""
            <template>
              <WSelect v-bind="form.attendanceCategory.value" label="Categoria">
            </template>
            """)

        let marks = EditorDiffMarks.marks(current: current, base: base)

        #expect(marks[2] == .changed, "the line is there; a minus would deny it")
        #expect(!marks.values.contains(.added))
    }

    /// The second half of the report: a new line typed inside a block that had
    /// already been reformatted. `CollectionDifference` pairs it with whatever
    /// removal is going spare, and the pairing alone would call it a change to
    /// a line it never touched.
    @Test func aNewLineInsideAChangedBlockIsStillAdded() {
        let base = lines("""
            <template>
              <WSelect
                v-bind="x"
              >
            </template>
            """)
        let current = lines("""
            <template>
              <WDrawer
              <WSelect v-bind="x">
            </template>
            """)

        let marks = EditorDiffMarks.marks(current: current, base: base)

        #expect(marks[2] == .added, "<WDrawer is new; nothing it replaced looked like it")
    }

    // MARK: Removal is a boundary, not a line

    /// A deletion leaves nothing on screen to mark, so the surviving line
    /// below it carries `removed` — and the gutter draws that on its top edge
    /// rather than beside its number.
    @Test func aPureDeletionMarksTheBoundaryBelowIt() {
        let base = lines("one\ntwo\nthree\n")
        let current = lines("one\nthree\n")

        let marks = EditorDiffMarks.marks(current: current, base: base)

        #expect(marks[2] == .removed)
        #expect(marks[1] == nil, "the line above a deletion is untouched")
    }

    @Test func removedHasNoGlyphToDrawBesideALine() {
        #expect(CodeGutterView.DiffMark.removed.glyph == nil)
        #expect(CodeGutterView.DiffMark.added.glyph == "+")
        #expect(CodeGutterView.DiffMark.changed.glyph != nil)
    }

    // MARK: What counts as a rewrite

    @Test func aRenamedVariableIsARewrite() {
        #expect(EditorDiffMarks.isRewrite("const total = sum(a)", "const totals = sum(a)"))
    }

    @Test func reindentingIsARewriteOfTheSameLine() {
        #expect(EditorDiffMarks.isRewrite("      <option value=\"\">", "  <option value=\"\">"))
    }

    /// Two closing tags share almost nothing but their shape. Pairing them
    /// would make every closing tag in a template look like a rewrite of every
    /// other, which is why the shared prefix has to clear the indentation.
    @Test func twoDifferentClosingTagsAreNotRewrites() {
        #expect(!EditorDiffMarks.isRewrite("</div>", "</p>"))
    }

    @Test func aWhollyDifferentStatementIsNotARewrite() {
        #expect(!EditorDiffMarks.isRewrite("<WDrawer", "  v-bind=\"form.value\""))
    }

    /// A line reworded but keeping its vocabulary is the same line.
    @Test func sharedWordsAreEnoughWhenTheShapeMoved() {
        #expect(EditorDiffMarks.isRewrite(
            "label=\"Categoria\" v-bind=\"form.attendanceCategory.value\"",
            "v-bind=\"form.attendanceCategory.value\" label=\"Categoria\""))
    }

    @Test func anEmptyLineIsARewriteOfAnEmptyLine() {
        #expect(EditorDiffMarks.isRewrite("", "   "))
        #expect(!EditorDiffMarks.isRewrite("", "content"))
    }

    // MARK: The invariant that survived the change

    /// `changedLines` answers whose text a line is, and both `added` and
    /// `changed` are the reader's. The git lens reads it, so a third state
    /// must not have quietly narrowed it.
    @Test func bothAddedAndChangedCountAsTheReadersText() {
        let base = lines("one\ntwo\nthree\n")
        let current = lines("one edited\ntwo\ninserted\nthree\n")

        let changed = EditorDiffMarks.changedLines(current: current, base: base)
        let marks = EditorDiffMarks.marks(current: current, base: base)

        for (line, mark) in marks where mark != .removed {
            #expect(changed.contains(line), "line \(line) is marked \(mark) but not claimed")
        }
    }
}

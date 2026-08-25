import Foundation
@testable import Ghostty
import Testing

/// The `+` and `-` beside the line numbers.
struct EditorDiffMarksTests {
    private func marks(
        _ current: [String],
        was base: [String]
    ) -> [Int: CodeGutterView.DiffMark] {
        EditorDiffMarks.marks(current: current, base: base)
    }

    @Test func anUnchangedFileIsUnmarked() {
        #expect(marks(["a", "b"], was: ["a", "b"]).isEmpty)
    }

    @Test func anAddedLineIsMarkedWhereItSits() {
        #expect(marks(["a", "new", "b"], was: ["a", "b"]) == [2: .added])
    }

    @Test func severalAddedLinesAreEachMarked() {
        #expect(marks(["a", "x", "y", "b"], was: ["a", "b"]) == [2: .added, 3: .added])
    }

    /// A deleted line has no line of its own to be marked on, so it is
    /// reported against the line that now sits where it was.
    @Test func aDeletionIsMarkedOnTheLineThatFollowsIt() {
        #expect(marks(["a", "c"], was: ["a", "b", "c"]) == [2: .removed])
    }

    /// The rule that keeps the margin describing lines the reader can see: a
    /// changed line is the new text, so it is `+` and never also `-`.
    @Test func aChangedLineIsAddedRatherThanBoth() {
        #expect(marks(["a", "changed", "c"], was: ["a", "b", "c"]) == [2: .added])
    }

    /// The line after a change must not inherit the removal.
    @Test func theLineAfterAChangeIsLeftAlone() {
        let result = marks(["a", "changed", "c", "d"], was: ["a", "b", "c", "d"])

        #expect(result == [2: .added])
        #expect(result[3] == nil)
    }

    @Test func aDeletionAtTheEndMarksTheLastLineLeft() {
        #expect(marks(["a", "b"], was: ["a", "b", "c"]) == [2: .removed])
    }

    @Test func aDeletionAtTheStartMarksTheFirstLineLeft() {
        #expect(marks(["b", "c"], was: ["a", "b", "c"]) == [1: .removed])
    }

    @Test func aFileMadeFromNothingIsAllAdditions() {
        #expect(marks(["a", "b"], was: []) == [1: .added, 2: .added])
    }

    @Test func aFileEmptiedOutHasNothingToMark() {
        #expect(marks([], was: ["a", "b"]).isEmpty)
    }

    /// Additions win where both would land, whichever side is longer.
    @Test func anAdditionBesideADeletionStaysAnAddition() {
        let result = marks(["a", "x", "y", "d"], was: ["a", "b", "c", "d"])

        #expect(result[2] == .added)
        #expect(result[3] == .added)
        #expect(result[4] == nil)
    }

    // MARK: Bounds

    /// It runs while somebody is typing, so a file past the bound gets no
    /// marks rather than a stuttering editor.
    @Test func aFilePastTheBudgetIsNotCompared() {
        let big = (0...EditorDiffMarks.lineBudget).map(String.init)

        #expect(EditorDiffMarks.marks(current: big, base: ["a"]).isEmpty)
        #expect(EditorDiffMarks.marks(current: ["a"], base: big).isEmpty)
    }

    @Test func aFileAtTheBudgetIsStillCompared() {
        let atLimit = (1...EditorDiffMarks.lineBudget).map(String.init)
        var changed = atLimit
        changed[0] = "changed"

        #expect(EditorDiffMarks.marks(current: changed, base: atLimit) == [1: .added])
    }

    // MARK: Splitting

    /// The editor shows no line after a trailing newline, so neither does
    /// this — otherwise every file that gained one would carry a phantom `+`.
    @Test func aTrailingNewlineIsNotALine() {
        #expect(EditorDiffMarks.lines(of: "a\nb\n") == ["a", "b"])
        #expect(EditorDiffMarks.lines(of: "a\nb") == ["a", "b"])
        #expect(EditorDiffMarks.lines(of: "") == [])
    }

    @Test func aBlankLineInTheMiddleSurvivesSplitting() {
        #expect(EditorDiffMarks.lines(of: "a\n\nb\n") == ["a", "", "b"])
    }
}

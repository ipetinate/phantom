import Foundation
@testable import Ghostty
import Testing

/// The three marks beside the line numbers.
///
/// The fixtures here mostly use one-token lines, which is fine for the two
/// states that are about *position* — added and removed. It is not enough for
/// `changed`: telling a rewritten line from a new one that replaced a deleted
/// one is done by comparing the two texts, and `"b"` against `"changed"`
/// carries no signal either way. Those cases use real code, and the ambiguous
/// one is pinned on purpose in `aWhollyDifferentReplacementReadsAsNew`.
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

    /// A line edited in place gets its own state. It used to get `.removed`,
    /// which put a minus beside a line that was right there on screen.
    @Test func aChangedLineIsMarkedAsAltered() {
        #expect(marks(
            ["let a = 1", "let total = sum(x)", "let c = 3"],
            was: ["let a = 1", "let total = sum(y)", "let c = 3"]) == [2: .changed])
    }

    /// And when the replacement looks nothing like what it replaced, it reads
    /// as **new** rather than as a change.
    ///
    /// Deliberate, and the direction matters. "This line is not in the commit"
    /// is true of a rewrite as well as of an addition, so calling a rewrite
    /// new costs the reader a shade of meaning. The opposite error — calling a
    /// line the reader just typed a change to something they never saw — is
    /// the one that was reported.
    @Test func aWhollyDifferentReplacementReadsAsNew() {
        #expect(marks(
            ["<template>", "<WDrawer", "</template>"],
            was: ["<template>", "  v-bind=\"form.value\"", "</template>"]) == [2: .added])
    }

    /// A line that replaces nothing is new, and stays `+`.
    @Test func aLineThatReplacesNothingIsNew() {
        #expect(marks(["a", "b", "new"], was: ["a", "b"]) == [3: .added])
    }

    /// The line after a change must not inherit its mark.
    @Test func theLineAfterAChangeIsLeftAlone() {
        let result = marks(
            ["let a = 1", "let total = sum(x)", "let c = 3", "let d = 4"],
            was: ["let a = 1", "let total = sum(y)", "let c = 3", "let d = 4"])

        #expect(result == [2: .changed])
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

    /// A replaced run is altered rather than new, line for line, and the
    /// line after it is left alone.
    @Test func aReplacedRunIsAlteredThroughout() {
        let result = marks(
            ["let a = 1", "let x = one(v)", "let y = two(v)", "let d = 4"],
            was: ["let a = 1", "let x = one(w)", "let y = two(w)", "let d = 4"])

        #expect(result[2] == .changed)
        #expect(result[3] == .changed)
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
        let atLimit = (1...EditorDiffMarks.lineBudget).map { "line \($0) here" }
        var changed = atLimit
        changed[0] = "line 1 there"

        #expect(EditorDiffMarks.marks(current: changed, base: atLimit) == [1: .changed])
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

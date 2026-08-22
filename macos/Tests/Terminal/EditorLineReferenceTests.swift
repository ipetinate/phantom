import Foundation
@testable import Ghostty
import Testing

/// The `@path:line` string ⌘K types into the agent's prompt.
struct EditorLineReferenceTests {
    private func lines(_ text: String, _ location: Int, _ length: Int = 0) -> (start: Int, end: Int) {
        EditorLineReference.lines(
            in: text as NSString,
            selection: NSRange(location: location, length: length))
    }

    // MARK: Which lines a selection touches

    @Test func aCaretIsItsOwnLine() {
        #expect(lines("aa\nbb\ncc", 4) == (2, 2))
        #expect(lines("aa\nbb\ncc", 0) == (1, 1))
        #expect(lines("aa\nbb\ncc", 8) == (3, 3))
    }

    @Test func aSelectionSpansTheLinesItTouches() {
        #expect(lines("aa\nbb\ncc", 1, 5) == (1, 2))
        #expect(lines("aa\nbb\ncc", 0, 8) == (1, 3))
    }

    /// The rule shared with `CodeLineMove`: dragging to the start of the next
    /// line selects one line's worth of text, and the reference must say one
    /// line — a range of two would send the agent to read a line nobody chose.
    @Test func aSelectionEndingAtALineStartHasNotTouchedThatLine() {
        #expect(lines("aa\nbb\ncc", 0, 3) == (1, 1))
        #expect(lines("aa\nbb\ncc", 3, 3) == (2, 2))
    }

    @Test func theLastLineWithoutANewlineCounts() {
        #expect(lines("aa\nbb", 3, 2) == (2, 2))
        #expect(lines("aa\nbb", 4) == (2, 2))
    }

    @Test func anEmptyDocumentIsLineOne() {
        #expect(lines("", 0) == (1, 1))
    }

    @Test func windowsLineEndingsCountTheSame() {
        #expect(lines("aa\r\nbb\r\ncc", 4, 0) == (2, 2))
        #expect(lines("aa\r\nbb\r\ncc", 0, 10) == (1, 3))
    }

    // MARK: The reference string

    @Test func aSingleLineReadsAsPathColonLine() {
        let ref = EditorLineReference.reference(
            filePath: "/repo/src/foo.ts", lines: (12, 12), cwd: "/repo")
        #expect(ref == "@src/foo.ts:12")
    }

    @Test func aRangeReadsAsStartDashEnd() {
        let ref = EditorLineReference.reference(
            filePath: "/repo/src/foo.ts", lines: (12, 24), cwd: "/repo")
        #expect(ref == "@src/foo.ts:12-24")
    }

    /// Outside the cwd the path stays absolute. A `../` guess would be
    /// resolved against whatever the agent thinks the workspace is, and a
    /// wrong file referenced confidently is worse than a long path.
    @Test func aFileOutsideTheCwdKeepsItsAbsolutePath() {
        let ref = EditorLineReference.reference(
            filePath: "/elsewhere/foo.ts", lines: (3, 3), cwd: "/repo")
        #expect(ref == "@/elsewhere/foo.ts:3")
    }

    @Test func aNilCwdKeepsTheAbsolutePath() {
        let ref = EditorLineReference.reference(
            filePath: "/repo/foo.ts", lines: (3, 3), cwd: nil)
        #expect(ref == "@/repo/foo.ts:3")
    }

    /// `/repo` must not claim `/repo-two/foo.ts` — the boundary rule the
    /// lookup already enforces, pinned here because this caller depends on it.
    @Test func aSiblingSharingAPrefixIsOutside() {
        let ref = EditorLineReference.reference(
            filePath: "/repo-two/foo.ts", lines: (1, 1), cwd: "/repo")
        #expect(ref == "@/repo-two/foo.ts:1")
    }

    /// The file that IS the cwd (degenerate but reachable through a picker)
    /// falls back to absolute rather than producing "@:12".
    @Test func theCwdItselfStaysAbsolute() {
        let ref = EditorLineReference.reference(
            filePath: "/repo", lines: (1, 1), cwd: "/repo")
        #expect(ref == "@/repo:1")
    }
}

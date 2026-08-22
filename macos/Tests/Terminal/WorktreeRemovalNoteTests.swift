import Foundation
@testable import Ghostty
import Testing

/// What the removal dialog says, and how it counts.
///
/// Every clause in here counts something, which is exactly the kind of prose
/// that reads fine in the one case the author tried and says "1 terminals
/// are" in the case they did not.
struct WorktreeRemovalNoteTests {
    private func note(
        path: String = "/Users/dev/.phantom/worktrees/react-ts-feat-a",
        dirty: Bool = false,
        terminals: Int = 0,
        unsaved: [String] = []
    ) -> String {
        WorktreeRemovalNote.message(
            path: path, isDirty: dirty, terminalCount: terminals, unsavedFiles: unsaved)
    }

    // MARK: The folder

    /// Only the last component. The panel is already listing this worktree,
    /// and the directories above it are the same for every row in it — the
    /// absolute path wrapped over three lines and said nothing the title did
    /// not.
    @Test func theFolderIsNamedWithoutItsDirectories() {
        #expect(note() == "react-ts-feat-a")
    }

    @Test func nothingToWarnAboutIsJustTheFolder() {
        let quiet = note(dirty: false, terminals: 0, unsaved: [])

        #expect(!quiet.contains("•"))
        #expect(!quiet.contains("\n"))
    }

    // MARK: Counting

    @Test func oneTerminalIsSingular() {
        #expect(note(terminals: 1).contains("1 terminal stays open"))
    }

    @Test func severalTerminalsArePlural() {
        #expect(note(terminals: 3).contains("3 terminals stay open"))
    }

    @Test func oneUnsavedFileIsSingular() {
        let text = note(unsaved: ["/w/src/App.tsx"])

        #expect(text.contains("App.tsx has unsaved edits"))
    }

    @Test func severalUnsavedFilesArePlural() {
        let text = note(unsaved: ["/w/a.ts", "/w/b.ts"])

        #expect(text.contains("a.ts, b.ts have unsaved edits"))
    }

    /// A dialog is not a file list. Past three the count carries it.
    @Test func aLongListOfUnsavedFilesIsCutWithACount() {
        let text = note(unsaved: ["/w/a.ts", "/w/b.ts", "/w/c.ts", "/w/d.ts", "/w/e.ts"])

        #expect(text.contains("a.ts, b.ts, c.ts and 2 more have unsaved edits"))
        #expect(!text.contains("d.ts"))
    }

    /// Only the file name — the path is the worktree being removed, which
    /// the first line already gave.
    @Test func unsavedFilesAreNamedWithoutTheirDirectories() {
        let text = note(unsaved: ["/Users/dev/w/src/deep/Thing.swift"])

        #expect(text.contains("Thing.swift"))
        #expect(!text.contains("/src/deep"))
    }

    // MARK: Shape

    /// One consequence per line, and a blank line under the folder. The
    /// version this replaces joined everything with single newlines and
    /// read as a block.
    @Test func eachConsequenceGetsItsOwnBullet() {
        let text = note(dirty: true, terminals: 2, unsaved: ["/w/App.tsx"])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "react-ts-feat-a")
        #expect(lines.dropFirst().first == "")
        #expect(text.components(separatedBy: "•").count - 1 == 3)
    }

    /// Uncommitted first, then who is standing in it, then what is lost.
    /// Cheapest to fix at the top, irreversible at the bottom.
    @Test func theConsequencesAreOrderedByWhatCanStillBeSaved() {
        let text = note(dirty: true, terminals: 1, unsaved: ["/w/App.tsx"])
        let uncommitted = text.range(of: "uncommitted")!
        let terminals = text.range(of: "terminal stays")!
        let unsaved = text.range(of: "unsaved edits")!

        #expect(uncommitted.lowerBound < terminals.lowerBound)
        #expect(terminals.lowerBound < unsaved.lowerBound)
    }
}

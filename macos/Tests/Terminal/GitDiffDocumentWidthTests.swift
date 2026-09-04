import Foundation
@testable import Ghostty
import Testing

/// The longest line on each side of a diff, measured once when the document is
/// built.
///
/// It used to be measured in the pane's `body` — every row, both sides, on
/// every render pass, for a number that cannot change after the diff is
/// parsed. These tests pin the answer so moving the measurement off the render
/// path cannot quietly change what the pane is as wide as.
struct GitDiffDocumentWidthTests {
    private func document(_ output: String) throws -> GitDiffDocument {
        GitDiffDocument(file: try #require(GitDiffParser.parse(unified: output).first))
    }

    @Test func eachSideIsMeasuredOnItsOwnLines() throws {
        let document = try document(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
        -short
        -a much longer line on the left only
        +tiny
        +brief
        """#)

        #expect(document.widestLeft == "a much longer line on the left only".count)
        #expect(document.widestRight == "brief".count)
    }

    /// The same walk the pane used to do, run against the rows the document
    /// holds. Any drift between the two shows up here rather than as a pane
    /// that scrolls a little short of its longest line.
    @Test func theStoredWidthIsWhatWalkingTheRowsWouldSay() throws {
        let document = try document(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,4 +1,4 @@
         context that stays put
        -removed line
        +an added line that is quite a lot longer than the others here
         another context line
        -second removal is longer than the first one by a fair margin
        +short
        """#)

        let left = document.rows.reduce(0) { max($0, $1.left?.displayText.count ?? 0) }
        let right = document.rows.reduce(0) { max($0, $1.right?.displayText.count ?? 0) }

        #expect(document.widestLeft == left)
        #expect(document.widestRight == right)
    }

    /// A CRLF file is the reason the count is on `displayText` and not on
    /// `text`: the carriage return is kept in the model and never drawn, so
    /// counting it would make every pane one character wider than its content.
    @Test func theCarriageReturnOfACRLFFileIsNotCounted() throws {
        let document = try document(
            "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-abcd\r\n+abc\r\n")

        #expect(document.widestLeft == 4)
        #expect(document.widestRight == 3)
    }

    @Test func anEmptyDiffIsZeroWideOnBothSides() throws {
        let document = GitDiffDocument(
            file: GitFileDiff(
                path: "f",
                previousPath: nil,
                status: .modified,
                oldMode: nil,
                newMode: nil,
                isBinary: false,
                isCombined: false,
                hunks: []))

        #expect(document.widestLeft == 0)
        #expect(document.widestRight == 0)
    }
}

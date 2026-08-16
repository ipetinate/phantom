import Foundation
@testable import Ghostty
import Testing

/// `GitDiffAlignment.rows` — one column of unified diff turned into two.
///
/// This is where a side-by-side view goes wrong in a way that looks
/// plausible: the colours are right, the text is right, and the two columns
/// are off by a line for the rest of the file. The tests below pin the
/// counting, because counting is all that keeps them level.
struct GitDiffAlignmentTests {
    private func diff(_ output: String) throws -> GitFileDiff {
        try #require(GitDiffParser.parse(unified: output).first)
    }

    // MARK: Pairing

    /// The case from the brief: three lines out, five in. Five rows, and
    /// the two the left has nothing for are filler — not the next real
    /// lines pulled up to fill the space.
    @Test func threeRemovedAndFiveAddedMakeFiveRowsWithFillerOnTheLeft() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,5 @@
        -one
        -two
        -three
        +ONE
        +TWO
        +THREE
        +FOUR
        +FIVE
        """#))

        #expect(rows.count == 5)
        #expect(rows.map { $0.left?.text } == ["one", "two", "three", nil, nil])
        #expect(rows.map { $0.right?.text } == ["ONE", "TWO", "THREE", "FOUR", "FIVE"])
    }

    @Test func fiveRemovedAndThreeAddedPutTheFillerOnTheRight() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,5 +1,3 @@
        -one
        -two
        -three
        -four
        -five
        +ONE
        +TWO
        +THREE
        """#))

        #expect(rows.count == 5)
        #expect(rows.map { $0.right?.text } == ["ONE", "TWO", "THREE", nil, nil])
    }

    @Test func aPureAdditionLeavesTheWholeLeftSideBlank() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        new file mode 100644
        --- /dev/null
        +++ b/f
        @@ -0,0 +1,3 @@
        +x
        +y
        +z
        """#))

        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.left == nil })
        #expect(rows.map { $0.right?.newNumber } == [1, 2, 3])
    }

    @Test func aPureDeletionLeavesTheWholeRightSideBlank() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        deleted file mode 100644
        --- a/f
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -x
        -y
        """#))

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.right == nil })
        #expect(rows.map { $0.left?.oldNumber } == [1, 2])
    }

    /// Context appears on both sides of the same row, and it is the anchor
    /// the two columns re-synchronize on after every changed block.
    @Test func contextIsTheSameLineOnBothSides() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,4 @@
         head
        -b
        +B
        +extra
         tail
        """#))

        #expect(rows.count == 4)
        #expect(rows[0].left?.text == "head")
        #expect(rows[0].right?.text == "head")
        #expect(rows[1].left?.text == "b")
        #expect(rows[1].right?.text == "B")
        #expect(rows[2].left == nil)
        #expect(rows[2].right?.text == "extra")
        #expect(rows[3].left?.text == "tail")
        #expect(rows[3].right?.text == "tail")
    }

    /// The gutter shows each side's own line number, and after an insertion
    /// the two sides no longer agree. Row index is neither of them.
    @Test func eachSideKeepsItsOwnLineNumbers() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,3 @@
         head
        +inserted
         tail
        """#))

        #expect(rows.map { $0.left?.oldNumber } == [1, nil, 2])
        #expect(rows.map { $0.right?.newNumber } == [1, 2, 3])
    }

    /// Two changed blocks separated by context stay in their own blocks —
    /// the removals of the second must not pair with the additions of the
    /// first.
    @Test func changedBlocksDoNotBleedAcrossTheContextBetweenThem() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
        -a
         mid
        -c
        +A
        +C
        """#))

        // The first block is one removal with nothing to pair with; the
        // second is one removal against two additions.
        #expect(rows.count == 4)
        #expect(rows[0].left?.text == "a")
        #expect(rows[0].right == nil)
        #expect(rows[1].left?.text == "mid")
        #expect(rows[2].left?.text == "c")
        #expect(rows[2].right?.text == "A")
        #expect(rows[3].left == nil)
        #expect(rows[3].right?.text == "C")
    }

    // MARK: Gap bands

    /// Between two hunks the diff skipped over lines, and the band says so.
    @Test func aBandMarksTheLinesBetweenTwoHunks() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
        -a
        +A
         b
        @@ -40,2 +40,2 @@ func later()
        -x
        +X
         y
        """#))

        let bands = rows.compactMap(\.gap)
        #expect(bands.count == 1, "nothing was skipped above a hunk that starts at line 1")
        #expect(bands[0].oldStart == 40)
        #expect(bands[0].heading == "func later()")

        // And it sits between the two hunks, not at either end.
        let bandIndex = try #require(rows.firstIndex { $0.gap != nil })
        #expect(bandIndex == 2)
    }

    /// A file whose first change is halfway down *did* skip everything
    /// above it, so the band belongs there.
    @Test func aFirstHunkBelowTheTopStillGetsItsBand() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -20,2 +20,2 @@
        -a
        +A
         b
        """#))

        #expect(rows.first?.gap?.oldStart == 20)
    }

    /// A new file is entirely its own diff. A band above the first line of
    /// it is a header for a gap that does not exist.
    @Test func aNewFileGetsNoBandAboveItsFirstLine() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        new file mode 100644
        --- /dev/null
        +++ b/f
        @@ -0,0 +1,2 @@
        +x
        +y
        """#))

        #expect(rows.allSatisfy { $0.gap == nil })
    }

    @Test func aBandHasNoLineOnEitherSide() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -20,1 +20,1 @@
        -a
        +A
        """#))

        let band = try #require(rows.first)
        #expect(band.gap != nil)
        #expect(band.left == nil)
        #expect(band.right == nil)
        #expect(band.inline == nil)
    }

    // MARK: Nothing to lay out

    @Test func aFileWithNoHunksHasNoRows() throws {
        let binary = try diff(#"""
        diff --git a/b.dat b/b.dat
        index 6772730..4e0e1df 100644
        Binary files a/b.dat and b/b.dat differ
        """#)
        #expect(GitDiffAlignment.rows(for: binary).isEmpty)

        let mode = try diff(#"""
        diff --git a/m b/m
        old mode 100644
        new mode 100755
        """#)
        #expect(GitDiffAlignment.rows(for: mode).isEmpty)
    }

    // MARK: Identity

    @Test func rowIdsAreUniqueAndInOrder() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -10,2 +10,3 @@
         a
        -b
        +B
        +c
        @@ -50,2 +51,2 @@
        -x
        +X
         y
        """#))

        #expect(rows.map(\.id) == Array(0..<rows.count))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    // MARK: The document the viewer holds

    @Test func theDocumentCarriesBothTheFileAndItsRows() throws {
        let file = try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
        -a
        +A
         b
        """#)

        let document = GitDiffDocument(file: file)
        #expect(document.file.path == "f")
        #expect(document.rows.count == 2)
        #expect(document.rows == GitDiffAlignment.rows(for: file))
    }

    // MARK: Word-level detail, where it is attached

    @Test func aPairedEditCarriesTheCharactersThatChanged() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -let total = compute(alpha)
        +let total = compute(beta)
        """#))

        let edits = try #require(rows[0].inline)
        #expect(edits.removed.count == 1)
        #expect(edits.added.count == 1)
    }

    /// Context is unchanged by definition, and filler has nothing to
    /// compare against.
    @Test func contextAndFillerCarryNoWordLevelDetail() throws {
        let rows = GitDiffAlignment.rows(for: try diff(#"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,3 @@
         same
        -a
        +A
        +extra
        """#))

        #expect(rows[0].inline == nil, "context")
        #expect(rows[2].inline == nil, "filler on the left")
    }
}

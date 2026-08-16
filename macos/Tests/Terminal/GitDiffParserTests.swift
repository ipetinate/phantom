import Foundation
@testable import Ghostty
import Testing

/// `GitDiffParser.parse` against real `git diff` output.
///
/// Every fixture below was produced by running git in a throwaway
/// repository and pasting what it printed, not transcribed from the
/// manual. That matters here more than usual: the two details that break a
/// hand-written unified-diff parser — the tab git appends after a path with
/// a space, and content lines that begin with the same characters as the
/// structure around them — are both things the documentation does not
/// mention and a real diff shows immediately.
struct GitDiffParserTests {
    // MARK: The ordinary case

    @Test func readsHunksLinesAndBothSetsOfLineNumbers() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/renamed.txt b/renamed.txt
        index d68dd40..c2f2e5e 100644
        --- a/renamed.txt
        +++ b/renamed.txt
        @@ -1,4 +1,4 @@
         a
        -b
        +B
         c
         d
        """#)

        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.path == "renamed.txt")
        #expect(file.status == .modified)
        #expect(file.hunks.count == 1)
        #expect(file.addedCount == 1)
        #expect(file.removedCount == 1)

        let lines = file.hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .removed, .added, .context, .context])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])

        // The removed line is line 2 of the old file and of no line of the
        // new one; the added line is the reverse.
        #expect(lines[1].oldNumber == 2)
        #expect(lines[1].newNumber == nil)
        #expect(lines[2].oldNumber == nil)
        #expect(lines[2].newNumber == 2)

        // Context after a one-for-one swap is line 3 on both sides.
        #expect(lines[3].oldNumber == 3)
        #expect(lines[3].newNumber == 3)
    }

    @Test func lineNumbersContinueAcrossHunks() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,3 @@
         one
        +inserted
         two
        @@ -40,2 +41,2 @@
        -forty
        +FORTY
         fortyone
        """#)

        let file = try #require(files.first)
        #expect(file.hunks.count == 2)

        // The insertion in the first hunk pushes the new side one ahead,
        // and the second hunk's header is what re-synchronizes them.
        let second = file.hunks[1].lines
        #expect(second[0].oldNumber == 40)
        #expect(second[1].newNumber == 41)
        #expect(second[2].oldNumber == 41)
        #expect(second[2].newNumber == 42)
    }

    // MARK: Hunk headers

    /// `@@ -1 +1 @@` is what git prints for a one-line file. Reading the
    /// missing count as zero drops the only line there is.
    @Test func anOmittedCountMeansOne() throws {
        let header = try #require(GitDiffParser.parseHunkHeader("@@ -1 +1 @@"))
        #expect(header.oldStart == 1)
        #expect(header.oldCount == 1)
        #expect(header.newStart == 1)
        #expect(header.newCount == 1)
        #expect(header.heading.isEmpty)
    }

    @Test func aOneLineFileKeepsItsOneLine() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/one.txt b/one.txt
        index 6c542ab..bc8c7b4 100644
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -only
        +ONLY
        """#)

        let file = try #require(files.first)
        #expect(file.hunks[0].lines.map(\.text) == ["only", "ONLY"])
    }

    @Test func keepsTheEnclosingFunctionGitPutsAfterTheHeader() throws {
        let header = try #require(
            GitDiffParser.parseHunkHeader("@@ -12,7 +12,9 @@ func alignRows(for diff: GitFileDiff) {")
        )
        #expect(header.oldStart == 12)
        #expect(header.newCount == 9)
        #expect(header.heading == "func alignRows(for diff: GitFileDiff) {")
    }

    /// The heading is free text and may contain the delimiter. Everything
    /// after the *second* `@@` is heading, not everything after the last.
    @Test func aHeadingContainingTheDelimiterSurvives() throws {
        let header = try #require(GitDiffParser.parseHunkHeader("@@ -1,2 +1,2 @@ label @@ more"))
        #expect(header.oldCount == 2)
        #expect(header.heading == "label @@ more")
    }

    @Test func rebuildsTheHeaderTextWithGitsOwnOmittedCountRule() {
        let header = GitDiffHunk.Header(oldStart: 1, oldCount: 1, newStart: 4, newCount: 7, heading: "go()")
        #expect(header.range == "@@ -1 +4,7 @@")
        #expect(header.text == "@@ -1 +4,7 @@ go()")
    }

    @Test func rejectsAHeaderItCannotRead() {
        #expect(GitDiffParser.parseHunkHeader("@@ nonsense @@") == nil)
        #expect(GitDiffParser.parseHunkHeader("not a header") == nil)
        #expect(GitDiffParser.parseHunkHeader("@@@ -1,2 -1,2 +1,6 @@@") == nil)
    }

    // MARK: No newline at end of file

    /// The marker describes the line above it. Parsed as a line of its own
    /// it puts a row reading `\ No newline at end of file` in the middle of
    /// the diff, which is what every naive parser does.
    @Test func noNewlineMarkerBelongsToThePreviousLine() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/nonl.txt b/nonl.txt
        index 9ed40b4..814f4a4 100644
        --- a/nonl.txt
        +++ b/nonl.txt
        @@ -1,2 +1,2 @@
         one
        -two
        \ No newline at end of file
        +two
        """#)

        let lines = try #require(files.first).hunks[0].lines
        #expect(lines.count == 3)
        #expect(lines.map(\.text) == ["one", "two", "two"])

        // Only the old file lacked the newline, so only the removed line
        // carries the flag.
        #expect(lines[1].kind == .removed)
        #expect(lines[1].isEndOfFileWithoutNewline)
        #expect(!lines[2].isEndOfFileWithoutNewline)
    }

    /// When neither side ends in a newline git prints the marker twice,
    /// once per side.
    @Test func bothSidesCanLackTheirTrailingNewline() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/n.txt b/n.txt
        --- a/n.txt
        +++ b/n.txt
        @@ -1 +1 @@
        -one
        \ No newline at end of file
        +two
        \ No newline at end of file
        """#)

        let lines = try #require(files.first).hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.isEndOfFileWithoutNewline })
    }

    /// The marker for the last line arrives after the header's counts are
    /// already satisfied, so a parser that stops counting stops one line
    /// too early to see it.
    @Test func aMarkerAfterTheLastCountedLineIsStillRead() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/n.txt b/n.txt
        --- a/n.txt
        +++ b/n.txt
        @@ -1 +1,2 @@
         one
        +two
        \ No newline at end of file
        """#)

        let lines = try #require(files.first).hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines[1].isEndOfFileWithoutNewline)
    }

    // MARK: Content that looks like structure

    /// A diff of a patch file. Every marker character this parser looks for
    /// appears as *content* here, one column to the right. Driving the read
    /// off the header's counts is what keeps them content.
    @Test func aDiffOfADiffIsContentNotStructure() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/patch.diff b/patch.diff
        index 0fd51ba..f47cbf2 100644
        --- a/patch.diff
        +++ b/patch.diff
        @@ -1,6 +1,7 @@
         diff --git a/x b/x
         --- a/x
         +++ b/x
        -@@ -1,2 +1,2 @@
        +@@ -1,2 +1,3 @@
         -old
         +new
        ++extra
        """#)

        #expect(files.count == 1, "the inner `diff --git` is a line of the file, not a second file")

        let file = try #require(files.first)
        #expect(file.path == "patch.diff")
        #expect(file.hunks.count == 1, "the inner `@@` is content, not a second hunk")

        let lines = file.hunks[0].lines
        #expect(lines.count == 8)
        #expect(
            lines.map(\.kind) == [
                .context, .context, .context, .removed, .added, .context, .context, .added,
            ]
        )

        // The first character is the marker; everything after it is text.
        #expect(lines[0].text == "diff --git a/x b/x")
        #expect(lines[3].text == "@@ -1,2 +1,2 @@")
        #expect(lines[5].text == "-old")
        #expect(lines[7].text == "+extra")
    }

    /// Git writes a lone space for an empty context line, but a patch that
    /// has been through a tool that trims trailing whitespace arrives with
    /// nothing there at all. It is still that line.
    @Test func anEmptyLineInsideAHunkIsAnEmptyContextLine() throws {
        let files = GitDiffParser.parse(unified: "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n\n-c\n+C\n")

        let lines = try #require(files.first).hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .context, .removed, .added])
        #expect(lines[1].text.isEmpty)
        #expect(lines[1].oldNumber == 2)
        #expect(lines[1].newNumber == 2)
    }

    // MARK: Files with no lines to show

    @Test func aNewFileIsAllAdditions() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/untracked.txt b/untracked.txt
        new file mode 100644
        index 0000000..b77b4eb
        --- /dev/null
        +++ b/untracked.txt
        @@ -0,0 +1,2 @@
        +x
        +y
        """#)

        let file = try #require(files.first)
        #expect(file.status == .added)
        #expect(file.path == "untracked.txt")
        #expect(file.newMode == "100644")
        #expect(file.hunks[0].lines.allSatisfy { $0.kind == .added })
        #expect(file.hunks[0].lines.map(\.newNumber) == [1, 2])
        #expect(file.hunks[0].lines.allSatisfy { $0.oldNumber == nil })
    }

    @Test func aDeletedFileIsAllRemovals() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index b77b4eb..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -x
        -y
        """#)

        let file = try #require(files.first)
        #expect(file.status == .deleted)
        #expect(file.path == "gone.txt", "a deleted file is named by the path it had")
        #expect(file.oldMode == "100644")
        #expect(file.hunks[0].lines.allSatisfy { $0.kind == .removed })
    }

    /// A new empty file has a header and no hunks. That is not the same
    /// thing as no diff, and the viewer has to be able to tell them apart.
    @Test func aNewEmptyFileHasNoHunksAndIsStillAnAddition() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/empty.txt b/empty.txt
        new file mode 100644
        index 0000000..e69de29
        """#)

        let file = try #require(files.first)
        #expect(file.status == .added)
        #expect(file.hunks.isEmpty)
        #expect(file.isEmpty, "nothing else explains the missing hunks")
        #expect(!file.isModeChangeOnly)
    }

    @Test func aBinaryFileSaysSoRatherThanShowingNothing() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/bin.dat b/bin.dat
        index 6772730..4e0e1df 100644
        Binary files a/bin.dat and b/bin.dat differ
        """#)

        let file = try #require(files.first)
        #expect(file.isBinary)
        #expect(file.path == "bin.dat", "the path comes off the header when there are no --- / +++ lines")
        #expect(file.hunks.isEmpty)
        #expect(!file.isEmpty)
    }

    @Test func aModeChangeWithNoContentChangeIsRecognized() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/mode.txt b/mode.txt
        old mode 100644
        new mode 100755
        """#)

        let file = try #require(files.first)
        #expect(file.oldMode == "100644")
        #expect(file.newMode == "100755")
        #expect(file.hunks.isEmpty)
        #expect(file.isModeChangeOnly)
        #expect(!file.isEmpty)
        #expect(file.path == "mode.txt")
    }

    @Test func aRenameThatChangedNothingCarriesBothPaths() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/tracked.txt b/renamed.txt
        similarity index 100%
        rename from tracked.txt
        rename to renamed.txt
        """#)

        let file = try #require(files.first)
        #expect(file.status == .renamed)
        #expect(file.path == "renamed.txt")
        #expect(file.previousPath == "tracked.txt")
        #expect(file.isPureRename)
        #expect(!file.isEmpty)
    }

    @Test func aRenameWithEditsKeepsBothPathsAndTheHunks() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/old.txt b/new.txt
        similarity index 87%
        rename from old.txt
        rename to new.txt
        index de98044..d68dd40 100644
        --- a/old.txt
        +++ b/new.txt
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        """#)

        let file = try #require(files.first)
        #expect(file.status == .renamed)
        #expect(file.path == "new.txt")
        #expect(file.previousPath == "old.txt")
        #expect(!file.isPureRename)
        #expect(file.hunks.count == 1)
    }

    @Test func aCopyIsDistinguishedFromARename() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/source.txt b/copy.txt
        similarity index 100%
        copy from source.txt
        copy to copy.txt
        """#)

        let file = try #require(files.first)
        #expect(file.status == .copied)
        #expect(file.path == "copy.txt")
        #expect(file.previousPath == "source.txt")
    }

    // MARK: Paths

    /// Git appends a tab after the path on the `---` and `+++` lines when
    /// the path contains a space — the convention that makes the line
    /// parseable at all. Kept, it becomes part of the path and stops
    /// matching the path anyone asked about.
    @Test func aPathWithASpaceLosesTheTabGitAppendsToIt() throws {
        let files = GitDiffParser.parse(unified: "diff --git a/my file.txt b/my file.txt\nindex 1f25f40..0d5b62c 100644\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-l1\n+l2\n")

        let file = try #require(files.first)
        #expect(file.path == "my file.txt")
        #expect(file.previousPath == nil)
    }

    /// Falling back to the `diff --git` line — the only place a binary
    /// diff names the file — with a space in the path. The two halves are
    /// the same path, which is what makes the split findable at all.
    @Test func aBinaryPathWithASpaceComesOffTheHeaderLine() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/my pic.png b/my pic.png
        index 6772730..4e0e1df 100644
        Binary files a/my pic.png and b/my pic.png differ
        """#)

        #expect(try #require(files.first).path == "my pic.png")
    }

    /// A path git had to quote — an embedded `"` here — arrives C-escaped
    /// on every line that mentions it.
    @Test func aQuotedPathIsUnescaped() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git "a/we\"ird.txt" "b/we\"ird.txt"
        index bca70f3..d169a2f 100644
        --- "a/we\"ird.txt"
        +++ "b/we\"ird.txt"
        @@ -1 +1 @@
        -q
        +q2
        """#)

        #expect(try #require(files.first).path == #"we"ird.txt"#)
    }

    /// Octal escapes are per byte, not per character: one accented letter
    /// is two of them, and decoding them one at a time yields two
    /// replacement characters instead of the letter.
    @Test func octalEscapesAreDecodedAsUTF8Bytes() {
        #expect(GitDiffParser.unquote(#""caf\303\251.txt""#) == "café.txt")
        #expect(GitDiffParser.unquote(#""tab\there""#) == "tab\there")
        #expect(GitDiffParser.unquote("plain.txt") == "plain.txt")
    }

    @Test func anAccentedPathArrivesUnquotedWhenQuotePathIsOff() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/café.txt b/café.txt
        index 587be6b..975fbec 100644
        --- a/café.txt
        +++ b/café.txt
        @@ -1 +1 @@
        -x
        +y
        """#)

        #expect(try #require(files.first).path == "café.txt")
    }

    // MARK: Line endings

    /// A file converted from LF to CRLF differs on every line and only in
    /// that character. Stripping it here would make both sides of every row
    /// read the same and the diff look like a bug.
    @Test func carriageReturnsSurviveInTextAndAreHiddenInDisplayText() throws {
        let files = GitDiffParser.parse(unified: "diff --git a/crlf.txt b/crlf.txt\n--- a/crlf.txt\n+++ b/crlf.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n")

        let lines = try #require(files.first).hunks[0].lines
        #expect(lines.map(\.text) == ["a\r", "b\r", "B\r"])
        #expect(lines.map(\.displayText) == ["a", "b", "B"])
        #expect(lines.allSatisfy { $0.hasCarriageReturn })
    }

    @Test func aHunkHeaderWithACarriageReturnStillParses() throws {
        let header = try #require(GitDiffParser.parseHunkHeader("@@ -1,2 +1,2 @@\r"))
        #expect(header.oldCount == 2)
    }

    // MARK: Conflicts

    /// A conflicted path gets a combined diff: one marker column per merge
    /// parent, not one. It is recognized so the viewer can say what it is,
    /// and the body is left alone rather than mislabelled line by line.
    @Test func aCombinedDiffIsRecognizedRatherThanMisread() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --cc conf.txt
        index 9012216,69d280f..0000000
        --- a/conf.txt
        +++ b/conf.txt
        @@@ -1,2 -1,2 +1,6 @@@
          base
        ++<<<<<<< HEAD
         +OURS
        ++=======
        + THEIRS
        ++>>>>>>> other
        """#)

        let file = try #require(files.first)
        #expect(file.isCombined)
        #expect(file.path == "conf.txt")
        #expect(file.hunks.isEmpty, "a two-column reading of a three-column body is worse than none")
    }

    // MARK: Several files, and nothing at all

    @Test func readsEveryFileInOneRun() {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/one.txt b/one.txt
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -a
        +A
        diff --git a/two.txt b/two.txt
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -b
        +B
        """#)

        #expect(files.map(\.path) == ["one.txt", "two.txt"])
        #expect(files.allSatisfy { $0.hunks.count == 1 })
    }

    @Test func emptyOutputIsNoFiles() {
        #expect(GitDiffParser.parse(unified: "").isEmpty)
        #expect(GitDiffParser.parse(unified: "\n\n").isEmpty)
    }

    @Test func outputItCannotUnderstandYieldsNothingRatherThanCrashing() {
        #expect(GitDiffParser.parse(unified: "fatal: ambiguous argument 'HEAD'").isEmpty)
        #expect(GitDiffParser.parse(unified: "@@ -1,2 +1,2 @@\n-orphan hunk\n+no header").isEmpty)
        #expect(GitDiffParser.parse(unified: "diff --git").isEmpty)
        #expect(GitDiffParser.parse(unified: "diff --git a/x b/x").count == 1)
    }

    /// The counts overshoot the body. It stops at the end of the input
    /// rather than reading past it.
    @Test func aTruncatedHunkStopsAtWhatIsThere() throws {
        let files = GitDiffParser.parse(unified: #"""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,90 +1,90 @@
         a
         b
        """#)

        #expect(try #require(files.first).hunks[0].lines.count == 2)
    }
}

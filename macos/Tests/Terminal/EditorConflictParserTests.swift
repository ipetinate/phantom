import Foundation
@testable import Ghostty
import Testing

/// Finding git's conflict markers, and keeping them out of ordinary prose.
struct EditorConflictParserTests {
    private func text(_ lines: String...) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: The plain three-marker form

    @Test func aConflictIsFoundWithBothSides() throws {
        let source = text(
            "before",
            "<<<<<<< HEAD",
            "mine",
            "=======",
            "theirs",
            ">>>>>>> feature",
            "after"
        )

        let found = EditorConflictParser.conflicts(in: source)

        let conflict = try #require(found.first)
        #expect(found.count == 1)
        #expect(conflict.current == ["mine"])
        #expect(conflict.incoming == ["theirs"])
        #expect(conflict.base == nil)
        #expect(conflict.currentLabel == "HEAD")
        #expect(conflict.incomingLabel == "feature")
        #expect(conflict.startLine == 1)
        #expect(conflict.endLine == 5)
    }

    @Test func bothSidesMayHoldSeveralLines() throws {
        let source = text(
            "<<<<<<< HEAD", "a", "b", "=======", "c", "d", "e", ">>>>>>> other"
        )

        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.current == ["a", "b"])
        #expect(conflict.incoming == ["c", "d", "e"])
    }

    /// A side is allowed to be empty: one branch deleted what the other edited.
    @Test func anEmptySideIsAConflictTheSameWay() throws {
        let source = text("<<<<<<< HEAD", "=======", "theirs", ">>>>>>> other")

        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.current.isEmpty)
        #expect(conflict.incoming == ["theirs"])
    }

    @Test func severalConflictsAreNumberedInFileOrder() {
        let source = text(
            "<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> x",
            "middle",
            "<<<<<<< HEAD", "c", "=======", "d", ">>>>>>> x"
        )

        let found = EditorConflictParser.conflicts(in: source)

        #expect(found.count == 2)
        #expect(found.map(\.id) == [0, 1])
        #expect(found[0].startLine < found[1].startLine)
    }

    // MARK: diff3

    @Test func theAncestorIsReadWhenGitWroteOne() throws {
        let source = text(
            "<<<<<<< HEAD",
            "mine",
            "||||||| merged common ancestors",
            "original",
            "=======",
            "theirs",
            ">>>>>>> feature"
        )

        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.current == ["mine"])
        #expect(conflict.base == ["original"])
        #expect(conflict.incoming == ["theirs"])
        #expect(conflict.hasBase)
    }

    /// The ancestor is a fourth choice, and only when it holds something.
    @Test func theChoicesFollowWhatTheBlockHas() {
        let plain = text("<<<<<<< HEAD", "a", "=======", "b", ">>>>>>> x")
        let withBase = text(
            "<<<<<<< HEAD", "a", "||||||| base", "o", "=======", "b", ">>>>>>> x")
        let emptyBase = text(
            "<<<<<<< HEAD", "a", "||||||| base", "=======", "b", ">>>>>>> x")

        #expect(EditorConflictParser.conflicts(in: plain).first?.choices
            == [.current, .incoming, .both])
        #expect(EditorConflictParser.conflicts(in: withBase).first?.choices
            == [.current, .incoming, .both, .base])
        #expect(EditorConflictParser.conflicts(in: emptyBase).first?.choices
            == [.current, .incoming, .both])
    }

    // MARK: What must not be mistaken for a conflict

    /// The reason this is a state machine. A Markdown heading underline is
    /// seven equals signs at the start of a line, and so is half the prose
    /// ever written about conflicts.
    @Test func aMarkdownHeadingIsNotAConflict() {
        let source = text("Title", "=======", "", "Body text.")

        #expect(EditorConflictParser.conflicts(in: source).isEmpty)
    }

    @Test func anUnterminatedStartIsNotAConflict() {
        let source = text("<<<<<<< HEAD", "mine", "=======", "theirs")

        #expect(EditorConflictParser.conflicts(in: source).isEmpty)
    }

    @Test func anEndWithNoStartIsNotAConflict() {
        let source = text("theirs", ">>>>>>> feature")

        #expect(EditorConflictParser.conflicts(in: source).isEmpty)
    }

    /// Eight is a line *about* markers, which is what a diff of a conflicted
    /// file looks like once git prefixes every line with its own character.
    @Test func eightCharactersIsNotAMarker() {
        let source = text("<<<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>>> x")

        #expect(EditorConflictParser.conflicts(in: source).isEmpty)
    }

    /// A marker has to start the line. Indented, it is code or prose.
    @Test func anIndentedMarkerIsNotAMarker() {
        let source = text("    <<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>> x")

        #expect(EditorConflictParser.conflicts(in: source).isEmpty)
    }

    @Test func theCheapGateAgreesWithTheParser() {
        #expect(EditorConflictParser.mayHoldConflict("Title\n=======\n") == false)
        #expect(EditorConflictParser.mayHoldConflict("<<<<<<< HEAD\n"))
    }

    // MARK: The range a resolution replaces

    /// It has to swallow the newline after the closing marker, or a conflict
    /// resolved to nothing leaves a blank line where it was.
    @Test func theRangeCoversTheWholeBlockAndItsNewline() throws {
        let source = text("before", "<<<<<<< HEAD", "=======", "t", ">>>>>>> x", "after")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .current))

        #expect(resolved == "before\nafter")
    }

    @Test func keepingASideLeavesItsLinesBehind() throws {
        let source = text("before", "<<<<<<< HEAD", "mine", "=======", "t", ">>>>>>> x", "after")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .current))

        #expect(resolved == "before\nmine\nafter")
    }

    @Test func keepingBothPutsCurrentFirst() throws {
        let source = text("<<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>> x", "after")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .both))

        #expect(resolved == "mine\ntheirs\nafter")
    }

    /// A conflict that ends the file has no newline to take, and adding one
    /// would change a file the reader never asked to change.
    @Test func aBlockAtTheEndOfFileGainsNoNewline() throws {
        let source = text("before", "<<<<<<< HEAD", "mine", "=======", "t", ">>>>>>> x")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.endsWithoutNewline)
        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .current))
        #expect(resolved == "before\nmine")
    }

    /// The range is measured in UTF-16 because that is what NSTextView counts
    /// in. Measured in characters, an emoji above the conflict would land the
    /// replacement in the wrong place.
    @Test func aRangeIsCorrectBelowAnEmoji() throws {
        let source = text("🙂 hello", "<<<<<<< HEAD", "mine", "=======", "t", ">>>>>>> x", "end")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .current))

        #expect(resolved == "🙂 hello\nmine\nend")
    }

    /// A Windows checkout keeps its line endings. Normalising here would
    /// rewrite every line of the file on the first resolution.
    @Test func carriageReturnsSurviveAResolution() throws {
        let source = "a\r\n<<<<<<< HEAD\r\nmine\r\n=======\r\nt\r\n>>>>>>> x\r\nb\r\n"
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        let resolved = (source as NSString).replacingCharacters(
            in: conflict.range, with: conflict.replacement(for: .current))

        #expect(conflict.current == ["mine\r"])
        #expect(resolved == "a\r\nmine\r\nb\r\n")
    }

    /// The separator in a CRLF file is `=======\r`, which is neither empty nor
    /// followed by a space. Missing that meant no conflict in a Windows
    /// checkout was ever found — the marker test ignores the return, and the
    /// sections keep theirs.
    @Test func aConflictIsFoundInACarriageReturnFile() throws {
        let source = "<<<<<<< HEAD\r\nmine\r\n=======\r\ntheirs\r\n>>>>>>> x\r\n"

        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.currentLabel == "HEAD")
        #expect(conflict.incomingLabel == "x")
        #expect(conflict.incoming == ["theirs\r"])
    }

    // MARK: Resolving every conflict at once

    @Test func aChoiceKeepsTheLinesItNames() throws {
        let source = text(
            "<<<<<<< HEAD", "a", "||||||| base", "o", "=======", "b", ">>>>>>> x")
        let conflict = try #require(EditorConflictParser.conflicts(in: source).first)

        #expect(conflict.lines(for: .current) == ["a"])
        #expect(conflict.lines(for: .incoming) == ["b"])
        #expect(conflict.lines(for: .both) == ["a", "b"])
        #expect(conflict.lines(for: .base) == ["o"])
    }

    // MARK: Where each part sits, for whatever paints behind it

    @Test func theSectionsOfAPlainBlockAreWhereTheyLook() throws {
        let source = text("a", "<<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>> x")
        let sections = try #require(EditorConflictParser.conflicts(in: source).first).sections

        #expect(Array(sections.currentLines) == [2])
        #expect(Array(sections.incomingLines) == [4])
        #expect(sections.baseLines == nil)
        #expect(sections.markerLines == [1, 3, 5])
    }

    /// The ancestor shifts everything below it, which is the arithmetic worth
    /// pinning: get it wrong and the wrong half of the conflict is painted.
    @Test func anAncestorShiftsTheSectionsBelowIt() throws {
        let source = text(
            "<<<<<<< HEAD", "mine", "||||||| base", "old", "=======", "theirs", ">>>>>>> x")
        let sections = try #require(EditorConflictParser.conflicts(in: source).first).sections

        #expect(Array(sections.currentLines) == [1])
        #expect(Array(sections.baseLines ?? 0..<0) == [3])
        #expect(Array(sections.incomingLines) == [5])
        #expect(sections.markerLines == [0, 2, 4, 6])
    }

    @Test func anEmptySideHasAnEmptyRange() throws {
        let source = text("<<<<<<< HEAD", "=======", "theirs", ">>>>>>> x")
        let sections = try #require(EditorConflictParser.conflicts(in: source).first).sections

        #expect(sections.currentLines.isEmpty)
        #expect(Array(sections.incomingLines) == [2])
        #expect(sections.markerLines == [0, 1, 3])
    }
}

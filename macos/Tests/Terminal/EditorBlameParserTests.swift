import Foundation
@testable import Ghostty
import Testing

/// Reading `git blame --porcelain`.
///
/// The part of this feature that can be wrong without anybody noticing: a
/// mis-parsed author is somebody else's name beside your line.
struct EditorBlameParserTests {
    private let sample = """
        a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0 12 12 1
        author Isac Petinate
        author-mail <isac@example.com>
        author-time 1750000000
        author-tz +0000
        committer Isac Petinate
        summary Give the gutter its marks back
        filename src/main.swift
        \tlet x = 1
        """

    @Test func everyFieldIsRead() throws {
        let blame = try #require(EditorBlameParser.parse(porcelain: sample))

        #expect(blame.author == "Isac Petinate")
        #expect(blame.summary == "Give the gutter its marks back")
        #expect(blame.commit == "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0")
        #expect(blame.time == Date(timeIntervalSince1970: 1_750_000_000))
    }

    /// The tab-prefixed source line ends the entry. Without stopping there, a
    /// second entry would overwrite the first with a different commit.
    @Test func aSecondEntryDoesNotOverwriteTheFirst() throws {
        let two = sample + """

            b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1 13 13 1
            author Somebody Else
            author-time 1760000000
            summary A later change
            \tlet y = 2
            """

        let blame = try #require(EditorBlameParser.parse(porcelain: two))

        #expect(blame.author == "Isac Petinate")
    }

    /// Git reports an uncommitted line as an all-zero commit. Saying "Not
    /// Committed Yet" beside a line the reader just typed is the least useful
    /// moment to say anything.
    @Test func anUncommittedLineIsRecognised() throws {
        let pending = """
            0000000000000000000000000000000000000000 4 4 1
            author Not Committed Yet
            author-time 1750000000
            summary Version of src/main.swift from src/main.swift
            \tlet z = 3
            """

        let blame = try #require(EditorBlameParser.parse(porcelain: pending))

        #expect(blame.isUncommitted)
    }

    @Test func nonsenseIsRefusedRatherThanGuessedAt() {
        #expect(EditorBlameParser.parse(porcelain: "") == nil)
        #expect(EditorBlameParser.parse(porcelain: "not a blame at all") == nil)
    }

    /// A commit with no subject is a real commit, and the line still has an
    /// author worth showing.
    @Test func aMissingSummaryStillAnswers() throws {
        let terse = """
            a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0 1 1 1
            author Someone
            author-time 1750000000
            \tcode
            """

        let blame = try #require(EditorBlameParser.parse(porcelain: terse))

        #expect(blame.author == "Someone")
        #expect(blame.summary.isEmpty)
    }

    @Test func theGhostTextNamesWhoAndWhat() {
        let blame = EditorBlameLine(
            author: "Isac",
            summary: "Fix the thing",
            commit: "abc1234",
            time: Date(timeIntervalSinceNow: -3600)
        )

        #expect(blame.ghostText.contains("Isac"))
        #expect(blame.ghostText.contains("Fix the thing"))
        #expect(blame.ghostText.contains("ago"))
    }
}

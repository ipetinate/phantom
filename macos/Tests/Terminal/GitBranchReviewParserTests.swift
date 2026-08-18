import Foundation
@testable import Ghostty
import Testing

/// ``GitBranchReviewParser`` against fixtures of git's own output.
///
/// Every fixture below was captured from a real `git` (2.50) running the
/// exact arguments ``GitBranchReviewLoader`` sends, then pasted here with
/// the NUL and unit-separator bytes written as escapes. Nothing here needs
/// a repository: these are claims about the *shape* of the output, and the
/// claims about git's behaviour live in `GitBranchReviewLoaderTests`.
@Suite struct GitBranchReviewParserTests {
    private let nul = "\u{0}"
    private let unit = "\u{1f}"

    // Commits

    /// The reason the format uses `%x1f` and `-z` instead of anything
    /// printable: a subject is arbitrary text, and every obvious separator
    /// is a character somebody has already put in a commit message.
    @Test func aSubjectKeepsItsTabsQuotesAndPipes() {
        let output = "abc123\(unit)work: with\ttab and \"quotes\" and | pipe\(unit)Ada\(unit)3 days ago\(nul)"

        let commits = GitBranchReviewParser.parseCommits(output)

        #expect(commits.count == 1)
        #expect(commits[0].sha == "abc123")
        #expect(commits[0].subject == "work: with\ttab and \"quotes\" and | pipe")
        #expect(commits[0].author == "Ada")
        #expect(commits[0].relativeDate == "3 days ago")
    }

    /// Records are NUL-*terminated*, not NUL-separated, so the last one is
    /// followed by a separator and the naive split finds an empty record
    /// after it.
    @Test func theTrailingSeparatorIsNotAnExtraCommit() {
        let output = [
            "aaa\(unit)second\(unit)Ada\(unit)1 minute ago",
            "bbb\(unit)first\(unit)Ada\(unit)2 minutes ago",
        ].joined(separator: nul) + nul

        let commits = GitBranchReviewParser.parseCommits(output)

        #expect(commits.map(\.sha) == ["aaa", "bbb"])
    }

    @Test func nothingInMakesNoCommits() {
        #expect(GitBranchReviewParser.parseCommits("").isEmpty)
    }

    /// `git commit --allow-empty-message` is a thing people do, and the
    /// commit still belongs in the list.
    @Test func anEmptySubjectIsStillACommit() {
        let commits = GitBranchReviewParser.parseCommits("aaa\(unit)\(unit)Ada\(unit)just now\(nul)")

        #expect(commits.count == 1)
        #expect(commits[0].subject.isEmpty)
        #expect(commits[0].author == "Ada")
    }

    // Line counts

    @Test func numstatReadsTheOrdinaryEntry() {
        let counts = GitBranchReviewParser.parseNumstat("12\t3\tmacos/Sources/App.swift\(nul)")

        #expect(counts["macos/Sources/App.swift"] == GitBranchReviewParser.LineCount(added: 12, removed: 3))
    }

    /// A binary file is `-` and `-`, not `0` and `0`. Reading it as zero
    /// would put "changed nothing" in a total that is about to be shown to
    /// somebody.
    @Test func aBinaryFileHasNoCounts() {
        let counts = GitBranchReviewParser.parseNumstat("-\t-\tlogo.png\(nul)")

        #expect(counts["logo.png"]?.added == nil)
        #expect(counts["logo.png"]?.isBinary == true)
    }

    /// The shape that makes this a token parse rather than a line parse:
    /// the path field is empty and two more NUL-terminated fields follow.
    @Test func aRenameCarriesItsCountsUnderTheNewPath() {
        let counts = GitBranchReviewParser.parseNumstat("0\t0\t\(nul)old.ts\(nul)new.ts\(nul)")

        #expect(counts["new.ts"] == GitBranchReviewParser.LineCount(added: 0, removed: 0))
        #expect(counts["old.ts"] == nil)
    }

    /// Only the first two tabs are structure; a path is allowed to contain
    /// one, and `-z` hands it over raw.
    @Test func aPathMayContainATab() {
        let counts = GitBranchReviewParser.parseNumstat("1\t0\tweird\tname.txt\(nul)")

        #expect(counts["weird\tname.txt"] == GitBranchReviewParser.LineCount(added: 1, removed: 0))
    }

    // Statuses

    @Test func nameStatusReadsTheLetters() {
        let output = "M\(nul)a.txt\(nul)A\(nul)b.txt\(nul)D\(nul)c.txt\(nul)"

        let entries = GitBranchReviewParser.parseNameStatus(output)

        #expect(entries.map(\.status) == [.modified, .added, .deleted])
        #expect(entries.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(entries.allSatisfy { $0.previousPath == nil })
    }

    /// A type change — a file swapped for a symlink — has no word of its
    /// own in the viewer's vocabulary, and dropping the file would make a
    /// list that claims to be complete incomplete.
    @Test func aTypeChangeIsReportedAsAModification() {
        let entries = GitBranchReviewParser.parseNameStatus("T\(nul)link\(nul)")

        #expect(entries.map(\.status) == [.modified])
        #expect(entries.map(\.path) == ["link"])
    }

    /// `R` and `C` carry a similarity score and are followed by two paths,
    /// which is what lets a row show `old → new`.
    @Test func aRenameAndACopyCarryThePathTheyCameFrom() {
        let output = "R100\(nul)old.ts\(nul)new.ts\(nul)C075\(nul)source.ts\(nul)copy.ts\(nul)"

        let entries = GitBranchReviewParser.parseNameStatus(output)

        #expect(entries[0] == GitBranchReviewParser.FileEntry(path: "new.ts", previousPath: "old.ts", status: .renamed))
        #expect(entries[1] == GitBranchReviewParser.FileEntry(path: "copy.ts", previousPath: "source.ts", status: .copied))
    }

    // The two halves joined

    /// The whole fixture, exactly as git printed it for a branch that
    /// modified a file, added two, and renamed one with an accent in its
    /// name.
    @Test func statusesAndCountsJoinIntoTheFileList() {
        let nameStatus = [
            "M", "a.txt",
            "A", "added.txt",
            "A", "blob.bin",
            "R100", "arquivo-ação.ts", "renamed-ação.ts",
        ].joined(separator: nul) + nul

        let numstat = "1\t0\ta.txt\(nul)2\t0\tadded.txt\(nul)-\t-\tblob.bin\(nul)0\t0\t\(nul)arquivo-ação.ts\(nul)renamed-ação.ts\(nul)"

        let files = GitBranchReviewParser.files(nameStatus: nameStatus, numstat: numstat)

        #expect(files.map(\.path) == ["a.txt", "added.txt", "blob.bin", "renamed-ação.ts"])
        #expect(files[0].addedLines == 1)
        #expect(files[1].status == .added)

        #expect(files[2].isBinary)
        #expect(files[2].addedLines == nil)

        #expect(files[3].status == .renamed)
        #expect(files[3].previousPath == "arquivo-ação.ts")
        #expect(files[3].addedLines == 0)
    }

    /// `-c core.quotePath=false` and `-z` between them mean a path with an
    /// accent arrives as itself. Without them git writes
    /// `"arquivo-a\303\247\303\243o.ts"`, quotes included, and every path
    /// comparison downstream misses.
    @Test func anAccentedPathIsNotEscaped() {
        let files = GitBranchReviewParser.files(
            nameStatus: "M\(nul)arquivo-ação.ts\(nul)",
            numstat: "1\t1\tarquivo-ação.ts\(nul)"
        )

        #expect(files.map(\.path) == ["arquivo-ação.ts"])
        #expect(files[0].addedLines == 1)
    }

    /// Truncated output — a killed `git`, a timeout — must not read past
    /// the end of what arrived.
    @Test func aHalfWrittenRenameIsDroppedRatherThanGuessed() {
        #expect(GitBranchReviewParser.parseNameStatus("R100\(nul)old.ts\(nul)").isEmpty)
        #expect(GitBranchReviewParser.parseNumstat("0\t0\t\(nul)old.ts\(nul)").isEmpty)
        #expect(GitBranchReviewParser.parseNameStatus("M\(nul)").isEmpty)
    }
}

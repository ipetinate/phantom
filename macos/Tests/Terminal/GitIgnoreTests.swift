import Foundation
@testable import Ghostty
import Testing

/// Writing a path into `.gitignore`.
///
/// The interesting cases are all about the line being *narrow* enough: an
/// unanchored or unescaped entry ignores more than the reader pointed at, and
/// they find out weeks later when a file they wanted is missing from a diff.
struct GitIgnoreTests {
    // MARK: The line

    /// Anchored, so it means this path and not every path ending this way.
    /// Unanchored, ignoring `src/config.ts` also ignores
    /// `vendor/lib/src/config.ts`.
    @Test func aFileIsAnchoredToTheRepositoryRoot() {
        #expect(GitIgnore.line(forRelativePath: "src/config.ts", isDirectory: false) == "/src/config.ts")
    }

    /// Git's own way of saying "the directory and everything in it", and it
    /// also stops the pattern matching a *file* of that name elsewhere.
    @Test func aDirectoryGetsATrailingSlash() {
        #expect(GitIgnore.line(forRelativePath: "build", isDirectory: true) == "/build/")
    }

    @Test func aLeadingOrTrailingSlashInTheInputIsNotDoubled() {
        #expect(GitIgnore.line(forRelativePath: "/dist/", isDirectory: true) == "/dist/")
    }

    /// A file really can be called `report[1].csv`. Unescaped, that entry
    /// ignores `report1.csv` and not the file the reader pointed at.
    @Test func charactersGitWouldReadAsAPatternAreEscaped() {
        #expect(GitIgnore.line(forRelativePath: "report[1].csv", isDirectory: false) == "/report\\[1\\].csv")
        #expect(GitIgnore.line(forRelativePath: "a*b?.log", isDirectory: false) == "/a\\*b\\?.log")
    }

    @Test func anEmptyPathProducesNoLine() {
        #expect(GitIgnore.line(forRelativePath: "/", isDirectory: false).isEmpty)
    }

    // MARK: Appending

    @Test func aLineIsAddedToAnEmptyFile() {
        #expect(GitIgnore.appending("/build/", to: "") == "/build/\n")
    }

    @Test func aLineIsAddedAfterExistingOnes() {
        #expect(GitIgnore.appending("/dist", to: "node_modules\n") == "node_modules\n/dist\n")
    }

    /// A file whose last line has no terminator would otherwise get the new
    /// entry glued onto it, producing one wrong pattern out of two right ones.
    @Test func aFileWithNoTrailingNewlineGetsOneFirst() {
        #expect(GitIgnore.appending("/dist", to: "node_modules") == "node_modules\n/dist\n")
    }

    @Test func anEntryAlreadyPresentIsNotAddedTwice() {
        #expect(GitIgnore.appending("/dist", to: "node_modules\n/dist\n") == nil)
    }

    @Test func anExistingEntryIsRecognisedThroughSurroundingSpace() {
        #expect(GitIgnore.alreadyContains("/dist", in: "node_modules\n  /dist  \n"))
    }

    /// Only an exact line is recognised. Deciding whether an existing
    /// *pattern* covers the path would mean implementing gitignore matching,
    /// and getting that subtly wrong would silently decline to add an entry
    /// the reader asked for — a duplicate line is harmless, a missing one is
    /// the bug. Stated as a test so the limit is deliberate rather than
    /// discovered.
    @Test func aPatternThatWouldCoverThePathIsNotTreatedAsPresent() {
        #expect(GitIgnore.appending("/dist", to: "*\n") == "*\n/dist\n")
    }

    @Test func anEmptyLineIsNeverWritten() {
        #expect(GitIgnore.appending("", to: "node_modules\n") == nil)
    }

    // MARK: Against a real file

    @Test func theFileIsCreatedWhenItIsNotThere() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitIgnoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(GitIgnore.add(relativePath: "build", isDirectory: true, inRepositoryAt: root.path))

        let written = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(written == "/build/\n")

        /// Second time reports false rather than writing again, which is what
        /// lets the caller stay quiet instead of claiming it did something.
        #expect(!GitIgnore.add(relativePath: "build", isDirectory: true, inRepositoryAt: root.path))
    }
}

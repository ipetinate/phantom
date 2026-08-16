import Foundation
@testable import Ghostty
import Testing

/// Deciding whether a document has changes worth diffing.
///
/// The interesting cases are all about *which* repository is answering: a
/// workspace with a submodule has the same file under two roots, and only
/// the inner one can see inside it.
struct EditorChangeLookupTests {
    private func change(
        _ path: String,
        from originalPath: String? = nil,
        index: Character = "M",
        worktree: Character = ".",
        untracked: Bool = false,
        unmerged: Bool = false
    ) -> GitFileChange {
        GitFileChange(
            path: path,
            originalPath: originalPath,
            index: index,
            worktree: worktree,
            isUntracked: untracked,
            isUnmerged: unmerged
        )
    }

    // MARK: Which repository owns the file

    @Test func theInnermostRepositoryWins() {
        let root = EditorChangeLookup.owningRoot(
            forPath: "/w/app/vendor/lib/src/main.swift",
            amongRoots: ["/w/app", "/w/app/vendor/lib"]
        )
        #expect(root == "/w/app/vendor/lib")
    }

    /// The same question with the roots in the other order. A `first(where:)`
    /// implementation passes one of these two tests and fails the other,
    /// which is the failure this pair exists to catch — dictionary order is
    /// not stable across launches, so that bug reproduces intermittently.
    @Test func theInnermostRepositoryWinsWhateverOrderTheRootsArrive() {
        let root = EditorChangeLookup.owningRoot(
            forPath: "/w/app/vendor/lib/src/main.swift",
            amongRoots: ["/w/app/vendor/lib", "/w/app"]
        )
        #expect(root == "/w/app/vendor/lib")
    }

    /// A sibling whose name merely starts the same way. Plain `hasPrefix`
    /// says `/tmp/app` owns this file; it does not.
    @Test func aRootIsNotClaimedByANameThatMerelyStartsTheSame() {
        #expect(!EditorChangeLookup.isDescendant(path: "/tmp/apple/main.swift", ofRoot: "/tmp/app"))
        #expect(EditorChangeLookup.owningRoot(forPath: "/tmp/apple/main.swift", amongRoots: ["/tmp/app"]) == nil)
    }

    @Test func aTrailingSlashOnTheRootChangesNothing() {
        #expect(EditorChangeLookup.isDescendant(path: "/w/app/a.swift", ofRoot: "/w/app/"))
        #expect(EditorChangeLookup.relativePath(forPath: "/w/app/a.swift", root: "/w/app/") == "a.swift")
    }

    @Test func aFileOutsideEveryRepositoryHasNoOwner() {
        #expect(EditorChangeLookup.owningRoot(forPath: "/etc/hosts", amongRoots: ["/w/app"]) == nil)
    }

    // MARK: The path as git names it

    @Test func theRelativePathIsWhatGitWouldPrint() {
        #expect(
            EditorChangeLookup.relativePath(forPath: "/w/app/Sources/main.swift", root: "/w/app")
                == "Sources/main.swift"
        )
    }

    /// The root itself is a directory, not a file git would ever list.
    @Test func theRootItselfHasNoRelativePath() {
        #expect(EditorChangeLookup.relativePath(forPath: "/w/app", root: "/w/app") == nil)
    }

    // MARK: What counts as changed

    @Test func aStagedFileHasChanges() {
        let status = GitStatus(staged: [change("a.swift")])
        #expect(EditorChangeLookup.hasChanges(relativePath: "a.swift", in: status))
    }

    @Test func anUnstagedFileHasChanges() {
        let status = GitStatus(unstaged: [change("a.swift", index: ".", worktree: "M")])
        #expect(EditorChangeLookup.hasChanges(relativePath: "a.swift", in: status))
    }

    @Test func aConflictedFileHasChanges() {
        let status = GitStatus(unmerged: [change("a.swift", index: "U", worktree: "U", unmerged: true)])
        #expect(EditorChangeLookup.hasChanges(relativePath: "a.swift", in: status))
    }

    /// An untracked file has no revision to compare against, so a diff would
    /// render the whole file as additions — telling the reader nothing they
    /// were not already looking at.
    @Test func anUntrackedFileIsNotOfferedADiff() {
        let status = GitStatus(unstaged: [change("new.swift", untracked: true)])
        #expect(!EditorChangeLookup.hasChanges(relativePath: "new.swift", in: status))
    }

    /// After `git mv` the entry names the destination, and that is exactly
    /// when a reader wants to see what else changed along with the move.
    @Test func aRenamedFileMatchesOnBothOfItsNames() {
        let status = GitStatus(staged: [change("new/a.swift", from: "old/a.swift", index: "R")])
        #expect(EditorChangeLookup.hasChanges(relativePath: "new/a.swift", in: status))
        #expect(EditorChangeLookup.hasChanges(relativePath: "old/a.swift", in: status))
    }

    @Test func anUnchangedFileInAChangedRepositoryHasNoChanges() {
        let status = GitStatus(staged: [change("a.swift")])
        #expect(!EditorChangeLookup.hasChanges(relativePath: "b.swift", in: status))
    }

    /// A path that merely ends the same way. The comparison is whole-path,
    /// not suffix — `Sources/a.swift` changing does not mean `a.swift` did.
    @Test func aPathIsNotMatchedByItsTail() {
        let status = GitStatus(staged: [change("Sources/a.swift")])
        #expect(!EditorChangeLookup.hasChanges(relativePath: "a.swift", in: status))
    }

    // MARK: Which side of the index to diff against

    /// A file edited after it was staged is in both lists and has two
    /// different diffs. The working tree is the one the reader has in the
    /// pane beside it, so that is the one to show.
    @Test func aFileStagedAndThenEditedDiffsAgainstTheWorkingTree() {
        let status = GitStatus(
            staged: [change("a.swift", index: "M", worktree: "M")],
            unstaged: [change("a.swift", index: "M", worktree: "M")]
        )
        #expect(EditorChangeLookup.change(relativePath: "a.swift", in: status)?.side == .unstaged)
    }

    @Test func aFileOnlyStagedDiffsAgainstTheIndex() {
        let status = GitStatus(staged: [change("a.swift", index: "M", worktree: ".")])
        #expect(EditorChangeLookup.change(relativePath: "a.swift", in: status)?.side == .staged)
    }

    /// A conflict outranks both, because neither ordinary diff describes it.
    @Test func aConflictIsReportedAheadOfEitherOrdinarySide() {
        let conflicted = change("a.swift", index: "U", worktree: "U", unmerged: true)
        let status = GitStatus(staged: [change("a.swift")], unmerged: [conflicted])
        #expect(EditorChangeLookup.change(relativePath: "a.swift", in: status)?.change.isUnmerged == true)
    }

    @Test func anUntrackedEntryIsNotOfferedAsASideToDiff() {
        let status = GitStatus(unstaged: [change("new.swift", untracked: true)])
        #expect(EditorChangeLookup.change(relativePath: "new.swift", in: status) == nil)
    }

    // MARK: Finding the repository from the file

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditorChangeLookupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theRepositoryIsFoundByWalkingUpFromTheFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        /// Compared as paths, not as URLs: `URL(fileURLWithPath:)` stats
        /// the filesystem and puts a trailing slash on a directory that
        /// exists, so two spellings of the same place stop being equal.
        let found = EditorChangeLookup.repositoryRoot(forPath: nested.appendingPathComponent("a.swift").path)
        #expect(found == root.path)
    }

    /// In a worktree or a submodule, `.git` is a **file** holding a
    /// `gitdir:` pointer. Requiring a directory would quietly exclude
    /// exactly the checkouts people do parallel work in.
    @Test func aWorktreeWhoseGitIsAFileIsStillARepository() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "gitdir: /elsewhere/.git/worktrees/w\n"
            .write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let found = EditorChangeLookup.repositoryRoot(forPath: root.appendingPathComponent("a.swift").path)
        #expect(found == root.path)
    }

    @Test func aFileInNoRepositoryFindsNothing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(EditorChangeLookup.repositoryRoot(
            forPath: root.appendingPathComponent("a.swift").path,
            maximumDepth: 3
        ) == nil)
    }

    /// The walk has to stop. `/` is its own parent, and a loop that only
    /// exits on finding `.git` never exits for a file outside a repository.
    @Test func theWalkStopsAtTheRootOfTheFilesystem() {
        #expect(EditorChangeLookup.repositoryRoot(forPath: "/a.swift", maximumDepth: 4) == nil)
    }
}

import Foundation
@testable import Ghostty
import Testing

/// `WorktreeDivergence.verdict` over the layouts a worktree switch leaves
/// behind.
///
/// Fixtures built by hand, like `GitCommonDirTests`': the rule reads `.git`
/// files, `commondir` pointers and `HEAD` and runs no git, so the fixtures
/// are those files and nothing else. A real repository would pass these even
/// if the rule quietly grew a `rev-parse`, and it must not — this answer is
/// asked for every open tab whenever the tab bar redraws.
struct WorktreeDivergenceTests {
    /// A main checkout with one linked worktree beside it, spelled the way
    /// `git worktree add` spells it.
    private final class Fixture {
        let root: String

        /// The main checkout, on `main`.
        let main: String

        /// A linked worktree of it, on `feat-a`.
        let linked: String

        init(linkedBranch: String = "feat-a", mainHead: String = "ref: refs/heads/main") {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("phantom-divergence-\(UUID().uuidString)")
                .path
            root = base
            main = (base as NSString).appendingPathComponent("repo")
            linked = (base as NSString)
                .appendingPathComponent("worktrees/repo-\(linkedBranch)")

            directory("")
            directory("repo/.git")
            file("repo/.git/HEAD", mainHead)

            let administrative = "repo/.git/worktrees/\(linkedBranch)"
            directory(administrative)
            file("\(administrative)/HEAD", "ref: refs/heads/\(linkedBranch)")
            file("\(administrative)/commondir", "../..")

            directory("worktrees/repo-\(linkedBranch)")
            file("worktrees/repo-\(linkedBranch)/.git", "gitdir: \(path(administrative))")
        }

        deinit {
            try? FileManager.default.removeItem(atPath: root)
        }

        func path(_ relative: String) -> String {
            relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
        }

        @discardableResult
        func directory(_ relative: String) -> String {
            let full = path(relative)
            try? FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            return full
        }

        @discardableResult
        func file(_ relative: String, _ contents: String = "") -> String {
            let full = path(relative)
            directory((relative as NSString).deletingLastPathComponent)
            try? contents.write(toFile: full, atomically: true, encoding: .utf8)
            return full
        }

        /// A second, unrelated repository — its own object store, its own
        /// everything.
        @discardableResult
        func otherRepository(_ name: String) -> String {
            directory("\(name)/.git")
            file("\(name)/.git/HEAD", "ref: refs/heads/main")
            return path(name)
        }
    }

    // MARK: Nothing to say

    /// The overwhelmingly ordinary case: the file you are editing is in the
    /// tree your shell is in.
    @Test func aFileInsideTheTerminalsDirectoryIsNotDivergent() {
        let fixture = Fixture()
        let document = fixture.file("repo/src/main.swift", "let x = 1")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main) == nil)
    }

    /// The same checkout reached from below it. The shell is in a
    /// subdirectory, the file is nearer the root, so the cheap descendant
    /// test does not fire and the walk has to agree with it.
    @Test func aFileAboveTheTerminalsDirectoryInTheSameCheckoutIsNotDivergent() {
        let fixture = Fixture()
        let document = fixture.file("repo/README.md", "# repo")
        fixture.directory("repo/src")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.path("repo/src")) == nil)
    }

    /// Two repositories that share nothing. Also "not from the terminal's
    /// worktree", and the one case where saying so would be wrong: nothing
    /// switched and there is no other copy to offer.
    @Test func aFileFromAnotherRepositoryIsNotDivergent() {
        let fixture = Fixture()
        fixture.otherRepository("unrelated")
        let document = fixture.file("unrelated/notes.md", "hello")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main) == nil)
    }

    /// A scratch file in no repository at all.
    @Test func aFileInNoRepositoryIsNotDivergent() {
        let fixture = Fixture()
        let document = fixture.file("scratch/notes.txt", "hello")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main) == nil)
    }

    /// A submodule shares no object store with the superproject, so it is
    /// another repository however much it looks nested.
    @Test func aFileInASubmoduleIsNotDivergent() {
        let fixture = Fixture()
        fixture.directory("repo/.git/modules/sub")
        fixture.file("repo/.git/modules/sub/HEAD", "ref: refs/heads/main")
        fixture.file("repo/sub/.git", "gitdir: \(fixture.path("repo/.git/modules/sub"))")
        let document = fixture.file("repo/sub/lib.swift", "let y = 2")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.linked) == nil)
    }

    /// No working directory reported yet — a surface that has never sent
    /// OSC 7. Nothing to compare against, so nothing is claimed.
    @Test func withoutATerminalDirectoryNothingIsDivergent() {
        let fixture = Fixture()
        let document = fixture.file("repo/src/main.swift", "let x = 1")

        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: nil) == nil)
        #expect(WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: "") == nil)
    }

    // MARK: Divergent, with a copy to offer

    @Test func aFileFromASiblingWorktreeIsDivergent() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")
        let counterpart = fixture.file("repo/src/main.swift", "let x = 0")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        #expect(verdict?.documentRoot == fixture.linked)
        #expect(verdict?.terminalRoot == fixture.main)
        #expect(verdict?.relativePath == "src/main.swift")
        #expect(verdict?.counterpart == counterpart)
        #expect(verdict?.isReadOnly == false)
    }

    /// The same fact from the other direction: the document in the main
    /// checkout, the terminal in the linked worktree. Both resolve to the
    /// same family, so the answer must not depend on which side is which.
    @Test func theMainCheckoutDivergesFromALinkedWorktreeToo() {
        let fixture = Fixture()
        let document = fixture.file("repo/src/main.swift", "let x = 0")
        fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.linked)

        #expect(verdict?.documentRoot == fixture.main)
        #expect(verdict?.terminalRoot == fixture.linked)
        #expect(verdict?.isReadOnly == false)
    }

    /// The branch names come off `HEAD`, and they are what the banner says.
    @Test func theVerdictNamesBothBranches() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")
        fixture.file("repo/src/main.swift", "let x = 0")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        #expect(verdict?.documentBranch == "feat-a")
        #expect(verdict?.terminalBranch == "main")
        #expect(verdict?.documentName == "feat-a")
        #expect(verdict?.terminalName == "main")
    }

    /// A path several levels down still resolves against the document's own
    /// root, which is what makes the counterpart the *same* file rather than
    /// a similarly named one.
    @Test func aNestedPathKeepsItsWholeRelativePath() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/a/b/c.swift", "let x = 1")
        let counterpart = fixture.file("repo/a/b/c.swift", "let x = 0")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        #expect(verdict?.relativePath == "a/b/c.swift")
        #expect(verdict?.counterpart == counterpart)
    }

    /// The terminal need not be sitting at its worktree's root — a shell is
    /// usually somewhere inside it.
    @Test func theTerminalIsFoundFromASubdirectoryOfItsWorktree() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")
        fixture.file("repo/src/main.swift", "let x = 0")
        fixture.directory("repo/deep/deeper")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.path("repo/deep/deeper"))

        #expect(verdict?.terminalRoot == fixture.main)
    }

    // MARK: Divergent with nothing to offer, which is read-only

    /// `stayMissing`: the file exists on the branch the tab came from and
    /// nowhere else.
    @Test func aFileTheTerminalsCheckoutDoesNotHaveIsReadOnly() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/src/added.swift", "let x = 1")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        #expect(verdict?.counterpart == nil)
        #expect(verdict?.isReadOnly == true)
    }

    /// A directory where the file should be is not a file, and offering it
    /// would open a buffer over a folder.
    @Test func aDirectoryAtTheCounterpartPathStillCountsAsPresent() {
        let fixture = Fixture()
        let document = fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")
        fixture.directory("repo/src/main.swift")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        /// Deliberately *not* read-only. `fileExists` says yes for a
        /// directory, and this documents which way that falls: the reader is
        /// offered it and git — or the open guard — refuses on its own terms,
        /// which is a better failure than a read-only banner over a file that
        /// is plainly there in the other checkout.
        #expect(verdict?.isReadOnly == false)
    }

    // MARK: Naming a checkout

    @Test func aBranchNameIsWhatACheckoutIsCalled() {
        #expect(WorktreeDivergence.name(ofRoot: "/w/repo-feat-a", branch: "feat/a") == "feat/a")
    }

    @Test func withNoBranchTheFolderNamesTheCheckout() {
        #expect(WorktreeDivergence.name(ofRoot: "/w/repo-feat-a", branch: nil) == "repo-feat-a")
        #expect(WorktreeDivergence.name(ofRoot: "/w/repo-feat-a", branch: "") == "repo-feat-a")
    }

    /// A detached HEAD reaches this as the abbreviated hash `gitInfo` falls
    /// back to, and seven hex characters tell the reader nothing about which
    /// checkout is meant. The folder does.
    @Test func aDetachedHeadIsNamedByItsFolderRatherThanItsHash() {
        #expect(WorktreeDivergence.name(ofRoot: "/w/repo-feat-a", branch: "1a2b3c4") == "repo-feat-a")
    }

    /// A real branch that happens to be seven characters long is still a
    /// branch — the hash test may not be so eager that it swallows one.
    @Test func aShortBranchNameThatIsNotHexSurvives() {
        #expect(WorktreeDivergence.name(ofRoot: "/w/repo-release", branch: "release") == "release")
    }

    /// The detached-HEAD case end to end, so the fallback is reached by the
    /// path the app takes rather than only by a direct call.
    @Test func aDetachedTerminalCheckoutIsNamedByItsFolder() {
        let fixture = Fixture(mainHead: "1a2b3c4d5e6f7a8b9c0d")
        let document = fixture.file("worktrees/repo-feat-a/src/main.swift", "let x = 1")
        fixture.file("repo/src/main.swift", "let x = 0")

        let verdict = WorktreeDivergence.verdict(
            documentPath: document, terminalDirectory: fixture.main)

        #expect(verdict?.terminalBranch == "1a2b3c4")
        #expect(verdict?.terminalName == "repo")
    }
}
